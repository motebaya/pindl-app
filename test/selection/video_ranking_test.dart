import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/media/video_selection.dart';

/// Phase 07 (07.2) — rendition ranking matrix (gate G2).
///
/// The selector must reproduce the JS reference order:
///   MP4: V_720P → V_960P → V_480P → V_360P → any other MP4;
///   HLS: V_HLSV4 → V_HLSV3_MOBILE → any m3u8;
///   last resort: any URL.
void main() {
  Map<String, dynamic> v(String url) => {'url': url};

  group('MP4 preference order', () {
    test('V_720P wins over everything', () {
      final pick = selectVideo({
        'V_960P': v('https://v1.pinimg.com/960.mp4'),
        'V_720P': v('https://v1.pinimg.com/720.mp4'),
        'V_HLSV4': v('https://v1.pinimg.com/hls4.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/720.mp4');
      expect(pick.quality, '720P');
      expect(pick.needConvert, isFalse);
    });

    test('V_960P preferred over V_480P when 720P absent', () {
      final pick = selectVideo({
        'V_480P': v('https://v1.pinimg.com/480.mp4'),
        'V_960P': v('https://v1.pinimg.com/960.mp4'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/960.mp4');
    });

    test('V_480P MP4 chosen over HLS when it is the only MP4 (legacy gap fixed)',
        () {
      final pick = selectVideo({
        'V_480P': v('https://v1.mp4/480.mp4'),
        'V_HLSV4': v('https://v1.pinimg.com/hls4.m3u8'),
      });
      expect(pick!.url, 'https://v1.mp4/480.mp4');
      expect(pick.needConvert, isFalse);
    });

    test('non-preference MP4 key still beats HLS', () {
      final pick = selectVideo({
        'V_EXP': v('https://v1.pinimg.com/exp.mp4'),
        'V_HLSV3_MOBILE': v('https://v1.pinimg.com/hls3.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/exp.mp4');
      expect(pick.needConvert, isFalse);
      expect(pick.quality, 'V_EXP');
    });

    test('V_720P carrying an m3u8 is NOT a direct MP4 — HLS ranking applies',
        () {
      final pick = selectVideo({
        'V_720P': v('https://v1.pinimg.com/720p.m3u8'),
        'V_HLSV4': v('https://v1.pinimg.com/hls4.m3u8'),
      });
      // The V_720P map holds m3u8 (not MP4); V_HLSV4 is the ranked HLS pick.
      expect(pick!.url, 'https://v1.pinimg.com/hls4.m3u8');
      expect(pick.needConvert, isTrue);
    });

    test('V_720P m3u8 falls back through the m3u8 scan when alone', () {
      final pick = selectVideo({
        'V_720P': v('https://v1.pinimg.com/720p.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/720p.m3u8');
      expect(pick.needConvert, isTrue);
    });
  });

  group('HLS preference (V_HLSV4 over V_HLSV3_MOBILE)', () {
    test('both present: V_HLSV4 wins', () {
      final pick = selectVideo({
        'V_HLSV3_MOBILE': v('https://v1.pinimg.com/hls3.m3u8'),
        'V_HLSV4': v('https://v1.pinimg.com/hls4.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/hls4.m3u8');
      expect(pick.quality, 'HLS');
      expect(pick.needConvert, isTrue);
    });

    test('V_HLSV3_MOBILE alone is used', () {
      final pick = selectVideo({
        'V_HLSV3_MOBILE': v('https://v1.pinimg.com/hls3.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/hls3.m3u8');
      expect(pick.quality, 'HLS');
    });
  });

  group('videoDataV2 group merge', () {
    test('single-child groups unwrap with normalized keys', () {
      final merged = videoListFromVideoDataV2({
        'videoList720P': {'v720P': {'url': 'https://v1.pinimg.com/720.mp4'}},
        'videoListEXP': {'vEXP': {'url': 'https://v1.pinimg.com/exp.mp4'}},
      });
      expect(merged!.keys, containsAll(['V_720P', 'V_EXP']));
      final pick = selectVideo(merged);
      expect(pick!.url, 'https://v1.pinimg.com/720.mp4');
    });

    test('direct rendition maps pass through', () {
      final merged = videoListFromVideoDataV2({
        'V_480P': {'url': 'https://v1.pinimg.com/480.mp4'},
      });
      final pick = selectVideo(merged);
      expect(pick!.url, 'https://v1.pinimg.com/480.mp4');
    });

    test('empty/no-video shapes yield null', () {
      expect(videoListFromVideoDataV2(null), isNull);
      expect(videoListFromVideoDataV2({}), isNull);
      expect(videoListFromVideoDataV2({
        'videoList720P': {},
      }), isNull);
      expect(selectVideo(null), isNull);
      expect(selectVideo({}), isNull);
    });

    test('record with no usable URLs yields null', () {
      expect(selectVideo({
        'V_720P': {'thumbnail': 'https://i.pinimg.com/t.jpg'},
      }), isNull);
    });
  });

  group('rendition key canonicalization (3.1.1+8)', () {
    test('camelCase keys normalize to the V_ convention', () {
      expect(canonicalVideoRenditionKey('v720P'), 'V_720P');
      expect(canonicalVideoRenditionKey('v480P'), 'V_480P');
      expect(canonicalVideoRenditionKey('vHLSV4'), 'V_HLSV4');
      expect(canonicalVideoRenditionKey('vHLSV3MOBILE'), 'V_HLSV3_MOBILE');
      expect(canonicalVideoRenditionKey('vHLSV3_MOBILE'), 'V_HLSV3_MOBILE');
      expect(canonicalVideoRenditionKey('vEXP'), 'V_EXP');
    });

    test('canonical keys and non-rendition keys pass through unchanged', () {
      for (final key in [...mp4Preference, ...hlsPreference, 'V_EXP']) {
        expect(canonicalVideoRenditionKey(key), key);
      }
      expect(canonicalVideoRenditionKey('__typename'), '__typename');
    });

    test('a camelCase videos node ranks like its V_ twin', () {
      final camel = videoListFromVideosNode({
        'videoList': {
          'vHLSV3MOBILE': {'url': 'https://v1.pinimg.com/hls3.m3u8'},
          'vHLSV4': {'url': 'https://v1.pinimg.com/hls4.m3u8'},
          'v720P': {'url': 'https://v1.pinimg.com/720.mp4'},
          '__typename': 'VideoList',
        },
      });
      expect(camel!.keys,
          containsAll(['V_720P', 'V_HLSV4', 'V_HLSV3_MOBILE', '__typename']));
      final pick = selectVideo(camel);
      expect(pick!.url, 'https://v1.pinimg.com/720.mp4');
      expect(pick.quality, '720P');
      expect(pick.needConvert, isFalse);
    });

    test('the snake video_list spelling still resolves as before', () {
      final pick = selectVideo(videoListFromVideosNode({
        'video_list': {'V_720P': {'url': 'https://v1.pinimg.com/720.mp4'}},
      }));
      expect(pick!.url, 'https://v1.pinimg.com/720.mp4');
    });

    test('no-video shapes yield null', () {
      expect(videoListFromVideosNode(null), isNull);
      expect(videoListFromVideosNode({}), isNull);
      expect(videoListFromVideosNode({'video_list': []}), isNull);
      expect(videoListFromVideosNode({'videoList': null}), isNull);
      expect(videoListFromVideosNode({'videoList': {}}), isNull);
    });
  });

  group('last resort', () {
    test('unknown container URL still downloads (needConvert per extension)',
        () {
      final pick = selectVideo({
        'V_WEIRD': v('https://v1.pinimg.com/weird.m3u8'),
      });
      expect(pick!.url, 'https://v1.pinimg.com/weird.m3u8');
      expect(pick.needConvert, isTrue);
      expect(pick.quality, 'V_WEIRD');
    });
  });
}
