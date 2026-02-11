/// Build configuration constants derived from compile-time environment variables.
///
/// The [enableFfmpeg] flag is the single source of truth for enabling/disabling
/// FFmpeg-dependent features (HLS parsing, HLS→MP4 conversion).
///
/// Usage:
///   flutter build apk --flavor lite  --dart-define=ENABLE_FFMPEG=false --release
///   flutter build apk --flavor ffmpeg --dart-define=ENABLE_FFMPEG=true  --release
class BuildConfig {
  BuildConfig._();

  /// Whether FFmpeg features (HLS conversion) are enabled in this build.
  /// Defaults to `false` (lite mode) when not explicitly set.
  static const bool enableFfmpeg =
      bool.fromEnvironment('ENABLE_FFMPEG', defaultValue: false);
}
