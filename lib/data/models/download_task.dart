import 'package:equatable/equatable.dart';

/// Status of a download task
enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  skipped,
  cancelled,
}

/// Represents a single download task
class DownloadTask extends Equatable {
  final String id;
  final String pinId;
  final String title;
  final String url;
  final String outputPath;
  final String filename;
  final DownloadStatus status;
  final String? error;
  final int? totalBytes;
  final int? downloadedBytes;
  final DateTime createdAt;
  final DateTime? completedAt;
  /// Subfolder path under Downloads, e.g. "PinDL/@username/Images"
  final String? subFolder;

  const DownloadTask({
    required this.id,
    required this.pinId,
    required this.title,
    required this.url,
    required this.outputPath,
    required this.filename,
    this.status = DownloadStatus.pending,
    this.error,
    this.totalBytes,
    this.downloadedBytes,
    required this.createdAt,
    this.completedAt,
    this.subFolder,
  });

  @override
  List<Object?> get props => [
        id,
        pinId,
        title,
        url,
        outputPath,
        filename,
        status,
        error,
        totalBytes,
        downloadedBytes,
        createdAt,
        completedAt,
        subFolder,
      ];
}
