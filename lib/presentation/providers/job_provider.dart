import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/build_config.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/persistence/board_resume.dart';
import '../../core/persistence/metadata_schema.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../data/models/author.dart';
import '../../data/models/board.dart';
import '../../data/models/board_section.dart';
import '../../data/models/board_selection.dart';
import '../../data/models/history_item.dart';
import '../../data/models/job_state.dart';
import '../../data/models/media_result.dart';
import '../../data/models/pin_item.dart';
import '../../data/models/user_pins_result.dart';
import '../../data/services/download_service.dart';
import '../../data/services/hls_converter.dart';
import '../../data/services/hls_service.dart';
import '../../data/services/log_service.dart';
import '../../data/controllers/board_controller.dart';
import '../../data/controllers/download_coordinator.dart';
import '../../data/controllers/extraction_controller.dart';
import '../../data/services/pinterest_extractor_service.dart';
import '../../data/services/task_state_persistence.dart';
import '../../data/models/background_task_state.dart';
import '../utils/error_messages.dart';
import 'history_provider.dart';
import 'log_provider.dart';
import 'foreground_service_manager.dart';

/// App job state for the new submit->info->download flow
/// Phase A: idle
/// Phase B: fetchingInfo (isExtracting = true)
/// Phase C: readyToDownload (hasResults = true, canDownload = true)
/// Phase D: downloading (isDownloading = true)
/// Phase E: completed / failed / cancelled
class AppJobState {
  final JobStatus status;
  final String? input;
  final bool isUsername;
  final Author? author;
  final List<PinItem> pins;
  final int totalImages;
  final int totalVideos;
  final MediaResult? singlePinResult;
  final int downloadedCount;
  final int skippedCount;
  final int failedCount;
  final int currentIndex;
  final String? error;
  
  // Resume/continue mode stats (loaded from previous metadata)
  final int previousDownloaded;
  final int previousSkipped;
  final int previousFailed;
  final int lastIndexDownloaded;
  final bool wasInterrupted;
  final bool isContinueMode;
  /// The media type that was used in the previous download session.
  /// Used to determine which remaining getter should apply lastIndexDownloaded.
  /// e.g. if previousMediaType == 'image', only remainingImages subtracts; remainingVideos returns totalVideos.
  final String? previousMediaType;
  /// Per-media-type completion flags (in-memory, derived from download results or metadata).
  /// Used by UI to disable download button for a type that's already fully downloaded.
  final bool imagesFullyDownloaded;
  final bool videosFullyDownloaded;
  /// v2 metadata: the previous session's authoritative completion set
  /// (success | explicit skip indices). Empty for v1 files (counter
  /// semantics — documented degradation, D-04 contract).
  final Set<int> previousCompletedIndices;

  /// Phase 07 (07.5, D-34): capped-extraction continuation. Non-null only
  /// when the last feed extraction hit the page cap with more pages pending;
  /// travels with its full request context or not at all.
  final String? nextBookmark;
  final BookmarkContext? bookmarkContext;

  // ---- Phase 10 (D-38): board flow context — additive; feed flows never
  // read these. One board at a time through the SAME state machine.

  /// Boards discovered for the current username (display order;
  /// caller sorts pinCount desc per the boards-ux plan).
  final List<Board> discoveredBoards;

  /// True while board discovery is running (Phase B for boards mode).
  final bool isDiscoveringBoards;

  /// Sections fetched per boardId (lazy, via loadBoardSections).
  final Map<String, List<BoardSection>> boardSections;

  /// The user's Whole/Sections/Skip selection (drives the board jobs).
  final BoardSelection boardSelection;

  const AppJobState({
    this.status = JobStatus.idle,
    this.input,
    this.isUsername = false,
    this.author,
    this.pins = const [],
    this.totalImages = 0,
    this.totalVideos = 0,
    this.singlePinResult,
    this.downloadedCount = 0,
    this.skippedCount = 0,
    this.failedCount = 0,
    this.currentIndex = 0,
    this.error,
    this.previousDownloaded = 0,
    this.previousSkipped = 0,
    this.previousFailed = 0,
    this.lastIndexDownloaded = -1,
    this.wasInterrupted = false,
    this.isContinueMode = false,
    this.previousMediaType,
    this.imagesFullyDownloaded = false,
    this.videosFullyDownloaded = false,
    this.previousCompletedIndices = const {},
    this.nextBookmark,
    this.bookmarkContext,
    this.discoveredBoards = const [],
    this.isDiscoveringBoards = false,
    this.boardSections = const {},
    this.boardSelection = const BoardSelection(choices: []),
  });

  /// Derived state: is currently fetching info (Phase B)
  bool get isExtracting => status == JobStatus.fetchingInfo;
  
  /// Derived state: is currently downloading (Phase D)
  bool get isDownloading => status == JobStatus.downloading;
  
  /// Derived state: has extracted results ready
  /// Includes failed/cancelled states to preserve preview
  bool get hasResults => 
      (status == JobStatus.readyToDownload || 
       status == JobStatus.downloading || 
       status == JobStatus.completed ||
       status == JobStatus.failed ||
       status == JobStatus.cancelled) &&
      (pins.isNotEmpty || singlePinResult != null);
  
  /// Derived state: can start download (Phase C or after completion)
  /// Allows re-download after completion (e.g. user switches media type on single pin)
  bool get canDownload => 
      (status == JobStatus.readyToDownload || status == JobStatus.completed) && 
      (pins.isNotEmpty || singlePinResult != null);
  
  /// Derived state: can submit new request
  bool get canSubmit => 
      status == JobStatus.idle || 
      status == JobStatus.completed || 
      status == JobStatus.failed || 
      status == JobStatus.cancelled ||
      status == JobStatus.readyToDownload;

  int get totalItems => pins.length;

  /// Phase 07 (07.5, D-34): "Fetch more" is available only when the last
  /// capped extraction left a resumable bookmark + provenance context.
  bool get canFetchMore =>
      nextBookmark != null &&
      bookmarkContext != null &&
      (status == JobStatus.readyToDownload || status == JobStatus.completed);
  
  /// Calculate remaining items for continue mode.
  /// Uses accumulated download counts (success + skipped + failed) from metadata
  /// to determine how many items are left. Only applies when previous session
  /// was for the same media type.
  int get remainingImages {
    if (!isContinueMode) return totalImages;
    if (previousMediaType != null && previousMediaType != 'image') return totalImages;
    final processed = previousDownloaded + previousSkipped + previousFailed;
    return (totalImages - processed).clamp(0, totalImages);
  }
  
  int get remainingVideos {
    if (!isContinueMode) return totalVideos;
    if (previousMediaType != null && previousMediaType != 'video') return totalVideos;
    final processed = previousDownloaded + previousSkipped + previousFailed;
    return (totalVideos - processed).clamp(0, totalVideos);
  }

  AppJobState copyWith({
    JobStatus? status,
    String? input,
    bool? isUsername,
    Author? author,
    List<PinItem>? pins,
    int? totalImages,
    int? totalVideos,
    MediaResult? singlePinResult,
    int? downloadedCount,
    int? skippedCount,
    int? failedCount,
    int? currentIndex,
    String? error,
    int? previousDownloaded,
    int? previousSkipped,
    int? previousFailed,
    int? lastIndexDownloaded,
    bool? wasInterrupted,
    bool? isContinueMode,
    String? previousMediaType,
    bool? imagesFullyDownloaded,
    bool? videosFullyDownloaded,
    Set<int>? previousCompletedIndices,
    String? nextBookmark,
    BookmarkContext? bookmarkContext,
    List<Board>? discoveredBoards,
    bool? isDiscoveringBoards,
    Map<String, List<BoardSection>>? boardSections,
    BoardSelection? boardSelection,
  }) {
    return AppJobState(
      status: status ?? this.status,
      input: input ?? this.input,
      isUsername: isUsername ?? this.isUsername,
      author: author ?? this.author,
      pins: pins ?? this.pins,
      totalImages: totalImages ?? this.totalImages,
      totalVideos: totalVideos ?? this.totalVideos,
      singlePinResult: singlePinResult ?? this.singlePinResult,
      downloadedCount: downloadedCount ?? this.downloadedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      failedCount: failedCount ?? this.failedCount,
      currentIndex: currentIndex ?? this.currentIndex,
      error: error ?? this.error,
      previousDownloaded: previousDownloaded ?? this.previousDownloaded,
      previousSkipped: previousSkipped ?? this.previousSkipped,
      previousFailed: previousFailed ?? this.previousFailed,
      lastIndexDownloaded: lastIndexDownloaded ?? this.lastIndexDownloaded,
      wasInterrupted: wasInterrupted ?? this.wasInterrupted,
      isContinueMode: isContinueMode ?? this.isContinueMode,
      previousMediaType: previousMediaType ?? this.previousMediaType,
      imagesFullyDownloaded: imagesFullyDownloaded ?? this.imagesFullyDownloaded,
      videosFullyDownloaded: videosFullyDownloaded ?? this.videosFullyDownloaded,
      previousCompletedIndices: previousCompletedIndices ?? this.previousCompletedIndices,
      nextBookmark: nextBookmark ?? this.nextBookmark,
      bookmarkContext: bookmarkContext ?? this.bookmarkContext,
      discoveredBoards: discoveredBoards ?? this.discoveredBoards,
      isDiscoveringBoards: isDiscoveringBoards ?? this.isDiscoveringBoards,
      boardSections: boardSections ?? this.boardSections,
      boardSelection: boardSelection ?? this.boardSelection,
    );
  }

  AppJobState reset() {
    return const AppJobState();
  }
}

/// Job notifier for managing extraction and download state
/// Enforces strict state machine: idle -> fetchingInfo -> readyToDownload -> downloading -> completed
class JobNotifier extends StateNotifier<AppJobState> {
  final LogService _logService;
  final PinterestExtractorService _extractor;
  final ExtractionController _extraction;
  late final BoardController _boards;
  final DownloadService _downloadService;
  late final DownloadCoordinator _download;
  final HlsService? _hlsService;
  final HlsConverter? _hlsConverter;
  final TaskStatePersistence? _persistence;
  final void Function({
    required String filename,
    required String url,
    required HistoryStatus status,
    String? errorMessage,
  })? _onDownloadComplete;
  
  /// Callback when a task (extraction/download) starts
  void Function()? onTaskStarted;
  /// Callback when a task completes, with task type ('extraction'/'download')
  void Function({required String taskType})? onTaskCompleted;
  /// Callback for extraction page progress (for notification updates)
  void Function({
    required String username,
    required int itemCount,
    required int currentPage,
    required int maxPage,
  })? onExtractionProgress;
  /// Callback when a short URL is resolved to a canonical input.
  /// UI should update the input field and media type selection accordingly.
  void Function({required String resolvedInput, required bool isUsername})? onInputResolved;
  
  // Method channel for MediaStore operations
  static const _mediaChannel = MethodChannel('com.motebaya.pindl/media');
  
  CancelToken? _extractCancelToken;
  CancelToken? _downloadCancelToken;
  CancelToken? _boardCancelToken;

  /// Active board discovery token captured for cancelBoardDiscovery.
  CancelToken? get boardCancelToken => _boardCancelToken;
  
  JobNotifier({
    required LogService logService,
    required PinterestExtractorService extractor,
    required DownloadService downloadService,
    HlsService? hlsService,
    HlsConverter? hlsConverter,
    TaskStatePersistence? persistence,
    void Function({
      required String filename,
      required String url,
      required HistoryStatus status,
      String? errorMessage,
    })? onDownloadComplete,
  })  : _logService = logService,
        _extractor = extractor,
        _extraction = ExtractionController(
          extractor: extractor,
          log: ControllerLog(
            init: logService.init,
            fetch: logService.fetch,
            parse: logService.parse,
            config: logService.config,
            queue: logService.queue,
            complete: logService.complete,
          ),
        ),
    _downloadService = downloadService,
    _boards = BoardController(
      extractor: extractor,
      log: ControllerLog(
        init: logService.init,
        fetch: logService.fetch,
        parse: logService.parse,
        config: logService.config,
        queue: logService.queue,
        complete: logService.complete,
      ),
    ),
    // Only instantiate HLS services when FFmpeg is enabled (compile-time const).
        // Tree-shaking eliminates HlsService/HlsConverter from lite AOT binaries.
        _hlsService = BuildConfig.enableFfmpeg ? (hlsService ?? HlsService()) : null,
        _hlsConverter = BuildConfig.enableFfmpeg ? (hlsConverter ?? HlsConverter()) : null,
        _persistence = persistence,
        _onDownloadComplete = onDownloadComplete,
        super(const AppJobState()) {
    _download = DownloadCoordinator(
      downloadService: _downloadService,
      hlsService: _hlsService,
      hlsConverter: _hlsConverter,
      hooks: DownloadCoordinatorHooks(
        queue: _logService.queue,
        downloading: _logService.downloading,
        saved: _logService.saved,
        skipped: _logService.skipped,
        failed: _logService.error,
        parse: _logService.parse,
        error: _logService.error,
        interrupted: _logService.interrupted,
        complete: _logService.complete,
        onFfmpegLog: (log) {
          // Only log important messages (not every frame)
          if (log.contains('frame=') && log.contains('fps=')) {
            // Skip verbose frame logs
          } else if (log.isNotEmpty) {
            print('[FFmpeg] $log');
          }
        },
        onHistory: ({required filename, required url, required success, errorMessage}) {
          _onDownloadComplete?.call(
            filename: filename,
            url: url,
            status: success ? HistoryStatus.success : HistoryStatus.failed,
            errorMessage: errorMessage,
          );
        },
        mapError: userMessage,
        onPersistedProgress: ({required currentIndex, skippedCount, failedCount, failedPinId}) {
          _updatePersistedProgress(
            currentIndex: currentIndex,
            skippedCount: skippedCount,
            failedCount: failedCount,
            failedPinId: failedPinId,
          );
        },
      ),
    );
  }

  /// Start info extraction (Submit button) - Phase B
  /// This only fetches metadata, does NOT start downloading
  /// If saveMetadata is true, saves metadata immediately after parsing
  /// Start info extraction (Submit button) - Phase B
  /// This only fetches metadata, does NOT start downloading.
  /// If saveMetadata is true, saves metadata immediately after parsing.
  ///
  /// Phase 08 (08.1): pipeline extracted to the widget-free/channel-free
  /// ExtractionController (lib/data/controllers/); this method is the
  /// state-machine adapter: pre-flight, hook wiring, state transitions,
  /// metadata-write execution (channel stays here), outcome application.
  Future<void> startExtraction({
    required String input,
    required MediaType mediaType,
    bool saveMetadata = false,
    int maxPages = 50,
    bool verbose = false,
  }) async {
    // Update the extractor's verbose flag with the latest setting
    _extractor.verbose = verbose;

    // Validate we can start extraction
    if (state.isExtracting || state.isDownloading) {
      _logService.error('Cannot start extraction: another operation in progress');
      return;
    }

    final inputType = PinUrlValidator.detectInputType(input);
    if (inputType == null) {
      _logService.error('Invalid input: $input');
      state = state.copyWith(
        status: JobStatus.failed,
        error: 'Invalid input. Enter a username or pin URL.',
      );
      return;
    }

    _extraction.onReadyToExtract = ({
      required resolvedInput,
      required isUsername,
      required viaShortUrl,
      required mediaType,
      required maxPages,
    }) {
      _extractCancelToken = _extraction.cancelToken;
      if (!viaShortUrl) {
        state = AppJobState(
          status: JobStatus.fetchingInfo,
          input: resolvedInput,
          isUsername: isUsername,
        );
      }
      _persistExtractionState(resolvedInput, isUsername, mediaType, maxPages);
      onTaskStarted?.call();
    };
    _extraction.onResolving = (input) {
      state = AppJobState(
        status: JobStatus.fetchingInfo,
        input: input,
        isUsername: false,
      );
    };
    _extraction.onResolved = ({required resolvedInput, required isUsername}) {
      onInputResolved?.call(
          resolvedInput: resolvedInput, isUsername: isUsername);
    };
    _extraction.onProgress = ({required username, required itemCount, required currentPage, required maxPage}) {
      _persistence?.updateProgress(currentPage: currentPage, totalItems: itemCount);
      onExtractionProgress?.call(
        username: username,
        itemCount: itemCount,
        currentPage: currentPage,
        maxPage: maxPage,
      );
    };

    try {
      final outcome = await _extraction.extract(
        input: input,
        mediaType: mediaType,
        saveMetadata: saveMetadata,
        maxPages: maxPages,
      );

      if (outcome.stoppedAfterResolve) {
        // Short URL resolved to a username — stop; manual submit next
        // (state already idle via the early hook).
        state = const AppJobState(status: JobStatus.idle);
        return;
      }

      if (outcome.author != null) {
        // Parse-time metadata write (channel stays provider-side).
        final write = outcome.metadataWrite;
        if (write != null) {
          await _saveMetadata(write.subFolder, write.filename, write.json);
          _logService.saved('Metadata saved for @${outcome.author!.username}');
        }

        state = state.copyWith(
          status: JobStatus.readyToDownload,
          author: outcome.author,
          pins: outcome.pins,
          singlePinResult: outcome.singlePinResult,
          totalImages: outcome.totalImages,
          totalVideos: outcome.totalVideos,
          nextBookmark: outcome.nextBookmark,
          bookmarkContext: outcome.bookmarkContext,
        );

        // Extraction completed successfully — notify foreground service
        // so it can show completion notification (identical to download completion)
        if (state.status == JobStatus.readyToDownload) {
          onTaskCompleted?.call(taskType: 'extraction');
        }
        if (outcome.singlePinResult != null) {
          _logService.complete('Info loaded for pin ${outcome.pins.first.pinId}. Ready to download.');
        } else {
          _logService.complete('Info loaded for @${outcome.author!.username}. Ready to download.');
        }
      }
    } on CancelledException {
      if (_extraction.lastPhase == ExtractionPhase.resolve) {
        _logService.interrupted('Short URL resolution cancelled');
      } else {
        _logService.interrupted('Info loading cancelled');
      }
      state = state.copyWith(status: JobStatus.cancelled);
    } catch (e) {
      if (_extraction.lastPhase == ExtractionPhase.resolve) {
        _logService.error('Failed to resolve short URL: $e');
      } else {
        _logService.error('Failed to load info: $e');
      }
      state = state.copyWith(status: JobStatus.failed, error: userMessage(e));
    }
  }

  // ── Background task state persistence helpers ──

  /// Persist initial extraction state to Hive
  void _persistExtractionState(String input, bool isUsername, MediaType mediaType, int maxPages) {
    if (_persistence == null) return;
    final taskState = BackgroundTaskState(
      taskId: '${DateTime.now().millisecondsSinceEpoch}',
      taskType: 'extraction',
      username: isUsername ? PinUrlValidator.normalizeUsername(input) : null,
      mediaType: mediaType.name,
      maxPages: maxPages,
    );
    _persistence!.saveActiveTask(taskState);
  }

  /// Persist download state to Hive
  void _persistDownloadState(MediaType mediaType, bool overwrite, bool saveMetadata, int totalItems) {
    if (_persistence == null) return;
    final taskState = BackgroundTaskState(
      taskId: '${DateTime.now().millisecondsSinceEpoch}',
      taskType: 'download',
      username: state.author?.username,
      mediaType: mediaType.name,
      overwrite: overwrite,
      saveMetadata: saveMetadata,
      totalItems: totalItems,
    );
    _persistence!.saveActiveTask(taskState);
  }

  /// Update download progress in persisted state
  void _updatePersistedProgress({
    int? currentIndex,
    int? successCount,
    int? skippedCount,
    int? failedCount,
    int? bytesReceived,
    int? bytesTotal,
    String? currentFilename,
    String? failedPinId,
  }) {
    _persistence?.updateProgress(
      currentIndex: currentIndex,
      successCount: successCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      bytesReceived: bytesReceived,
      bytesTotal: bytesTotal,
      currentFilename: currentFilename,
      failedPinId: failedPinId,
    );
  }

  /// Mark persisted task as completed
  void _completePersistedTask() {
    _persistence?.markCompleted();
  }

  /// Phase 07 (07.5, D-34): "Fetch more" — one-hop continuation of a capped
  /// feed extraction. Reuses the stored bookmark ONLY on full context match;
  /// any mismatch (or a cross-user session drift) falls back to a fresh
  /// extraction from page 1 (fail-safe direction). Results merge with dedupe
  /// by pin id (first occurrence wins — 07.2 G5). Each press is a visible,
  /// cancellable run — never a silent loop.
  Future<void> fetchMore({
    required MediaType mediaType,
    int maxPages = 50,
    bool saveMetadata = false,
  }) async {
    final stored = state.bookmarkContext;
    final token = state.nextBookmark;
    if (stored == null || token == null) return;
    if (state.isExtracting || state.isDownloading) return;

    // Provenance check: the fresh context captures what this continuation
    // request WOULD be. computed from the service's current session config —
    // if another user was extracted in between, the user_id diverges and the
    // match fails (exactly the wrong-feed hazard D-34 exists to prevent).
    final fresh = BookmarkContext(
      username: stored.username,
      resource: BookmarkContext.resourceUserPins,
      requestOptions: _extractor.canonicalRequestOptions(stored.username),
      extractionMode: mediaType.name,
      maxPages: maxPages,
      bookmark: token,
    );
    if (!stored.matches(fresh)) {
      _logService.queue('Bookmark context changed — re-extracting from page 1');
      await startExtraction(
        input: stored.username,
        mediaType: mediaType,
        saveMetadata: saveMetadata,
        maxPages: maxPages,
      );
      return;
    }

    _logService.fetch('Fetching more pins for @${stored.username}...');
    state = state.copyWith(status: JobStatus.fetchingInfo);
    _extractCancelToken = CancelToken();
    try {
      final result = await _extractor.getUserPins(
        username: stored.username,
        bookmark: token,
        maxPages: maxPages,
        cancelToken: _extractCancelToken,
        onProgress: (count, currentPage, maxPage) {
          _logService.fetch('Fetched $count more pins (page $currentPage/$maxPage)...');
          onExtractionProgress?.call(
            username: stored.username,
            itemCount: state.pins.length + count,
            currentPage: currentPage,
            maxPage: maxPage,
          );
        },
      );

      // Merge with dedupe by pin id — first occurrence wins (07.2).
      final seen = state.pins.map((p) => p.pinId).toSet();
      final merged = [
        ...state.pins,
        ...result.pins.where((p) => !seen.contains(p.pinId)),
      ];
      _logService.parse('Fetched ${merged.length - state.pins.length} more pins (total ${merged.length})');

      // Continue again only if THIS run also ended capped.
      BookmarkContext? newContext;
      if (result.bookmark != null) {
        newContext = BookmarkContext(
          username: stored.username,
          resource: BookmarkContext.resourceUserPins,
          requestOptions: _extractor.canonicalRequestOptions(stored.username),
          extractionMode: mediaType.name,
          maxPages: maxPages,
          bookmark: result.bookmark!,
        );
        _logService.queue('Page cap reached — more items may be available (use Fetch More)');
      }

      state = state.copyWith(
        status: JobStatus.readyToDownload,
        author: result.author,
        pins: merged,
        totalImages: merged.where((p) => p.hasImage).length,
        totalVideos: merged.where((p) => p.hasVideo).length,
        nextBookmark: result.bookmark,
        bookmarkContext: newContext,
      );

      // Parse-time metadata rewrite keeps the file's pins/bookmark in sync
      // with the merged feed (download-time writes always use state.pins).
      if (saveMetadata && state.author != null) {
        final metadataJson = MetadataReader.buildV2Metadata(
          author: state.author!,
          pins: merged,
          completedIndices: const {},
          totalImages: state.totalImages,
          totalVideos: state.totalVideos,
          successDownloaded: 0,
          skipDownloaded: 0,
          failedDownloaded: 0,
          wasInterrupted: false,
          mediaType: mediaType.name,
          status: 'parsed',
          nextBookmark: state.nextBookmark,
          bookmarkContext: state.bookmarkContext,
        );
        await _saveMetadata(
            'PinDL/@${stored.username}', '${state.author!.userId}.json', metadataJson);
      }
      _logService.complete('Fetch more complete for @${stored.username}.');
    } catch (e) {
      _logService.error('Fetch more failed: ${userMessage(e)}');
      state = state.copyWith(
        status: JobStatus.failed,
        error: userMessage(e),
      );
    }
  }

  /// Cancel info extraction (Phase B only)
  void cancelExtraction() {
    if (!state.isExtracting) return;
    _extraction.cancel();
    _logService.interrupted('Info loading cancelled by user');
  }

  // ---- Phase 10 (D-38): board discovery flows (Phase B for boards mode).
  // Feed flows never touch these; board jobs (download side) land in 10.2/10.3.

  /// Discover a user's public boards (Phase B, boards mode): config →
  /// fetchBoards (capped) → sorted pinCount desc (boards-ux plan §2, JS
  /// parity). Additive state only — feed state fields untouched.
  Future<void> discoverBoards({
    required String username,
    int maxPages = 1,
    bool verbose = false,
  }) async {
    _extractor.verbose = verbose;
    if (state.isExtracting || state.isDiscoveringBoards) {
      _logService.error('Cannot start board discovery: another operation in progress');
      return;
    }
    final normalizedUsername = PinUrlValidator.normalizeUsername(username);
    _boardCancelToken = CancelToken();

    state = state.copyWith(
      status: JobStatus.fetchingInfo,
      isDiscoveringBoards: true,
      input: normalizedUsername,
      isUsername: true,
      error: null,
    );
    _logService.init('Discovering boards for @$normalizedUsername...');

    try {
      final config = await _extractor.getConfigInfo(
        username: normalizedUsername,
        cancelToken: _boardCancelToken,
      );
      final listing = await _boards.fetchBoards(
        userId: config.userId,
        username: normalizedUsername,
        maxPages: maxPages,
        cancelToken: _boardCancelToken,
      );
      // JS parity: sort by pinCount desc (boards-ux plan §2).
      final boards = [...listing.items]
        ..sort((a, b) => b.pinCount.compareTo(a.pinCount));

      state = state.copyWith(
        status: JobStatus.readyToDownload,
        isDiscoveringBoards: false,
        discoveredBoards: boards,
        boardSelection: BoardSelection(choices: const []),
      );
      _logService.complete(
          'Found ${boards.length} boards for @$normalizedUsername. Select boards to download.');
    } on CancelledException {
      _logService.interrupted('Board discovery cancelled');
      state = state.copyWith(status: JobStatus.cancelled, isDiscoveringBoards: false);
    } catch (e) {
      _logService.error('Board discovery failed: ${userMessage(e)}');
      state = state.copyWith(
        status: JobStatus.failed,
        isDiscoveringBoards: false,
        error: userMessage(e),
      );
    }
  }

  /// Lazy section fetch for one board (picker expansion). Never throws to
  /// the UI: failures log and leave the board without sections (user can
  /// still pick Whole mode).
  Future<void> loadBoardSections({
    required String boardId,
    required String username,
    required String boardSlug,
  }) async {
    if (state.boardSections.containsKey(boardId)) return;
    try {
      final listing = await _boards.fetchBoardSections(
        boardId: boardId,
        username: username,
        boardSlug: boardSlug,
        cancelToken: _boardCancelToken,
      );
      state = state.copyWith(
        boardSections: {...state.boardSections, boardId: listing.items},
      );
    } on CancelledException {
      _logService.interrupted('Section loading cancelled');
    } catch (e) {
      _logService.error('Section loading failed: ${userMessage(e)}');
    }
  }

  /// Update the user's board selection (picker callback).
  void updateBoardSelection(BoardSelection selection) {
    state = state.copyWith(boardSelection: selection);
  }

  /// Cancel an in-flight board discovery.
  void cancelBoardDiscovery() {
    if (!state.isDiscoveringBoards) return;
    _boardCancelToken?.cancel('User cancelled');
    _logService.interrupted('Board discovery cancelled by user');
  }

  /// Phase 10.2 (D-38): run the user's board selection as SEQUENTIAL
  /// per-board feed jobs. Each active board fetches its pins (whole board
  /// or picked sections — same pipeline), then downloads through the
  /// UNCHANGED [DownloadCoordinator.runFeedDownload] with a board-scoped
  /// base folder; per-board+type resume persists via `board_resume`.
  Future<void> startBoardDownload({
    required String outputPath,
    required MediaType mediaType,
    required bool overwrite,
    required String username,
    bool saveMetadata = false,
  }) async {
    final selection = state.boardSelection;
    if (selection.isEmpty) {
      _logService.error('No boards selected');
      return;
    }
    if (state.isDownloading || state.isExtracting) {
      _logService.error('Cannot start board download: another operation in progress');
      return;
    }

    _downloadCancelToken = CancelToken();
    _download.cancelToken = _downloadCancelToken;
    state = state.copyWith(
      status: JobStatus.downloading,
      downloadedCount: 0,
      skippedCount: 0,
      failedCount: 0,
      currentIndex: 0,
    );
    onTaskStarted?.call();

    final runs = DownloadCoordinator.planBoardRuns(
      selection: selection,
      username: username,
    );
    final totalBoards = runs.length;

    // Phase 10.3: board-scoped resume — read the previous session's
    // board_resume block (continue settings gate), pre-compute completed
    // indices per boardId for skip/re-offer bookkeeping.
    final continueMode = state.isContinueMode;
    Map<String, BoardTypeResume>? resumeByBoard;
    if (continueMode) {
      resumeByBoard = await _loadBoardResume(
        username: username,
        mediaType: mediaType,
      );
    }

    try {
      for (var i = 0; i < runs.length; i++) {
        if (_downloadCancelToken?.isCancelled ?? false) break;
        final run = runs[i];
        final choice = run.choice;
        _logService.queue(
            'Board ${i + 1}/$totalBoards: ${choice.name} (${choice.mode.name})');

        // ---- Fetch pins for this board (whole vs picked sections) ----
        List<PinItem> pins;
        if (choice.mode == BoardDownloadMode.sections) {
          // 10.3 continue: boards fully completed per type are skipped up
          // front (re-offered only when failed items exist — D-04 truth
          // table applies unchanged at the index level below).
          final resume = resumeByBoard?[choice.boardId];
          if (resume != null &&
              choice.boardPinCount > 0 &&
              resume.completedIndices.length >= choice.boardPinCount &&
              resume.failedDownloaded == 0) {
            _logService.queue(
                'Board ${choice.name}: already complete for this type — skipping');
            continue;
          }
          var sectionPins = <PinItem>[];
          for (final sectionId in choice.sectionIds) {
            if (_downloadCancelToken?.isCancelled ?? false) break;
            final result = await _boards.fetchSectionPins(
              sectionId: sectionId,
              username: username,
              boardSlug: choice.slug,
              cancelToken: _downloadCancelToken,
            );
            // Union across picked sections, dedupe by pin id (a pin can
            // conceptually appear in two sections; first occurrence wins —
            // same rule as the feed dedupe, Phase 07 G5).
            final seen = sectionPins.map((p) => p.pinId).toSet();
            for (final p in result.pins) {
              if (seen.add(p.pinId)) sectionPins.add(p);
            }
          }
          pins = sectionPins;
        } else {
          final result = await _boards.fetchBoardPins(
            boardId: choice.boardId,
            username: username,
            boardSlug: choice.slug,
            cancelToken: _downloadCancelToken,
          );
          pins = result.pins;
        }

        if (pins.isEmpty) {
          _logService.queue(
              'No ${mediaType.name}s found in board ${choice.name} — skipping');
          continue;
        }

        // ---- Download this board as a feed-shaped run ----
        final runResult = await _download.runFeedDownload(
          pins: pins,
          author: state.author,
          mediaType: mediaType,
          outputPath: outputPath,
          overwrite: overwrite,
          saveMetadata: false,
          isContinueMode: false,
          lastIndexDownloaded: -1,
          previousMediaType: null,
          previousCompletedIndices: const {},
          totalImages: pins.length,
          totalVideos: 0,
          previousDownloaded: 0,
          previousSkipped: 0,
          previousFailed: 0,
          nextBookmark: null,
          bookmarkContext: null,
          baseFolderOverride: run.baseFolder,
          onStats: ({downloadedDelta, skippedDelta, failedDelta, indexDelta}) {
            state = state.copyWith(
              downloadedCount: state.downloadedCount + (downloadedDelta ?? 0),
              skippedCount: state.skippedCount + (skippedDelta ?? 0),
              failedCount: state.failedCount + (failedDelta ?? 0),
              currentIndex: state.currentIndex + (indexDelta ?? 0),
            );
          },
        );

        // ---- 10.3: persist per-board+type resume block ----
        if (saveMetadata && runResult.sessionCompleted.isNotEmpty) {
          await _upsertBoardResume(
            username: username,
            boardId: choice.boardId,
            boardSlug: choice.slug,
            mediaType: mediaType,
            completedIndices: runResult.sessionCompleted,
            successDownloaded: runResult.stats.downloaded,
            skipDownloaded: runResult.stats.skipped,
            failedDownloaded: runResult.stats.failed,
          );
        }
      }

      final wasInterrupted = _downloadCancelToken?.isCancelled ?? false;
      if (wasInterrupted) {
        state = state.copyWith(status: JobStatus.cancelled);
      } else {
        state = state.copyWith(status: JobStatus.completed);
        _logService.complete(
            'Board download complete — $totalBoards board(s), '
            '${state.downloadedCount} saved, ${state.skippedCount} skipped, '
            '${state.failedCount} failed.');
        onTaskCompleted?.call(taskType: 'download');
      }
    } catch (e) {
      _logService.error('Board download failed: ${userMessage(e)}');
      state = state.copyWith(status: JobStatus.failed, error: userMessage(e));
    }
  }

  /// 10.3: read the previous session's board_resume block from the user
  /// metadata for the given media type (tolerant: missing file/corrupt
  /// block → null → fresh runs; D-25: only THIS type's sets are returned).
  Future<Map<String, BoardTypeResume>?> _loadBoardResume({
    required String username,
    required MediaType mediaType,
  }) async {
    try {
      final baseFolder = 'PinDL/@$username';
      final files = await _downloadService.listFilesInFolder(baseFolder,
          extension: 'json');
      if (files.isEmpty) return null;
      final content = await _downloadService.readTextFromDownloads(
          files.first, baseFolder);
      if (content == null || content.isEmpty) return null;
      final result = MetadataReader.parseAndRead(content);
      if (!result.isOk || result.boardResume == null) return null;
      final map = <String, BoardTypeResume>{};
      for (final entry in result.boardResume!.entries) {
        final type = entry.typeFor(mediaType.name);
        if (type != null) map[entry.boardId] = type;
      }
      return map;
    } catch (_) {
      return null;
    }
  }

  /// 10.3: merge this board's completion set into the user metadata's
  /// board_resume block (v2-additive; media-type keyed per D-25).
  Future<void> _upsertBoardResume({
    required String username,
    required String boardId,
    required String boardSlug,
    required MediaType mediaType,
    required Set<int> completedIndices,
    required int successDownloaded,
    required int skipDownloaded,
    required int failedDownloaded,
  }) async {
    try {
      final baseFolder = 'PinDL/@$username';
      final files = await _downloadService.listFilesInFolder(baseFolder,
          extension: 'json');
      Map<String, dynamic> existing = {};
      Author? author;
      BoardResume? boardResume;
      if (files.isNotEmpty) {
        final content = await _downloadService.readTextFromDownloads(
            files.first, baseFolder);
        if (content != null && content.isNotEmpty) {
          final decoded = MetadataReader.parseAndRead(content);
          if (decoded.isOk) {
            author = decoded.author;
            boardResume = decoded.boardResume;
            existing = decoded.jsonMap ?? {};
          }
        }
      }

      final typeKey = mediaType.name;
      final prevEntry = boardResume?.entryFor(boardId);
      final prevType = prevEntry?.typeFor(typeKey);
      final mergedIndices = {
        ...(prevType?.completedIndices ?? const <int>{}),
        ...completedIndices,
      };
      final newEntry = BoardResumeEntry(
        boardId: boardId,
        boardSlug: boardSlug,
        types: {
          ...(prevEntry?.types ?? const {}),
          typeKey: BoardTypeResume(
            completedIndices: mergedIndices,
            successDownloaded:
                (prevType?.successDownloaded ?? 0) + successDownloaded,
            skipDownloaded: (prevType?.skipDownloaded ?? 0) + skipDownloaded,
            failedDownloaded:
                (prevType?.failedDownloaded ?? 0) + failedDownloaded,
          ),
        },
      );
      final otherEntries = (boardResume?.entries ?? const <BoardResumeEntry>[])
          .where((e) => e.boardId != boardId)
          .toList();
      final newBlock =
          BoardResume(entries: [...otherEntries, newEntry]);

      final json = existing.isNotEmpty
          ? (existing..['board_resume'] = newBlock.toJson())
          : MetadataReader.buildV2Metadata(
              author: author ??
                  Author(
                      username: username, name: username, userId: 'unknown'),
              pins: const [],
              completedIndices: const {},
              totalImages: 0,
              totalVideos: 0,
              successDownloaded: 0,
              skipDownloaded: 0,
              failedDownloaded: 0,
              wasInterrupted: false,
              mediaType: mediaType.name,
              status: 'downloaded',
              boardResume: newBlock,
            );
      final filename = files.isNotEmpty
          ? files.first
          : '${json['author']?['userId'] ?? username}.json';
      await _saveMetadata(baseFolder, filename, json);
      _logService.saved('Board resume data saved for @$username');
    } catch (e) {
      // Best-effort: resume persistence failure never fails the job.
      _logService.error('Board resume save failed: ${userMessage(e)}');
    }
  }

  /// Load existing metadata for continue mode
  /// Returns true if metadata was found and loaded
  /// [username] - The username (without @) to look for metadata
  Future<bool> loadExistingMetadata(String username) async {
    final normalizedUsername = PinUrlValidator.normalizeUsername(username);
    final baseFolder = 'PinDL/@$normalizedUsername';
    
    _logService.fetch('Looking for existing metadata in $baseFolder...');
    
    try {
      // First, find the metadata file (userId.json)
      final files = await _downloadService.listFilesInFolder(baseFolder, extension: 'json');
      
      if (files.isEmpty) {
        _logService.error('No metadata found for @$normalizedUsername');
        _logService.error('Make sure metadata file exists in: Download/$baseFolder/<userId>.json');
        return false;
      }
      
      // Get the first json file (should be userId.json)
      final metadataFilename = files.first;
      _logService.fetch('Found metadata file: $metadataFilename');
      
      // Read the metadata content
      final content = await _downloadService.readTextFromDownloads(metadataFilename, baseFolder);
      
      if (content == null || content.isEmpty) {
        _logService.error('Failed to read metadata file: $metadataFilename');
        return false;
      }
      
      // Phase 04: versioned read (persistence/01). Three safe paths:
      // corrupt JSON → no-resume-data (safe restart); future schema →
      // upgrade prompt, never silent reinterpretation; v1 → legacy
      // counter semantics (documented degradation).
      final read = MetadataReader.parseAndRead(content);
      if (read.isCorrupt) {
        _logService.error('Metadata unreadable (corrupt/truncated) — re-extract or delete the metadata file to restart safely.');
        return false;
      }
      if (read.isFutureSchema) {
        _logService.error('Metadata was created by a newer PinDL (schema ${read.schemaVersion}) — update the app to continue this download.');
        return false;
      }

      final result = UserPinsResult.fromMetadataJson(read.jsonMap!);
      final completedIndices = read.completedIndices ?? const <int>{};

      _logService.parse('Loaded metadata (schema ${read.schemaVersion}) for @${result.author.username}');
      _logService.parse('Previous stats: Downloaded ${result.successDownloaded}, Skipped ${result.skipDownloaded}, Failed ${result.failedDownloaded}');
      _logService.parse('Last index: ${result.lastIndexDownloaded}, Was interrupted: ${result.wasInterrupted}');

      // Read previous media type from metadata (used for cross-type continue detection)
      final previousMediaType = read.mediaType;

      // Derive per-type completion from accumulated counts:
      // If (success + skipped + failed) >= total for that type → fully done
      final totalProcessed = result.successDownloaded + result.skipDownloaded + result.failedDownloaded;
      final bool imagesAlreadyDone = previousMediaType == 'image' &&
          !result.wasInterrupted &&
          result.totalImages > 0 &&
          totalProcessed >= result.totalImages;
      final bool videosAlreadyDone = previousMediaType == 'video' &&
          !result.wasInterrupted &&
          result.totalVideos > 0 &&
          totalProcessed >= result.totalVideos;

      // Update state with loaded metadata.
      // Restore lastIndexDownloaded from metadata so startIndex skips directly
      // to where the previous session left off — no re-checking from index 0.
      state = AppJobState(
        status: JobStatus.readyToDownload,
        input: username,
        isUsername: true,
        author: result.author,
        pins: result.pins,
        totalImages: result.totalImages,
        totalVideos: result.totalVideos,
        previousDownloaded: result.successDownloaded,
        previousSkipped: result.skipDownloaded,
        previousFailed: result.failedDownloaded,
        // v2: hole-aware index; v1: raw counter (legacy semantics)
        lastIndexDownloaded: read.schemaVersion >= 2
            ? maxContiguous(completedIndices)
            : result.lastIndexDownloaded,
        wasInterrupted: result.wasInterrupted,
        isContinueMode: true,
        previousMediaType: previousMediaType,
        imagesFullyDownloaded: imagesAlreadyDone,
        videosFullyDownloaded: videosAlreadyDone,
        previousCompletedIndices: completedIndices,
      );
      
      final remaining = previousMediaType == 'video'
          ? state.remainingVideos
          : state.remainingImages;
      _logService.complete('Ready to continue. Remaining: $remaining ${previousMediaType ?? "items"}s (processed: ${result.successDownloaded} downloaded, ${result.skipDownloaded} skipped, ${result.failedDownloaded} failed)');
      
      return true;
    } catch (e) {
      _logService.error('Failed to load metadata: $e');
      return false;
    }
  }

  /// Start download (Download button) - Phase D
  /// Only callable from Phase C (readyToDownload).
  ///
  /// Phase 08 (08.2): the feed queue + HLS branches live in the
  /// DownloadCoordinator; single-pin stays a direct DownloadService flow
  /// (no queue). This method remains the state-machine adapter.
  Future<void> startDownload({
    required String outputPath,
    required MediaType mediaType,
    required bool overwrite,
    bool downloadImage = true,
    bool downloadVideo = false,
    bool saveMetadata = false,
  }) async {
    // Validate we're in the correct phase
    if (!state.canDownload) {
      _logService.error('Cannot start download: not in ready state');
      return;
    }

    _downloadCancelToken = CancelToken();
    _download.cancelToken = _downloadCancelToken;

    // Transition to Phase D: downloading
    state = state.copyWith(
      status: JobStatus.downloading,
      downloadedCount: 0,
      skippedCount: 0,
      failedCount: 0,
      currentIndex: 0,
    );

    _logService.queue('Starting download queue');

    // Persist download state for background recovery
    final totalToDownload = state.singlePinResult != null
        ? (downloadImage ? 1 : 0) + (downloadVideo && state.singlePinResult!.hasVideoContent ? 1 : 0)
        : state.pins.length;
    _persistDownloadState(mediaType, overwrite, saveMetadata, totalToDownload);

    // Notify foreground service manager that task started
    onTaskStarted?.call();

    try {
      // Handle single pin result
      if (state.singlePinResult != null) {
        await _downloadSinglePin(
          outputPath,
          overwrite,
          downloadImage: downloadImage,
          downloadVideo: downloadVideo,
          saveMetadata: saveMetadata,
        );
        return;
      }

      // Handle user pins via the download coordinator (queue + HLS).
      final result = await _download.runFeedDownload(
        pins: state.pins,
        author: state.author,
        mediaType: mediaType,
        outputPath: outputPath,
        overwrite: overwrite,
        saveMetadata: saveMetadata,
        isContinueMode: state.isContinueMode,
        lastIndexDownloaded: state.lastIndexDownloaded,
        previousMediaType: state.previousMediaType,
        previousCompletedIndices: state.previousCompletedIndices,
        totalImages: state.totalImages,
        totalVideos: state.totalVideos,
        previousDownloaded: state.previousDownloaded,
        previousSkipped: state.previousSkipped,
        previousFailed: state.previousFailed,
        nextBookmark: state.nextBookmark,
        bookmarkContext: state.bookmarkContext,
        onStats: ({downloadedDelta, skippedDelta, failedDelta, indexDelta}) {
          state = state.copyWith(
            downloadedCount: state.downloadedCount + (downloadedDelta ?? 0),
            skippedCount: state.skippedCount + (skippedDelta ?? 0),
            failedCount: state.failedCount + (failedDelta ?? 0),
            currentIndex: state.currentIndex + (indexDelta ?? 0),
          );
        },
      );

      // Early exits replicate the old edge paths exactly (no finalization
      // side effects, previous counters on the all-downloaded path).
      if (result.earlyExit == FeedEarlyExit.noItems) {
        state = state.copyWith(status: JobStatus.completed);
        return;
      }
      if (result.earlyExit == FeedEarlyExit.allDownloaded) {
        state = state.copyWith(
          status: JobStatus.completed,
          downloadedCount: state.previousDownloaded,
          skippedCount: state.previousSkipped,
          failedCount: state.previousFailed,
        );
        return;
      }

      final wasInterrupted = result.wasInterrupted || (state.status == JobStatus.cancelled);

      // Save user metadata if requested (to PinDL/@username/<userId>.json)
      final write = result.metadataWrite;
      if (saveMetadata && write != null) {
        await _saveMetadata(write.subFolder, write.filename, write.json);
      }

      if (!wasInterrupted) {
        state = state.copyWith(
          status: JobStatus.completed,
          imagesFullyDownloaded: mediaType == MediaType.image
              ? true
              : state.imagesFullyDownloaded,
          videosFullyDownloaded: mediaType == MediaType.video
              ? true
              : state.videosFullyDownloaded,
        );
        _completePersistedTask();
        // Notify foreground service manager that download completed
        onTaskCompleted?.call(taskType: 'download');
      }

      final sessionStats = '${state.downloadedCount} downloaded, ${state.skippedCount} skipped, ${state.failedCount} failed';

      _logService.complete(
        'Download ${wasInterrupted ? "interrupted" : "complete"}. $sessionStats',
      );
    } catch (e) {
      _logService.error('Download failed: $e');
      state = state.copyWith(
        status: JobStatus.failed,
        error: userMessage(e),
      );
    }
  }

  /// Single-pin download flow (no queue): image/thumbnail or carousel slots,
  /// then video; per-item counting and history. Phase 08: kept provider-side
  /// (it touches only DownloadService + _saveMetadata), slimmed of queue logic.
  Future<void> _downloadSinglePin(
    String outputPath,
    bool overwrite, {
    required bool downloadImage,
    required bool downloadVideo,
    required bool saveMetadata,
  }) async {
    final result = state.singlePinResult!;
    int downloaded = 0;
    int skipped = 0;
    int failed = 0;

    Future<void> downloadOne({
      required String url,
      required String filename,
      required String pinId,
    }) async {
      _logService.downloading('Downloading $filename');
      try {
        await _downloadService.downloadFile(
          url: url,
          outputPath: outputPath,
          filename: filename,
          pinId: pinId,
          overwrite: overwrite,
        );
        _logService.saved('Saved: $filename');
        downloaded++;
        _onDownloadComplete?.call(
          filename: filename,
          url: url,
          status: HistoryStatus.success,
        );
      } on DownloadException catch (e) {
        if (e.message.contains('already exists')) {
          _logService.skipped('Skipped: $filename (exists)');
          skipped++;
        } else {
          _logService.error('Failed: $filename - ${e.message}');
          failed++;
          _onDownloadComplete?.call(
            filename: filename,
            url: url,
            status: HistoryStatus.failed,
            errorMessage: e.message,
          );
        }
      } catch (e) {
        _logService.error('Failed: $filename - $e');
        failed++;
        _onDownloadComplete?.call(
          filename: filename,
          url: url,
          status: HistoryStatus.failed,
          errorMessage: userMessage(e),
        );
      }
    }

    // Download thumbnail/image if requested
    if (downloadImage) {
      // Phase 07 (07.3): carousel pins yield one download per slot, in slot
      // order, with deterministic indexed names (<pinId>_image_<n>.<ext>,
      // 1-based). Each slot is an independent history entry with its own
      // failed/skip counting; skip-existing covers re-runs (names stable).
      if (result.slots.length > 1) {
        for (var i = 0; i < result.slots.length; i++) {
          final slotUrl = result.slots[i].imageUrl;
          final filename = FormatUtils.pinFilename(
            pinId: result.pinId,
            role: 'image',
            url: slotUrl,
            imageIndex: i + 1,
          );
          await downloadOne(
            url: slotUrl,
            filename: filename,
            pinId: '${result.pinId}_img$i',
          );
        }
      } else {
        final imageUrl = result.getImageDownloadUrl(useThumbnailForVideo: true);
        if (imageUrl != null) {
          // Deterministic filename: <pinId>_image.jpg or <pinId>_thumbnail.jpg
          final role = (result.hasVideoContent && !result.hasImage) ? 'thumbnail' : 'image';
          final filename = FormatUtils.pinFilename(pinId: result.pinId, role: role, url: imageUrl);
          await downloadOne(
            url: imageUrl,
            filename: filename,
            pinId: '${result.pinId}_img',
          );
        }
      }
    }

    // Download video if requested
    if (downloadVideo && result.hasVideoContent) {
      final videoUrl = result.videoUrl;
      if (videoUrl != null) {
        // Deterministic filename: <pinId>_video.mp4
        final filename = FormatUtils.pinFilename(pinId: result.pinId, role: 'video', url: videoUrl);
        await downloadOne(
          url: videoUrl,
          filename: filename,
          pinId: '${result.pinId}_vid',
        );
      }
    }

    // Save metadata if requested (single pin goes to PinDL/metadata/)
    if (saveMetadata && result.rawJson != null) {
      await _saveMetadata('PinDL/metadata', '${result.metadataId}.json', result.rawJson!);
    }

    state = state.copyWith(
      status: JobStatus.completed,
      downloadedCount: downloaded,
      skippedCount: skipped,
      failedCount: failed,
      imagesFullyDownloaded: downloadImage
          ? true
          : state.imagesFullyDownloaded,
      videosFullyDownloaded: downloadVideo
          ? true
          : state.videosFullyDownloaded,
    );

    _logService.complete('Download complete. Downloaded: $downloaded, Skipped: $skipped, Failed: $failed');
  }


  /// Save metadata JSON file via method channel (works on Android 11+)
  /// [subFolder] - relative path under Downloads, e.g. "PinDL/@username" or "PinDL/metadata"
  Future<void> _saveMetadata(String subFolder, String filename, Map<String, dynamic> json) async {
    try {
      const encoder = JsonEncoder.withIndent('  ');
      final jsonString = encoder.convert(json);

      if (Platform.isAndroid) {
        // Use method channel to save via MediaStore
        await _mediaChannel.invokeMethod('saveTextToFile', {
          'content': jsonString,
          'filename': filename,
          'subFolder': subFolder,
        });
        _logService.saved('Saved metadata: $filename');
      } else {
        // Fallback for other platforms (iOS, etc.)
        final metadataDir = Directory(subFolder);
        if (!await metadataDir.exists()) {
          await metadataDir.create(recursive: true);
        }
        final file = File('${metadataDir.path}/$filename');
        await file.writeAsString(jsonString);
        _logService.saved('Saved metadata: $filename');
      }
    } catch (e) {
      _logService.error('Failed to save metadata: $e');
    }
  }

  /// Cancel download (Phase D only)
  Future<void> cancelDownload() async {
    if (!state.isDownloading) return;
    await _downloadService.cancelAll();
    _logService.interrupted('Download cancelled by user');
    state = state.copyWith(
      status: JobStatus.cancelled,
    );
  }

  /// Reset job state to idle
  void reset() {
    state = state.reset();
    _logService.clear();
  }
}

/// Provider for Pinterest extractor service
/// Created once and never invalidated by settings changes.
/// The verbose flag is updated directly on the service instance by JobNotifier
/// before each extraction, avoiding the Riverpod invalidation cascade that
/// previously caused jobProvider to reset (destroying the result card).
final pinterestExtractorProvider = Provider<PinterestExtractorService>((ref) {
  final service = PinterestExtractorService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for download service
final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for job notifier
final jobProvider = StateNotifierProvider<JobNotifier, AppJobState>((ref) {
  final downloadHistoryNotifier = ref.read(downloadHistoryProvider.notifier);
  
  // TaskStatePersistence is initialized in main.dart before providers are created
  TaskStatePersistence? persistence;
  try {
    persistence = ref.watch(taskStatePersistenceProvider);
  } catch (_) {
    // Persistence not available (e.g., during testing)
  }
  
  return JobNotifier(
    logService: ref.watch(logServiceProvider),
    extractor: ref.watch(pinterestExtractorProvider),
    downloadService: ref.watch(downloadServiceProvider),
    persistence: persistence,
    onDownloadComplete: ({
      required String filename,
      required String url,
      required HistoryStatus status,
      String? errorMessage,
    }) {
      downloadHistoryNotifier.add(
        filename: filename,
        url: url,
        status: status,
        errorMessage: errorMessage,
      );
    },
  );
});

/// Provider for download progress stream
final downloadProgressProvider = StreamProvider<DownloadProgress>((ref) {
  final service = ref.watch(downloadServiceProvider);
  return service.progressStream;
});
