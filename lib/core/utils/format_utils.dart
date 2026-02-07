/// Utility functions for formatting values
/// Ported from Node.js Downloader.humanSize()
class FormatUtils {
  FormatUtils._();

  static const List<String> _sizeUnits = ['B', 'KB', 'MB', 'GB', 'TB'];

  /// Convert bytes to human-readable size string
  /// e.g., 1024 -> "1.00 KB"
  static String humanSize(int bytes) {
    if (bytes == 0) return '0 B';

    final i = (bytes == 0) ? 0 : (log(bytes) / log(1024)).floor();
    final size = bytes / pow(1024, i);

    return '${size.toStringAsFixed(2)} ${_sizeUnits[i]}';
  }

  /// Log base for size calculations
  static double log(num x) => _ln(x);
  static double _ln(num x) => x <= 0 ? 0 : _log(x.toDouble());
  static double _log(double x) {
    // Natural log approximation
    if (x <= 0) return 0;
    double result = 0;
    while (x >= 2) {
      x /= 2.718281828459045;
      result += 1;
    }
    x -= 1;
    double term = x;
    double sum = x;
    for (int i = 2; i <= 10; i++) {
      term *= -x * (i - 1) / i;
      sum += term / i;
    }
    return result + sum;
  }

  /// Power function
  static double pow(num base, num exponent) {
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

  /// Extract filename from URL
  static String filenameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        return sanitizeFilename(uri.pathSegments.last);
      }
    } catch (_) {}
    return 'download';
  }

  /// Format duration to human-readable string
  static String formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m ${duration.inSeconds.remainder(60)}s';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  /// Format timestamp for logs
  static String formatLogTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  /// Convert to title case
  static String toTitleCase(String text) {
    return text.replaceAllMapped(
      RegExp(r'\w\S*'),
      (match) {
        final word = match.group(0)!;
        return word[0].toUpperCase() + word.substring(1).toLowerCase();
      },
    );
  }

  /// Truncate string with ellipsis
  static String truncate(String text, int maxLength) {
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength - 3)}...';
  }

  /// Format count with K/M suffix
  static String formatCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }
}
