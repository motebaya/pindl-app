import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_https/return_code.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/hls_conversion_result.dart';

/// HLS to MP4 conversion service using FFmpeg
/// Ported from Node.js HLS.js convertToMp4
class HlsConverter {
  /// Convert HLS streams to MP4
  /// 
  /// [videoM3u8Url] - URL to the video variant .m3u8
  /// [audioM3u8Url] - Optional URL to the audio .m3u8 (if separate)
  /// [outputFilename] - Desired output filename (without path)
  /// [onProgress] - Optional progress callback (0.0 to 1.0)
  /// [onLog] - Optional log callback for FFmpeg output
  /// 
  /// Returns [HlsConversionResult] with the temp file path on success
  Future<HlsConversionResult> convertToMp4({
    required String videoM3u8Url,
    String? audioM3u8Url,
    required String outputFilename,
    void Function(double progress)? onProgress,
    void Function(String log)? onLog,
  }) async {
    try {
      // Get temp directory for output
      final tempDir = await getTemporaryDirectory();
      final outputPath = p.join(tempDir.path, outputFilename);
      
      // Clean up any existing temp file
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
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
        outputPath,
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
          onLog(log.getMessage() ?? '');
        });
      }

      // Execute FFmpeg
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();
      
      if (ReturnCode.isSuccess(returnCode)) {
        // Verify output file exists
        if (await outputFile.exists()) {
          final fileSize = await outputFile.length();
          onLog?.call('Conversion successful: $outputPath (${_formatBytes(fileSize)})');
          
          return HlsConversionResult.success(
            outputPath: outputPath,
            fileSize: fileSize,
          );
        } else {
          return HlsConversionResult.error('Output file not created');
        }
      } else {
        // Get error logs
        final logs = await session.getAllLogsAsString();
        final errorMessage = 'FFmpeg failed with code ${returnCode?.getValue()}: $logs';
        onLog?.call(errorMessage);
        
        return HlsConversionResult.error(errorMessage);
      }
    } catch (e) {
      return HlsConversionResult.error('Conversion error: $e');
    }
  }
  
  /// Format bytes to human-readable string
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
