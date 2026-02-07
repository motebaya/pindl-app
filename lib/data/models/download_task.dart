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

  /// Progress percentage (0.0 to 1.0)
  double get progress {
    if (totalBytes == null || totalBytes == 0) return 0;
    return (downloadedBytes ?? 0) / totalBytes!;
  }

  /// Check if download is in progress
  bool get isInProgress => status == DownloadStatus.downloading;

  /// Check if download is complete
  bool get isComplete => status == DownloadStatus.completed;

  /// Check if download failed
  bool get isFailed => status == DownloadStatus.failed;

  /// Full file path
  String get fullPath => '$outputPath/$filename';

  DownloadTask copyWith({
    String? id,
    String? pinId,
    String? title,
    String? url,
    String? outputPath,
    String? filename,
    DownloadStatus? status,
    String? error,
    int? totalBytes,
    int? downloadedBytes,
    DateTime? createdAt,
    DateTime? completedAt,
    String? subFolder,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      pinId: pinId ?? this.pinId,
      title: title ?? this.title,
      url: url ?? this.url,
      outputPath: outputPath ?? this.outputPath,
      filename: filename ?? this.filename,
      status: status ?? this.status,
      error: error ?? this.error,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      subFolder: subFolder ?? this.subFolder,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pinId': pinId,
      'title': title,
      'url': url,
      'outputPath': outputPath,
      'filename': filename,
      'status': status.name,
      'error': error,
      'totalBytes': totalBytes,
      'downloadedBytes': downloadedBytes,
      'createdAt': createdAt.toIso8601String(),
      'completedAt': completedAt?.toIso8601String(),
      'subFolder': subFolder,
    };
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] as String,
      pinId: json['pinId'] as String,
      title: json['title'] as String? ?? '',
      url: json['url'] as String,
      outputPath: json['outputPath'] as String,
      filename: json['filename'] as String,
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.pending,
      ),
      error: json['error'] as String?,
      totalBytes: json['totalBytes'] as int?,
      downloadedBytes: json['downloadedBytes'] as int?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
      subFolder: json['subFolder'] as String?,
    );
  }

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
