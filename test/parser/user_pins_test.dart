import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: user-pins feed JSON parsing (4 envelope cases).
void main() {
  group('parseUserPinsResponse — success + bookmark (page1)', () {
    final author = Author(username: 'fixtureuser', name: 'Fixture Author', userId: '111222333444555666');

    test('parses 3 pins with counts', () {
      final result = PinterestParser.parseUserPinsResponse(
        Fixtures.userPinsPage1(),
        existingAuthor: author,
      );
      expect(result, isNotNull);
      expect(result!.pins.length, 3);
      expect(result.totalImages, 3); // every pin carries images.orig
      expect(result.totalVideos, 2); // MP4 pin + HLS pin
    });

    test('bookmark present -> hasMore true', () {
      final result = PinterestParser.parseUserPinsResponse(
        Fixtures.userPinsPage1(),
        existingAuthor: author,
      );
      expect(result!.bookmark, 'P9|0|fixture-bookmark-token|0|0|0');
      expect(result.hasMore, isTrue);
    });

    test('extracts author from native_creator when not provided', () {
      final result = PinterestParser.parseUserPinsResponse(Fixtures.userPinsPage1());
      expect(result, isNotNull);
      expect(result!.author.username, 'fixtureuser');
      expect(result.author.name, 'Fixture Author');
      expect(result.author.userId, '111222333444555666');
    });
  });

  group('parseUserPinsResponse — last page (no bookmark)', () {
    test('hasMore false when bookmark absent', () {
      final author = Author(username: 'x', name: 'x', userId: '1');
      final result = PinterestParser.parseUserPinsResponse(
        Fixtures.userPinsLast(),
        existingAuthor: author,
      );
      expect(result, isNotNull);
      expect(result!.bookmark, isNull);
      expect(result.hasMore, isFalse);
      expect(result.pins.length, 1);
    });
  });

  group('parseUserPinsResponse — empty data (loop-guard case)', () {
    test('empty data with existing author -> empty result, bookmark nulled', () {
      final author = Author(username: 'x', name: 'x', userId: '1');
      final result = PinterestParser.parseUserPinsResponse(
        Fixtures.userPinsEmpty(),
        existingAuthor: author,
      );
      expect(result, isNotNull);
      expect(result!.pins, isEmpty);
      expect(result.bookmark, isNull); // end-of-pagination signal
      expect(result.hasMore, isFalse);
    });

    test('empty data without author -> null', () {
      expect(PinterestParser.parseUserPinsResponse(Fixtures.userPinsEmpty()), isNull);
    });
  });

  group('parseUserPinsResponse — non-success envelope', () {
    test('returns null on status != success', () {
      expect(PinterestParser.parseUserPinsResponse(Fixtures.userPinsBadStatus()), isNull);
    });
  });
}
