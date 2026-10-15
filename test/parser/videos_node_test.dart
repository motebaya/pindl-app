import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// 3.1.1+8 — the second half of the video-pin regression.
///
/// The four reported pins (617837642698964831, 3025924747245513,
/// 617837642695441979, 617837642701818224) came back image-only even though
/// their pages DO carry video. Live captures show why, and it is not a
/// ranking problem:
///
///   * their relay records carry `storyPinData: null` and keep the renditions
///     in the RECORD-LEVEL `videos` node (`videos.videoList`, camelCase keys
///     `v720P` / `vHLSV4` / `vHLSV3MOBILE`), which the resolver never read; and
///   * the stubborn pin was served a four-key media-less relay stub, with the
///     complete pin object (video included) only in `__PWS_INITIAL_PROPS__`.
///
/// Each shape is pinned here against a fixture shaped like the live capture.
void main() {
  group('record-level videos node: camelCase videoList', () {
    const pinId = '1234567890123456789';

    test('the direct 720P MP4 is selected (no conversion)', () {
      final result =
          PinterestParser.parseMediaData(Fixtures.pinVideosNodeCamel(), pinId);

      expect(result, isNotNull);
      expect(result!.hasVideoContent, isTrue);
      expect(result.isVideo, isTrue);
      expect(
        result.videoUrl,
        'https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/fixture720w.mp4',
      );
      expect(result.videoNeedConvert, isFalse);
      expect(result.videoIsHls, isFalse);
      expect(result.message, 'video found for -> $pinId');
      // The relay record's own image is untouched by the video resolution.
      expect(result.imageUrl, endsWith('fixture736.jpg'));
      expect(result.author.username, 'fixtureuser');
    });

    test('parseVideoData agrees on the same record', () {
      final result =
          PinterestParser.parseVideoData(Fixtures.pinVideosNodeCamel(), pinId);
      expect(result, isNotNull);
      expect(result!.videoUrl, endsWith('fixture720w.mp4'));
      expect(result.videoIsHls, isFalse);
      expect(result.thumbnail, contains('fixturethumb.jpg'));
    });

    test('the single-pin classifier reports media (not "no payload")', () {
      final outcome = PinterestParser.parseMediaDataOrNull(
          Fixtures.pinVideosNodeCamel(), pinId);
      expect(outcome.isSourceChanged, isFalse);
      expect(outcome.isPinNotFound, isFalse);
      expect(outcome.result!.hasVideoContent, isTrue);
    });

    test('an HLS-only videos node is flagged as needing conversion', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinVideosNodeCamelHlsOnly(), '2345678901234567890');
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isTrue);
      expect(result.videoUrl, endsWith('fixture_v4.m3u8'));
      expect(result.videoNeedConvert, isTrue);
      expect(result.videoIsHls, isTrue);
    });
  });

  group('record-level videos node: malformed shapes are tolerated', () {
    const pinId = '1234567890123456789';

    String relayPage(String videosJson) =>
        '<html><body><script>'
        'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k:1", '
        '{"data":{"pin_closeup":{"data":{"id":"$pinId","videos":$videosJson,'
        '"images_736x":{"url":"https://i.pinimg.com/736x/aa/bb/cc/x.jpg"}}}}})'
        '</script></body></html>';

    test('renditions without a URL yield no video (image still parses)', () {
      final result = PinterestParser.parseMediaData(
          relayPage('{"videoList":{"v720P":{"duration":4033}}}'), pinId);
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isFalse);
      expect(result.imageUrl, contains('/736x/'));
    });

    test('a list-shaped videos node means "no video"', () {
      final result =
          PinterestParser.parseMediaData(relayPage('[]'), pinId);
      expect(result!.hasVideoContent, isFalse);
    });

    test('a non-map videoList is ignored', () {
      final result = PinterestParser.parseMediaData(
          relayPage('{"videoList":"nope"}'), pinId);
      expect(result!.hasVideoContent, isFalse);
    });
  });

  group('SSR INITIAL_PROPS pin object: video-only fallback', () {
    const pinId = '3456789012345678901';

    const stubRelay =
        'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k:1", '
        '{"data":{"pin_closeup":{"data":{"id":"$pinId",'
        '"topInterest":"topic","imageSignature":"sig","images_736x":'
        '{"url":"https://i.pinimg.com/736x/aa/bb/cc/fixture736.jpg"}}}}})';

    String propsPage(String pinsJson) => '<html><body><script>$stubRelay'
        '</script><script id="__PWS_INITIAL_PROPS__" type="application/json">'
        '{"initialReduxState":{"pins":$pinsJson}}</script></body></html>';

    test('the stub variant recovers its video from the props pin object', () {
      final html = Fixtures.pinStubRelayPropsVideo();

      // The relay record alone carries no video at all (that was the defect)…
      expect(PinterestParser.initialPropsPinRecord(html, pinId), isNotNull);
      // …but the page as a whole does, so the pin is no longer image-only.
      final result = PinterestParser.parseMediaData(html, pinId);

      expect(result, isNotNull);
      expect(result!.hasVideoContent, isTrue);
      expect(result.isVideo, isTrue);
      expect(result.videoUrl, endsWith('fixture720w.mp4'));
      expect(result.videoNeedConvert, isFalse);
      expect(result.message, 'video found for -> $pinId');
      // Video-only fallback: the relay-derived image selection is preserved
      // (no image-quality behavior change rides along with this fix).
      expect(result.imageUrl, endsWith('fixture736.jpg'));
    });

    test('parseVideoData finds it too', () {
      final result = PinterestParser.parseVideoData(
          Fixtures.pinStubRelayPropsVideo(), pinId);
      expect(result!.videoUrl, endsWith('fixture720w.mp4'));
      expect(result.videoIsHls, isFalse);
    });

    test('the props object does NOT displace a relay-derived video', () {
      final result = PinterestParser.parseMediaData(
          propsPage('{"$pinId":{"id":"$pinId","videos":{"video_list":'
              '{"V_720P":{"url":"https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/props720w.mp4"}}}}}'),
          pinId);
      expect(result!.videoUrl, endsWith('props720w.mp4'));
    });

    test('a props pin object without videos leaves the pin image-only', () {
      final result = PinterestParser.parseMediaData(
          propsPage('{"$pinId":{"id":"$pinId","title":"No Video"}}'), pinId);
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isFalse);
      expect(result.imageUrl, contains('/736x/'));
    });

    test('an empty props pins map is not fatal', () {
      final result = PinterestParser.parseMediaData(propsPage('{}'), pinId);
      expect(result!.hasVideoContent, isFalse);
      expect(result.imageUrl, contains('/736x/'));
    });

    test('malformed props JSON is ignored, never throws', () {
      final html = '<html><body><script>$stubRelay</script>'
          '<script id="__PWS_INITIAL_PROPS__" type="application/json">'
          '{"initialReduxState":{"pins":{oops</script></body></html>';
      expect(PinterestParser.initialPropsPinRecord(html, pinId), isNull);
      final result = PinterestParser.parseMediaData(html, pinId);
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isFalse);
      expect(result.imageUrl, contains('/736x/'));
    });

    test('a props object for another pin is never used', () {
      final result = PinterestParser.parseMediaData(
          propsPage('{"999":{"id":"999","videos":{"video_list":'
              '{"V_720P":{"url":"https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/other.mp4"}}}}}'),
          pinId);
      expect(result!.hasVideoContent, isFalse);
    });
  });
}
