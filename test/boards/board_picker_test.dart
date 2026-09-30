import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/board.dart';
import 'package:pindl/data/models/board_section.dart';
import 'package:pindl/data/models/board_selection.dart';
import 'package:pindl/presentation/widgets/board_picker.dart';
import 'package:pindl/presentation/widgets/soft_checkbox.dart';

Board _board(String id, String slug, String name, int pins,
        {int sections = 0}) =>
    Board(
      boardId: id,
      slug: slug,
      name: name,
      pinCount: pins,
      sectionCount: sections,
    );

BoardSection _section(String id, String title, int pins) => BoardSection(
      sectionId: id,
      slug: 's-$id',
      title: title,
      boardId: 'b1',
      pinCount: pins,
    );

/// Stateful host harness — mirrors a real parent that feeds the emitted
/// selection back into the controlled BoardPicker.
class _Harness {
  BoardSelection sel;
  final List<Board> sectionRequests = [];
  _Harness(this.sel);
}

Future<void> _pump(
  WidgetTester tester, {
  required _Harness h,
  required List<Board> boards,
  Map<String, List<BoardSection>> sectionsByBoard = const {},
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: StatefulBuilder(
          builder: (context, setState) => BoardPicker(
            boards: boards,
            sectionsByBoard: sectionsByBoard,
            selection: h.sel,
            onChanged: (s) => setState(() => h.sel = s),
            onRequestSections: (b) => h.sectionRequests.add(b),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  final boards = [
    _board('b1', 'first', 'First Board', 10, sections: 2),
    _board('b2', 'second', 'Second Board', 3),
  ];

  testWidgets('renders all boards with name and pin counts', (tester) async {
    final h = _Harness(BoardSelection(choices: const []));
    await _pump(tester, h: h, boards: boards);
    expect(find.text('First Board'), findsOneWidget);
    expect(find.text('Second Board'), findsOneWidget);
    expect(find.text('10 pins · 2 sections'), findsOneWidget);
    expect(find.text('3 pins'), findsOneWidget);
  });

  testWidgets('checkbox include → defaults to WHOLE mode (JS semantics)',
      (tester) async {
    final h = _Harness(BoardSelection(choices: const []));
    await _pump(tester, h: h, boards: boards);
    await tester.tap(find.byType(SoftCheckbox).first);
    await tester.pumpAndSettle();
    final choice = h.sel.choices.firstWhere((c) => c.boardId == 'b1');
    expect(choice.mode, BoardDownloadMode.whole);
    // Mode pills appear for the included board.
    expect(find.text('Whole'), findsOneWidget);
    expect(find.text('Sections'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('mode radios: Whole → Sections fires a lazy section request',
      (tester) async {
    final h = _Harness(BoardSelection(choices: const []));
    await _pump(tester, h: h, boards: boards);
    await tester.tap(find.byType(SoftCheckbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sections'));
    await tester.pumpAndSettle();
    final choice = h.sel.choices.firstWhere((c) => c.boardId == 'b1');
    expect(choice.mode, BoardDownloadMode.sections);
    expect(h.sectionRequests.map((b) => b.boardId), ['b1'],
        reason: 'no sections known → lazy request fired');
  });

  testWidgets('Pick sections reveals checkboxes with counts; picks flow '
      'into the selection and count math', (tester) async {
    final h = _Harness(BoardSelection(choices: [
      BoardChoice(
        boardId: 'b1',
        slug: 'first',
        name: 'First Board',
        mode: BoardDownloadMode.sections,
        sections: [_section('s1', 'Art', 5), _section('s2', 'Tech', 7)],
        boardPinCount: 10,
      ),
    ]));
    await _pump(tester, h: h, boards: boards, sectionsByBoard: {
      'b1': [_section('s1', 'Art', 5), _section('s2', 'Tech', 7)],
    });
    expect(find.text('Art (5)'), findsOneWidget);
    expect(find.text('Tech (7)'), findsOneWidget);
    await tester.tap(find.text('Art (5)'));
    await tester.pumpAndSettle();
    final choice = h.sel.choices.firstWhere((c) => c.boardId == 'b1');
    expect(choice.sectionIds, {'s1'});
    expect(choice.estimatedPins, 5);
    // uncheck → pick removed
    await tester.tap(find.text('Art (5)'));
    await tester.pumpAndSettle();
    expect(
        h.sel.choices.firstWhere((c) => c.boardId == 'b1').sectionIds,
        isEmpty);
  });

  testWidgets('unchecking the include box resets to SKIP and clears mode UI',
      (tester) async {
    final h = _Harness(BoardSelection(choices: [
      BoardChoice(
        boardId: 'b1',
        slug: 'first',
        name: 'First Board',
        mode: BoardDownloadMode.whole,
        boardPinCount: 10,
      ),
    ]));
    await _pump(tester, h: h, boards: boards);
    expect(find.text('Whole'), findsOneWidget);
    await tester.tap(find.byType(SoftCheckbox).first);
    await tester.pumpAndSettle();
    final choice = h.sel.choices.firstWhere((c) => c.boardId == 'b1');
    expect(choice.mode, BoardDownloadMode.skip);
    expect(choice.sectionIds, isEmpty);
    expect(find.text('Whole'), findsNothing);
  });

  testWidgets('mode row is HIDDEN for skipped boards', (tester) async {
    final h = _Harness(BoardSelection(choices: const []));
    await _pump(tester, h: h, boards: boards);
    expect(find.text('Whole'), findsNothing);
    expect(find.text('Sections'), findsNothing);
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('Whole pill tap switches mode (picks retained by the model)',
      (tester) async {
    final h = _Harness(BoardSelection(choices: [
      BoardChoice(
        boardId: 'b1',
        slug: 'first',
        name: 'First Board',
        mode: BoardDownloadMode.sections,
        sectionIds: const {'s1'},
        sections: [_section('s1', 'Art', 5)],
        boardPinCount: 10,
      ),
    ]));
    await _pump(tester, h: h, boards: boards,
        sectionsByBoard: {
          'b1': [_section('s1', 'Art', 5)],
        });
    await tester.tap(find.text('Whole'));
    await tester.pumpAndSettle();
    final choice = h.sel.choices.firstWhere((c) => c.boardId == 'b1');
    expect(choice.mode, BoardDownloadMode.whole);
    expect(choice.sectionIds, {'s1'},
        reason: 'model keeps picks; count math ignores them in whole mode');
  });

  testWidgets('second board is independent (per-board isolation)', (tester) async {
    final h = _Harness(BoardSelection(choices: const []));
    await _pump(tester, h: h, boards: boards);
    await tester.tap(find.byType(SoftCheckbox).first);
    await tester.pumpAndSettle();
    // Second board still skipped, untouched.
    expect(
        h.sel.choices.where((c) => c.boardId == 'b2'), isEmpty);
    expect(
        h.sel.choices.firstWhere((c) => c.boardId == 'b1').mode,
        BoardDownloadMode.whole);
  });
}
