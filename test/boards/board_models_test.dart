import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/board.dart';
import 'package:pindl/data/models/board_section.dart';
import 'package:pindl/data/models/pin_item.dart';

import '../helpers/fixture_loader.dart';

void main() {
  group('Board.fromListingRow — probe-validated shape (Phase 09.2)', () {
    final data =
        (Fixtures.boardsPage1()['resource_response']['data'] as List)
            .cast<Map<String, dynamic>>();

    test('parses the full row with the identity split applied', () {
      final board = Board.fromListingRow(data.first)!;
      expect(board.boardId, '111111111111111111'); // canonical identity
      expect(board.slug, 'fixture-board'); // display/path identity
      expect(board.name, 'Fixture Board');
      expect(board.pinCount, 12);
      expect(board.sectionCount, 2);
      // HD cover preferred, standard fallback.
      expect(board.coverImageUrl,
          'https://i.pinimg.com/600x600/aa/bb/cc/aabbcc11223344556677889900112233.jpg');
      expect(board.description, 'Fixture board description');
    });

    test('second row: null description tolerated, no HD cover', () {
      final board = Board.fromListingRow(data[1])!;
      expect(board.boardId, '222222222222222222');
      expect(board.slug, 'fixture-second-board');
      expect(board.description, isNull);
      expect(board.coverImageUrl,
          'https://i.pinimg.com/236x/dd/ee/ff/ddeeff00112233445566778899aabbcc.jpg');
      expect(board.sectionCount, 0);
    });

    test('slug comes from the row url, never a request key', () {
      // G5: slug is display/path identity; boardId is canonical. The model
      // keeps them distinct fields; equality is over ALL fields (Equatable),
      // but requests built from a Board must use boardId (registry tests
      // pin the option builders to `board_id`).
      final board = Board.fromListingRow(data.first)!;
      expect(board.slug, isNot(board.boardId));
    });

    test('tolerant reader: odd/missing fields degrade, never throw', () {
      expect(Board.fromListingRow({}), isNull); // no id → null, skip row
      final minimal = Board.fromListingRow({
        'id': '999',
        'url': null,
        'name': null,
        'pin_count': '12', // string-count tolerance
      })!;
      expect(minimal.boardId, '999');
      expect(minimal.slug, '');
      expect(minimal.name, '');
      expect(minimal.pinCount, 12);
      expect(minimal.sectionCount, 0);
      expect(minimal.coverImageUrl, isNull);
    });

    test('round-trip: fromListingRow → toJson → fromJson preserves all', () {
      final original = Board.fromListingRow(data.first)!;
      final restored = Board.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.boardId, original.boardId);
      expect(restored.slug, original.slug);
    });
  });

  group('BoardSection.fromListingRow — probe-validated shape', () {
    final data =
        (Fixtures.boardSectionsPage1()['resource_response']['data'] as List)
            .cast<Map<String, dynamic>>();

    test('parses section row incl. parent board id', () {
      final s = BoardSection.fromListingRow(data.first)!;
      expect(s.sectionId, '333333333333333333'); // canonical identity
      expect(s.slug, 'fixture-section');
      expect(s.title, 'Fixture Section');
      expect(s.boardId, '111111111111111111');
      expect(s.pinCount, 5);
      expect(s.description, 'Fixture section description');
    });

    test('null description tolerated', () {
      final s = BoardSection.fromListingRow(data[1])!;
      expect(s.sectionId, '444444444444444444');
      expect(s.description, isNull);
    });

    test('tolerant reader: no id → null; odd fields degrade', () {
      expect(BoardSection.fromListingRow({}), isNull);
      final minimal = BoardSection.fromListingRow({
        'id': '888',
        'slug': null,
        'pin_count': '7',
        'board': null,
      })!;
      expect(minimal.sectionId, '888');
      expect(minimal.slug, '');
      expect(minimal.pinCount, 7);
      expect(minimal.boardId, isNull);
    });

    test('round-trip: fromListingRow → toJson → fromJson preserves all', () {
      final original = BoardSection.fromListingRow(data.first)!;
      final restored = BoardSection.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.sectionId, original.sectionId);
      expect(restored.boardId, original.boardId);
    });
  });

  group('identity split invariants (G5 — labeled DESIGN decision)', () {
    test('board and section ids are disjoint identities in fixtures', () {
      final board = Board.fromListingRow(
          (Fixtures.boardsPage1()['resource_response']['data'] as List)
              .first as Map<String, dynamic>)!;
      final section = BoardSection.fromListingRow(
          (Fixtures.boardSectionsPage1()['resource_response']['data'] as List)
              .first as Map<String, dynamic>)!;
      // A section id must never collide with its parent board id — the
      // resume keying (09.5) distinguishes board vs section scope by id.
      expect(section.sectionId, isNot(board.boardId));
      expect(section.boardId, board.boardId);
    });
  });

  group('board rows flow through the UNCHANGED pin pipeline (09.3 prep)', () {
    test('grid_item board pin rows parse via PinItem.fromUserPinJson', () {
      // Contract evidence for the boards-extraction plan §5: section/board
      // pin rows share the grid_item shape family (JS ROW_NORMALIZERS →
      // normalizePin), so the Phase 03/07 pipeline is reused untouched.
      final pinRow = {
        'id': '555555555555555555',
        'grid_title': 'Fixture Board Pin',
        'title': 'Fixture Board Pin',
        'created_at': 'Thu, 11 Dec 2025 04:04:36 +0000',
        'images': {
          'orig': {
            'url':
                'https://i.pinimg.com/originals/aa/bb/cc/aabbcc11223344556677889900112233.jpg',
            'width': 736,
            'height': 1104,
          }
        },
        'videos': [],
        'native_creator': {
          'id': '111222333444555666',
          'username': 'fixtureuser',
          'full_name': 'Fixture Author',
        },
      };
      final pin = PinItem.fromUserPinJson(pinRow);
      expect(pin.pinId, '555555555555555555');
      expect(pin.hasImage, isTrue);
      expect(pin.hasVideo, isFalse);
    });
  });
}
