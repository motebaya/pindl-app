/// Utility functions for formatting values
/// Ported from Node.js Downloader.humanSize()
class FormatUtils {
  FormatUtils._();

  static const List<String> _sizeUnits = ['B', 'KB', 'MB', 'GB', 'TB'];

  /// Convert bytes to human-readable size string
  /// e.g., 1024 -> "1.00 KB"
  static String humanSize(int bytes) {
    if (bytes == 0) return '0 B';

    final i = (bytes == 0) ? 0 : (_log(bytes) / _log(1024)).floor();
    final size = bytes / _pow(1024, i);

    return '${size.toStringAsFixed(2)} ${_sizeUnits[i]}';
  }

  /// Natural log (private helper for humanSize)
  static double _log(num x) {
    if (x <= 0) return 0;
    double val = x.toDouble();
    double result = 0;
    while (val >= 2) {
      val /= 2.718281828459045;
      result += 1;
    }
    val -= 1;
    double term = val;
    double sum = val;
    for (int i = 2; i <= 10; i++) {
      term *= -val * (i - 1) / i;
      sum += term / i;
    }
    return result + sum;
  }

  /// Power function (private helper for humanSize)
  static double _pow(num base, num exponent) {
    double result = 1;
    for (int i = 0; i < exponent; i++) {
      result *= base;
    }
    return result;
  }

  /// Sanitize filename for filesystem
  /// Removes invalid characters
  static String sanitizeFilename(String filename) {
    return filename.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '');
  }

  /// Extract file extension from a URL, stripping query params.
  /// Returns the extension including the dot (e.g. '.jpg', '.mp4').
  /// Falls back to [fallback] if no recognizable extension is found.
  static String extensionFromUrl(String url, {String fallback = '.jpg'}) {
    try {
      // Strip query string and fragment
      final path = Uri.parse(url).path;
      final lastSegment = path.split('/').last;
      final dotIndex = lastSegment.lastIndexOf('.');
      if (dotIndex >= 0 && dotIndex < lastSegment.length - 1) {
        final ext = lastSegment.substring(dotIndex).toLowerCase();
        // Only accept known media extensions
        const validExts = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.mp4', '.webm', '.mov', '.m3u8'};
        if (validExts.contains(ext)) return ext;
      }
    } catch (_) {}
    return fallback;
  }

  /// Build a deterministic filename from pinId and media role.
  /// Convention:
  ///   video:     <pinId>_video.mp4
  ///   thumbnail: <pinId>_thumbnail.jpg
  ///   image:     <pinId>_image.jpg  (or <pinId>_image_<index>.jpg for multiples)
  static String pinFilename({
    required String pinId,
    required String role, // 'video', 'thumbnail', 'image'
    required String url,
    int? imageIndex,
  }) {
    final String ext;
    if (role == 'video') {
      ext = '.mp4'; // Always .mp4 for video output
    } else {
      ext = extensionFromUrl(url, fallback: '.jpg');
    }

    final suffix = (role == 'image' && imageIndex != null)
        ? '${role}_$imageIndex'
        : role;

    return sanitizeFilename('${pinId}_$suffix$ext');
  }
}
