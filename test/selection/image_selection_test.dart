import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/media/image_selection.dart';

/// 3.1.1 — image rendition ranking + full-resolution upgrade.
///
/// Device report: a public pin downloaded a 60x60 / 6 KB JPEG as its image.
/// Root cause: flat `images_*` maps were consumed in insertion order, and the
/// live SSR shape emits `images_60x60` first. Evidence for the upgrade rule:
/// every reported pin's `originals` URL answered 200 with a real JPEG
/// (71–154 KB) — see reports/3.1.1-device-bugfix.md.
void main() {
  group('pinterestImageRank', () {
    test('originals outranks every numeric rendition', () {
      expect(
        pinterestImageRank('https://i.pinimg.com/originals/aa/bb/cc/x.jpg'),
        greaterThan(pinterestImageRank('https://i.pinimg.com/1200x/aa/bb/cc/x.jpg')),
      );
      expect(
        pinterestImageRank('https://i.pinimg.com/orig/aa/bb/cc/x.jpg'),
        greaterThan(pinterestImageRank('https://i.pinimg.com/736x/aa/bb/cc/x.jpg')),
      );
    });

    test('numeric renditions rank by largest axis', () {
      expect(
        pinterestImageRank('https://i.pinimg.com/736x/aa/bb/cc/x.jpg'),
        greaterThan(pinterestImageRank('https://i.pinimg.com/236x/aa/bb/cc/x.jpg')),
      );
      expect(
        pinterestImageRank('https://i.pinimg.com/236x/aa/bb/cc/x.jpg'),
        greaterThan(pinterestImageRank('https://i.pinimg.com/136x136/aa/bb/cc/x.jpg')),
      );
      expect(
        pinterestImageRank('https://i.pinimg.com/136x136/aa/bb/cc/x.jpg'),
        greaterThan(pinterestImageRank('https://i.pinimg.com/60x60/aa/bb/cc/x.jpg')),
      );
    });

    test('non-rendition URLs score -1 (never preferred, still usable)', () {
      expect(pinterestImageRank(null), -1);
      expect(pinterestImageRank(''), -1);
      expect(pinterestImageRank('https://example.com/a/b/c/d/x.jpg'), -1);
      // Video-thumbnail path: a different shape, not a rendition token.
      expect(
        pinterestImageRank(
            'https://i.pinimg.com/videos/thumbnails/originals/aa/bb/cc/x.jpg'),
        -1,
      );
    });

    test('renditionTokenOf documents the recognised path shape', () {
      expect(
        renditionTokenOf('https://i.pinimg.com/236x/aa/bb/cc/x.jpg'),
        '236x',
      );
      expect(
        renditionTokenOf('https://i.pinimg.com/originals/aa/bb/cc/x.jpg'),
        'originals',
      );
      expect(renditionTokenOf('https://i.pinimg.com/236x/aa/bb/x.jpg'), isNull);
    });
  });

  group('bestPinterestImageUrl', () {
    test('picks the largest rendition regardless of list order', () {
      // The live 60x60-first ordering that caused the bug.
      expect(
        bestPinterestImageUrl([
          'https://i.pinimg.com/60x60/aa/bb/cc/x.jpg',
          'https://i.pinimg.com/236x/aa/bb/cc/x.jpg',
          'https://i.pinimg.com/originals/aa/bb/cc/x.jpg',
        ]),
        'https://i.pinimg.com/originals/aa/bb/cc/x.jpg',
      );
    });

    test('null / empty entries are skipped', () {
      expect(
        bestPinterestImageUrl([
          null,
          '',
          'https://i.pinimg.com/474x/aa/bb/cc/x.jpg',
        ]),
        'https://i.pinimg.com/474x/aa/bb/cc/x.jpg',
      );
    });

    test('empty input yields null', () {
      expect(bestPinterestImageUrl(const []), isNull);
    });
  });

  group('upgradePinterestImageUrl', () {
    test('rewrites thumbnail tokens to originals', () {
      for (final token in ['60x60', '136x136', '170x', '236x', '474x', '564x']) {
        expect(
          upgradePinterestImageUrl('https://i.pinimg.com/$token/aa/bb/cc/x.jpg'),
          'https://i.pinimg.com/originals/aa/bb/cc/x.jpg',
          reason: token,
        );
      }
    });

    test('leaves large renditions and originals untouched', () {
      expect(
        upgradePinterestImageUrl('https://i.pinimg.com/736x/aa/bb/cc/x.jpg'),
        'https://i.pinimg.com/736x/aa/bb/cc/x.jpg',
      );
      expect(
        upgradePinterestImageUrl('https://i.pinimg.com/1200x/aa/bb/cc/x.jpg'),
        'https://i.pinimg.com/1200x/aa/bb/cc/x.jpg',
      );
      expect(
        upgradePinterestImageUrl('https://i.pinimg.com/originals/aa/bb/cc/x.jpg'),
        'https://i.pinimg.com/originals/aa/bb/cc/x.jpg',
      );
    });

    test('never touches other hosts or the video-thumbnail path', () {
      const other = 'https://media.example.com/60x60/aa/bb/cc/x.jpg';
      expect(upgradePinterestImageUrl(other), other);
      const thumb =
          'https://i.pinimg.com/videos/thumbnails/originals/aa/bb/cc/x.jpg';
      expect(upgradePinterestImageUrl(thumb), thumb);
    });

    test('threshold is configurable (minDimension)', () {
      // 474x is below the 736 default, above a 300 floor.
      expect(
        upgradePinterestImageUrl('https://i.pinimg.com/474x/aa/bb/cc/x.jpg',
            minDimension: 300),
        'https://i.pinimg.com/474x/aa/bb/cc/x.jpg',
      );
    });
  });
}
