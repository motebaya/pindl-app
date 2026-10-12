/// Carousel slot extraction for FEED and BOARD rows — Feed/Board carousel
/// migration (plan: `planning/feed-carousel-migration.md`, evidence report:
/// `reports/3.1.1-carousel-migration-and-versioning.md`).
///
/// Why this module exists: the single-pin path already expands a carousel into
/// one download per slide (`PinterestParser._slotsFrom` → `MediaResult.slots`,
/// device-verified 8/8 slides), but a carousel pin reached through a
/// username/board feed downloaded only its primary image (OQ-13). Feed rows DO
/// carry every slide — live-verified 2026-10-12 on `BoardFeedResource`
/// (board 188658740579752021): the 8-slide pin's row ships
/// `carousel_data.carousel_slots[8]`, each slot carrying
/// `images.{60x60,136x136,170x,236x,474x,564x,600x315,736x}`, with
/// `slot0.images.736x` = the same image hash as the row's own `images.orig`.
///
/// Shape tolerance mirrors the parser's relay-slot handling: snake_case
/// (`carousel_data.carousel_slots`) as served by the resource APIs and
/// camelCase (`carouselData.carouselSlots`, flat `images_<token>` renditions)
/// as served by the pin SSR page. Rendition selection reuses the D-48 ranking
/// ([bestPinterestImageUrl]) instead of map insertion order.
///
/// Order = server slot order = display order (JS-verified in 07.3).
library;

import 'image_selection.dart';

/// Slide image URLs of one feed/board row, in display order.
///
/// Empty when the row is not a carousel (no `carousel_data` block, no slots,
/// or no resolvable slot image) — callers then behave exactly as before.
List<String> carouselSlotUrlsFromRow(Map<String, dynamic> row) {
  final carousel = _asMap(row['carousel_data']) ?? _asMap(row['carouselData']);
  if (carousel == null) return const [];
  final raw = _asList(carousel['carousel_slots']) ??
      _asList(carousel['carouselSlots']);
  if (raw == null) return const [];
  final urls = <String>[];
  for (final slot in raw) {
    final map = _asMap(slot);
    if (map == null) continue;
    final url = _slotImageUrl(map);
    if (url != null) urls.add(url);
  }
  return urls;
}

/// Best rendition URL of one slot record: `imageLargeUrl` → nested
/// `images`/`image.images` map → flat `images_<token>` maps.
String? _slotImageUrl(Map<String, dynamic> slot) {
  final large = slot['imageLargeUrl'];
  if (large is String && large.isNotEmpty) return large;

  final direct = _asMap(slot['images']);
  if (direct != null) {
    final best = _bestFromImagesMap(direct);
    if (best != null) return best;
  }

  final image = _asMap(slot['image']);
  if (image != null) {
    final nested = _asMap(image['images']);
    if (nested != null) {
      final best = _bestFromImagesMap(nested);
      if (best != null) return best;
    }
    final url = image['url'];
    if (url is String && url.isNotEmpty) return url;
  }

  // Flat rendition maps (`images_236x`, `images_736x`, …) carry size tokens in
  // their KEYS, so they are ranked by the URL each one points at.
  return bestPinterestImageUrl(<String?>[
    for (final entry in slot.entries)
      if (entry.key.startsWith('images_')) _urlOf(entry.value),
  ]);
}

String? _bestFromImagesMap(Map<String, dynamic> images) =>
    bestPinterestImageUrl(<String?>[
      for (final entry in images.entries) _urlOf(entry.value),
    ]);

/// `{'url': '…'}` → the URL; anything else → null.
String? _urlOf(Object? value) {
  final map = _asMap(value);
  if (map == null) return null;
  final url = map['url'];
  return url is String && url.isNotEmpty ? url : null;
}

Map<String, dynamic>? _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<dynamic>? _asList(Object? value) => value is List ? value : null;
