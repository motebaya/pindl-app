import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../core/constants/pinterest_constants.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/utils/format_utils.dart';
import '../models/download_task.dart';

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
///     <userId>.json (user metadata)
///   metadata/
///     <pinId>.json (single pin metadata)
class DownloadService {
  final Dio _dio;
  final int maxConcurrent;
  
  // Method channel for MediaScanner
  static const _mediaChannel = MethodChannel('com.motebaya.pindl/media');

  final List<DownloadTask> _queue = [];
  final Map<String, CancelToken> _activeTokens = {};
  int _activeDownloads = 0;
  bool _isCancelled = false;
  
  // Store the actual output path used (for reporting to user)
  String? _actualOutputPath;
  String? get actualOutputPath => _actualOutputPath;

  final _progressController = StreamController<DownloadProgress>.broadcast();
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  DownloadService({
    Dio? dio,
    this.maxConcurrent = 3,
  }) : _dio = dio ?? _createDio();

  static Dio _createDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {
        'User-Agent': PinterestConstants.userAgent,
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
  
  /// Save a temp file to public Downloads directory via MediaStore
  /// Returns the public path where file was saved
  /// 
  /// [subFolder] - The subfolder path under PinDL, e.g. "@username/Images"
  Future<String?> _saveToPublicDownloads(String tempPath, String filename, String subFolder) async {
    try {
      if (Platform.isAndroid) {
        final mimeType = _getMimeType(filename);
        final result = await _mediaChannel.invokeMethod<String>('saveFileToDownloads', {
          'sourcePath': tempPath,
          'filename': filename,
          'mimeType': mimeType,
          'subFolder': subFolder,
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
          if (extension != null) 'extension': extension,
        });
        return result?.cast<String>() ?? [];
      }
      return [];
    } catch (e) {
      print('listFilesInFolder error: $e');
      return [];
    }
  }
  
  /// Get a valid writable path for downloads
  /// On Android 11+, file_picker paths may not be writable via dart:io
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
    final totalItems = _queue.length;
    var currentIndex = 0;

    while (_queue.isNotEmpty && !_isCancelled) {
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

      // Clean up any existing temp/part files
      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      // Download to .part file in temp directory
      await _dio.download(
        task.url,
        partPath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
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
      );

      // Rename .part to temp final
      await File(partPath).rename(tempPath);
      
      // Save to public Downloads via MediaStore (deletes temp file internally)
      final publicPath = await _saveToPublicDownloads(tempPath, task.filename, subFolder);
      
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
        // Clean up temp files on cancel
        try {
          final tempDir = await getTemporaryDirectory();
          final tempPath = p.join(tempDir.path, '${task.pinId}_${task.filename}');
          final partPath = '$tempPath.part';
          final partFile = File(partPath);
          if (await partFile.exists()) await partFile.delete();
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

    // Clean up any existing temp/part files
    final partFile = File(partPath);
    if (await partFile.exists()) {
      await partFile.delete();
    }
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    try {
      await _dio.download(
        url,
        partPath,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );

      // Rename .part to temp final
      await File(partPath).rename(tempPath);
      
      // Save to public Downloads via MediaStore (deletes temp file internally)
      final publicPath = await _saveToPublicDownloads(tempPath, safeFilename, subFolder);
      
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
      // Clean up temp files on error
      try {
        if (await partFile.exists()) await partFile.delete();
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
  String get humanReceived => FormatUtils.humanSize(received);
  String get humanTotal => FormatUtils.humanSize(total);
}
