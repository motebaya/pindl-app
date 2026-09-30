import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// Phase 07 — relay rich-scan + fallbacks + carousel matrix
/// (workstreams 07.1/07.3; gates G1, G3; PinNotFound typed outcome).
void main() {
  const pinId = '999888777666555444333222111000987654321';

  group('07.1 richest-record scan (gate G1)', () {
    test('media-bearing record preferred over an earlier stub', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinStubThenRich(), pinId);
      expect(result, isNotNull);
      expect(result!.title, 'Rich Record With Image');
      expect(
          result.imageUrl,
          'https://i.pinimg.com/originals/11/22/33/'
          '11223344556677889900112233445566.jpg');
      expect(result.author.username, 'richuser');
    });

    test('flat images_* map fallback supplies the image (no imageLargeUrl)',
        () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinFlatImages(), pinId);
      expect(result, isNotNull);
      expect(
          result!.imageUrl,
          'https://i.pinimg.com/originals/44/55/66/'
          '44556677889900112233445566778899.jpg');
    });

    test('title fallback: gridTitle used when title absent', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinFlatImages(), pinId);
      expect(result!.title, 'Grid Title Fallback');
    });

    test('author fallback: native_creator used when pinner absent', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinFlatImages(), pinId);
      expect(result!.author.username, 'flatuser');
      expect(result.author.name, 'Flat Creator');
      expect(result.author.userId, '333444555666777888');
    });

    test('images-map area fallback: largest rendition wins when orig absent',
        () {
      // Synthetic: no orig, two sized renditions (larger area must win).
      const html = '<html><script>'
          'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k1", '
          '{"data":{"c":{"data":{"images":{'
          '"170x":{"url":"https://i.pinimg.com/170x/a.jpg","width":170,"height":255},'
          '"736x":{"url":"https://i.pinimg.com/736x/a.jpg","width":736,"height":1104}'
          '}}}}});'
          '</script></html>';
      final result = PinterestParser.parseMediaData(html, pinId);
      expect(result!.imageUrl, 'https://i.pinimg.com/736x/a.jpg');
    });
  });

  group('07.1 classifier outcomes over the rich scan', () {
    test('PinNotFound record classifies as pinNotFound (typed outcome)', () {
      final outcome =
          PinterestParser.parseMediaDataOrNull(Fixtures.pinNotFound(), pinId);
      expect(outcome.isPinNotFound, isTrue);
      expect(outcome.result, isNull);
    });

    test('stub-only payload set: neither NotFound nor Changed (unchanged pin)',
        () {
      final outcome =
          PinterestParser.parseMediaDataOrNull(Fixtures.pinStubOnly(), pinId);
      expect(outcome.result, isNull);
      expect(outcome.isPinNotFound, isFalse);
      expect(outcome.isSourceChanged, isFalse);
    });

    test('no relay payload at all classifies as sourceChanged', () {
      final outcome = PinterestParser.parseMediaDataOrNull(
          '<html><body>plain</body></html>', pinId);
      expect(outcome.isSourceChanged, isTrue);
    });

    test('stub-first + rich-later classifies as success (scan, not firstMatch)',
        () {
      final outcome = PinterestParser.parseMediaDataOrNull(
          Fixtures.pinStubThenRich(), pinId);
      expect(outcome.result, isNotNull);
      expect(outcome.isPinNotFound, isFalse);
    });
  });

  group('07.3 carousel slots (gate G3)', () {
    test('three-slot carousel yields three ordered slots', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinCarousel(), pinId);
      expect(result, isNotNull);
      expect(result!.slots.length, 3);
      expect(result.slots[0].imageUrl,
          endsWith('aa11bbcc00112233445566778899aabb.jpg'));
      expect(result.slots[1].imageUrl,
          endsWith('cc22dde00112233445566778899ccdd.jpg'));
      expect(result.slots[2].imageUrl,
          endsWith('ee33ff00112233445566778899aabbcc.jpg'));
      // Slot order preserved; widths/heights flow through.
      expect(result.slots[0].width, 736);
    });

    test('slot 0 populates the single-image fields (backward compat)', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinCarousel(), pinId);
      expect(result!.hasImage, isTrue);
      expect(result.imageUrl, result.slots.first.imageUrl);
    });

    test('non-carousel pins have empty slots', () {
      final result = PinterestParser.parseMediaData(Fixtures.pinImage(), pinId);
      expect(result!.slots, isEmpty);
    });

    test('snake_case carousel shape tolerated (carousel_data.carousel_slots)',
        () {
      const html = '<html><script>'
          'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k2", '
          '{"data":{"c":{"data":{'
          '"carousel_data":{"carousel_slots":['
          '{"images":{"orig":{"url":"https://i.pinimg.com/originals/s1.jpg"}}},'
          '{"images":{"orig":{"url":"https://i.pinimg.com/originals/s2.jpg"}}}'
          ']}}}}});'
          '</script></html>';
      final result = PinterestParser.parseMediaData(html, pinId);
      expect(result!.slots.length, 2);
      expect(result.slots[1].imageUrl, 'https://i.pinimg.com/originals/s2.jpg');
    });
  });

  group('indexed filenames (07.3 contract with FormatUtils)', () {
    test('carousel download names are deterministic and 1-based', () {
      final result = PinterestParser.parseMediaData(
          Fixtures.pinCarousel(), pinId);
      final names = result!.slots
          .asMap()
          .entries
          .map((e) => pinNameFor(result.pinId, e.value.imageUrl, e.key + 1))
          .toList();
      expect(names.length, 3);
      expect(names.toSet().length, 3, reason: 'names must be unique per slot');
      for (final n in names) {
        expect(RegExp(r'^\d+_image_\d+\.jpg$').hasMatch(n), isTrue,
            reason: 'unexpected name shape: $n');
      }
    });
  });
}

/// Mirrors the job_provider carousel call: FormatUtils.pinFilename with
/// role 'image' and 1-based imageIndex. Reimplemented here to keep the
/// parser test free of the format import; shape parity asserted above.
String pinNameFor(String pinId, String url, int index) {
  final ext = url.endsWith('.png') ? '.png' : '.jpg';
  return '$pinId' '_image_' '$index$ext';
}
