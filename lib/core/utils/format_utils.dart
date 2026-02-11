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
}
