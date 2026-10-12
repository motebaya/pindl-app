import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/constants/pinterest_constants.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/network/media_hosts.dart';
import '../../core/network/range_resume.dart';
import '../../core/network/retry.dart';
import '../../core/utils/format_utils.dart';
import '../../core/validation/media_validator.dart';
import '../models/download_task.dart';
import 'log_service.dart';

/// Callback for download progress
typedef DownloadProgressCallback = void Function(
  String pinId,
  int received,
  int total,
  int currentIndex,
  int totalItems,
);

/// Callback for download status changes
typedef DownloadStatusCallback = void Function(
  String pinId,
  DownloadStatus status,
  String? error,
);

/// Download service with queue management
/// Ported from Node.js downloader.js
/// 
/// Storage structure:
/// Downloads/PinDL/
///   @username/
///     Images/
///     Videos/
///     `<userId>.json` (user metadata)
///   metadata/
///     `<pinId>.json` (single pin metadata)
class DownloadService {
  final Dio _dio;
  final int maxConcurrent;
  final LogService? _logService;

  // Method channel for MediaScanner
  static const _mediaChannel = MethodChannel('com.motebaya.pindl/media');

  final List<DownloadTask> _queue = [];
  final Map<String, CancelToken> _activeTokens = {};
  int _activeDownloads = 0;
  bool _isCancelled = false;
  bool _isPaused = false;

  /// Phase 06 retention sweep: runs once per service lifetime (per run),
  /// mirroring the HLS converter's 24 h stale-temp sweep (D-05 bound).
  bool _sweptPartsOnce = false;
  
  // Store the actual output path used (for reporting to user)
  String? _actualOutputPath;
  String? get actualOutputPath => _actualOutputPath;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  DownloadService({
    Dio? dio,
    this.maxConcurrent = 3,
    LogService? logService,
  })  : _logService = logService,
        _dio = dio ?? _createDio();

  /// Retry telemetry to the console panel (extraction/03 step 4); console
  /// panel (not print) keeps the analyzer print baseline unchanged.
  void _logRetry(String message) => _logService?.fetch('retry: $message');

  /// Phase 06 retention policy: `.part` / `.part.meta.json` files in the temp
  /// dir older than 24 h (the D-05 bound) are deleted once per run. Fresh
  /// interrupted state survives for byte-level resume (RangeResume).
  void _sweepStalePartsOnce(Directory tempDir) {
    if (_sweptPartsOnce) return;
    _sweptPartsOnce = true;
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    var swept = 0;
    try {
      for (final e in tempDir.listSync()) {
        final name = e.uri.pathSegments.last;
        if (!name.endsWith('.part') && !name.endsWith('.part.meta.json')) {
          continue;
        }
        try {
          if (e.statSync().modified.isBefore(cutoff)) {
            e.deleteSync();
            swept++;
          }
        } catch (_) {}
      }
    } catch (_) {}
    if (swept > 0) _logRetry('swept $swept stale part file(s) (>= 24 h)');
  }

  static Dio _createDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {
        'User-Agent': PinterestConstants.userAgent,
        // 3.1.1: media files are already compressed — asking for identity
        // keeps Content-Length authoritative, so byte-range resume and the
        // completion check compare like with like (a compressed response's
        // Content-Length describes the wire body, not the decoded stream).
        'Accept-Encoding': 'identity',
      },
    ));
  }
  
  /// Trigger MediaScanner to make file visible in gallery/file explorer
  Future<void> _scanFile(String filePath) async {
    try {
      if (Platform.isAndroid) {
        await _mediaChannel.invokeMethod('scanFile', {'path': filePath});
      }
    } catch (e) {
      // Ignore if method channel not available - file still exists
      print('MediaScanner error (non-fatal): $e');
    }
  }
  
  /// Save a file from temp path to public Downloads directory (public API for HLS converter)
  /// Returns the public path where file was saved
  Future<String?> saveFileToDownloads(String tempPath, String filename, String subFolder, {bool overwrite = true}) async {
    return _saveToPublicDownloads(tempPath, filename, subFolder, overwrite: overwrite);
  }
  
  /// Save a temp file to public Downloads directory via MediaStore
  /// Returns the public path where file was saved
  /// 
  /// [subFolder] - The subfolder path under PinDL, e.g. "@username/Images"
  /// [overwrite] - If true, delete existing file before saving; if false, MediaStore may auto-rename
  Future<String?> _saveToPublicDownloads(String tempPath, String filename, String subFolder, {bool overwrite = true}) async {
    try {
      if (Platform.isAndroid) {
        final mimeType = _getMimeType(filename);
        final result = await _mediaChannel.invokeMethod<String>('saveFileToDownloads', {
          'sourcePath': tempPath,
          'filename': filename,
          'mimeType': mimeType,
          'subFolder': subFolder,
          'overwrite': overwrite,
        });
        return result;
      }
      return null;
    } catch (e) {
      print('saveFileToDownloads error: $e');
      return null;
    }
  }
  
  /// Get MIME type from filename extension
  String _getMimeType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mov':
        return 'video/quicktime';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }
  
  /// Check if a file already exists in the public Downloads folder (public API)
  Future<bool> fileExistsInDownloads(String filename, String subFolder) async {
    return _fileExistsInDownloads(filename, subFolder);
  }
  
  /// Check if a file already exists in the public Downloads folder
  Future<bool> _fileExistsInDownloads(String filename, String subFolder) async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<bool>('fileExists', {
          'filename': filename,
          'subFolder': subFolder,
        });
        return result ?? false;
      }
      return false;
    } catch (e) {
      print('fileExists check error: $e');
      return false;
    }
  }
  
  /// Save text content to public Downloads directory
  /// Used for metadata JSON files
  Future<String?> saveTextToDownloads(String content, String filename, String subFolder) async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<String>('saveTextToFile', {
          'content': content,
          'filename': filename,
          'subFolder': subFolder,
        });
        return result;
      }
      return null;
    } catch (e) {
      print('saveTextToFile error: $e');
      return null;
    }
  }
  
  /// Read text content from public Downloads directory
  /// Used for reading metadata JSON files for continue mode
  Future<String?> readTextFromDownloads(String filename, String subFolder) async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<String>('readTextFromFile', {
          'filename': filename,
          'subFolder': subFolder,
        });
        return result;
      }
      return null;
    } catch (e) {
      print('readTextFromFile error: $e');
      return null;
    }
  }
  
  /// List files in a folder
  /// Used for checking existing downloads in continue mode
  Future<List<String>> listFilesInFolder(String subFolder, {String? extension}) async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<List<dynamic>>('listFilesInFolder', {
          'subFolder': subFolder,
          'extension': ?extension,
        });
        return result?.cast<String>() ?? [];
      }
      return [];
    } catch (e) {
      print('listFilesInFolder error: $e');
      return [];
    }
  }
  
  /// Check if MANAGE_EXTERNAL_STORAGE permission is granted (Android 11+)
  /// Required for "continue" mode to work after app reinstall
  Future<bool> hasManageStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<bool>('hasManageStoragePermission');
        return result ?? false;
      }
      return true; // Other platforms don't need this permission
    } catch (e) {
      // Phase 11.6: channel errors must not masquerade as "not granted"
      // silently (AND-1 diagnostics class).
      debugPrint('hasManageStoragePermission channel error: $e');
      return false;
    }
  }
  
  /// Request MANAGE_EXTERNAL_STORAGE permission (Android 11+)
  /// Opens system settings for the user to grant permission
  /// Returns true if permission was already granted
  Future<bool> requestManageStoragePermission() async {
    try {
      if (Platform.isAndroid) {
        final result = await _mediaChannel.invokeMethod<bool>('requestManageStorage');
        return result ?? false;
      }
      return true;
    } catch (e) {
      // Phase 11.6: same diagnostics rule as hasManageStoragePermission.
      debugPrint('requestManageStoragePermission channel error: $e');
      return false;
    }
  }
  
  /// Get a valid writable path for downloads
  /// On Android 11+, user-selected paths outside app-scoped storage may
  /// not be writable via dart:io
  /// Returns: (writablePath, isUserSelectedPath)
  Future<(String, bool)> getWritablePathWithInfo(String requestedPath) async {
    // Try the requested path first
    final requestedDir = Directory(requestedPath);
    try {
      if (!await requestedDir.exists()) {
        await requestedDir.create(recursive: true);
      }
      // Test if we can write to this directory
      final testFile = File(p.join(requestedPath, '.pindl_test_${DateTime.now().millisecondsSinceEpoch}'));
      await testFile.writeAsString('test');
      await testFile.delete();
      return (requestedPath, true); // Path is writable
    } catch (e) {
      print('Cannot write to $requestedPath: $e');
      // Path not writable (Android 11+ scoped storage restriction)
      // Fall back to app-specific external storage
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        // Create a PinDL subfolder
        final pindlDir = Directory(p.join(appDir.path, 'PinDL'));
        if (!await pindlDir.exists()) {
          await pindlDir.create(recursive: true);
        }
        return (pindlDir.path, false);
      }
      // Ultimate fallback: app documents directory
      final docsDir = await getApplicationDocumentsDirectory();
      final pindlDir = Directory(p.join(docsDir.path, 'PinDL'));
      if (!await pindlDir.exists()) {
        await pindlDir.create(recursive: true);
      }
      return (pindlDir.path, false);
    }
  }
  
  /// Legacy method for compatibility
  Future<String> getWritablePath(String requestedPath) async {
    final (path, _) = await getWritablePathWithInfo(requestedPath);
    return path;
  }

  /// Add item to download queue
  /// [subFolder] should include the full path like "PinDL/@username/Images"
  void enqueue({
    required String id,
    required String pinId,
    required String title,
    required String url,
    required String outputPath,
    required String filename,
    required bool overwrite,
    String? subFolder,
  }) {
    _queue.add(DownloadTask(
      id: id,
      pinId: pinId,
      title: title,
      url: url,
      outputPath: outputPath,
      filename: FormatUtils.sanitizeFilename(filename),
      createdAt: DateTime.now(),
      subFolder: subFolder,
    ));
  }

  /// Process download queue
  Future<void> processQueue({
    required void Function(String pinId) onCompleted,
    required void Function(String pinId, String reason) onSkipped,
    required void Function(String pinId, String error) onFailed,
    required bool overwrite,
    void Function(int current, int total)? onProgress,
    String subFolder = 'PinDL',
  }) async {
    _isCancelled = false;
    _isPaused = false;
    final totalItems = _queue.length;
    var currentIndex = 0;

    while (_queue.isNotEmpty && !_isCancelled) {
      // Wait while paused
      while (_isPaused && !_isCancelled) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (_isCancelled) break;

      // Start new downloads up to max concurrent limit
      while (_activeDownloads < maxConcurrent &&
          _queue.isNotEmpty &&
          !_isCancelled) {
        final task = _queue.removeAt(0);
        currentIndex++;
        _processTask(
          task: task,
          overwrite: overwrite,
          currentIndex: currentIndex,
          totalItems: totalItems,
          onCompleted: onCompleted,
          onSkipped: onSkipped,
          onFailed: onFailed,
          subFolder: task.subFolder ?? subFolder,
        );
      }

      // Wait a bit before checking again
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Wait for remaining downloads
    while (_activeDownloads > 0 && !_isCancelled) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _processTask({
    required DownloadTask task,
    required bool overwrite,
    required int currentIndex,
    required int totalItems,
    required void Function(String pinId) onCompleted,
    required void Function(String pinId, String reason) onSkipped,
    required void Function(String pinId, String error) onFailed,
    required String subFolder,
  }) async {
    _activeDownloads++;
    final cancelToken = CancelToken();
    _activeTokens[task.pinId] = cancelToken;

    try {
      // SEC-2: media-host allowlist (boundary matching, canonical D-08).
      // Fail-closed: a non-allowlisted host is never fetched, never imported.
      // (Inside try so the finally bookkeeping below always runs.) The host
      // rides in the reason string so console/history record it for the
      // one-line allowlist addition (security/02 escape hatch).
      if (!MediaHosts.isAllowed(task.url)) {
        final host = Uri.tryParse(task.url)?.host ?? task.url;
        onFailed(task.pinId, '${MediaHosts.rejectionReason}: $host');
        return;
      }
      // Check if file already exists in Downloads (skip if overwrite is false)
      if (!overwrite) {
        final exists = await _fileExistsInDownloads(task.filename, subFolder);
        if (exists) {
          onSkipped(task.pinId, 'File exists');
          return;
        }
      }
      
      // Use temp directory for downloading (always writable)
      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(tempDir.path, '${task.pinId}_${task.filename}');
      final partPath = '$tempPath.part';

      // Clean up any existing temp-final file. The `.part` + sidecar are the
      // byte-level resume state (Phase 06) — retained across interruptions
      // and swept only when stale (_sweepStalePartsOnce).
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      _sweepStalePartsOnce(tempDir);

      // Byte-level resume (Phase 06, gate G0/D-30): continues a previous
      // transfer from the persisted offset on a verified 206, and falls back
      // to one clean full restart on any mismatch/anomaly. D-03 bounded
      // retries re-invoke it; each attempt resumes when eligible.
      await retry(
        () => RangeResume.download(
          _dio,
          task.url,
          partPath,
          cancelToken: cancelToken,
          onProgress: (received, total) {
            if (total > 0) {
              _progressController.add(DownloadProgress(
                pinId: task.pinId,
                title: task.title,
                received: received,
                total: total,
                currentIndex: currentIndex,
                totalItems: totalItems,
              ));
            }
          },
        ),
        cancelToken: cancelToken,
        onLog: _logRetry,
      );

      // Rename .part to temp final — the sidecar has served its purpose and
      // dies with the completed part.
      await File(partPath).rename(tempPath);
      final partMeta = File('$partPath.meta.json');
      if (await partMeta.exists()) await partMeta.delete();

      // DL-2/SEC-4: fail-closed content validation before anything is
      // imported or counted complete. Corrupt/mismatched bodies become a
      // FAILED item with a diagnosable reason — never a false success.
      final verdict = await MediaValidator.validateFile(
        tempPath,
        expect: _expectationFor(task.filename),
      );
      if (!verdict.ok) {
        _logRetry('validation failed for ${task.filename}: ${verdict.reason}');
        try {
          await File(tempPath).delete();
        } catch (_) {}
        throw DownloadException(
          'validation failed: ${verdict.reason}',
          filePath: tempPath,
        );
      }

      // Save to public Downloads via MediaStore (deletes temp file internally)
      // Pass overwrite flag to control whether existing file should be replaced
      final publicPath = await _saveToPublicDownloads(tempPath, task.filename, subFolder, overwrite: overwrite);
      
      if (publicPath != null) {
        _actualOutputPath = 'Downloads/$subFolder';
        print('Saved to public: $publicPath');
      } else {
        // Fallback: file stays in temp, scan it
        await _scanFile(tempPath);
        _actualOutputPath = tempDir.path;
        print('Fallback: saved to temp: $tempPath');
      }

      onCompleted(task.pinId);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // Phase 06 (06.4): cancellation PRESERVES `.part` + sidecar so the
        // next run resumes from the recorded offset (contract: cancel is an
        // interruption, not a discard). Only the temp-final file is cleaned.
        try {
          final tempDir = await getTemporaryDirectory();
          final tempPath = p.join(tempDir.path, '${task.pinId}_${task.filename}');
          final tempFile = File(tempPath);
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        // Don't call onFailed for cancellation
      } else {
        onFailed(task.pinId, e.message ?? 'Download error');
      }
    } catch (e) {
      onFailed(task.pinId, e.toString());
    } finally {
      _activeDownloads--;
      _activeTokens.remove(task.pinId);
    }
  }

  /// Infer the expected media super-type from the filename extension.
  /// null = no expectation (signature still required for image-named files).
  static MediaExpectation? _expectationFor(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'bmp':
        return MediaExpectation.image;
      case 'mp4':
      case 'webm':
      case 'mov':
      case 'm4v':
        return MediaExpectation.video;
      default:
        return null;
    }
  }

  /// Download a single file
  /// Returns the public path where file was saved (or null if fallback)
  /// Throws DownloadException with 'File already exists' if overwrite is false and file exists
  Future<String?> downloadFile({
    required String url,
    required String outputPath,
    required String filename,
    required String pinId,
    required bool overwrite,
    String subFolder = 'PinDL',
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final safeFilename = FormatUtils.sanitizeFilename(filename);

    // SEC-2: media-host allowlist (boundary matching, canonical D-08).
    if (!MediaHosts.isAllowed(url)) {
      final host = Uri.tryParse(url)?.host ?? url;
      throw DownloadException('${MediaHosts.rejectionReason}: $host');
    }

    // Check if file already exists in Downloads (skip if overwrite is false)
    if (!overwrite) {
      final exists = await _fileExistsInDownloads(safeFilename, subFolder);
      if (exists) {
        throw DownloadException(
          'File already exists',
          filePath: 'Downloads/$subFolder/$safeFilename',
        );
      }
    }
    
    // Use temp directory for downloading (always writable)
    final tempDir = await getTemporaryDirectory();
    final tempPath = p.join(tempDir.path, '${pinId}_$safeFilename');
    final partPath = '$tempPath.part';

    // Clean up any existing temp-final file. The `.part` + sidecar are the
    // byte-level resume state (Phase 06) — retained across interruptions.
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    _sweepStalePartsOnce(tempDir);

    try {
      // Byte-level resume (Phase 06, gate G0/D-30) — see _processTask.
      await retry(
        () => RangeResume.download(
          _dio,
          url,
          partPath,
          cancelToken: cancelToken,
          onProgress: onProgress,
        ),
        onLog: _logRetry,
      );

      // Rename .part to temp final — sidecar dies with the completed part.
      await File(partPath).rename(tempPath);
      final partMeta = File('$partPath.meta.json');
      if (await partMeta.exists()) await partMeta.delete();

      // DL-2/SEC-4: fail-closed content validation before public save.
      final verdict = await MediaValidator.validateFile(
        tempPath,
        expect: _expectationFor(safeFilename),
      );
      if (!verdict.ok) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
        throw DownloadException(
          'validation failed: ${verdict.reason}',
          filePath: tempPath,
        );
      }

      // Save to public Downloads via MediaStore (deletes temp file internally)
      // For single file download, always use overwrite mode (existence check already done)
      final publicPath = await _saveToPublicDownloads(tempPath, safeFilename, subFolder, overwrite: overwrite);
      
      if (publicPath != null) {
        _actualOutputPath = 'Downloads/$subFolder';
        print('Saved to public: $publicPath');
        return publicPath;
      } else {
        // Fallback: scan the temp file
        await _scanFile(tempPath);
        _actualOutputPath = tempDir.path;
        print('Fallback: saved to temp: $tempPath');
        return tempPath;
      }
    } on DioException catch (e) {
      // Phase 06 (06.4): interrupted transfers PRESERVE `.part` + sidecar —
      // network errors resume from the persisted offset on the next attempt
      // or next run; cancellation preserves too (contract). Only the
      // temp-final file is cleaned here.
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}

      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw DownloadException(
        'Download failed: ${e.message}',
        filePath: tempPath,
        originalError: e,
      );
    }
  }

  /// Cancel all active downloads
  Future<void> cancelAll() async {
    _isCancelled = true;
    _queue.clear();

    for (final token in _activeTokens.values) {
      token.cancel('User cancelled');
    }
    _activeTokens.clear();
  }

  /// Cancel a specific download
  void cancelDownload(String pinId) {
    _activeTokens[pinId]?.cancel('User cancelled');
    _activeTokens.remove(pinId);
  }

  // Phase 12.3 (CQ-3): pauseQueue/resumeQueue/isPaused removed — dead code
  // (no callers; UI pause feature does not exist; git history preserves them).
  // JobStatus.paused stays (persisted state enum value; do not renumber).

  /// Get queue size
  int get queueSize => _queue.length;

  /// Check if any downloads are active
  bool get hasActiveDownloads => _activeDownloads > 0;

  /// Clear the queue
  void clearQueue() {
    _queue.clear();
  }

  /// Dispose resources
  void dispose() {
    cancelAll();
    _progressController.close();
    _dio.close();
  }
}

/// Progress information for a download
class DownloadProgress {
  final String pinId;
  final String title;
  final int received;
  final int total;
  final int currentIndex;
  final int totalItems;

  DownloadProgress({
    required this.pinId,
    required this.title,
    required this.received,
    required this.total,
    required this.currentIndex,
    required this.totalItems,
  });

  double get percentage => total > 0 ? received / total : 0;
}
