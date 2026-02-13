import 'package:hive_flutter/hive_flutter.dart';
import '../models/background_task_state.dart';

/// Persistence service for background task state using Hive.
///
/// Provides a thin wrapper around the Hive box for [BackgroundTaskState].
/// Ensures only one active task exists at a time and handles throttled writes
/// for byte-level progress updates (max 1 write/sec).
class TaskStatePersistence {
  static const String boxName = 'background_tasks';
  static const String _activeTaskKey = 'active_task';

  Box<BackgroundTaskState>? _box;
  DateTime? _lastByteProgressWrite;

  /// Initialize by opening the Hive box.
  /// Call this after Hive.initFlutter() in main.dart.
  Future<void> init() async {
    _box = await Hive.openBox<BackgroundTaskState>(boxName);
  }

  /// Get the box (must call init first).
  Box<BackgroundTaskState> get box {
    if (_box == null || !_box!.isOpen) {
      throw StateError(
        'TaskStatePersistence not initialized. Call init() first.',
      );
    }
    return _box!;
  }

  /// Get the currently active/interrupted task, if any.
  BackgroundTaskState? getActiveTask() {
    try {
      return box.get(_activeTaskKey);
    } catch (_) {
      return null;
    }
  }

  /// Save a new active task (replaces any existing).
  Future<void> saveActiveTask(BackgroundTaskState state) async {
    await box.put(_activeTaskKey, state);
  }

  /// Update progress on the active task.
  /// For byte-level progress, throttles to max 1 write/sec.
  Future<void> updateProgress({
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
  }) async {
    final task = getActiveTask();
    if (task == null) return;

    // Throttle byte-level progress writes (max 1/sec)
    if (bytesReceived != null &&
        currentIndex == null &&
        successCount == null) {
      final now = DateTime.now();
      if (_lastByteProgressWrite != null &&
          now.difference(_lastByteProgressWrite!).inMilliseconds < 1000) {
        return; // Skip this write — too frequent
      }
      _lastByteProgressWrite = now;
    }

    task.updateProgress(
      currentIndex: currentIndex,
      successCount: successCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      currentPage: currentPage,
      totalItems: totalItems,
      lastBookmark: lastBookmark,
      bytesReceived: bytesReceived,
      bytesTotal: bytesTotal,
      currentFilename: currentFilename,
      failedPinId: failedPinId,
    );
  }

  /// Mark the active task as interrupted.
  Future<void> markInterrupted({String? error}) async {
    final task = getActiveTask();
    if (task == null) return;
    task.markInterrupted(error: error);
  }

  /// Mark the active task as completed and remove it.
  Future<void> markCompleted() async {
    final task = getActiveTask();
    if (task == null) return;
    task.markCompleted();
    // Remove from active tasks — completed tasks don't need to persist
    await box.delete(_activeTaskKey);
  }

  /// Mark the active task as failed.
  Future<void> markFailed(String error) async {
    final task = getActiveTask();
    if (task == null) return;
    task.markFailed(error);
  }

  /// Clear the active task (e.g., user declines to resume).
  Future<void> clearActiveTask() async {
    await box.delete(_activeTaskKey);
  }

  /// Check if there's an interrupted task that can be resumed.
  bool hasInterruptedTask() {
    final task = getActiveTask();
    return task != null && task.isInterrupted;
  }

  /// Check if there's any active task (active or interrupted).
  bool hasAnyTask() {
    return getActiveTask() != null;
  }

  /// Dispose the box.
  Future<void> dispose() async {
    if (_box != null && _box!.isOpen) {
      await _box!.close();
    }
  }
}
