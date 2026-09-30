import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../core/utils/format_utils.dart';
import '../models/hls_conversion_result.dart';

/// HLS to MP4 conversion service using FFmpeg.
/// Ported from Node.js HLS.js convertToMp4.
///
/// Phase 05 reliability contract:
///  - Output is written to `<final>.part.mp4`; only a file that passes MP4
///    validation (size ≥ 1 KiB + ISO-BMFF brand check) is renamed to the
///    final temp name (HLS-2, atomic write).
///  - The FFmpeg session reference is held per conversion; cancelling the
///    [CancelToken] fires `FFmpegKit.cancel(sessionId)` immediately and the
///    conversion resolves CANCELLED — an incomplete item per the Phase 04
///    truth table, never "failed" (HLS-5).
///  - Temp state is bounded per D-05: on the first conversion of an app run,
///    `*.mp4`/`*.part.mp4` files older than 24 h are swept; the strict
///    "never survive past next start" guarantee is explicitly NOT made.
class HlsConverter {
  /// D-05: stale-temp age bound for the per-run sweep.
  static const Duration staleTempAge = Duration(hours: 24);

  /// MP4 validation: minimum believable size (hls/01: ≥1 KiB).
  static const int minMp4Bytes = 1024;

  bool _sweepDoneThisRun = false;

  /// Convert HLS streams to MP4
  ///
  /// [videoM3u8Url] - URL to the video variant .m3u8
  /// [audioM3u8Url] - Optional URL to the audio .m3u8 (if separate)
  /// [outputFilename] - Desired output filename (without path)
  /// [onProgress] - Optional progress callback (0.0 to 1.0)
  /// [onLog] - Optional log callback for FFmpeg output
  /// [cancelToken] - When cancelled, the FFmpeg session is aborted
  ///
  /// Returns [HlsConversionResult] with the temp file path on success
  Future<HlsConversionResult> convertToMp4({
    required String videoM3u8Url,
    String? audioM3u8Url,
    required String outputFilename,
    void Function(double progress)? onProgress,
    void Function(String log)? onLog,
    CancelToken? cancelToken,
  }) async {
    // D-05: first conversion of this app run sweeps stale temp files.
    await _sweepStaleTempOnce(onLog);
    try {
      // Get temp directory for output
      final tempDir = await getTemporaryDirectory();
      // HLS-2 atomic write: output to <final>.part.mp4; validated output is
      // renamed to the final temp name (no partial file ever presents as final).
      final outputPath = p.join(tempDir.path, outputFilename);
      final partPath = '$outputPath.part.mp4';
      
      // Clean up any existing temp/part file
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }
      
      // Build FFmpeg command
      // Matches Node.js HLS.js convertToMp4 logic
      // 
      // IMPORTANT: Pinterest uses .cmfv/.cmfa segment files (Common Media Format).
      // FFmpeg 7.x has TWO levels of extension security checks:
      // 1. HLS demuxer: fixed with -allowed_extensions ALL
      // 2. MOV/MP4 segment demuxer: fixed with -seg_format_options extension_picky=0
      //
      // We need BOTH options to handle Pinterest's non-standard segment extensions.
      final args = <String>[
        '-y',  // Overwrite output
        '-protocol_whitelist', 'file,http,https,tcp,tls,crypto',
        '-user_agent', 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
        '-headers','Referer: https://www.pinterest.com/\r\nOrigin: https://www.pinterest.com\r\n',
        '-allowed_extensions','m3u8,mp4,m4a,m4s,ts,cmfv,cmfa,key',
        '-extension_picky','0',
        '-i', videoM3u8Url,
      ];

      // Add audio input if separate
      if (audioM3u8Url != null) {
        // Each input needs its own format options
        args.addAll([
          '-allowed_extensions', 'm3u8,mp4,m4a,m4s,ts,cmfv,cmfa,key',
          '-extension_picky','0',
          '-i', audioM3u8Url,
        ]);
      }

      // Map streams
      if (audioM3u8Url != null) {
        // Separate audio: map video from input 0, audio from input 1
        args.addAll(['-map', '0:v:0', '-map', '1:a:0']);
      } else {
        // Combined or video-only: map video and optional audio from input 0
        args.addAll(['-map', '0:v:0', '-map', '0:a?']);
      }

      // Codec settings - stream copy (fast, no re-encoding)
      args.addAll([
        '-c', 'copy',  // Stream copy - fastest, no quality loss
        '-bsf:a', 'aac_adtstoasc',  // Fix AAC for MP4 container
        '-movflags', '+faststart',  // Enable progressive download
        partPath,
      ]);


      final commandForLog = args.map((a) {
        // wrap args containing spaces/newlines so the printed command looks like a real CLI command
        final needsQuote = a.contains(' ') || a.contains('\r') || a.contains('\n');
        return needsQuote ? '"${a.replaceAll('"', r'\"')}"' : a;
      }).join(' ');
      onLog?.call('FFmpeg command: ${commandForLog.replaceAll('\r\n', r'\r\n')}');

      // Enable log callback for progress
      if (onLog != null) {
        FFmpegKitConfig.enableLogCallback((log) {
          onLog(log.getMessage());
        });
      }

      // Execute FFmpeg — async session so cancel can reach it (HLS-5).
      final session = await FFmpegKit.executeWithArgumentsAsync(args);
      final sessionId = session.getSessionId();

      // Cancel propagation: user cancel → FFmpegKit.cancel(sessionId)
      // fires immediately; the session aborts and getReturnCode resolves
      // with the cancel code. (dio 5.x whenCancel is a one-shot Future —
      // a late fire after completion is a harmless no-op on a dead session.)
      if (cancelToken != null) {
        unawaited(cancelToken.whenCancel.then((_) {
          onLog?.call('Cancel requested — aborting FFmpeg session $sessionId');
          FFmpegKit.cancel(sessionId);
        }));
      }

      late final HlsConversionResult result;
      {
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          // HLS-2: validate the part file before it may present as final —
          // size floor + ISO-BMFF brand check (JS validateMp4 parity).
          final verdict = await validateMp4File(partPath);
          if (verdict != null) {
            await _safeDelete(partFile);
            result = HlsConversionResult.error('Output failed MP4 validation: $verdict');
          } else if (await outputFile.exists()) {
            await _safeDelete(outputFile);
          }

          if (verdict == null) {
            // Atomic rename: only now does a final-named file exist.
            await partFile.rename(outputPath);
            final fileSize = await outputFile.length();
            onLog?.call('Conversion successful: $outputPath (${FormatUtils.humanSize(fileSize)})');
            result = HlsConversionResult.success(
              outputPath: outputPath,
              fileSize: fileSize,
            );
          }
        } else if (cancelToken != null && cancelToken.isCancelled) {
          // Truth table: cancelled = INCOMPLETE → re-offered, never failed.
          await _safeDelete(partFile);
          result = HlsConversionResult.cancelled();
        } else {
          // Get error logs
          final logs = await session.getAllLogsAsString();
          final errorMessage = 'FFmpeg failed with code ${returnCode?.getValue()}: $logs';
          onLog?.call(errorMessage);
          await _safeDelete(partFile);
          result = HlsConversionResult.error(errorMessage);
        }
      }
      return result;
    } catch (e) {
      return HlsConversionResult.error('Conversion error: $e');
    }
  }

  /// Validates a completed MP4 file (hls/01 + JS validateMp4 parity).
  /// Returns null when valid; otherwise a diagnosable reason string.
  /// Checks: file exists, size ≥ [minMp4Bytes], ISO-BMFF brand at bytes 4–8
  /// ∈ {ftyp, moov, wide, free, skip}.
  static Future<String?> validateMp4File(String path) async {
    final file = File(path);
    if (!await file.exists()) return 'file does not exist';
    final size = await file.length();
    if (size < minMp4Bytes) return 'undersized MP4 ($size B < $minMp4Bytes B)';
    final raf = await file.open();
    try {
      final head = await raf.read(12);
      if (head.length < 12) return 'file too short for brand check';
      final brand = String.fromCharCodes(head.sublist(4, 8));
      const allowed = {'ftyp', 'moov', 'wide', 'free', 'skip'};
      if (!allowed.contains(brand)) return 'unknown ISO-BMFF brand: $brand';
      return null;
    } finally {
      await raf.close();
    }
  }

  /// D-05 sweep: on first conversion per app-run, delete temp `*.mp4` /
  /// `*.part.mp4` files older than [staleTempAge]. Younger files may be
  /// in-flight from a previous session — they remain (in-flight safety;
  /// no strict-liveness claim is made, per C-6).
  Future<void> _sweepStaleTempOnce(void Function(String)? onLog) async {
    if (_sweepDoneThisRun) return;
    _sweepDoneThisRun = true;
    try {
      final tempDir = await getTemporaryDirectory();
      final cutoff = DateTime.now().subtract(staleTempAge);
      await for (final entity in tempDir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!(name.endsWith('.mp4') || name.endsWith('.part.mp4'))) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await _safeDelete(entity);
          onLog?.call('Swept stale temp file: $name');
        }
      }
    } catch (e) {
      // Sweep is best-effort; never fail a conversion for it.
      onLog?.call('Temp sweep skipped: $e');
    }
  }

  static Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
