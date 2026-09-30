import 'package:flutter/material.dart';

import '../../core/theme/neumorphism_theme.dart';
import '../../data/models/board.dart';
import '../../data/models/board_section.dart';
import '../../data/models/board_selection.dart';
import 'soft_checkbox.dart';

/// Phase 10.1 — board discovery + selection (boards-ux plan §2–3).
///
/// A CONTROLLED widget: data in ([boards], [sectionsByBoard], [selection]),
/// selection out ([onChanged]). No provider imports — the home page hosts
/// it and wires the provider; widget tests drive it with fixture data.
///
/// Per-board semantics (JS inquirer port): checkbox = include/exclude;
/// when included, mode radio Whole board | Pick sections | Skip; Pick
/// sections reveals a section checkbox list with counts. Sorted by
/// pinCount desc (JS parity) happens in the CALLER (data order in =
/// display order out).
class BoardPicker extends StatelessWidget {
  final List<Board> boards;

  /// Sections known per boardId (lazy-loaded by the caller on demand).
  final Map<String, List<BoardSection>> sectionsByBoard;

  final BoardSelection selection;

  /// Sections lookup is async/lazy — fired when a board switches to
  /// sections mode without known sections.
  final void Function(Board board)? onRequestSections;

  final ValueChanged<BoardSelection> onChanged;

  const BoardPicker({
    super.key,
    required this.boards,
    required this.sectionsByBoard,
    required this.selection,
    required this.onChanged,
    this.onRequestSections,
  });

  BoardChoice _choiceOf(Board b) {
    for (final c in selection.choices) {
      if (c.boardId == b.boardId) return c;
    }
    return BoardChoice(
      boardId: b.boardId,
      slug: b.slug,
      name: b.name,
      sections: sectionsByBoard[b.boardId] ?? const [],
      boardPinCount: b.pinCount,
    );
  }

  void _replace(BoardChoice updated) {
    final exists =
        selection.choices.any((c) => c.boardId == updated.boardId);
    final newChoices = exists
        ? selection.choices
            .map((c) => c.boardId == updated.boardId ? updated : c)
            .toList()
        : [...selection.choices, updated];
    onChanged(BoardSelection(choices: newChoices));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final board in boards)
          _BoardRow(
            board: board,
            choice: _choiceOf(board),
            sections: sectionsByBoard[board.boardId] ?? const [],
            isDark: isDark,
            onToggleIncluded: _toggleIncluded,
            onModeChanged: _changeMode,
            onSectionToggled: _toggleSection,
            onRequestSections: onRequestSections,
          ),
      ],
    );
  }

  void _toggleIncluded(Board board, bool included) {
    final current = _choiceOf(board);
    final sections = sectionsByBoard[board.boardId] ?? const [];
    _replace(current.copyWith(
      mode: included
          ? BoardDownloadMode.whole
          : BoardDownloadMode.skip,
      sections: sections,
      sectionIds: included ? current.sectionIds : const {},
    ));
  }

  void _changeMode(Board board, BoardDownloadMode mode) {
    final current = _choiceOf(board);
    _replace(current.copyWith(mode: mode));
    if (mode == BoardDownloadMode.sections &&
        (sectionsByBoard[board.boardId] ?? const []).isEmpty) {
      onRequestSections?.call(board);
    }
  }

  void _toggleSection(Board board, String sectionId, bool picked) {
    final current = _choiceOf(board);
    final next = Set<String>.from(current.sectionIds);
    picked ? next.add(sectionId) : next.remove(sectionId);
    _replace(current.copyWith(sectionIds: next));
  }
}

class _BoardRow extends StatelessWidget {
  final Board board;
  final BoardChoice choice;
  final List<BoardSection> sections;
  final bool isDark;
  final void Function(Board, bool) onToggleIncluded;
  final void Function(Board, BoardDownloadMode) onModeChanged;
  final void Function(Board, String, bool) onSectionToggled;
  final void Function(Board)? onRequestSections;

  const _BoardRow({
    required this.board,
    required this.choice,
    required this.sections,
    required this.isDark,
    required this.onToggleIncluded,
    required this.onModeChanged,
    required this.onSectionToggled,
    required this.onRequestSections,
  });

  bool get included => !choice.isExcluded;

  @override
  Widget build(BuildContext context) {
    final cardColor = NeumorphismTheme.getCardColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SoftCheckbox(
                value: included,
                label: null,
                compact: false,
                onChanged: (v) => onToggleIncluded(board, v),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      board.name.isEmpty ? '/${board.slug}/' : board.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: textColor,
                      ),
                    ),
                    Text(
                      '${board.pinCount} pins'
                      '${board.sectionCount > 0 ? ' · ${board.sectionCount} sections' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: textColor.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (included) ...[
            const SizedBox(height: 8),
            _ModeSelector(
              choice: choice,
              isDark: isDark,
              onModeChanged: (m) => onModeChanged(board, m),
            ),
            if (choice.mode == BoardDownloadMode.sections &&
                sections.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final s in sections)
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: SoftCheckbox(
                    value: choice.sectionIds.contains(s.sectionId),
                    label: '${s.title} (${s.pinCount})',
                    compact: true,
                    onChanged: (v) => onSectionToggled(board, s.sectionId, v),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Whole | Pick sections | Skip — pill-style radio row.
class _ModeSelector extends StatelessWidget {
  final BoardChoice choice;
  final bool isDark;
  final ValueChanged<BoardDownloadMode> onModeChanged;

  const _ModeSelector({
    required this.choice,
    required this.isDark,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = NeumorphismTheme.getAccentColor(isDark);
    final cardColor = NeumorphismTheme.getCardColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);

    Widget pill(String label, BoardDownloadMode mode) {
      final selected = choice.mode == mode;
      return GestureDetector(
        onTap: () => onModeChanged(mode),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? accentColor : cardColor,
            borderRadius: BorderRadius.circular(999),
            boxShadow: selected
                ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4)
                : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? Colors.white : textColor,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill('Whole', BoardDownloadMode.whole),
        const SizedBox(width: 6),
        pill('Sections', BoardDownloadMode.sections),
        const SizedBox(width: 6),
        pill('Skip', BoardDownloadMode.skip),
      ],
    );
  }
}



