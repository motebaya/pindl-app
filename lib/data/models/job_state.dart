import 'package:equatable/equatable.dart';
import 'author.dart';

/// Media type for filtering
enum MediaType { image, video }

/// Status of a job - strict state machine for submit->info->download flow
/// Phase A: idle
/// Phase B: fetchingInfo (submit phase - extracting metadata only)
/// Phase C: readyToDownload (info loaded, waiting for download confirmation)
/// Phase D: downloading
/// Phase E: completed / interrupted / failed
enum JobStatus {
  idle,           // Phase A: No operation in progress
  fetchingInfo,   // Phase B: Submit pressed - fetching/extracting info only
  readyToDownload,// Phase C: Info fetched, awaiting download confirmation
  downloading,    // Phase D: Download in progress
  paused,         // Download paused (can resume)
  completed,      // Phase E: All done successfully
  failed,         // Phase E: Operation failed
  cancelled,      // Phase E: User cancelled
}

/// Represents a download job state for persistence and resume
class JobState extends Equatable {
  final String id;
  final String input;
  final bool isUsername;
  final MediaType mediaType;
  final String outputPath;
  final bool saveMetadata;
  final bool overwrite;
  final JobStatus status;
  final Author? author;
  final int totalItems;
  final int lastDownloadedIndex;
  final Set<String> completedPinIds;
  final Set<String> skippedPinIds;
  final Set<String> failedPinIds;
  final String? error;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const JobState({
    required this.id,
    required this.input,
    required this.isUsername,
    required this.mediaType,
    required this.outputPath,
    required this.saveMetadata,
    required this.overwrite,
    this.status = JobStatus.idle,
    this.author,
    this.totalItems = 0,
    this.lastDownloadedIndex = 0,
    this.completedPinIds = const {},
    this.skippedPinIds = const {},
    this.failedPinIds = const {},
    this.error,
    required this.createdAt,
    this.updatedAt,
  });

  /// Check if job can be resumed
  bool get canResume =>
      status == JobStatus.paused ||
      status == JobStatus.cancelled ||
      (status == JobStatus.downloading && lastDownloadedIndex < totalItems);

  /// Check if job is complete
  bool get isComplete => status == JobStatus.completed;

  /// Check if job is in progress
  bool get isInProgress =>
      status == JobStatus.fetchingInfo || status == JobStatus.downloading;

  /// Get completion percentage
  double get progress {
    if (totalItems == 0) return 0;
    return (completedPinIds.length + skippedPinIds.length + failedPinIds.length) /
        totalItems;
  }

  /// Display name for the job
  String get displayName {
    if (author != null) {
      return '@${author!.username}';
    }
    return input;
  }

  JobState copyWith({
    String? id,
    String? input,
    bool? isUsername,
    MediaType? mediaType,
    String? outputPath,
    bool? saveMetadata,
    bool? overwrite,
    JobStatus? status,
    Author? author,
    int? totalItems,
    int? lastDownloadedIndex,
    Set<String>? completedPinIds,
    Set<String>? skippedPinIds,
    Set<String>? failedPinIds,
    String? error,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return JobState(
      id: id ?? this.id,
      input: input ?? this.input,
      isUsername: isUsername ?? this.isUsername,
      mediaType: mediaType ?? this.mediaType,
      outputPath: outputPath ?? this.outputPath,
      saveMetadata: saveMetadata ?? this.saveMetadata,
      overwrite: overwrite ?? this.overwrite,
      status: status ?? this.status,
      author: author ?? this.author,
      totalItems: totalItems ?? this.totalItems,
      lastDownloadedIndex: lastDownloadedIndex ?? this.lastDownloadedIndex,
      completedPinIds: completedPinIds ?? this.completedPinIds,
      skippedPinIds: skippedPinIds ?? this.skippedPinIds,
      failedPinIds: failedPinIds ?? this.failedPinIds,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'input': input,
      'isUsername': isUsername,
      'mediaType': mediaType.name,
      'outputPath': outputPath,
      'saveMetadata': saveMetadata,
      'overwrite': overwrite,
      'status': status.name,
      'author': author?.toJson(),
      'totalItems': totalItems,
      'lastDownloadedIndex': lastDownloadedIndex,
      'completedPinIds': completedPinIds.toList(),
      'skippedPinIds': skippedPinIds.toList(),
      'failedPinIds': failedPinIds.toList(),
      'error': error,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  factory JobState.fromJson(Map<String, dynamic> json) {
    return JobState(
      id: json['id'] as String,
      input: json['input'] as String,
      isUsername: json['isUsername'] as bool,
      mediaType: MediaType.values.firstWhere(
        (e) => e.name == json['mediaType'],
        orElse: () => MediaType.image,
      ),
      outputPath: json['outputPath'] as String,
      saveMetadata: json['saveMetadata'] as bool? ?? false,
      overwrite: json['overwrite'] as bool? ?? false,
      status: JobStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => JobStatus.idle,
      ),
      author: json['author'] != null
          ? Author.fromJson(json['author'] as Map<String, dynamic>)
          : null,
      totalItems: json['totalItems'] as int? ?? 0,
      lastDownloadedIndex: json['lastDownloadedIndex'] as int? ?? 0,
      completedPinIds: Set<String>.from(json['completedPinIds'] as List? ?? []),
      skippedPinIds: Set<String>.from(json['skippedPinIds'] as List? ?? []),
      failedPinIds: Set<String>.from(json['failedPinIds'] as List? ?? []),
      error: json['error'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  @override
  List<Object?> get props => [
        id,
        input,
        isUsername,
        mediaType,
        outputPath,
        saveMetadata,
        overwrite,
        status,
        author,
        totalItems,
        lastDownloadedIndex,
        completedPinIds,
        skippedPinIds,
        failedPinIds,
        error,
        createdAt,
        updatedAt,
      ];
}
