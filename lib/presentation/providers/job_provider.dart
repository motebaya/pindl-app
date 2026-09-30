import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/build_config.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/persistence/metadata_schema.dart';
import '../../core/utils/format_utils.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../data/models/author.dart';
import '../../data/models/history_item.dart';
import '../../data/models/job_state.dart';
import '../../data/models/media_result.dart';
import '../../data/models/pin_item.dart';
import '../../data/models/user_pins_result.dart';
import '../../data/services/download_service.dart';
import '../../data/services/hls_converter.dart';
import '../../data/services/hls_service.dart';
import '../../data/services/log_service.dart';
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
  final DownloadService _downloadService;
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
        _downloadService = downloadService,
        // Only instantiate HLS services when FFmpeg is enabled (compile-time const).
        // Tree-shaking eliminates HlsService/HlsConverter from lite AOT binaries.
        _hlsService = BuildConfig.enableFfmpeg ? (hlsService ?? HlsService()) : null,
        _hlsConverter = BuildConfig.enableFfmpeg ? (hlsConverter ?? HlsConverter()) : null,
        _persistence = persistence,
        _onDownloadComplete = onDownloadComplete,
        super(const AppJobState());

  /// Start info extraction (Submit button) - Phase B
  /// This only fetches metadata, does NOT start downloading
  /// If saveMetadata is true, saves metadata immediately after parsing
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

    _extractCancelToken = CancelToken();

    // ── Short URL resolution: resolve pin.it URLs BEFORE routing ──
    // Short URLs can redirect to either a pin page or a user profile page.
    // We must resolve first to determine the correct extraction path.
    String resolvedInput = input;
    bool isUsername = inputType == 'username';

    if (PinUrlValidator.isShortUrl(input)) {
      // Transition to fetchingInfo early so UI shows loading state
      state = AppJobState(
        status: JobStatus.fetchingInfo,
        input: input,
        isUsername: false,
      );
      _logService.init('Resolving short URL: $input');

      try {
        final rawRedirectUrl = await _extractor.resolveShortUrl(
          input, _extractCancelToken,
        );
        _logService.fetch('Redirected to: $rawRedirectUrl');

        // Clean the redirected URL (strip /sent/, query params, etc.)
        final cleaned = PinUrlValidator.cleanRedirectedUrl(rawRedirectUrl);
        if (cleaned == null) {
          state = state.copyWith(
            status: JobStatus.failed,
            error: 'Could not parse redirected URL: $rawRedirectUrl',
          );
          return;
        }

        resolvedInput = cleaned.value;
        isUsername = cleaned.type == 'username';
        _logService.parse('Resolved to ${cleaned.type}: $resolvedInput');

        // Update input field callback so UI shows the resolved value
        onInputResolved?.call(resolvedInput: resolvedInput, isUsername: isUsername);

        // If resolved to a username, STOP here — don't auto-extract.
        // User needs to adjust settings (max pages, media type) before submitting.
        if (isUsername) {
          _logService.complete('Short URL resolved to username: @$resolvedInput — submit manually to extract.');
          state = const AppJobState(status: JobStatus.idle);
          return;
        }
      } on CancelledException {
        _logService.interrupted('Short URL resolution cancelled');
        state = state.copyWith(status: JobStatus.cancelled);
        return;
      } catch (e) {
        _logService.error('Failed to resolve short URL: $e');
        state = state.copyWith(
          status: JobStatus.failed,
          error: userMessage(e),
        );
        return;
      }
    }

    // Transition to Phase B: fetchingInfo (if not already set by short URL resolution)
    state = AppJobState(
      status: JobStatus.fetchingInfo,
      input: resolvedInput,
      isUsername: isUsername,
    );

    // Persist initial extraction state
    _persistExtractionState(resolvedInput, isUsername, mediaType, maxPages);

    // Notify foreground service manager that task started
    onTaskStarted?.call();

    _logService.init('Loading info for: $resolvedInput');

    try {
      if (isUsername) {
        await _extractUserPins(resolvedInput, mediaType, saveMetadata: saveMetadata, maxPages: maxPages);
      } else {
        await _extractSinglePin(resolvedInput, mediaType);
      }
      // Extraction completed successfully — notify foreground service
      // so it can show completion notification (identical to download completion)
      if (state.status == JobStatus.readyToDownload) {
        onTaskCompleted?.call(taskType: 'extraction');
      }
    } on CancelledException {
      _logService.interrupted('Info loading cancelled');
      state = state.copyWith(
        status: JobStatus.cancelled,
      );
    } catch (e) {
      _logService.error('Failed to load info: $e');
      state = state.copyWith(
        status: JobStatus.failed,
        error: userMessage(e),
      );
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

  Future<void> _extractUserPins(String username, MediaType mediaType, {bool saveMetadata = false, int maxPages = 50}) async {
    final normalizedUsername = PinUrlValidator.normalizeUsername(username);
    
    _logService.config('Getting config for @$normalizedUsername');
    
    final config = await _extractor.getConfigInfo(
      username: normalizedUsername,
      cancelToken: _extractCancelToken,
    );
    
    _logService.config('App version: ${config.appVersion}');
    _logService.config('User ID: ${config.userId}');
    
    _logService.fetch('Fetching pins for @$normalizedUsername (max $maxPages pages)');
    
    final result = await _extractor.getUserPins(
      username: normalizedUsername,
      maxPages: maxPages,
      cancelToken: _extractCancelToken,
      onProgress: (count, currentPage, maxPage) {
        _logService.fetch('Fetched $count pins (page $currentPage/$maxPage)...');
        // Persist extraction page progress to Hive
        _persistence?.updateProgress(
          currentPage: currentPage,
          totalItems: count,
        );
        // Notify foreground service for notification update
        onExtractionProgress?.call(
          username: normalizedUsername,
          itemCount: count,
          currentPage: currentPage,
          maxPage: maxPage,
        );
      },
    );
    
    _logService.parse('Parsed ${result.pins.length} pins');
    _logService.parse('Images: ${result.totalImages}, Videos: ${result.totalVideos}');
    
    // Phase 07 (07.5, D-34): capture the capped-extraction cursor WITH its
    // request context, or clear any stale one (fresh extraction = new world).
    BookmarkContext? newContext;
    if (result.bookmark != null) {
      newContext = BookmarkContext(
        username: normalizedUsername,
        resource: BookmarkContext.resourceUserPins,
        requestOptions: _extractor.canonicalRequestOptions(normalizedUsername),
        extractionMode: mediaType.name,
        maxPages: maxPages,
        bookmark: result.bookmark!,
      );
      // Cap note (contract 07.5): honest wording — the count of remaining
      // items is unknowable without fetching.
      _logService.queue(
          'Page cap reached — more items may be available (use Fetch More)');
    }
    
    // Transition to Phase C: readyToDownload
    state = state.copyWith(
      status: JobStatus.readyToDownload,
      author: result.author,
      pins: result.pins,
      totalImages: result.totalImages,
      totalVideos: result.totalVideos,
      nextBookmark: result.bookmark,
      bookmarkContext: newContext,
    );
    
    // REVISION 1: Save metadata immediately after parsing (before download)
    if (saveMetadata && result.author != null) {
      final baseFolder = 'PinDL/@$normalizedUsername';
      final metadataJson = MetadataReader.buildV2Metadata(
        author: result.author,
        pins: result.pins,
        completedIndices: const {}, // nothing downloaded yet at parse time
        totalImages: result.totalImages,
        totalVideos: result.totalVideos,
        successDownloaded: 0,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: mediaType.name,
        status: 'parsed', // Mark as parsed but not downloaded yet
        nextBookmark: state.nextBookmark,
        bookmarkContext: state.bookmarkContext,
      );
      await _saveMetadata(baseFolder, '${result.author.userId}.json', metadataJson);
      _logService.saved('Metadata saved for @${result.author.username}');
    }
    
    _logService.complete('Info loaded for @${result.author.username}. Ready to download.');
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

  Future<void> _extractSinglePin(String pinInput, MediaType mediaType) async {
    final pinInfo = PinUrlValidator.parse(pinInput);
    if (pinInfo == null) {
      throw ValidationException('Invalid pin URL or ID');
    }
    
    _logService.fetch('Fetching pin: ${pinInfo.id}');
    
    // Use getPinMedia to get both image and video data
    final result = await _extractor.getPinMedia(
      pinIdOrUrl: pinInput,
      cancelToken: _extractCancelToken,
    );
    
    _logService.parse('Found media for pin: ${result.title}');
    if (result.hasImage) {
      _logService.parse('Image available: ${result.imageUrl}');
    }
    if (result.hasVideoContent) {
      _logService.parse('Video available: ${result.videoUrl}');
    }
    
    // Convert single result to pin list for unified handling
    final pin = PinItem(
      pinId: result.pinId,
      title: result.title,
      imageUrl: result.imageUrl,
      hasImage: result.hasImage,
      hasVideo: result.hasVideoContent,
    );
    
    // Transition to Phase C: readyToDownload
    state = state.copyWith(
      status: JobStatus.readyToDownload,
      author: result.author,
      pins: [pin],
      singlePinResult: result,
      totalImages: result.hasImage ? 1 : 0,
      totalVideos: result.hasVideoContent ? 1 : 0,
    );
    
    _logService.complete('Info loaded for pin ${result.pinId}. Ready to download.');
  }

  /// Cancel info extraction (Phase B only)
  void cancelExtraction() {
    if (!state.isExtracting) return;
    _extractCancelToken?.cancel('User cancelled');
    _logService.interrupted('Info loading cancelled by user');
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
  /// Only callable from Phase C (readyToDownload)
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

      // Handle user pins
      await _downloadUserPins(outputPath, mediaType, overwrite, saveMetadata: saveMetadata);
    } catch (e) {
      _logService.error('Download failed: $e');
      state = state.copyWith(
        status: JobStatus.failed,
        error: userMessage(e),
      );
    }
  }

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
          _logService.downloading('Downloading carousel image: $filename');
          try {
            await _downloadService.downloadFile(
              url: slotUrl,
              outputPath: outputPath,
              filename: filename,
              pinId: '${result.pinId}_img$i',
              overwrite: overwrite,
            );
            _logService.saved('Saved: $filename');
            downloaded++;
            _onDownloadComplete?.call(
              filename: filename,
              url: slotUrl,
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
                url: slotUrl,
                status: HistoryStatus.failed,
                errorMessage: e.message,
              );
            }
          } catch (e) {
            _logService.error('Failed: $filename - $e');
            failed++;
            _onDownloadComplete?.call(
              filename: filename,
              url: slotUrl,
              status: HistoryStatus.failed,
              errorMessage: userMessage(e),
            );
          }
        }
        // Carousel handled; fall through to the video branch only.
      } else
      {
      final imageUrl = result.getImageDownloadUrl(useThumbnailForVideo: true);
      if (imageUrl != null) {
        // Deterministic filename: <pinId>_image.jpg or <pinId>_thumbnail.jpg
        final role = (result.hasVideoContent && !result.hasImage) ? 'thumbnail' : 'image';
        final filename = FormatUtils.pinFilename(pinId: result.pinId, role: role, url: imageUrl);
        _logService.downloading('Downloading image: $filename');
        
        try {
          await _downloadService.downloadFile(
            url: imageUrl,
            outputPath: outputPath,
            filename: filename,
            pinId: '${result.pinId}_img',
            overwrite: overwrite,
          );
          _logService.saved('Saved: $filename');
          downloaded++;
          
          // Record to download history
          _onDownloadComplete?.call(
            filename: filename,
            url: imageUrl,
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
              url: imageUrl,
              status: HistoryStatus.failed,
              errorMessage: e.message,
            );
          }
        } catch (e) {
          _logService.error('Failed: $filename - $e');
          failed++;
          _onDownloadComplete?.call(
            filename: filename,
            url: imageUrl,
            status: HistoryStatus.failed,
            errorMessage: userMessage(e),
          );
        }
      }
      } // single-image path (non-carousel)
    }
    
    // Download video if requested
    if (downloadVideo && result.hasVideoContent) {
      final videoUrl = result.videoUrl;
      if (videoUrl != null) {
        // Deterministic filename: <pinId>_video.mp4
        final filename = FormatUtils.pinFilename(pinId: result.pinId, role: 'video', url: videoUrl);
        _logService.downloading('Downloading video: $filename');
        
        try {
          await _downloadService.downloadFile(
            url: videoUrl,
            outputPath: outputPath,
            filename: filename,
            pinId: '${result.pinId}_vid',
            overwrite: overwrite,
          );
          _logService.saved('Saved: $filename');
          downloaded++;
          
          // Record to download history
          _onDownloadComplete?.call(
            filename: filename,
            url: videoUrl,
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
              url: videoUrl,
              status: HistoryStatus.failed,
              errorMessage: e.message,
            );
          }
        } catch (e) {
          _logService.error('Failed: $filename - $e');
          failed++;
          _onDownloadComplete?.call(
            filename: filename,
            url: videoUrl,
            status: HistoryStatus.failed,
            errorMessage: userMessage(e),
          );
        }
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

  Future<void> _downloadUserPins(
    String outputPath,
    MediaType mediaType,
    bool overwrite, {
    bool saveMetadata = false,
  }) async {
    final pins = state.pins;
    final author = state.author;
    final isVideoOnly = mediaType == MediaType.video;
    
    // Build folder paths: PinDL/@username/Images or PinDL/@username/Videos
    final username = author?.username ?? 'unknown';
    final baseFolder = 'PinDL/@$username';
    final imagesFolder = '$baseFolder/Images';
    final videosFolder = '$baseFolder/Videos';
    
    // Build download queue following Node.js logic:
    // - If user selects ONLY "video": download only videos.video_list.V_720P.url
    // - If user selects ONLY "image": download images.orig.url AND video thumbnails
    // - (Note: current UI only allows single selection for username mode)
    
    // Aggregate all URLs to download
    // Added isHls flag for HLS video conversion support
    // role: 'video', 'image', or 'thumbnail' — used for deterministic filename generation
    final List<({String pinId, String title, String url, bool isVideo, bool isHls, String subFolder, String role})> downloadItems = [];
    
    for (final pin in pins) {
      if (isVideoOnly) {
        // Video mode: only download video URLs
        if (pin.hasVideo && pin.videoUrl?.url != null) {
          // Check if this is an HLS video that needs conversion
          final isHls = pin.videoUrl!.isHls;
          downloadItems.add((
            pinId: pin.pinId,
            title: pin.title,
            url: pin.videoUrl!.url,
            isVideo: true,
            isHls: isHls,
            subFolder: videosFolder,
            role: 'video',
          ));
        }
      } else {
        // Image mode: download image URLs (and thumbnails for video pins)
        if (pin.hasImage && pin.imageUrl != null) {
          downloadItems.add((
            pinId: pin.pinId,
            title: pin.title,
            url: pin.imageUrl!,
            isVideo: false,
            isHls: false,
            subFolder: imagesFolder,
            role: 'image',
          ));
        } else if (pin.hasVideo && pin.thumbnail != null) {
          // For video pins without separate image, download thumbnail
          downloadItems.add((
            pinId: pin.pinId,
            title: pin.title,
            url: pin.thumbnail!,
            isVideo: false,
            isHls: false,
            subFolder: imagesFolder,
            role: 'thumbnail',
          ));
        }
      }
    }
    
    if (downloadItems.isEmpty) {
      _logService.error('No ${mediaType.name}s found in pins');
      state = state.copyWith(
        status: JobStatus.completed,
      );
      return;
    }
    
    // In continue mode, skip items up to lastIndexDownloaded — but ONLY when
    // the current media type matches the previously downloaded media type.
    // If the user switches types (e.g. images → videos), start from 0.
    final bool sameMediaType = state.previousMediaType == null || 
        state.previousMediaType == mediaType.name;
    final startIndex = state.isContinueMode && state.lastIndexDownloaded >= 0 && sameMediaType
        ? state.lastIndexDownloaded + 1 
        : 0;
    
    if (startIndex >= downloadItems.length) {
      _logService.complete('All items already downloaded!');
      state = state.copyWith(
        status: JobStatus.completed,
        downloadedCount: state.previousDownloaded,
        skippedCount: state.previousSkipped,
        failedCount: state.previousFailed,
      );
      return;
    }
    
    // Filter items to download (skip already completed ones)
    final itemsToDownload = downloadItems.sublist(startIndex);
    
    // Log aggregation stats (including HLS count)
    final videoCount = itemsToDownload.where((i) => i.isVideo).length;
    final hlsCount = itemsToDownload.where((i) => i.isHls).length;
    final mp4Count = videoCount - hlsCount;
    final imageCount = itemsToDownload.where((i) => !i.isVideo).length;
    
    if (state.isContinueMode) {
      _logService.queue('Continue mode: skipping first $startIndex items');
      _logService.queue('Remaining to download: $imageCount images, $videoCount videos (${mp4Count} MP4, $hlsCount HLS), total ${itemsToDownload.length} items');
    } else {
      _logService.queue('To be downloaded: $imageCount images, $videoCount videos (${mp4Count} MP4, $hlsCount HLS)');
    }
    if (hlsCount > 0) {
      if (BuildConfig.enableFfmpeg) {
        _logService.queue('HLS videos will be converted to MP4 using FFmpeg');
      } else {
        _logService.queue('Lite mode: HLS videos will be fetched via single-pin extraction');
      }
    }
    _logService.queue('Output: Downloads/$baseFolder');
    
    // Build a map of pinId -> (url, filename) for history tracking
    final Map<String, (String url, String filename)> pinUrlMap = {};
    
    // D-04 resume truth: the completion sets are authoritative; the derived
    // v1-compatible last_index_downloaded is computed at write time via
    // maxContiguous(session ∪ previous) inside MetadataReader.buildV2Metadata.
    
    // Separate HLS items (need special processing) from regular items
    final hlsItems = itemsToDownload.where((i) => i.isHls).toList();
    final regularItems = itemsToDownload.where((i) => !i.isHls).toList();
    
    // Add regular items to download queue
    for (var i = 0; i < regularItems.length; i++) {
      final item = regularItems[i];
      // Deterministic filename based on pinId and role
      final filename = FormatUtils.pinFilename(pinId: item.pinId, role: item.role, url: item.url);
      pinUrlMap[item.pinId] = (item.url, filename);
      
      _downloadService.enqueue(
        id: '${item.pinId}_${startIndex + i}',
        pinId: item.pinId,
        title: item.title.isEmpty ? item.pinId : item.title,
        url: item.url,
        outputPath: outputPath,
        filename: filename,
        overwrite: overwrite,
        subFolder: item.subFolder,
      );
    }
    
    // D-04 completion-set tracking: indices are absolute (downloadItems
    // coordinates). The previous session's set merges only when the media
    // type matches (otherwise indices refer to a different item list).
    final sessionCompleted = <int>{};
    final previousCompleted = sameMediaType ? state.previousCompletedIndices : const <int>{};
    final regularIndexByPin = <String, int>{
      for (var i = 0; i < regularItems.length; i++) regularItems[i].pinId: startIndex + i,
    };

    // Process regular queue first
    if (regularItems.isNotEmpty) {
      await _downloadService.processQueue(
        overwrite: overwrite,
        subFolder: isVideoOnly ? videosFolder : imagesFolder,
        onCompleted: (pinId) {
          _logService.saved('Saved: $pinId');
          // D-04: success = complete → enters the completion set.
          final idx = regularIndexByPin[pinId];
          if (idx != null) sessionCompleted.add(idx);

          state = state.copyWith(
            downloadedCount: state.downloadedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          
          final info = pinUrlMap[pinId];
          if (info != null) {
            _onDownloadComplete?.call(
              filename: info.$2,
              url: info.$1,
              status: HistoryStatus.success,
            );
          }
        },
        onSkipped: (pinId, reason) {
          _logService.skipped('Skipped $pinId: $reason');
          // D-04: explicit skip = complete → enters the completion set.
          final idx = regularIndexByPin[pinId];
          if (idx != null) sessionCompleted.add(idx);

          state = state.copyWith(
            skippedCount: state.skippedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          _updatePersistedProgress(
            currentIndex: state.currentIndex,
            skippedCount: state.skippedCount,
          );
        },
        onFailed: (pinId, error) {
          _logService.error('Failed $pinId: $error');
          // D-04: failed = INCOMPLETE → hole; NOT in the completion set;
          // continue re-offers it. Index bookkeeping still advances.

          state = state.copyWith(
            failedCount: state.failedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          _updatePersistedProgress(
            currentIndex: state.currentIndex,
            failedCount: state.failedCount,
            failedPinId: pinId,
          );
          
          final info = pinUrlMap[pinId];
          if (info != null) {
            _onDownloadComplete?.call(
              filename: info.$2,
              url: info.$1,
              status: HistoryStatus.failed,
              errorMessage: error,
            );
          }
        },
      );
    }
    
    // Process HLS items — strategy depends on build flavor
    if (BuildConfig.enableFfmpeg && _hlsService != null && _hlsConverter != null) {
      // ── FFmpeg build: HLS parsing + FFmpeg conversion ──
      for (var i = 0; i < hlsItems.length; i++) {
        if (_downloadCancelToken?.isCancelled ?? false) break;
        
        final item = hlsItems[i];
        final outputFilename = FormatUtils.pinFilename(pinId: item.pinId, role: 'video', url: item.url);  // HLS -> MP4
        pinUrlMap[item.pinId] = (item.url, outputFilename);
        
        _logService.downloading('HLS video: Fetching playlist for ${item.pinId}...');
        
        try {
          // Step 1: Check if output file already exists (skip if overwrite is false)
          if (!overwrite) {
            final exists = await _downloadService.fileExistsInDownloads(outputFilename, videosFolder);
            if (exists) {
              _logService.skipped('Skipped ${item.pinId}: File exists');
              sessionCompleted.add(startIndex + regularItems.length + i);

              state = state.copyWith(
                skippedCount: state.skippedCount + 1,
                currentIndex: state.currentIndex + 1,
              );
              continue;
            }
          }
          
          // Step 2: Fetch and parse HLS master playlist
          final hlsResult = await _hlsService.fetchAndParse(item.url);
          
          if (!hlsResult.success) {
            throw Exception('HLS parse failed: ${hlsResult.errorMessage}');
          }
          
          _logService.parse('HLS variant: ${hlsResult.width}x${hlsResult.height} @ ${hlsResult.bandwidth ?? 0} bps');
          
          // Step 3: Convert HLS to MP4 using FFmpeg
          _logService.downloading('Converting HLS -> MP4...');
          
          final conversionResult = await _hlsConverter.convertToMp4(
            videoM3u8Url: hlsResult.videoVariantUrl!,
            audioM3u8Url: hlsResult.audioUrl,
            outputFilename: outputFilename,
            onLog: (log) {
              // Only log important messages (not every frame)
              if (log.contains('frame=') && log.contains('fps=')) {
                // Skip verbose frame logs
              } else if (log.isNotEmpty) {
                print('[FFmpeg] $log');
              }
            },
            cancelToken: _downloadCancelToken,
          );
          
          if (!conversionResult.success) {
            if (conversionResult.wasCancelled) {
              // Phase 05 truth table: cancelled = INCOMPLETE (re-offered on
              // continue) — never counted failed, no history entry.
              _logService.interrupted('HLS conversion cancelled: ${item.pinId}');
              continue;
            }
            throw Exception('FFmpeg conversion failed: ${conversionResult.errorMessage}');
          }
          
          // Step 4: Move converted MP4 to public Downloads
          final savedPath = await _downloadService.saveFileToDownloads(
            conversionResult.outputPath!,
            outputFilename,
            videosFolder,
            overwrite: overwrite,
          );
          
          if (savedPath != null) {
            _logService.saved('Saved: $outputFilename');
            sessionCompleted.add(startIndex + regularItems.length + i);

            state = state.copyWith(
              downloadedCount: state.downloadedCount + 1,
              currentIndex: state.currentIndex + 1,
            );
            
            _onDownloadComplete?.call(
              filename: outputFilename,
              url: item.url,
              status: HistoryStatus.success,
            );
          } else {
            throw Exception('Failed to save converted file to Downloads');
          }
        } catch (e) {
          _logService.error('HLS failed ${item.pinId}: $e');

          state = state.copyWith(
            failedCount: state.failedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          
          _onDownloadComplete?.call(
            filename: outputFilename,
            url: item.url,
            status: HistoryStatus.failed,
            errorMessage: userMessage(e),
          );
        }
      }
    } else {
      // ── Lite build: HLS conversion unsupported — honest skip (HLS-4/05.5).
      // The old "fallback" re-fetched the pin page for a direct MP4 the feed
      // already proved absent — a guaranteed failure after a wasted request.
      // Now: skip upfront with an explicit reason; explicit skip = complete
      // per the truth table (in the set; not re-offered on continue).
      if (hlsItems.isNotEmpty) {
        _logService.queue(
            '${hlsItems.length} HLS video(s) skipped — require the FFmpeg build');
      }
      for (var i = 0; i < hlsItems.length; i++) {
        if (_downloadCancelToken?.isCancelled ?? false) break;
        final item = hlsItems[i];
        _logService.skipped('Skipped ${item.pinId}: HLS video — requires FFmpeg build');
        sessionCompleted.add(startIndex + regularItems.length + i);
        state = state.copyWith(
          skippedCount: state.skippedCount + 1,
          currentIndex: state.currentIndex + 1,
        );
      }
    }
    
    // Check if download was cancelled/interrupted - save resume stats
    final wasInterrupted = state.status == JobStatus.cancelled;
    
    // Accumulate counts across sessions:
    // success_downloaded = previous sessions' total + this session's count
    final totalDownloaded = state.previousDownloaded + state.downloadedCount;
    final totalSkipped = state.previousSkipped + state.skippedCount;
    final totalFailed = state.previousFailed + state.failedCount;
    
    // Save user metadata if requested (to PinDL/@username/<userId>.json)
    // Phase 04: schema v2 — carries the authoritative completion set
    // (D-04 truth table) + v1-compatible derived fields.
    if (saveMetadata && author != null) {
      final mergedCompleted = sessionCompleted.union(
        sameMediaType ? previousCompleted : const <int>{},
      );
      final metadataJson = MetadataReader.buildV2Metadata(
        author: author,
        pins: pins,
        completedIndices: mergedCompleted,
        totalImages: state.totalImages,
        totalVideos: state.totalVideos,
        successDownloaded: totalDownloaded,
        skipDownloaded: totalSkipped,
        failedDownloaded: totalFailed,
        wasInterrupted: wasInterrupted,
        mediaType: mediaType.name,
        nextBookmark: state.nextBookmark,
        bookmarkContext: state.bookmarkContext,
      );
      await _saveMetadata(baseFolder, '${author.userId}.json', metadataJson);
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
