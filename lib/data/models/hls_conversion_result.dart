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

  HlsConversionResult._({
    required this.success,
    this.outputPath,
    this.fileSize,
    this.errorMessage,
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

  @override
  String toString() {
    if (success) {
      return 'HlsConversionResult(success, path: $outputPath, size: $fileSize)';
    }
    return 'HlsConversionResult(error: $errorMessage)';
  }
}
