/// Image rendition ranking + full-resolution upgrade — 3.1.1 device-evidence
/// fix (see reports/3.1.1-device-bugfix.md).
///
/// Two live-verified defects this module exists for:
///
///   1. Flat `images_*` maps were consumed in *insertion* order, so a record
///      whose first entry is `images_60x60` produced a 60×60 thumbnail (6 KB)
///      as the pin's image while `images_orig` sat one key away. Ranking by
///      rendition size fixes that (real capture: images_60x60 first, images_orig
///      last, same hash).
///   2. Carousel slots only carry a `236x` rendition, and records without
///      `imageLargeUrl` fall back to whatever the maps offer. Pinterest serves
///      the same image hash at every size token, so [upgradePinterestImageUrl]
///      rewrites a thumbnail token to `originals` for downloads.
///
/// Evidence: every reported pin's `originals` URL answered 200 with a real
/// JPEG (71–154 KB) while the parsed URL was 60x60/236x (6 KB / 17 KB).
/// Recorded in reports/3.1.1-device-bugfix.md.
library;

/// Resolution score for one Pinterest image URL. Higher = better.
///
/// `originals` (and the legacy `orig` token) outrank every numeric rendition.
/// Numeric tokens (`1200x`, `736x`, `474x`, `236x`, `170x`, `136x136`,
/// `60x60`, `600x315`) score by their largest axis. Anything that is not a
/// recognisable `i.pinimg.com/<token>/…` URL scores -1 (never preferred over a
/// known rendition, but still usable when it is the only candidate).
int pinterestImageRank(String? url) {
  if (url == null || url.isEmpty) return -1;
  final token = _renditionToken(url);
  if (token == null) return -1;
  if (token == 'originals' || token == 'orig') return 1000000;
  final match = RegExp(r'^(\d+)x(\d*)$').firstMatch(token);
  if (match == null) return -1;
  final first = int.tryParse(match.group(1)!) ?? 0;
  final second = int.tryParse(match.group(2) ?? '') ?? 0;
  return first > second ? first : second;
}

/// Best (highest-resolution) URL among [urls], or null when empty.
String? bestPinterestImageUrl(Iterable<String?> urls) {
  String? best;
  var bestRank = -2;
  for (final url in urls) {
    if (url == null || url.isEmpty) continue;
    final rank = pinterestImageRank(url);
    if (rank > bestRank) {
      bestRank = rank;
      best = url;
    }
  }
  return best;
}

/// Rewrites a *thumbnail* `i.pinimg.com` rendition to `originals`.
///
/// Only URLs of the shape `https://i.pinimg.com/<token>/<aa>/<bb>/<cc>/<file>`
/// whose token resolves to a rendition smaller than [minDimension] on its
/// largest axis are touched; `originals`/`orig` and larger renditions pass
/// through untouched. Video-thumbnail paths (`…/videos/thumbnails/originals/…`),
/// query strings, and non-Pinterest hosts are never rewritten.
///
/// The rewrite is safe because the size token is a server-side resize
/// directive over the same image hash — every reported pin was verified to
/// answer 200 for the `originals` form (evidence in the 3.1.1 report). Callers
/// keep the fail-closed media validator as the backstop.
String upgradePinterestImageUrl(String url, {int minDimension = 736}) {
  if (url.isEmpty) return url;
  final token = _renditionToken(url);
  if (token == null) return url;
  if (token == 'originals' || token == 'orig') return url;
  final match = RegExp(r'^(\d+)x(\d*)$').firstMatch(token);
  if (match == null) return url; // unknown token (e.g. a hash) — leave alone
  final first = int.tryParse(match.group(1)!) ?? 0;
  final second = int.tryParse(match.group(2) ?? '') ?? 0;
  final largest = first > second ? first : second;
  if (largest >= minDimension) return url;
  return url.replaceFirst('/$token/', '/originals/');
}

/// The rendition token of a Pinterest image URL, or null when the URL does not
/// have the expected shape. Public for tests (documented pattern, not a regex
/// guess: `<host>/<token>/<2 hex>/<2 hex>/<2 hex>/<file>`).
String? renditionTokenOf(String url) => _renditionToken(url);

String? _renditionToken(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (!uri.host.endsWith('pinimg.com')) return null;
  final segments = uri.pathSegments;
  // <token>/<aa>/<bb>/<cc>/<file>
  if (segments.length != 5) return null;
  for (var i = 1; i <= 3; i++) {
    if (segments[i].length != 2) return null;
  }
  return segments[0];
}
