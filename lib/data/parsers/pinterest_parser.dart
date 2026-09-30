import 'dart:convert';
import '../../core/media/video_selection.dart';
import '../models/author.dart';
import '../models/media_result.dart';
import '../models/pinterest_config.dart';
import '../models/video_url.dart';

// PORTED from my Node.js CLI tool
// - https://github.com/motebaya/pinterest-js

/// Classified outcome for single-pin parsing (Phase 03 typed errors).
/// [result] non-null = success; otherwise exactly one failure class is set:
/// [pinNotFound] (relay record carries a PinNotFound error object) or
/// [sourceChanged] (page has no relay record at all).
class PinParseOutcome {
  final MediaResult? result;
  final bool pinNotFound;
  final bool sourceChanged;

  const PinParseOutcome.media(this.result)
      : pinNotFound = false,
        sourceChanged = false;
  const PinParseOutcome.notFound()
      : result = null,
        pinNotFound = true,
        sourceChanged = false;
  const PinParseOutcome.changed()
      : result = null,
        pinNotFound = false,
        sourceChanged = true;

  bool get isPinNotFound => pinNotFound;
  bool get isSourceChanged => sourceChanged;
}

class PinterestParser {
  PinterestParser._();
  
  // REGEX Patterns
  static final RegExp _appVersionPattern =
      RegExp(r'''['"]appVersion['"]\s*:\s*['"](\w+?)['"]''');
  static final RegExp _userId1Pattern = RegExp(
      r'''['"]profile_cover['"]\s*:\s*\{['"]id['"]\s*:\s*['"](\d+?)['"]''',
      caseSensitive: false);
  static final RegExp _userId2Pattern = RegExp(r'/users/(\d+)/pins');
  static final RegExp _userId3Pattern = RegExp(
      r'<script\s+[^>]*id="__PWS_INITIAL_PROPS__"\s+[^>]*type="application/json"[^>]*>(.*?)</script>',
      dotAll: true);
  static final RegExp _mediaDataPattern = RegExp(
      r'window\.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__\(\s*"(?<payload>(?:\\.|[^"\\])*)"\s*,\s*(?<json>\{[\s\S]*?\})\s*\)\s*;?');

  /// Extract Pinterest config (appVersion and userId) from profile HTML
  static PinterestConfig? parseConfig(String html) {
    // Extract appVersion
    final appVersionMatch = _appVersionPattern.firstMatch(html);
    if (appVersionMatch == null) return null;
    final appVersion = appVersionMatch.group(1);
    if (appVersion == null) return null;

    // Try multiple strategies for userId
    String? userId;

    // Strategy 1: profile_cover
    final userId1Match = _userId1Pattern.firstMatch(html);
    if (userId1Match != null) {
      userId = userId1Match.group(1);
    }

    // Strategy 2: /users/ID/pins
    if (userId == null) {
      final userId2Match = _userId2Pattern.firstMatch(html);
      if (userId2Match != null) {
        userId = userId2Match.group(1);
      }
    }

    // Strategy 3: __PWS_INITIAL_PROPS__ JSON
    if (userId == null) {
      final userId3Match = _userId3Pattern.firstMatch(html);
      if (userId3Match != null) {
        try {
          final jsonStr = userId3Match.group(1);
          if (jsonStr != null) {
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final users =
                json['initialReduxState']?['users'] as Map<String, dynamic>?;
            if (users != null) {
              userId = users.keys.firstWhere(
                (k) => k.isNotEmpty,
                orElse: () => '',
              );
            }
          }
        } catch (_) {}
      }
    }

    if (userId == null || userId.isEmpty) return null;

    return PinterestConfig(appVersion: appVersion, userId: userId);
  }

  /// Parse image data from single pin page HTML
  /// Ported from Pinterest.getImages() with new regex
  /// Expected output format:
  /// {
  ///   "status": true,
  ///   "author": { "username", "name", "userId" },
  ///   "result": { "title", "url", "entityId" },
  ///   "message": "image found for -> {pinId}"
  /// }
  /// ALL relay payloads (global scan — Phase 07 rich scan, JS
  /// parseRelayPayloads). Unparseable blobs are skipped, not fatal.
  static List<Map<String, dynamic>> parseRelayPayloads(String html) {
    final results = <Map<String, dynamic>>[];
    for (final match in _mediaDataPattern.allMatches(html)) {
      try {
        final jsonStr = match.namedGroup('json');
        if (jsonStr == null) continue;
        final json = jsonDecode(jsonStr);
        if (json is Map<String, dynamic>) results.add(json);
      } catch (_) {}
    }
    return results;
  }

  /// The pin record inside a relay payload. Tolerant across the two observed
  /// shapes: the pin object directly at `data.<firstKey>` (error records —
  /// the PinNotFound shape carries `error` at this level) or nested one level
  /// deeper at `data.<firstKey>.data` (success records).
  static Map<String, dynamic>? pinRecordFromPayload(
      Map<String, dynamic> payload) {
    final dataWrapper = payload['data'];
    if (dataWrapper is! Map<String, dynamic> || dataWrapper.isEmpty) {
      return null;
    }
    final node = dataWrapper[dataWrapper.keys.first];
    if (node is! Map<String, dynamic>) return null;
    final nested = node['data'];
    if (nested is Map<String, dynamic>) return nested;
    return node;
  }

  /// Candidate pin records: every parseable relay record that is NOT a
  /// PinNotFound error record (error records are never media candidates —
  /// the classifier reports them as the typed outcome instead).
  static List<Map<String, dynamic>> _candidateRecords(String html) {
    final records = <Map<String, dynamic>>[];
    for (final payload in parseRelayPayloads(html)) {
      final record = pinRecordFromPayload(payload);
      if (record == null || _recordIsPinNotFoundRecord(record)) continue;
      records.add(record);
    }
    return records;
  }

  /// Shape check: record carries a PinNotFound error object
  /// (JS parity: __isError/PIN_NOT_FOUND error records).
  static bool _recordIsPinNotFoundRecord(Map<String, dynamic> record) {
    final error = record['error'];
    if (error is Map<String, dynamic>) {
      final code = error['code']?.toString().toUpperCase();
      if (code == 'PIN_NOT_FOUND') return true;
      final message = error['message']?.toString().toLowerCase() ?? '';
      if (message.contains('not found')) return true;
    }
    return false;
  }

  /// Best image from an images rendition map (JS pickBestImage port):
  /// prefer `orig`, else largest pixel area, else first entry with a URL.
  static Map<String, dynamic>? _bestImageFromImagesMap(
      Map<String, dynamic>? images) {
    if (images == null || images.isEmpty) return null;
    final orig = images['orig'];
    if (orig is Map<String, dynamic> && orig['url'] is String) return orig;
    Map<String, dynamic>? best;
    int bestArea = -1;
    images.forEach((_, v) {
      if (v is! Map<String, dynamic>) return;
      final url = v['url'];
      if (url is! String || url.isEmpty) return;
      final w = v['width'] is int ? v['width'] as int : 0;
      final h = v['height'] is int ? v['height'] as int : 0;
      final area = w * h;
      if (area > bestArea) {
        bestArea = area;
        best = v;
      }
    });
    return best;
  }

  static final RegExp _flatImagesKeyPattern = RegExp(r'^images_\w+$');

  /// Flat `images_*` map fallback (live SSR shape — JS added after live
  /// probing): any top-level key `images_\w+` holding either a rendition map
  /// directly (`images_orig: {url, ...}`) or a wrapper of renditions
  /// (`images_variants: {orig: {url, ...}}`).
  static Map<String, dynamic>? _bestImageFromFlatMaps(
      Map<String, dynamic> record) {
    for (final e in record.entries) {
      if (!_flatImagesKeyPattern.hasMatch(e.key)) continue;
      if (e.value is! Map<String, dynamic>) continue;
      final flat = e.value as Map<String, dynamic>;
      // Rendition map directly (carries a url) — use it as-is.
      if (flat['url'] is String) return flat;
      // Wrapper of renditions — pick the best child.
      final best = _bestImageFromImagesMap(flat);
      if (best != null) return best;
    }
    return null;
  }

  /// Resolve the record's best image URL (JS chain): `imageLargeUrl`
  /// preferred, then the `images` map, then flat `images_*` maps.
  static Map<String, dynamic>? _resolveImage(Map<String, dynamic> record) {
    final large = record['imageLargeUrl'];
    if (large is String && large.isNotEmpty) {
      return {'url': large};
    }
    final fromMap = _bestImageFromImagesMap(record['images'] as Map<String, dynamic>?);
    if (fromMap != null) return fromMap;
    return _bestImageFromFlatMaps(record);
  }

  /// Resolve the record's best video (JS chain): merged `videoDataV2` groups
  /// ranked by selectVideo (07.2). Navigates the single-pin shape
  /// `storyPinData.pages[*].blocks[*].videoDataV2` (first page/block carrying
  /// one), then falls back to record-level keys. Null when no video.
  static VideoUrl? _resolveVideo(Map<String, dynamic> record) {
    Map<String, dynamic>? v2;
    final storyPinData = record['storyPinData'] as Map<String, dynamic>?;
    final pages = storyPinData?['pages'] as List<dynamic>?;
    if (pages != null) {
      for (final page in pages) {
        if (page is! Map<String, dynamic>) continue;
        final blocks = page['blocks'] as List<dynamic>?;
        if (blocks == null) continue;
        for (final block in blocks) {
          if (block is! Map<String, dynamic>) continue;
          final candidate = block['videoDataV2'] as Map<String, dynamic>?;
          if (candidate != null) {
            v2 = candidate;
            break;
          }
        }
        if (v2 != null) break;
      }
    }
    v2 ??= record['videoDataV2'] as Map<String, dynamic>?;
    return selectVideo(videoListFromVideoDataV2(v2));
  }

  /// Author fallback chain (audit extraction.md row): pinner →
  /// closeupAttribution → native_creator.
  static Author _authorFrom(Map<String, dynamic> record) {
    final pinner = record['pinner'] as Map<String, dynamic>?;
    final closeup = record['closeupAttribution'] as Map<String, dynamic>?;
    final nativeCreator = record['native_creator'] as Map<String, dynamic>?;
    return Author(
      username: pinner?['username'] as String? ??
          nativeCreator?['username'] as String? ??
          '-',
      name: closeup?['fullName'] as String? ??
          nativeCreator?['full_name'] as String? ??
          '-',
      userId: pinner?['entityId']?.toString() ??
          nativeCreator?['id']?.toString() ??
          '-',
    );
  }

  /// Title fallback chain: `title` → `gridTitle` → '-'.
  static String _titleFrom(Map<String, dynamic> record) {
    final title = record['title'];
    if (title is String && title.isNotEmpty) return title;
    final grid = record['gridTitle'];
    if (grid is String && grid.isNotEmpty) return grid;
    return '-';
  }

  /// Carousel slots (Phase 07, JS mediaFromPinRecord slot loop): camelCase
  /// `carouselData.carouselSlots` with `carousel_data.carousel_slots`
  /// snake fallback. Slot images use the same resolution chain as the pin.
  static List<MediaSlot> _slotsFrom(Map<String, dynamic> record) {
    final carousel = record['carouselData'] as Map<String, dynamic>? ??
        record['carousel_data'] as Map<String, dynamic>?;
    if (carousel == null) return const [];
    final slotsRaw = carousel['carouselSlots'] as List<dynamic>? ??
        carousel['carousel_slots'] as List<dynamic>?;
    if (slotsRaw == null) return const [];
    final slots = <MediaSlot>[];
    for (final s in slotsRaw) {
      if (s is! Map<String, dynamic>) continue;
      final img = _resolveImage(s);
      final url = img?['url'];
      if (url is! String || url.isEmpty) continue;
      slots.add(MediaSlot(
        imageUrl: url,
        width: img!['width'] is int ? img['width'] as int : null,
        height: img['height'] is int ? img['height'] as int : null,
      ));
    }
    return slots;
  }

  /// Full media extraction from one record (JS mediaFromPinRecord port).
  /// Null when the record carries neither image, video, nor carousel slots.
  static MediaResult? _mediaFromRecord(
      Map<String, dynamic> pinData, String pinId) {
    final image = _resolveImage(pinData);
    final video = _resolveVideo(pinData);
    final slots = _slotsFrom(pinData);
    if (image == null && video == null && slots.isEmpty) return null;

    // Single-image fields stay populated for backward compatibility: slot 0
    // wins when a carousel exists without a record-level image.
    final imageUrl = image?['url'] as String? ??
        (slots.isNotEmpty ? slots.first.imageUrl : null);

    return MediaResult(
      author: _authorFrom(pinData),
      title: _titleFrom(pinData),
      pinId: pinId,
      entityId: pinData['entityId'] as String?,
      imageUrl: imageUrl,
      videoUrl: video?.url,
      thumbnail: video?.thumbnail,
      isVideo: video != null,
      hasImage: imageUrl != null,
      hasVideoContent: video != null,
      rawJson: pinData,
      slots: slots,
      message: video != null
          ? 'video found for -> $pinId'
          : 'image found for -> $pinId',
    );
  }

  static MediaResult? parseImageData(String html, String pinId) {
    for (final record in _candidateRecords(html)) {
      final image = _resolveImage(record);
      final url = image?['url'];
      if (url is! String || url.isEmpty) continue;
      return MediaResult(
        author: _authorFrom(record),
        title: _titleFrom(record),
        pinId: pinId,
        imageUrl: url,
        isVideo: false,
        message: 'image found for -> $pinId',
      );
    }
    return null;
  }

  /// Parse video data from single pin page HTML
  /// Ported from Pinterest.getVideos() with new regex
  /// Expected output format:
  /// {
  ///   "status": true,
  ///   "author": { "username", "name", "userId" },
  ///   "result": { "thumbnail", "url" }
  /// }
  static MediaResult? parseVideoData(String html, String pinId) {
    for (final record in _candidateRecords(html)) {
      final video = _resolveVideo(record);
      if (video == null) continue;
      return MediaResult(
        author: _authorFrom(record),
        title: _titleFrom(record),
        pinId: pinId,
        videoUrl: video.url,
        thumbnail: video.thumbnail,
        isVideo: true,
        message: 'video found for -> $pinId',
      );
    }
    return null;
  }

  /// Classified single-pin parsing (Phase 03 / extraction plan 01):
  /// distinguishes "no relay payload at all" (SourceChanged) and
  /// "PinNotFound error record" from a plain media-less record.
  /// The legacy null-returning methods above are unchanged (Phase 02 pins).
  static PinParseOutcome parseImageDataOrNull(String html, String pinId) =>
      _classify(html, () => parseImageData(html, pinId));

  static PinParseOutcome parseVideoDataOrNull(String html, String pinId) =>
      _classify(html, () => parseVideoData(html, pinId));

  static PinParseOutcome parseMediaDataOrNull(String html, String pinId) =>
      _classify(html, () => parseMediaData(html, pinId));

  static PinParseOutcome _classify(
      String html, MediaResult? Function() parse) {
    // Rich scan (Phase 07): classify over ALL relay payloads. No payloads
    // at all -> SourceChanged. An error-shaped record with no media-bearing
    // candidate -> PinNotFound (typed). Otherwise parse.
    final payloads = parseRelayPayloads(html);
    if (payloads.isEmpty) {
      return const PinParseOutcome.changed();
    }
    var sawNotFound = false;
    for (final payload in payloads) {
      final record = pinRecordFromPayload(payload);
      if (record == null) continue;
      if (_recordIsPinNotFoundRecord(record)) {
        sawNotFound = true;
        continue;
      }
      return PinParseOutcome.media(parse());
    }
    if (sawNotFound) return const PinParseOutcome.notFound();
    return const PinParseOutcome.changed();
  }

  /// Try to get both image and video data from a pin.
  /// Phase 07 (07.1): richest-record scan over ALL relay payloads — prefers
  /// media-bearing records (JS mediaFromPinRecord behavior) over stubs, with
  /// flat `images_*` maps and title/author fallbacks (07.1) and carousel
  /// slots (07.3). Legacy firstMatch semantics superseded deliberately.
  static MediaResult? parseMediaData(String html, String pinId) {
    for (final record in _candidateRecords(html)) {
      // JS: prefer the first record that actually carries media
      // (mediaFromPinRecord(d).length > 0 before candidates[0]).
      final media = _mediaFromRecord(record, pinId);
      if (media != null) return media;
    }
    return null;
  }
}
