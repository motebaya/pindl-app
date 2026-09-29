/// Result of HLS to MP4 conversion.
///
/// Extracted into a standalone model so that both the real [HlsConverter]
/// (ffmpeg build) and the no-op [HlsConverterStub] (lite build) can share
/// the same return type without pulling in FFmpeg dependencies.
class HlsConversionResult {
  final bool success;
  final String? outputPath; // Temp path where MP4 was created
  final int? fileSize;
  final String? errorMessage;

  /// Phase 05 (HLS-5 / truth table): the FFmpeg session was cancelled by the
  /// user — the item is INCOMPLETE (re-offered on continue), never "failed".
  final bool wasCancelled;

  HlsConversionResult._({
    required this.success,
    this.outputPath,
    this.fileSize,
    this.errorMessage,
    this.wasCancelled = false,
  });

  factory HlsConversionResult.success({
    required String outputPath,
    int? fileSize,
  }) {
    return HlsConversionResult._(
      success: true,
      outputPath: outputPath,
      fileSize: fileSize,
    );
  }

  factory HlsConversionResult.error(String message) {
    return HlsConversionResult._(
      success: false,
      errorMessage: message,
    );
  }

  factory HlsConversionResult.cancelled() {
    return HlsConversionResult._(
      success: false,
      wasCancelled: true,
      errorMessage: 'Conversion cancelled by user',
    );
  }

  @override
  String toString() {
    if (success) {
      return 'HlsConversionResult(success, path: $outputPath, size: $fileSize)';
    }
    if (wasCancelled) return 'HlsConversionResult(cancelled)';
    return 'HlsConversionResult(error: $errorMessage)';
  }
}
