import '../constants/pinterest_constants.dart';

/// Information about a parsed Pinterest URL
class PinUrlInfo {
  /// The format of the URL: 'long', 'short', or 'id'
  final String format;

  /// The extracted pin ID
  final String id;

  /// The normalized full URL
  final String url;

  PinUrlInfo({
    required this.format,
    required this.id,
    required this.url,
  });

  bool get isShortUrl => format == 'short';
  bool get isLongUrl => format == 'long';
  bool get isIdOnly => format == 'id';

  @override
  String toString() => 'PinUrlInfo(format: $format, id: $id, url: $url)';
}

/// Validates and parses Pinterest URLs
/// Ported from Node.js Utils.isPinUrl() and Helper.REGEX.pinUrl
class PinUrlValidator {
  PinUrlValidator._();

  /// Regex pattern for Pinterest pin URLs
  /// Matches:
  /// - Long URL: https://pinterest.com/pin/123456789/
  /// - Short URL: https://pin.it/abc123
  /// - ID only: 123456789
  static final RegExp pinUrlPattern = RegExp(
    r'^(?:https?:\/\/(?:www|\w+\.)?pinterest\.[a-z.]+\/pin\/(\d{16,21})\/?|https?:\/\/(?:www\.)?pin\.it\/([a-zA-Z0-9]+)\/?|(\d{16,21}))$',
  );

  /// Check if input is a valid Pinterest pin URL or ID
  /// Returns PinUrlInfo if valid, null otherwise
  static PinUrlInfo? parse(String input) {
    input = input.trim();
    final match = pinUrlPattern.firstMatch(input);

    if (match == null) return null;

    final longId = match.group(1);
    final shortId = match.group(2);
    final idOnly = match.group(3);

    if (longId != null) {
      return PinUrlInfo(
        format: 'long',
        id: longId,
        url: input,
      );
    } else if (shortId != null) {
      return PinUrlInfo(
        format: 'short',
        id: shortId,
        url: input,
      );
    } else if (idOnly != null) {
      return PinUrlInfo(
        format: 'id',
        id: idOnly,
        url: '${PinterestConstants.host}/pin/$idOnly/',
      );
    }

    return null;
  }

  /// Check if input looks like a username (starts with @ or no special chars)
  static bool isUsername(String input) {
    input = input.trim();
    if (input.isEmpty) return false;

    // Remove @ prefix if present
    if (input.startsWith('@')) {
      input = input.substring(1);
    }

    // Username should not look like a URL or ID
    if (input.contains('/') || input.contains('.')) return false;
    if (RegExp(r'^\d{16,21}$').hasMatch(input)) return false;

    // Username should be alphanumeric with underscores
    return RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(input);
  }

  /// Normalize username (remove @ prefix if present)
  static String normalizeUsername(String input) {
    input = input.trim();
    if (input.startsWith('@')) {
      return input.substring(1);
    }
    return input;
  }

  /// Determine if input is a pin URL/ID or username
  /// Returns 'pin' if it's a pin, 'username' if it's a username, null if invalid
  static String? detectInputType(String input) {
    input = input.trim();
    if (input.isEmpty) return null;

    if (parse(input) != null) return 'pin';
    if (isUsername(input)) return 'username';

    return null;
  }

  /// Clean a redirected Pinterest URL by stripping extra path segments and query params.
  ///
  /// Pinterest short URL redirects often produce URLs like:
  ///   https://id.pinterest.com/pin/627830004345010675/sent/?invite_code=xxx&sfo=1
  ///   https://id.pinterest.com/theusername/?invite_code=xxx&sfo=1
  ///
  /// This method extracts the canonical form:
  ///   - Pin URL: https://id.pinterest.com/pin/627830004345010675/
  ///   - Username URL: theusername (extracted from path)
  ///
  /// Returns a [ResolvedInput] with the cleaned value and detected type.
  static ResolvedInput? cleanRedirectedUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return null;

    // Must be a pinterest domain
    final host = uri.host.toLowerCase();
    if (!host.contains('pinterest.')) return null;

    // Split path into segments, filtering empty strings
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

    if (segments.isEmpty) return null;

    // Case 1: Pin URL — path starts with "pin" followed by numeric ID
    if (segments.length >= 2 && segments[0] == 'pin') {
      final pinId = segments[1];
      if (RegExp(r'^\d{16,21}$').hasMatch(pinId)) {
        final cleanUrl = '${PinterestConstants.host}/pin/$pinId/';
        return ResolvedInput(
          type: 'pin',
          value: cleanUrl,
          pinId: pinId,
        );
      }
    }

    // Case 2: Username URL — first segment is a username (not "pin", not system paths)
    final firstSegment = segments[0];
    final systemPaths = {'pin', 'search', 'ideas', 'settings', 'business', '_', 'oauth', 'resource'};
    if (!systemPaths.contains(firstSegment) &&
        RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(firstSegment)) {
      return ResolvedInput(
        type: 'username',
        value: firstSegment,
      );
    }

    return null;
  }

  /// Check if a URL is a short pin.it URL
  static bool isShortUrl(String input) {
    final parsed = parse(input.trim());
    return parsed != null && parsed.isShortUrl;
  }
}

/// Result of resolving and cleaning a redirected Pinterest URL.
class ResolvedInput {
  /// 'pin' or 'username'
  final String type;

  /// The cleaned value: canonical URL for pins, username string for profiles
  final String value;

  /// The numeric pin ID (only set when type == 'pin')
  final String? pinId;

  const ResolvedInput({
    required this.type,
    required this.value,
    this.pinId,
  });
}
