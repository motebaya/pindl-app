// HLS -> MP4 DEVICE evidence instrument (3.1.1+8).
//
// This is the one item the 3.1.1 round could only verify host-side: the exact
// FFmpeg argv was validated on a Linux host, but the parsed-HLS -> FFmpegKit
// dispatch had never produced a real MP4 ON ANDROID through the app's own
// converter (reports/3.1.1-device-bugfix.md §9 item 1). The device report that
// started this thread was a video pin saved as a 920 B `<pinId>_video.mp4`
// (the HLS master playlist itself), so "the converter runs on-device and emits
// a decode-clean MP4" is the criterion that has to be measured.
//
// It runs a LADDER, so a failure is attributable rather than mysterious:
//   A. `-version`            — does FFmpegKit execute at all here?
//   B. direct MP4 -> copy    — network + demuxer + muxer on the device;
//   C. the production path   — HlsService.parse -> HlsConverter.convertToMp4.
//
// Like integration_test/range_gate_spike_test.dart this is a ONE-SHOT evidence
// instrument: not part of the unit suite, never runs in CI, and not to be
// extended into a regression harness (the offline matrix lives in test/hls/).
// Lines are prefixed EVIDENCE| and are copied into the report.
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     -t integration_test/hls_ffmpeg_device_test.dart \
//     --flavor ffmpeg --debug --dart-define=ENABLE_FFMPEG=true -d emulator-5554
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pindl/core/config/build_config.dart';
import 'package:pindl/core/validation/media_validator.dart';
import 'package:pindl/data/services/hls_converter.dart';
import 'package:pindl/data/services/hls_service.dart';
import 'package:pindl/presentation/providers/log_provider.dart';

/// Live Pinterest HLS master of the reported pin — the exact object the old
/// code saved verbatim as an `.mp4` (920 B of playlist text).
const _hlsMaster =
    'https://v1.pinimg.com/videos/iht/hls/42/16/b2/4216b2353d83ddb92380d54c322343c8.m3u8';

/// Progressive MP4 of the same pin (control for the network/muxer leg).
const _directMp4 =
    'https://v1.pinimg.com/videos/iht/expMp4/42/16/b2/4216b2353d83ddb92380d54c322343c8_720w.mp4';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('parsed HLS -> FFmpegKit -> decode-clean MP4, on device',
      (tester) async {
    debugPrint('EVIDENCE|hls-device: build.enableFfmpeg='
        '${BuildConfig.enableFfmpeg}');
    debugPrint('EVIDENCE|hls-device: ffmpegVersion='
        '${await FFmpegKitConfig.getFFmpegVersion()} kitVersion='
        '${await FFmpegKitConfig.getVersion()}');

    // The capability banner the user actually sees on this build (closes
    // reports/3.1.1-device-bugfix.md §9 item 3).
    final container = ProviderContainer();
    addTearDown(container.dispose);
    debugPrint('EVIDENCE|hls-device: console banner='
        '${container.read(logServiceProvider).entries.first.message}');

    if (!BuildConfig.enableFfmpeg) {
      debugPrint('EVIDENCE|hls-device: SKIPPED — lite build (no FFmpegKit '
          'native libs; the app skips HLS explicitly)');
      return;
    }

    final tempDir = await getTemporaryDirectory();
    debugPrint('EVIDENCE|hls-device: tempDir=$tempDir');

    // A. Does FFmpegKit execute at all in this environment?
    final a = await FFmpegKit.executeWithArgumentsAsync(['-version']);
    await _report('A:-version', a);

    // B. Synthetic input (no file, no network): can FFmpeg produce output at
    //    all on this device?
    final bOut = '${tempDir.path}/probe_synth.mp4';
    final b = await FFmpegKit.executeWithArgumentsAsync([
      '-y',
      '-f', 'lavfi',
      '-i', 'testsrc=duration=1:size=64x64:rate=10',
      '-frames:v', '5',
      bOut,
    ]);
    await _report('B:lavfi', b);
    final bFile = File(bOut);
    debugPrint('EVIDENCE|hls-device: [B] output exists='
        '${bFile.existsSync()} size=${bFile.existsSync() ? await bFile.length() : 0}');
    if (bFile.existsSync()) await bFile.delete();

    // C. LOCAL file input (dio downloads the MP4; FFmpeg only reads the disk)
    //    — isolates FFmpeg's own network stack from its input pipeline.
    final localIn = '${tempDir.path}/probe_input.mp4';
    try {
      final response = await Dio().download(_directMp4, localIn);
      debugPrint('EVIDENCE|hls-device: [C] dio fetched '
          '${await File(localIn).length()} B (${response.statusCode})');
      final cOut = '${tempDir.path}/probe_local_copy.mp4';
      final c = await FFmpegKit.executeWithArgumentsAsync([
        '-y', '-i', localIn, '-t', '2', '-c', 'copy', cOut,
      ]);
      await _report('C:localFile', c);
      final cFile = File(cOut);
      debugPrint('EVIDENCE|hls-device: [C] output exists='
          '${cFile.existsSync()} size=${cFile.existsSync() ? await cFile.length() : 0}');
      if (cFile.existsSync()) await cFile.delete();
    } catch (e) {
      debugPrint('EVIDENCE|hls-device: [C] dio download failed: $e');
    }

    // D. REMOTE HTTP input — the case the app actually uses.
    final dOut = '${tempDir.path}/probe_direct.mp4';
    final d = await FFmpegKit.executeWithArgumentsAsync([
      '-y', '-i', _directMp4, '-t', '2', '-c', 'copy', dOut,
    ]);
    await _report('D:httpInput', d);
    final dFile = File(dOut);
    debugPrint('EVIDENCE|hls-device: [D] output exists='
        '${dFile.existsSync()} size=${dFile.existsSync() ? await dFile.length() : 0}');
    if (dFile.existsSync()) await dFile.delete();

    // C. The production path: parse the master, then convert via HlsConverter.
    final parsed = await HlsService().fetchAndParse(_hlsMaster);
    debugPrint('EVIDENCE|hls-device: [C] master parsed success=${parsed.success} '
        '${parsed.width}x${parsed.height} bandwidth=${parsed.bandwidth} '
        'audioSeparate=${parsed.audioUrl != null} '
        'variant=${parsed.videoVariantUrl}');
    expect(parsed.success, isTrue,
        reason: 'master playlist must parse: ${parsed.errorMessage}');

    final logs = <String>[];
    final stopwatch = Stopwatch()..start();
    final conversion = await HlsConverter().convertToMp4(
      videoM3u8Url: parsed.videoVariantUrl!,
      audioM3u8Url: parsed.audioUrl,
      outputFilename: 'hls_device_evidence.mp4',
      onLog: logs.add,
    );
    stopwatch.stop();

    debugPrint('EVIDENCE|hls-device: [C] conversion success=${conversion.success} '
        'cancelled=${conversion.wasCancelled} '
        'error=${conversion.errorMessage ?? 'none'}');
    for (final line in logs.take(20)) {
      debugPrint('EVIDENCE|hls-device: [C] log| $line');
    }
    debugPrint('EVIDENCE|hls-device: [C] elapsedMs='
        '${stopwatch.elapsedMilliseconds}');

    if (!conversion.success) {
      debugPrint('EVIDENCE|hls-device: [C] FAILED — see the ladder above: '
          'step A says whether FFmpegKit executes at all on this device, '
          'step B whether network+muxer work');
      expect(conversion.success, isTrue,
          reason: 'production HLS conversion failed: '
              '${conversion.errorMessage}');
      return;
    }

    // The artifact is a real MP4 by the app's own validator (size floor +
    // ISO-BMFF brand) — the check the old flow never ran on this file.
    final file = File(conversion.outputPath!);
    final size = await file.length();
    final brand = await _brand(file);
    final verdict = await HlsConverter.validateMp4File(conversion.outputPath!);
    final media = await MediaValidator.validateFile(
      conversion.outputPath!,
      expect: MediaExpectation.video,
    );

    debugPrint('EVIDENCE|hls-device: [C] bytes=$size brand=$brand '
        'validateMp4=${verdict ?? 'OK'} '
        'mediaValidator=${media.ok ? 'OK' : media.reason} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}');
    debugPrint('EVIDENCE|hls-device: [C] the SAME url saved as bytes is 920 B '
        'of m3u8 text (the reported corrupt file); this artifact is $size B '
        'with brand "$brand"');

    expect(verdict, isNull, reason: 'converted output must be a valid MP4');
    expect(media.ok, isTrue, reason: media.reason);
    expect(size, greaterThan(100000),
        reason: 'a real converted video is not a few hundred bytes');

    await file.delete();
  });
}

Future<void> _report(String label, FFmpegSession session) async {
  final code = await session.getReturnCode();
  final logs = await session.getAllLogsAsString() ?? '';
  debugPrint('EVIDENCE|hls-device: [$label] rc=${code?.getValue()} '
      'success=${ReturnCode.isSuccess(code)} logs=${logs.length}B');
  for (final line in logs.split('\n').take(12)) {
    if (line.trim().isEmpty || line.startsWith('  lib')) continue;
    if (line.startsWith('  configuration:') ||
        line.startsWith('  built with')) {
      continue;
    }
    debugPrint('EVIDENCE|hls-device: [$label]| $line');
  }
}

Future<String> _brand(File file) async {
  final raf = await file.open();
  try {
    final head = await raf.read(12);
    if (head.length < 12) return '????';
    return String.fromCharCodes(head.sublist(4, 8));
  } finally {
    await raf.close();
  }
}
