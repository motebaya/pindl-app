import '../../data/models/video_url.dart';

/// Media rendition ranking — Phase 07 (workstream 07.2).
///
/// Port of the JS reference `pickBestVideo` / `MP4_PREFERENCE`
/// (audit `audits/parity/media.md`, BEHAVIORALLY DIFFERENT ×2 rows):
///
///   1. MP4 renditions in explicit preference order:
///      V_720P → V_960P → V_480P → V_360P (direct MP4, no conversion);
///   2. any other direct-MP4 rendition (map order);
///   3. HLS: V_HLSV4 over V_HLSV3_MOBILE ("newer master"), then any HLS;
///   4. any other entry with a URL (last resort).
///
/// Behavior change vs the legacy inline chain (720P-first, HLSV3-first):
/// a pin offering only V_480P.mp4 now yields the 480P MP4 instead of an
/// HLS variant; a pin with both HLS variants now yields V_HLSV4. Intended
/// improvement — release-noted in Phase 07 (07.6).

/// Keys of direct-MP4 renditions, most preferred first (JS MP4_PREFERENCE).
const List<String> mp4Preference = [
  'V_720P',
  'V_960P',
  'V_480P',
  'V_360P',
];

/// HLS keys, most preferred first (JS: V_HLSV4 is the newer master).
const List<String> hlsPreference = [
  'V_HLSV4',
  'V_HLSV3_MOBILE',
];

/// The `videos` JSON node shape in feed/pin records. Accepts the map form
/// (`{ "video_list": {...} }`); the null form signals the story-pin fallback;
/// a list (empty array) means "no video".
typedef VideosNode = Map<String, dynamic>?;

/// Extracts the rendition map from a record's `videos` node.
Map<String, dynamic>? videoListFromVideosNode(VideosNode videos) {
  if (videos is Map<String, dynamic> && videos.isNotEmpty) {
    return videos['video_list'] as Map<String, dynamic>?;
  }
  return null;
}

/// Merges the `videoDataV2` rendition groups (single-pin relay records).
///
/// JS `videoListFromVideoDataV2`: the relay shape nests real rendition maps
/// under group wrappers (`videoList720P.v720P`, `videoListMobile.vMobile`,
/// `videoListEXP.vEXP`); group keys differ per pin. Tolerant rule: a group
/// value that is a map containing exactly one map value is unwrapped
/// (single-child); a map carrying direct rendition keys (url/thumbnail) is
/// taken as-is. Null/empty groups are skipped. Unwrapped keys are normalized
/// `videoList720P` → `V_720P` (inferred from the feed `V_` convention so the
/// preference list applies; fixture-covered).
Map<String, dynamic>? videoListFromVideoDataV2(Map<String, dynamic>? v2) {
  if (v2 == null || v2.isEmpty) return null;
  final merged = <String, dynamic>{};
  v2.forEach((groupKey, groupValue) {
    if (groupValue is! Map<String, dynamic> || groupValue.isEmpty) return;
    // Direct rendition map (has url) — take as-is.
    if (groupValue.containsKey('url')) {
      merged[groupKey] = groupValue;
      return;
    }
    // Group wrapper: unwrap single-child groups under a normalized key.
    final children = groupValue.values
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    if (children.length == 1) {
      final key = groupKey.startsWith('videoList')
          ? 'V_${groupKey.substring('videoList'.length)}'
          : groupKey;
      merged[key] = children.single;
    }
  });
  return merged.isEmpty ? null : merged;
}

/// Ranks the merged rendition map and returns the best [VideoUrl], or null
/// when no rendition carries a URL. Pure — no I/O, no regex.
VideoUrl? selectVideo(Map<String, dynamic>? videoList) {
  if (videoList == null || videoList.isEmpty) return null;

  String? directUrl(Map<String, dynamic> v) {
    final url = v['url'];
    return url is String ? url : null;
  }

  bool isMp4(Map<String, dynamic> v) => directUrl(v)?.endsWith('.mp4') ?? false;

  // 1+2. MP4 renditions by explicit preference, then any other MP4.
  for (final key in mp4Preference) {
    final v = videoList[key];
    if (v is Map<String, dynamic> && isMp4(v) && directUrl(v) != null) {
      return VideoUrl.fromJson(v, _qualityLabel(key), needConvert: false);
    }
  }
  for (final e in videoList.entries) {
    final v = e.value;
    if (v is Map<String, dynamic> &&
        isMp4(v) &&
        !mp4Preference.contains(e.key)) {
      return VideoUrl.fromJson(v, e.key, needConvert: false);
    }
  }

  // 3. HLS: explicit order, then any m3u8 rendition.
  for (final key in hlsPreference) {
    final v = videoList[key];
    if (v is Map<String, dynamic> && directUrl(v) != null) {
      return VideoUrl.fromJson(v, _qualityLabel(key), needConvert: true);
    }
  }
  for (final e in videoList.entries) {
    final v = e.value;
    if (v is Map<String, dynamic> && (directUrl(v)?.endsWith('.m3u8') ?? false)) {
      return VideoUrl.fromJson(v, e.key, needConvert: true);
    }
  }

  // 4. Last resort: any entry with a URL.
  for (final e in videoList.entries) {
    final v = e.value;
    if (v is Map<String, dynamic> && directUrl(v) != null) {
      final url = directUrl(v)!;
      return VideoUrl.fromJson(v, e.key, needConvert: url.endsWith('.m3u8'));
    }
  }
  return null;
}

/// Display quality label (legacy-compatible): known MP4 keys drop the `V_`
/// prefix ('V_720P' → '720P'); known HLS keys collapse to 'HLS'; anything
/// else keeps its raw key (e.g. 'V_EXP').
String _qualityLabel(String key) {
  if (mp4Preference.contains(key)) return key.substring(2);
  if (hlsPreference.contains(key)) return 'HLS';
  return key;
}
