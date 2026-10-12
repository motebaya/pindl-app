import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/config/build_config.dart';
import 'package:pindl/data/services/log_service.dart';
import 'package:pindl/presentation/providers/log_provider.dart';

/// 3.1.1 — the console must state the build's HLS capability on the first
/// frame. Device report: an HLS pin silently produced a corrupt
/// `<pinId>_video.mp4` and there was "no error show in console"; on the next QA
/// round the tester must be able to tell instantly whether the installed APK
/// can convert HLS at all (an `ffmpeg`-flavor APK built without
/// `--dart-define=ENABLE_FFMPEG=true` is exactly the trap this surfaces).
void main() {
  group('startup capability banner (3.1.1)', () {
    test('the log service opens with a CONFIG HLS capability line', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final service = container.read(logServiceProvider);
      expect(service.entries, isNotEmpty);

      final first = service.entries.first;
      expect(first.level, LogLevel.config);
      expect(first.message, contains('HLS -> MP4 conversion'));

      // The banner must agree with the compiled-in flag — never claim
      // conversion on a lite build or deny it on an ffmpeg build.
      final expected = BuildConfig.enableFfmpeg
          ? 'ENABLED (ffmpeg build)'
          : 'DISABLED (lite build)';
      expect(first.message, contains(expected));
    });

    test('a single container read does not duplicate the banner', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(logServiceProvider);
      container.read(logServiceProvider);
      final service = container.read(logServiceProvider);

      final banners = service.entries
          .where((e) => e.message.contains('HLS -> MP4 conversion'))
          .length;
      expect(banners, 1);
    });
  });
}
