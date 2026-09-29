import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: single-pin relay parsing (image / video / PinNotFound / stub).
/// Pins CURRENT behavior:
/// - PinNotFound shape -> null (typed-error integration is Phase 03; the Phase 03
///   change will flip these pins deliberately).
/// - Stub-only record -> null (firstMatch semantics; richest-record scan is Phase 07).
void main() {
  const pinId = '999888777666555444333222111000987654321';

  group('parseMediaData — image pin', () {
    test('extracts imageLargeUrl + author + title + entityId', () {
      final result = PinterestParser.parseMediaData(Fixtures.pinImage(), pinId);
      expect(result, isNotNull);
      expect(result!.imageUrl, 'https://i.pinimg.com/originals/aa/bb/cc/aabbcc11223344556677889900112233.jpg');
      expect(result.isVideo, isFalse);
      expect(result.hasImage, isTrue);
      expect(result.hasVideoContent, isFalse);
      expect(result.title, 'Fixture Image Pin');
      expect(result.entityId, '999888777666555444333222111000987654321');
      expect(result.author.username, 'fixtureuser');
      expect(result.author.userId, '111222333444555666');
      expect(result.author.name, 'Fixture Author');
      expect(result.message, 'image found for -> $pinId');
    });

    test('parseImageData also succeeds on the same fixture', () {
      final result = PinterestParser.parseImageData(Fixtures.pinImage(), pinId);
      expect(result, isNotNull);
      expect(result!.imageUrl, isNotNull);
      expect(result.isVideo, isFalse);
    });
  });

  group('parseMediaData — video pin (videoDataV2.v720P)', () {
    test('extracts v720P mp4 url + thumbnail', () {
      final result = PinterestParser.parseMediaData(Fixtures.pinVideo(), pinId);
      expect(result, isNotNull);
      expect(result!.isVideo, isTrue);
      expect(result.videoUrl, 'https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc123.mp4');
      expect(result.thumbnail, 'https://i.pinimg.com/videos/thumbnails/abc123.jpg');
      expect(result.message, 'video found for -> $pinId');
    });

    test('parseVideoData succeeds on the same fixture', () {
      final result = PinterestParser.parseVideoData(Fixtures.pinVideo(), pinId);
      expect(result, isNotNull);
      expect(result!.videoUrl, 'https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc123.mp4');
    });
  });

  group('parseMediaData — PinNotFound record (current: null)', () {
    test('parseImageData returns null (no imageLargeUrl)', () {
      expect(PinterestParser.parseImageData(Fixtures.pinNotFound(), pinId), isNull);
    });

    test('parseVideoData returns null (no storyPinData)', () {
      expect(PinterestParser.parseVideoData(Fixtures.pinNotFound(), pinId), isNull);
    });

    test('parseMediaData returns null (neither media nor video)', () {
      expect(PinterestParser.parseMediaData(Fixtures.pinNotFound(), pinId), isNull);
    });
  });

  group('parseMediaData — stub-only record (current: null via firstMatch)', () {
    test('media-less record yields null (richest-record scan is Phase 07)', () {
      expect(PinterestParser.parseMediaData(Fixtures.pinStubOnly(), pinId), isNull);
    });
  });

  group('relay regex edge — payload with escaped quotes', () {
    test('json with escaped inner quotes still parses', () {
      const html = '<script>'
          r'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k", {"data":{"x":{"data":{"title":"say \"hi\"","imageLargeUrl":"https://i.pinimg.com/a.jpg"}}}});'
          '</script>';
      final result = PinterestParser.parseImageData(html, pinId);
      expect(result, isNotNull);
      expect(result!.title, 'say "hi"');
    });

    test('no relay record -> null', () {
      expect(PinterestParser.parseMediaData('<html><body>nothing</body></html>', pinId), isNull);
    });
  });
}
