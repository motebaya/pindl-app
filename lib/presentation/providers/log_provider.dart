import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config/build_config.dart';
import '../../data/services/log_service.dart';

/// Provider for log service
final logServiceProvider = Provider<LogService>((ref) {
  final service = LogService();

  // Capability banner (3.1.1). Device report: an HLS pin produced a corrupt
  // 920 B `<pinId>_video.mp4` and "no error show in console" — the user could
  // not tell whether this APK even carries HLS conversion. The console now
  // states it on the first frame, so a lite APK (or an ffmpeg APK built without
  // `--dart-define=ENABLE_FFMPEG=true`) is visible immediately instead of
  // surfacing as a mysterious skip.
  service.config(
    BuildConfig.enableFfmpeg
        ? 'HLS -> MP4 conversion: ENABLED (ffmpeg build)'
        : 'HLS -> MP4 conversion: DISABLED (lite build) — HLS videos are skipped',
  );

  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for log stream
final logStreamProvider = StreamProvider<LogEntry>((ref) {
  final service = ref.watch(logServiceProvider);
  return service.stream;
});

/// Provider for current log entries
final logEntriesProvider = Provider<List<LogEntry>>((ref) {
  final service = ref.watch(logServiceProvider);
  return service.entries;
});
