import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';
import '../../data/services/task_state_persistence.dart';
import '../../data/services/notification_helper.dart';
import '../../data/services/download_service.dart';
import 'job_provider.dart';

/// Manages the foreground service lifecycle based on app lifecycle transitions.
///
/// Core behavior:
/// - Notification appears ONLY when app is backgrounded AND a task is active
/// - Progress bar rendered via flutter_local_notifications (separate from FGS notification)
/// - Completion heads-up with sound shown ONLY when app is backgrounded
/// - State synced between service and UI on transitions
class ForegroundServiceManager with WidgetsBindingObserver {
  final WidgetRef _ref;
  final TaskStatePersistence _persistence;
  final NotificationHelper _notificationHelper = NotificationHelper();
  bool _isServiceRunning = false;
  bool _isInitialized = false;
  bool _isInBackground = false;
  StreamSubscription? _progressSubscription;
  DateTime? _taskStartedAt;

  ForegroundServiceManager({
    required WidgetRef ref,
    required TaskStatePersistence persistence,
  })  : _ref = ref,
        _persistence = persistence;

  /// Whether the app is currently in the background.
  bool get isInBackground => _isInBackground;

  /// Whether the foreground service is running.
  bool get isServiceRunning => _isServiceRunning;

  /// Initialize the foreground task configuration.
  /// Must be called once, typically in HomePage.initState.
  void init() {
    if (_isInitialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // MUST match NotificationHelper._progressChannelId so both FGS and
        // flutter_local_notifications post to the same Android channel.
        // FGS creates notification with serviceId=256, then flutter_local_notifications
        // overwrites it (same ID 256, same channel) with progress bar content.
        channelId: 'pindl_progress',
        channelName: 'Download Progress',
        channelDescription: 'Shows progress of active downloads and extractions',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        showWhen: false,
        visibility: NotificationVisibility.VISIBILITY_PUBLIC,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    // Initialize flutter_local_notifications for progress bars and completion
    _notificationHelper.init();

    WidgetsBinding.instance.addObserver(this);
    _isInitialized = true;

    // Request notification permission on Android 13+
    _requestNotificationPermission();
  }

  /// Request POST_NOTIFICATIONS permission (Android 13+ / API 33+).
  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('Failed to request notification permission: $e');
    }
  }

  /// Whether there is an active task running (extraction or download).
  bool get _hasActiveTask {
    final jobState = _ref.read(jobProvider);
    return jobState.isExtracting || jobState.isDownloading;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _onAppBackgrounded();
        break;
      case AppLifecycleState.resumed:
        _onAppResumed();
        break;
      default:
        break;
    }
  }

  /// Called when app transitions to background.
  Future<void> _onAppBackgrounded() async {
    _isInBackground = true;
    if (!_hasActiveTask || _isServiceRunning) return;

    final jobState = _ref.read(jobProvider);
    final title = jobState.isExtracting
        ? 'Extracting: @${jobState.input ?? 'unknown'}'
        : 'Downloading (${jobState.currentIndex}/${jobState.totalItems})';
    final body = jobState.isExtracting
        ? 'Extracting in background'
        : 'Downloading in background';

    try {
      // Start the foreground service to keep process alive.
      // This notification is MIN importance / VISIBILITY_SECRET — it won't
      // appear in the status bar or shade. All user-visible notifications
      // are handled by flutter_local_notifications (NotificationHelper).
      await FlutterForegroundTask.startService(
        notificationTitle: 'PinDL',
        notificationText: 'Running in background',
        serviceId: 256,
        callback: _backgroundTaskCallback,
      );
      _isServiceRunning = true;
      _taskStartedAt ??= DateTime.now();

      // Show initial progress bar notification
      if (jobState.isExtracting) {
        _notificationHelper.showIndeterminateProgress(
          title: title,
          body: body,
        );
      } else if (jobState.isDownloading) {
        _notificationHelper.showProgress(
          title: title,
          body: body,
          progress: 0,
          maxProgress: 100,
        );
      }

      // Subscribe to download progress stream for byte-level updates
      _progressSubscription?.cancel();
      _progressSubscription =
          _ref.read(downloadServiceProvider).progressStream.listen((progress) {
        if (_isServiceRunning && _isInBackground) {
          _onDownloadByteProgress(progress);
        }
      });
    } catch (e) {
      debugPrint('Failed to start foreground service: $e');
    }
  }

  /// Called when app returns to foreground.
  Future<void> _onAppResumed() async {
    _isInBackground = false;
    if (!_isServiceRunning) return;

    try {
      await FlutterForegroundTask.stopService();
      _isServiceRunning = false;
      _progressSubscription?.cancel();
      _progressSubscription = null;
      // Cancel ALL task-related notifications (progress + completion) — UI takes over
      await _notificationHelper.cancelAll();
    } catch (e) {
      debugPrint('Failed to stop foreground service: $e');
    }
  }

  /// Handle byte-level download progress from DownloadService stream.
  void _onDownloadByteProgress(DownloadProgress progress) {
    if (!_isServiceRunning || !_isInBackground) return;

    final jobState = _ref.read(jobProvider);
    final title =
        'Downloading (${jobState.currentIndex}/${jobState.totalItems}): '
        '${progress.title}';
    final body =
        'success: ${jobState.downloadedCount}, '
        'skipped: ${jobState.skippedCount}, '
        'failed: ${jobState.failedCount}';

    // Update progress bar notification with byte-level progress
    final received = progress.received;
    final total = progress.total;

    if (total > 0) {
      final percent = ((received / total) * 100).clamp(0, 100).toInt();
      _notificationHelper.showProgress(
        title: title,
        body: body,
        progress: percent,
        maxProgress: 100,
      );
    } else {
      _notificationHelper.showIndeterminateProgress(
        title: title,
        body: body,
      );
    }
  }

  /// Update extraction progress notification (called from JobNotifier).
  void updateExtractionNotification({
    required String username,
    required int itemCount,
    required int currentPage,
    required int maxPage,
  }) {
    if (!_isServiceRunning || !_isInBackground) return;

    final title = 'Extracting: @$username';
    final body = 'collecting items: $itemCount, pages: $currentPage/$maxPage';

    // Update progress bar (flutter_local_notifications only — no FGS updateService)
    if (maxPage > 0) {
      _notificationHelper.showProgress(
        title: title,
        body: body,
        progress: currentPage,
        maxProgress: maxPage,
      );
    } else {
      _notificationHelper.showIndeterminateProgress(
        title: title,
        body: body,
      );
    }
  }

  /// Update download item-level notification (called from JobNotifier).
  /// Note: byte-level progress is handled by _onDownloadByteProgress via the
  /// progress stream. This method is intentionally a no-op now that FGS
  /// updateService() calls have been removed (Issue 1 fix). Item-level text
  /// updates are folded into the byte-progress notification instead.
  void updateDownloadItemNotification({
    required int currentIndex,
    required int totalItems,
    required String filename,
    required int downloaded,
    required int skipped,
    required int failed,
  }) {
    // No-op: all notification updates go through flutter_local_notifications
    // via _onDownloadByteProgress and updateExtractionNotification.
  }

  /// Record when a task starts (for duration calculation).
  void onTaskStarted() {
    _taskStartedAt = DateTime.now();
  }

  /// Notify that the task has completed.
  /// Shows heads-up completion notification with sound ONLY if app is in background.
  Future<void> onTaskCompleted({required String taskType}) async {
    // Calculate duration
    final duration = _taskStartedAt != null
        ? DateTime.now().difference(_taskStartedAt!)
        : Duration.zero;
    final durationStr = NotificationHelper.formatDuration(duration);

    final label = taskType == 'extraction' ? 'Extract' : 'Download';

    // Show completion heads-up ONLY if in background
    if (_isInBackground) {
      await _notificationHelper.cancelProgress();
      await _notificationHelper.showCompletion(
        title: '$label Complete',
        body: '$label completed in $durationStr',
      );
    }

    // Stop foreground service if running
    await stopService();
    _taskStartedAt = null;
  }

  /// Stop service and cleanup.
  Future<void> stopService() async {
    if (!_isServiceRunning) return;

    try {
      await FlutterForegroundTask.stopService();
      _isServiceRunning = false;
      _progressSubscription?.cancel();
      _progressSubscription = null;
      await _notificationHelper.cancelProgress();
    } catch (e) {
      debugPrint('Failed to stop foreground service: $e');
    }
  }

  /// Dispose: remove observer, stop service, cancel subscriptions.
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressSubscription?.cancel();
    if (_isServiceRunning) {
      FlutterForegroundTask.stopService();
      _isServiceRunning = false;
    }
    _notificationHelper.cancelAll();
  }
}

/// Top-level callback required by flutter_foreground_task.
@pragma('vm:entry-point')
void _backgroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(PinDLTaskHandler());
}

/// Minimal TaskHandler implementation.
/// The actual work continues in the main isolate's existing services.
class PinDLTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[PinDLTaskHandler] Service started at $timestamp by $starter');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Not used — we use eventAction: nothing()
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'cancel') {
      debugPrint('[PinDLTaskHandler] Cancel button pressed from notification');
      FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint(
      '[PinDLTaskHandler] Service destroyed at $timestamp, isTimeout=$isTimeout',
    );

    if (isTimeout) {
      debugPrint('[PinDLTaskHandler] Timeout detected — scheduling WorkManager recovery');
      try {
        await Workmanager().registerOneOffTask(
          'pindl_recovery_${DateTime.now().millisecondsSinceEpoch}',
          'pindl_background_recovery',
          constraints: Constraints(
            networkType: NetworkType.connected,
          ),
          initialDelay: const Duration(seconds: 5),
        );
      } catch (e) {
        debugPrint('[PinDLTaskHandler] Failed to schedule WorkManager: $e');
      }
    }
  }
}

/// Provider for TaskStatePersistence
final taskStatePersistenceProvider = Provider<TaskStatePersistence>((ref) {
  return TaskStatePersistence();
});

/// Provider for ForegroundServiceManager
final foregroundServiceManagerProvider =
    Provider.family<ForegroundServiceManager, WidgetRef>((ref, widgetRef) {
  final persistence = ref.watch(taskStatePersistenceProvider);
  return ForegroundServiceManager(ref: widgetRef, persistence: persistence);
});
