import 'package:equatable/equatable.dart';

import 'board_section.dart';

/// Per-board download mode — port of the JS inquirer semantics
/// (boards-ux plan §3, Phase 10 contract):
/// Whole = board as one unit; Sections = per-section choice; Skip = exclude.
enum BoardDownloadMode { whole, sections, skip }

/// One board's selection outcome. Identity follows D-37: [boardId] is the
/// canonical key; [slug] travels for display/path only.
class BoardChoice extends Equatable {
  final String boardId;
  final String slug;
  final String name;
  final BoardDownloadMode mode;

  /// Section ids picked when [mode] == sections (empty otherwise).
  final Set<String> sectionIds;

  /// Sections known for this board (for count math + the picker UI).
  final List<BoardSection> sections;

  /// Pin count of the board row (display/aggregation hint from the listing).
  final int boardPinCount;

  const BoardChoice({
    required this.boardId,
    required this.slug,
    required this.name,
    this.mode = BoardDownloadMode.skip,
    this.sectionIds = const {},
    this.sections = const [],
    this.boardPinCount = 0,
  });

  BoardChoice copyWith({
    BoardDownloadMode? mode,
    Set<String>? sectionIds,
    List<BoardSection>? sections,
  }) =>
      BoardChoice(
        boardId: boardId,
        slug: slug,
        name: name,
        mode: mode ?? this.mode,
        sectionIds: sectionIds ?? this.sectionIds,
        sections: sections ?? this.sections,
        boardPinCount: boardPinCount,
      );

  /// Pins this choice contributes to a job: whole board → boardPinCount;
  /// sections → sum of picked sections' counts; skip → 0.
  /// Aggregation HINT (listing counts, not fetched pins) — the job totals
  /// come from the actual fetch results.
  int get estimatedPins {
    switch (mode) {
      case BoardDownloadMode.whole:
        return boardPinCount;
      case BoardDownloadMode.sections:
        var total = 0;
        for (final s in sections) {
          if (sectionIds.contains(s.sectionId)) total += s.pinCount;
        }
        return total;
      case BoardDownloadMode.skip:
        return 0;
    }
  }

  bool get isExcluded => mode == BoardDownloadMode.skip;

  @override
  List<Object?> get props =>
      [boardId, slug, name, mode, sectionIds, sections, boardPinCount];

  @override
  String toString() => 'BoardChoice($boardId, $mode, pins≈$estimatedPins)';
}

/// The complete user selection across a user's boards — the payload the
/// download flow consumes (pure data; provider turns it into board jobs).
class BoardSelection extends Equatable {
  /// One choice per discovered board, in display order.
  final List<BoardChoice> choices;

  const BoardSelection({required this.choices});

  /// Boards with a non-skip mode, in display order (job order).
  List<BoardChoice> get active => choices.where((c) => !c.isExcluded).toList();

  int get boardCount => active.length;

  /// Sum of per-board estimates (display hint; job totals come from fetches).
  int get estimatedPins =>
      choices.fold(0, (sum, c) => sum + c.estimatedPins);

  bool get isEmpty => active.isEmpty;

  @override
  List<Object?> get props => [choices];

  @override
  String toString() =>
      'BoardSelection(${active.length} boards, pins≈$estimatedPins)';
}

/// D-38 REASON TRACE (Phase 10.1 decision — board job state):
///
/// DECISION: board flows run as PER-BOARD FEED JOBS through the EXISTING
/// `AppJobState` state machine (extended additively with board context
/// fields), one board at a time, sequential. NO parallel board-job state
/// class, NO job queue model.
///
/// Trace:
/// - The two-phase contract (B extract → C confirm → D download) is the
///   app's mental model and the source of every existing progress/persist/
///   notification behavior; a parallel state class would fork it.
/// - The download stack consumes `List<PinItem>` + per-item indices and
///   persists per feed (metadata v2 writer). Board pins ARE feed rows
///   (Phase 09 equivalence-proven), so a board download is a feed download
///   with a board-scoped subfolder + `board_resume` block.
/// - Per-board+type resume (Phase 09) already keys by boardId — sequential
///   per-board jobs map 1:1 onto it; a multi-board concurrent queue would
///   need new persistence semantics (scope creep, Phase 12 territory).
/// - Aggregated progress = the runner iterates choices and the UI sums
///   per-board counters (10.3); no queue model needed for that sum.
///
/// Consequences: job_provider gains additive board fields (discovered
/// boards, selection, current board context) + two flow methods (discover,
/// run board job) delegating to BoardController; JobStatus/JobStatus
/// machine untouched; feed flows byte-identical.
