import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/board.dart';
import 'package:pindl/data/models/board_section.dart';
import 'package:pindl/data/models/board_selection.dart';

BoardChoice _choice({
  required String id,
  String slug = 'b',
  BoardDownloadMode mode = BoardDownloadMode.skip,
  Set<String> picks = const {},
  List<BoardSection> sections = const [],
  int pinCount = 0,
}) =>
    BoardChoice(
      boardId: id,
      slug: slug,
      name: 'Board $id',
      mode: mode,
      sectionIds: picks,
      sections: sections,
      boardPinCount: pinCount,
    );

BoardSection _section({required String id, int pins = 0}) => BoardSection(
      sectionId: id,
      slug: 's-$id',
      title: 'Section $id',
      boardId: 'b1',
      pinCount: pins,
    );

void main() {
  group('BoardChoice — JS Whole/Sections/Skip semantics (Phase 10.1)', () {
    test('whole board contributes the board pin count', () {
      final c = _choice(id: 'b1', mode: BoardDownloadMode.whole, pinCount: 12);
      expect(c.estimatedPins, 12);
      expect(c.isExcluded, isFalse);
    });

    test('sections mode contributes only picked sections (JS pick semantics)',
        () {
      final c = _choice(
        id: 'b1',
        mode: BoardDownloadMode.sections,
        picks: {'s1', 's3'},
        sections: [_section(id: 's1', pins: 5), _section(id: 's3', pins: 7)],
        pinCount: 30,
      );
      expect(c.estimatedPins, 12, reason: '5 + 7, NOT the board count');
      expect(c.isExcluded, isFalse);
    });

    test('sections mode with zero picks estimates 0 (nothing selected)',
        () {
      final c = _choice(
        id: 'b1',
        mode: BoardDownloadMode.sections,
        sections: [_section(id: 's1', pins: 5)],
        pinCount: 5,
      );
      expect(c.estimatedPins, 0);
    });

    test('skip excludes the board entirely', () {
      final c = _choice(id: 'b1', mode: BoardDownloadMode.skip, pinCount: 99);
      expect(c.estimatedPins, 0);
      expect(c.isExcluded, isTrue);
    });

    test('unknown picked section ids contribute 0 (tolerant math)', () {
      final c = _choice(
        id: 'b1',
        mode: BoardDownloadMode.sections,
        picks: {'ghost'},
        sections: [_section(id: 's1', pins: 5)],
      );
      expect(c.estimatedPins, 0);
    });

    test('copyWith changes only the targeted fields (identity immutable)',
        () {
      final c = _choice(id: 'b1', mode: BoardDownloadMode.skip, pinCount: 3);
      final whole = c.copyWith(mode: BoardDownloadMode.whole);
      expect(whole.mode, BoardDownloadMode.whole);
      expect(whole.boardId, c.boardId);
      expect(whole.slug, c.slug);
      expect(whole.boardPinCount, c.boardPinCount);
    });

    test('equivalence over value fields (Equatable)', () {
      final a = _choice(id: 'b1', mode: BoardDownloadMode.whole, pinCount: 3);
      final b = _choice(id: 'b1', mode: BoardDownloadMode.whole, pinCount: 3);
      expect(a, b);
    });
  });

  group('BoardSelection — job-order aggregation', () {
    test('active list drops skips, preserves display order (job order)', () {
      final sel = BoardSelection(choices: [
        _choice(id: 'b1', mode: BoardDownloadMode.skip),
        _choice(id: 'b2', mode: BoardDownloadMode.whole, pinCount: 4),
        _choice(id: 'b3', mode: BoardDownloadMode.sections,
            picks: {'s1'}, sections: [_section(id: 's1', pins: 2)]),
        _choice(id: 'b4', mode: BoardDownloadMode.whole, pinCount: 6),
      ]);
      expect(sel.active.map((c) => c.boardId).toList(), ['b2', 'b3', 'b4']);
      expect(sel.boardCount, 3);
    });

    test('estimatedPins sums per-board contributions', () {
      final sel = BoardSelection(choices: [
        _choice(id: 'b1', mode: BoardDownloadMode.whole, pinCount: 4),
        _choice(id: 'b2', mode: BoardDownloadMode.sections,
            picks: {'s1', 's2'},
            sections: [_section(id: 's1', pins: 2), _section(id: 's2', pins: 3)]),
        _choice(id: 'b3', mode: BoardDownloadMode.skip, pinCount: 50),
      ]);
      expect(sel.estimatedPins, 9);
    });

    test('isEmpty when everything is skipped', () {
      final sel = BoardSelection(
          choices: [_choice(id: 'b1', mode: BoardDownloadMode.skip)]);
      expect(sel.isEmpty, isTrue);
      expect(sel.boardCount, 0);
    });

    test('empty selection is valid (all-skip state)', () {
      expect(const BoardSelection(choices: []).isEmpty, isTrue);
    });
  });
}
