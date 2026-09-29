/// Media host allowlist (SEC-2) with boundary matching (canonical D-08).
///
/// Downloads are restricted to the Pinterest CDN family observed in the
/// JS probes and current responses. Matching is BOUNDARY matched:
///   allowed  <=>  host == entry || host.endsWith('.' + entry)
/// Bare `endsWith` is prohibited — `evilpinimg.com` must NOT pass.
///
/// Escape hatch (accepted trade-off, security/02): if Pinterest adds an
/// unlisted CDN host, one item fails with a logged host and the fix is a
/// one-line addition to [allowed]. Fail-loud beats fail-open.
class MediaHosts {
  MediaHosts._();

  /// Allowed hosts (suffix entries cover their subdomains).
  static const Set<String> allowed = {
    'pinimg.com', // covers i./v./v1./s-… CDN sharding
    'i.pinimg.com',
    'v1.pinimg.com',
    'v.pinimg.com',
  };

  /// Hosts allowed as redirect targets for short-URL resolution
  /// (pinterest/pin.it family — security/02 redirect-host check).
  static const Set<String> redirectTargets = {
    'pinterest.com',
    'pin.it',
  };

  /// Static lookalike examples used by the allowlist unit tests as
  /// negative cases (bare-suffix matching would wrongly admit these).
  static const List<String> knownLookalikes = [
    'evilpinimg.com',
    'pinimg.com.evil.io',
    'notpinimg.com',
  ];

  /// Reason string used when a host fails the allowlist.
  static const String rejectionReason = 'unexpected media host';

  /// Whether [urlOrHost] passes boundary matching against [allowSet].
  ///
  /// Accepts a bare host (`i.pinimg.com`) or a full URL (`https://…`);
  /// matching is case-insensitive and a trailing dot is ignored.
  static bool isAllowed(String urlOrHost, {Set<String>? allowSet}) {
    final host = _hostOf(urlOrHost);
    if (host == null || host.isEmpty) return false;
    final set = allowSet ?? allowed;
    for (final entry in set) {
      if (host == entry || host.endsWith('.$entry')) return true;
    }
    return false;
  }

  /// Whether a redirect landed on the pinterest/pin.it family.
  static bool isAllowedRedirect(String url) =>
      isAllowed(url, allowSet: redirectTargets);

  /// Extract lowercase host from a URL or bare host string.
  static String? _hostOf(String urlOrHost) {
    var s = urlOrHost.trim().toLowerCase();
    if (s.isEmpty) return null;
    final scheme = s.indexOf('://');
    if (scheme >= 0) {
      s = s.substring(scheme + 3);
      // strip path/query/port
      final cut = RegExp(r'[/?#]').firstMatch(s);
      if (cut != null) s = s.substring(0, cut.start);
      final port = s.indexOf(':');
      if (port >= 0) s = s.substring(0, port);
    } else {
      // bare host (maybe with port or path remnants)
      final cut = RegExp(r'[/?#:]').firstMatch(s);
      if (cut != null) s = s.substring(0, cut.start);
    }
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
