import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/build_config.dart';
import '../../core/exceptions/pinterest_exception.dart';
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
import 'history_provider.dart';
import 'log_provider.dart';

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
  
  /// Derived state: can start download (Phase C only)
  bool get canDownload => 
      status == JobStatus.readyToDownload && 
      (pins.isNotEmpty || singlePinResult != null);
  
  /// Derived state: can submit new request
  bool get canSubmit => 
      status == JobStatus.idle || 
      status == JobStatus.completed || 
      status == JobStatus.failed || 
      status == JobStatus.cancelled ||
      status == JobStatus.readyToDownload;

  int get totalItems => pins.length;
  
  /// Calculate remaining items for continue mode
  int get remainingImages {
    if (!isContinueMode || lastIndexDownloaded < 0) return totalImages;
    return (totalImages - (lastIndexDownloaded + 1)).clamp(0, totalImages);
  }
  
  int get remainingVideos {
    if (!isContinueMode || lastIndexDownloaded < 0) return totalVideos;
    return (totalVideos - (lastIndexDownloaded + 1)).clamp(0, totalVideos);
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
  final void Function({
    required String filename,
    required String url,
    required HistoryStatus status,
    String? errorMessage,
  })? _onDownloadComplete;
  
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

    final isUsername = inputType == 'username';
    _extractCancelToken = CancelToken();

    // Transition to Phase B: fetchingInfo
    state = AppJobState(
      status: JobStatus.fetchingInfo,
      input: input,
      isUsername: isUsername,
    );

    _logService.init('Loading info for: $input');

    try {
      if (isUsername) {
        await _extractUserPins(input, mediaType, saveMetadata: saveMetadata, maxPages: maxPages);
      } else {
        await _extractSinglePin(input, mediaType);
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
        error: e.toString(),
      );
    }
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
      },
    );
    
    _logService.parse('Parsed ${result.pins.length} pins');
    _logService.parse('Images: ${result.totalImages}, Videos: ${result.totalVideos}');
    
    // Transition to Phase C: readyToDownload
    state = state.copyWith(
      status: JobStatus.readyToDownload,
      author: result.author,
      pins: result.pins,
      totalImages: result.totalImages,
      totalVideos: result.totalVideos,
    );
    
    // REVISION 1: Save metadata immediately after parsing (before download)
    if (saveMetadata && result.author != null) {
      final baseFolder = 'PinDL/@$normalizedUsername';
      final metadataJson = {
        'author': result.author.toJson(),
        'pins': result.pins.map((p) => p.toJson()).toList(),
        'totalImages': result.totalImages,
        'totalVideos': result.totalVideos,
        'success_downloaded': 0,
        'skip_downloaded': 0,
        'failed_downloaded': 0,
        'last_index_downloaded': -1,
        'was_interrupted': false,
        'status': 'parsed', // Mark as parsed but not downloaded yet
        'media_type': mediaType.name,
        'saved_at': DateTime.now().toIso8601String(),
      };
      await _saveMetadata(baseFolder, '${result.author.userId}.json', metadataJson);
      _logService.saved('Metadata saved for @${result.author.username}');
    }
    
    _logService.complete('Info loaded for @${result.author.username}. Ready to download.');
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
      
      // Parse the JSON
      final json = jsonDecode(content) as Map<String, dynamic>;
      final result = UserPinsResult.fromMetadataJson(json);
      
      _logService.parse('Loaded metadata for @${result.author.username}');
      _logService.parse('Previous stats: Downloaded ${result.successDownloaded}, Skipped ${result.skipDownloaded}, Failed ${result.failedDownloaded}');
      _logService.parse('Last index: ${result.lastIndexDownloaded}, Was interrupted: ${result.wasInterrupted}');
      
      // Update state with loaded metadata
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
        lastIndexDownloaded: result.lastIndexDownloaded,
        wasInterrupted: result.wasInterrupted,
        isContinueMode: true,
      );
      
      final remainingImages = state.remainingImages;
      final remainingVideos = state.remainingVideos;
      _logService.complete('Ready to continue. Remaining: $remainingImages images, $remainingVideos videos');
      
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
        error: e.toString(),
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
      final imageUrl = result.getImageDownloadUrl(useThumbnailForVideo: true);
      if (imageUrl != null) {
        final filename = imageUrl.split('/').last;
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
            errorMessage: e.toString(),
          );
        }
      }
    }
    
    // Download video if requested
    if (downloadVideo && result.hasVideoContent) {
      final videoUrl = result.videoUrl;
      if (videoUrl != null) {
        final filename = videoUrl.split('/').last;
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
            errorMessage: e.toString(),
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
    final List<({String pinId, String title, String url, bool isVideo, bool isHls, String subFolder})> downloadItems = [];
    
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
    
    // In continue mode, skip items up to lastIndexDownloaded
    final startIndex = state.isContinueMode && state.lastIndexDownloaded >= 0 
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
    
    // Track last completed index for resume (continue from previous lastIndex)
    int lastCompletedIndex = state.isContinueMode ? state.lastIndexDownloaded : -1;
    
    // Separate HLS items (need special processing) from regular items
    final hlsItems = itemsToDownload.where((i) => i.isHls).toList();
    final regularItems = itemsToDownload.where((i) => !i.isHls).toList();
    
    // Add regular items to download queue
    for (var i = 0; i < regularItems.length; i++) {
      final item = regularItems[i];
      final filename = item.url.split('/').last;
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
    
    // Process regular queue first
    if (regularItems.isNotEmpty) {
      await _downloadService.processQueue(
        overwrite: overwrite,
        subFolder: isVideoOnly ? videosFolder : imagesFolder,
        onCompleted: (pinId) {
          _logService.saved('Saved: $pinId');
          lastCompletedIndex = startIndex + state.currentIndex;
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
          lastCompletedIndex = startIndex + state.currentIndex;
          state = state.copyWith(
            skippedCount: state.skippedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
        },
        onFailed: (pinId, error) {
          _logService.error('Failed $pinId: $error');
          lastCompletedIndex = startIndex + state.currentIndex;
          state = state.copyWith(
            failedCount: state.failedCount + 1,
            currentIndex: state.currentIndex + 1,
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
        final outputFilename = '${item.pinId}.mp4';  // HLS -> MP4
        pinUrlMap[item.pinId] = (item.url, outputFilename);
        
        _logService.downloading('HLS video: Fetching playlist for ${item.pinId}...');
        
        try {
          // Step 1: Check if output file already exists (skip if overwrite is false)
          if (!overwrite) {
            final exists = await _downloadService.fileExistsInDownloads(outputFilename, videosFolder);
            if (exists) {
              _logService.skipped('Skipped ${item.pinId}: File exists');
              lastCompletedIndex = startIndex + regularItems.length + i;
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
          );
          
          if (!conversionResult.success) {
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
            lastCompletedIndex = startIndex + regularItems.length + i;
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
          lastCompletedIndex = startIndex + regularItems.length + i;
          state = state.copyWith(
            failedCount: state.failedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          
          _onDownloadComplete?.call(
            filename: outputFilename,
            url: item.url,
            status: HistoryStatus.failed,
            errorMessage: e.toString(),
          );
        }
      }
    } else {
      // ── Lite build: fallback to single-pin extraction for direct MP4 ──
      for (var i = 0; i < hlsItems.length; i++) {
        if (_downloadCancelToken?.isCancelled ?? false) break;
        
        final item = hlsItems[i];
        final outputFilename = '${item.pinId}.mp4';
        pinUrlMap[item.pinId] = (item.url, outputFilename);
        
        _logService.downloading('Lite mode: fetching direct video for ${item.pinId}...');
        
        try {
          // Step 1: Check if output file already exists (skip if overwrite is false)
          if (!overwrite) {
            final exists = await _downloadService.fileExistsInDownloads(outputFilename, videosFolder);
            if (exists) {
              _logService.skipped('Skipped ${item.pinId}: File exists');
              lastCompletedIndex = startIndex + regularItems.length + i;
              state = state.copyWith(
                skippedCount: state.skippedCount + 1,
                currentIndex: state.currentIndex + 1,
              );
              continue;
            }
          }
          
          // Step 2: Use single-pin extraction to attempt direct MP4 retrieval
          // Construct pin URL from pinId and call getPinVideo -> parseVideoData
          final pinUrl = 'https://www.pinterest.com/pin/${item.pinId}/';
          final mediaResult = await _extractor.getPinVideo(
            pinIdOrUrl: pinUrl,
            cancelToken: _downloadCancelToken,
          );
          
          if (mediaResult.videoUrl != null) {
            // Direct MP4 found — download it normally
            final videoFilename = mediaResult.videoUrl!.split('/').last;
            final finalFilename = videoFilename.endsWith('.mp4') ? videoFilename : outputFilename;
            
            await _downloadService.downloadFile(
              url: mediaResult.videoUrl!,
              outputPath: outputPath,
              filename: finalFilename,
              pinId: item.pinId,
              overwrite: overwrite,
              subFolder: videosFolder,
            );
            
            _logService.saved('Saved: $finalFilename');
            lastCompletedIndex = startIndex + regularItems.length + i;
            state = state.copyWith(
              downloadedCount: state.downloadedCount + 1,
              currentIndex: state.currentIndex + 1,
            );
            
            _onDownloadComplete?.call(
              filename: finalFilename,
              url: mediaResult.videoUrl!,
              status: HistoryStatus.success,
            );
          } else {
            // No direct video URL available from single-pin extraction
            throw Exception(
              'Failed to fetch direct video URL. Please use the FFmpeg build to download this video.',
            );
          }
        } catch (e) {
          _logService.error('Failed ${item.pinId}: $e');
          lastCompletedIndex = startIndex + regularItems.length + i;
          state = state.copyWith(
            failedCount: state.failedCount + 1,
            currentIndex: state.currentIndex + 1,
          );
          
          _onDownloadComplete?.call(
            filename: outputFilename,
            url: item.url,
            status: HistoryStatus.failed,
            errorMessage: e.toString(),
          );
        }
      }
    }
    
    // Check if download was cancelled/interrupted - save resume stats
    final wasInterrupted = state.status == JobStatus.cancelled;
    
    // Calculate combined stats (previous + current session)
    final totalDownloaded = state.previousDownloaded + state.downloadedCount;
    final totalSkipped = state.previousSkipped + state.skippedCount;
    final totalFailed = state.previousFailed + state.failedCount;
    
    // Save user metadata if requested (to PinDL/@username/<userId>.json)
    if (saveMetadata && author != null) {
      final metadataJson = {
        'author': author.toJson(),
        'pins': pins.map((p) => p.toJson()).toList(),
        'totalImages': state.totalImages,
        'totalVideos': state.totalVideos,
        'success_downloaded': totalDownloaded,
        'skip_downloaded': totalSkipped,
        'failed_downloaded': totalFailed,
        'last_index_downloaded': lastCompletedIndex,
        'was_interrupted': wasInterrupted,
        'media_type': mediaType.name,
        'saved_at': DateTime.now().toIso8601String(),
      };
      await _saveMetadata(baseFolder, '${author.userId}.json', metadataJson);
    }
    
    if (!wasInterrupted) {
      state = state.copyWith(
        status: JobStatus.completed,
      );
    }
    
    final sessionStats = 'Session: ${state.downloadedCount} downloaded, ${state.skippedCount} skipped, ${state.failedCount} failed';
    final totalStats = state.isContinueMode 
        ? ' | Total: $totalDownloaded downloaded, $totalSkipped skipped, $totalFailed failed'
        : '';
    
    _logService.complete(
      'Download ${wasInterrupted ? "interrupted" : "complete"}. $sessionStats$totalStats',
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
  
  return JobNotifier(
    logService: ref.watch(logServiceProvider),
    extractor: ref.watch(pinterestExtractorProvider),
    downloadService: ref.watch(downloadServiceProvider),
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
