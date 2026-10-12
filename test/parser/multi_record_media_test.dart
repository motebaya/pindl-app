import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// 3.1.1 — best-media selection across relay records (live device shapes).
///
/// The reported pins exposed three first-match defects:
///   1. the direct MP4 record was shadowed by an HLS-only record -> the app
///      downloaded a 918/920 B m3u8 as `<pinId>_video.mp4`;
///   2. flat `images_*` maps were read in insertion order, so `images_60x60`
///      won over `images_orig` -> a 6 KB thumbnail became the pin's image;
///   3. a `videoDataV2` node on a later story page/block was never reached.
/// Each is pinned here against a fixture shaped like the live capture.
void main() {
  const pinId = '999888777666555444333222111000987654321';

  group('multi-record video: direct MP4 wins over an earlier HLS-only record', () {
    test('parseMediaData selects the expMp4 rendition (no conversion)', () {
      final result =
          PinterestParser.parseMediaData(Fixtures.pinMultiRecordHlsThenMp4(), pinId);
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isTrue);
      expect(result.videoUrl, 'https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/fixture720w.mp4');
      expect(result.videoNeedConvert, isFalse);
      expect(result.videoIsHls, isFalse);
      // The record that carries the MP4 is also the one with the HD image.
      expect(result.imageUrl, contains('/736x/'));
    });

    test('parseVideoData also prefers the direct MP4', () {
      final result =
          PinterestParser.parseVideoData(Fixtures.pinMultiRecordHlsThenMp4(), pinId);
      expect(result!.videoUrl, endsWith('.mp4'));
      expect(result.videoIsHls, isFalse);
    });

    test('an HLS-only pin is still flagged as needing conversion', () {
      // Same fixture with the MP4 record removed: the HLS url survives and is
      // flagged, which is what gates the single-pin conversion branch.
      final html = Fixtures.pinMultiRecordHlsThenMp4();
      final firstRecordOnly = html.substring(0, html.indexOf('</script>'));
      final result = PinterestParser.parseMediaData(firstRecordOnly, pinId);
      expect(result!.hasVideoContent, isTrue);
      expect(result.videoUrl, endsWith('.m3u8'));
      expect(result.videoNeedConvert, isTrue);
      expect(result.videoIsHls, isTrue);
    });
  });

  group('flat images: highest rendition wins, not the first key', () {
    test('images_60x60 first + images_orig last -> originals chosen', () {
      final result =
          PinterestParser.parseMediaData(Fixtures.pinFlat60x60First(), pinId);
      expect(result, isNotNull);
      expect(
        result!.imageUrl,
        'https://i.pinimg.com/originals/aa/bb/cc/aabbcc11223344556677889900112233.jpg',
      );
      expect(result.hasImage, isTrue);
    });

    test('parseImageData agrees with the richest-record choice', () {
      final result =
          PinterestParser.parseImageData(Fixtures.pinFlat60x60First(), pinId);
      expect(result!.imageUrl, contains('/originals/'));
      expect(result.imageUrl, isNot(contains('/60x60/')));
    });
  });

  group('story pages: every page/block group is considered', () {
    test('a video on the second page/block is found', () {
      final result =
          PinterestParser.parseMediaData(Fixtures.pinVideoLaterPage(), pinId);
      expect(result, isNotNull);
      expect(result!.hasVideoContent, isTrue);
      expect(result.videoUrl, endsWith('fixture720w.mp4'));
      expect(result.videoNeedConvert, isFalse);
    });
  });

  group('regression guards on the richer existing fixtures', () {
    test('carousel slots still parse with their full-size URLs', () {
      final result = PinterestParser.parseMediaData(Fixtures.pinCarousel(), pinId);
      expect(result!.slots, hasLength(3));
      expect(result.slots.first.imageUrl, contains('/originals/'));
    });

    test('single-video fixture unchanged (mp4 + thumbnail)', () {
      final result = PinterestParser.parseMediaData(Fixtures.pinVideo(), pinId);
      expect(result!.videoUrl, 'https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc123.mp4');
      expect(result.videoIsHls, isFalse);
    });
  });
}
