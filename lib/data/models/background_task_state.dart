import 'package:hive/hive.dart';

/// Persisted background task state for foreground service resume capability.
///
/// Written to Hive on every meaningful progress event.
/// Read on app resume/relaunch to detect and recover interrupted tasks.
///
/// TypeId: 1 (first Hive model in PinDL)
class BackgroundTaskState extends HiveObject {
  /// UUID identifying this task
  String taskId;

  /// 'extraction' or 'download'
  String taskType;

  /// Username (without @) for extraction/user downloads
  String? username;

  /// Total items in the task
  int totalItems;

  /// Current progress cursor
  int currentIndex;

  /// Successful completions
  int successCount;

  /// Skipped items (already exist)
  int skippedCount;

  /// Failed items
  int failedCount;

  /// Current extraction page (for extraction tasks)
  int currentPage;

  /// Max pages configured (for extraction tasks)
  int maxPages;

  /// Last bookmark from Pinterest API (for extraction resume)
  String? lastBookmark;

  /// Bytes received for current download
  int bytesReceived;

  /// Total bytes for current download
  int bytesTotal;

  /// 'active' | 'completed' | 'interrupted' | 'failed'
  String status;

  /// When the task started
  DateTime startedAt;

  /// Last update timestamp
  DateTime updatedAt;

  /// 'image' | 'video'
  String? mediaType;

  /// Overwrite existing files
  bool overwrite;

  /// Save metadata after download
  bool saveMetadata;

  /// Currently downloading filename
  String? currentFilename;

  /// Last error message
  String? errorMessage;

  /// Pin IDs that failed (for retry support)
  List<String> failedPinIds;

  BackgroundTaskState({
    required this.taskId,
    required this.taskType,
    this.username,
    this.totalItems = 0,
    this.currentIndex = 0,
    this.successCount = 0,
    this.skippedCount = 0,
    this.failedCount = 0,
    this.currentPage = 0,
    this.maxPages = 50,
    this.lastBookmark,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.status = 'active',
    DateTime? startedAt,
    DateTime? updatedAt,
    this.mediaType,
    this.overwrite = false,
    this.saveMetadata = false,
    this.currentFilename,
    this.errorMessage,
    List<String>? failedPinIds,
  })  : startedAt = startedAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now(),
        failedPinIds = failedPinIds ?? [];

  /// Check if this task was interrupted and can be resumed
  bool get isInterrupted => status == 'interrupted';

  /// Check if this task is active
  bool get isActive => status == 'active';

  /// Check if this is an extraction task
  bool get isExtraction => taskType == 'extraction';

  /// Check if this is a download task
  bool get isDownload => taskType == 'download';

  /// Mark task as interrupted and update timestamp
  void markInterrupted({String? error}) {
    status = 'interrupted';
    errorMessage = error;
    updatedAt = DateTime.now();
    if (isInBox) save();
  }

  /// Mark task as completed
  void markCompleted() {
    status = 'completed';
    updatedAt = DateTime.now();
    if (isInBox) save();
  }

  /// Mark task as failed
  void markFailed(String error) {
    status = 'failed';
    errorMessage = error;
    updatedAt = DateTime.now();
    if (isInBox) save();
  }

  /// Update progress and persist
  void updateProgress({
    int? currentIndex,
    int? successCount,
    int? skippedCount,
    int? failedCount,
    int? currentPage,
    int? totalItems,
    String? lastBookmark,
    int? bytesReceived,
    int? bytesTotal,
    String? currentFilename,
    String? failedPinId,
  }) {
    if (currentIndex != null) this.currentIndex = currentIndex;
    if (successCount != null) this.successCount = successCount;
    if (skippedCount != null) this.skippedCount = skippedCount;
    if (failedCount != null) this.failedCount = failedCount;
    if (currentPage != null) this.currentPage = currentPage;
    if (totalItems != null) this.totalItems = totalItems;
    if (lastBookmark != null) this.lastBookmark = lastBookmark;
    if (bytesReceived != null) this.bytesReceived = bytesReceived;
    if (bytesTotal != null) this.bytesTotal = bytesTotal;
    if (currentFilename != null) this.currentFilename = currentFilename;
    if (failedPinId != null) failedPinIds.add(failedPinId);
    updatedAt = DateTime.now();
    if (isInBox) save();
  }

  @override
  String toString() =>
      'BackgroundTaskState($taskId, $taskType, status=$status, '
      'progress=$currentIndex/$totalItems, '
      'success=$successCount, skip=$skippedCount, fail=$failedCount)';
}

/// Hand-written Hive TypeAdapter for [BackgroundTaskState].
/// Avoids build_runner code generation for a single model.
class BackgroundTaskStateAdapter extends TypeAdapter<BackgroundTaskState> {
  @override
  final int typeId = 1;

  @override
  BackgroundTaskState read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return BackgroundTaskState(
      taskId: fields[0] as String,
      taskType: fields[1] as String,
      username: fields[2] as String?,
      totalItems: fields[3] as int? ?? 0,
      currentIndex: fields[4] as int? ?? 0,
      successCount: fields[5] as int? ?? 0,
      skippedCount: fields[6] as int? ?? 0,
      failedCount: fields[7] as int? ?? 0,
      currentPage: fields[8] as int? ?? 0,
      maxPages: fields[9] as int? ?? 50,
      lastBookmark: fields[10] as String?,
      bytesReceived: fields[11] as int? ?? 0,
      bytesTotal: fields[12] as int? ?? 0,
      status: fields[13] as String? ?? 'active',
      startedAt: fields[14] as DateTime?,
      updatedAt: fields[15] as DateTime?,
      mediaType: fields[16] as String?,
      overwrite: fields[17] as bool? ?? false,
      saveMetadata: fields[18] as bool? ?? false,
      currentFilename: fields[19] as String?,
      errorMessage: fields[20] as String?,
      failedPinIds: (fields[21] as List?)?.cast<String>() ?? [],
    );
  }

  @override
  void write(BinaryWriter writer, BackgroundTaskState obj) {
    writer
      ..writeByte(22) // number of fields
      ..writeByte(0)
      ..write(obj.taskId)
      ..writeByte(1)
      ..write(obj.taskType)
      ..writeByte(2)
      ..write(obj.username)
      ..writeByte(3)
      ..write(obj.totalItems)
      ..writeByte(4)
      ..write(obj.currentIndex)
      ..writeByte(5)
      ..write(obj.successCount)
      ..writeByte(6)
      ..write(obj.skippedCount)
      ..writeByte(7)
      ..write(obj.failedCount)
      ..writeByte(8)
      ..write(obj.currentPage)
      ..writeByte(9)
      ..write(obj.maxPages)
      ..writeByte(10)
      ..write(obj.lastBookmark)
      ..writeByte(11)
      ..write(obj.bytesReceived)
      ..writeByte(12)
      ..write(obj.bytesTotal)
      ..writeByte(13)
      ..write(obj.status)
      ..writeByte(14)
      ..write(obj.startedAt)
      ..writeByte(15)
      ..write(obj.updatedAt)
      ..writeByte(16)
      ..write(obj.mediaType)
      ..writeByte(17)
      ..write(obj.overwrite)
      ..writeByte(18)
      ..write(obj.saveMetadata)
      ..writeByte(19)
      ..write(obj.currentFilename)
      ..writeByte(20)
      ..write(obj.errorMessage)
      ..writeByte(21)
      ..write(obj.failedPinIds);
  }
}
