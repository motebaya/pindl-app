import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Notification helper for PinDL background tasks.
///
/// Uses flutter_local_notifications to provide:
/// 1. Progress bar notifications (ongoing, silent) — channel: pindl_progress
/// 2. Completion heads-up notifications (sound, auto-cancel) — channel: pindl_complete
///
/// flutter_foreground_task does NOT support setProgress() in its notification,
/// so we use flutter_local_notifications to overlay notifications with the
/// standard Android progress bar style.
class NotificationHelper {
  /// Must match the FGS serviceId (256) so flutter_local_notifications
  /// replaces the foreground service notification with our progress bar version.
  static const int progressNotificationId = 256;
  static const int completionNotificationId = 901;

  static const String _progressChannelId = 'pindl_progress';
  static const String _progressChannelName = 'Download Progress';
  static const String _progressChannelDesc = 'Shows progress of active downloads and extractions';

  static const String _completeChannelId = 'pindl_complete';
  static const String _completeChannelName = 'Task Completed';
  static const String _completeChannelDesc = 'Notifies when downloads or extractions finish';

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Initialize the notification plugin and create channels.
  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('ic_download_notification');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// Show or update the progress notification with a determinate progress bar.
  ///
  /// [title] — notification title (e.g. "Downloading (3/47): file.jpg")
  /// [body] — notification body (e.g. "success: 2, skipped: 0, failed: 0")
  /// [progress] — current progress value (0..maxProgress)
  /// [maxProgress] — maximum progress value
  Future<void> showProgress({
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
  }) async {
    if (!_initialized) await init();

    final androidDetails = AndroidNotificationDetails(
      _progressChannelId,
      _progressChannelName,
      channelDescription: _progressChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      onlyAlertOnce: true,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      icon: 'ic_download_notification',
      category: AndroidNotificationCategory.progress,
    );

    await _plugin.show(
      progressNotificationId,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Show or update the progress notification with an indeterminate progress bar.
  Future<void> showIndeterminateProgress({
    required String title,
    required String body,
  }) async {
    if (!_initialized) await init();

    final androidDetails = AndroidNotificationDetails(
      _progressChannelId,
      _progressChannelName,
      channelDescription: _progressChannelDesc,
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      indeterminate: true,
      onlyAlertOnce: true,
      playSound: false,
      enableVibration: false,
      showWhen: false,
      icon: 'ic_download_notification',
      category: AndroidNotificationCategory.progress,
    );

    await _plugin.show(
      progressNotificationId,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Cancel the progress notification.
  Future<void> cancelProgress() async {
    if (!_initialized) return;
    await _plugin.cancel(progressNotificationId);
  }

  /// Show completion heads-up notification with system sound.
  ///
  /// [title] — e.g. "Download Complete" or "Extraction Complete"
  /// [body] — e.g. "Download completed in 1h 2m 3s"
  ///
  /// Uses HIGH importance to trigger heads-up popup.
  /// Uses default system notification sound.
  /// Auto-cancels on tap.
  Future<void> showCompletion({
    required String title,
    required String body,
  }) async {
    if (!_initialized) await init();

    final androidDetails = AndroidNotificationDetails(
      _completeChannelId,
      _completeChannelName,
      channelDescription: _completeChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      playSound: true,
      enableVibration: true,
      showWhen: true,
      icon: 'ic_download_notification',
      category: AndroidNotificationCategory.status,
    );

    await _plugin.show(
      completionNotificationId,
      title,
      body,
      NotificationDetails(android: androidDetails),
    );
  }

  /// Cancel all notifications.
  Future<void> cancelAll() async {
    if (!_initialized) return;
    await _plugin.cancelAll();
  }

  /// Format a Duration into human-readable string.
  /// Examples: "1h 2m 3s", "5m 20s", "12s"
  static String formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }
}
