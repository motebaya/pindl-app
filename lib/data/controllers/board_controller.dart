import 'package:dio/dio.dart' show CancelToken;

import '../../core/persistence/metadata_schema.dart';
import '../models/board.dart';
import '../models/board_section.dart';
import '../models/pin_item.dart';
import '../pinterest/resources.dart';
import '../services/pinterest_extractor_service.dart';
import 'extraction_controller.dart' show ControllerLog;

/// Capped listing result for non-pin resources ([Board] / [BoardSection]).
/// [nextBookmark] is non-null ONLY on a page-cap exit while the feed still
/// has pages — the same cap-exit-only contract as the user-pins feed
/// (Phase 07.5 / D-34 / DISC-21: natural ends return null). The bookmark
/// is raw here; the 09.4 context tuple wraps it before persistence.
class BoardListing<T> {
  final List<T> items;

  /// Cap-exit continuation cursor; null on a natural end.
  final String? nextBookmark;

  const BoardListing({required this.items, this.nextBookmark});
}

/// Result of a board-pins extraction: pins parsed through the UNCHANGED
/// pipeline plus the author from the first row (user-pins parity: the
/// metadata writer and result cards key on the author identity).
class BoardPinsResult {
  final List<PinItem> pins;

  /// Cap-exit continuation cursor; null on a natural end.
  final String? nextBookmark;

  /// Full provenance tuple for the cursor (09.4 / D-34) — non-null exactly
  /// when [nextBookmark] is non-null. Persistence consumes the tuple; the
  /// raw cursor never travels alone.
  final BookmarkContext? bookmarkContext;

  const BoardPinsResult({
    required this.pins,
    this.nextBookmark,
    this.bookmarkContext,
  });
}

/// Phase 09.3 — board fetch: boards / board sections / section pins /
/// whole-board pins via the [PinterestResources] registry, through the
/// [PinterestExtractorService.fetchResourcePage] primitive.
///
/// Reason trace (contract 09.3): responsibility (board domain isolated from
/// the user-pins flow) · testability (fixture-driven through the injected
/// service, no Flutter bindings) · evidence (boards-extraction plan §5 —
/// section/board pin rows share the grid_item shape, JS ROW_NORMALIZERS →
/// normalizePin; probe-validated row shapes, seam-1 checkpoint).
///
/// Widget-free + channel-free by construction (G3): no `package:flutter`
/// imports, no method channels, no file I/O. Logs emit on the same
/// [ControllerLog] sinks the user-pins flow uses — console parity without
/// production prints.
class BoardController {
  final PinterestExtractorService extractor;
  final ControllerLog log;

  BoardController({required this.extractor, required this.log});

  /// Fetch a user's public boards (capped). Rows without an identity are
  /// skipped (tolerant reader contract); first-occurrence wins on repeated
  /// board ids across overlapping pages.
  Future<BoardListing<Board>> fetchBoards({
    required String userId,
    required String username,
    int maxPages = 1,
    String? bookmark,
    CancelToken? cancelToken,
  }) async {
    final def = PinterestResources.userBoards;
    final options =
        PinterestResourceOptions.userBoards(userId: userId, username: username);
    final sourceUrl = resolveSourceUrl(def, username: username);

    final boards = <Board>[];
    final seenIds = <String>{};
    String? currentBookmark = bookmark;
    String? pendingBookmark;
    var page = 0;

    while (page < maxPages) {
      page++;
      final pageData = await extractor.fetchResourcePage(
        def: def,
        options: options,
        sourceUrl: sourceUrl,
        bookmark: currentBookmark,
        cancelToken: cancelToken,
      );
      if (pageData == null) break; // request/parse failure — return what we have

      // Cap-exit cursor: the LAST SERVED page's answer (DISC-21 rule).
      pendingBookmark = pageData.hasNext ? pageData.bookmark : null;

      for (final row in pageData.data) {
        if (row is! Map<String, dynamic>) continue;
        final board = Board.fromListingRow(row);
        if (board == null) continue;
        if (seenIds.contains(board.boardId)) continue;
        seenIds.add(board.boardId);
        boards.add(board);
      }

      if (!pageData.hasNext) break; // natural end
      currentBookmark = pageData.bookmark;
    }

    final capped = page >= maxPages && pendingBookmark != null;
    if (capped) {
      log.fetch(
          'Page cap reached ($maxPages) — ${boards.length} boards so far; bookmark retained');
    } else {
      log.fetch('Boards fetched: ${boards.length}');
    }
    return BoardListing(
      items: boards,
      nextBookmark: capped ? pendingBookmark : null,
    );
  }

  /// Fetch a board's sections (capped). Same tolerance/dedupe rules as
  /// [fetchBoards], keyed by section id.
  Future<BoardListing<BoardSection>> fetchBoardSections({
    required String boardId,
    required String username,
    required String boardSlug,
    int maxPages = 1,
    String? bookmark,
    CancelToken? cancelToken,
  }) async {
    final def = PinterestResources.boardSections;
    final options = PinterestResourceOptions.boardSections(boardId: boardId);
    final sourceUrl =
        resolveSourceUrl(def, username: username, boardSlug: boardSlug);

    final sections = <BoardSection>[];
    final seenIds = <String>{};
    String? currentBookmark = bookmark;
    String? pendingBookmark;
    var page = 0;

    while (page < maxPages) {
      page++;
      final pageData = await extractor.fetchResourcePage(
        def: def,
        options: options,
        sourceUrl: sourceUrl,
        bookmark: currentBookmark,
        cancelToken: cancelToken,
      );
      if (pageData == null) break;

      pendingBookmark = pageData.hasNext ? pageData.bookmark : null;

      for (final row in pageData.data) {
        if (row is! Map<String, dynamic>) continue;
        final section = BoardSection.fromListingRow(row);
        if (section == null) continue;
        if (seenIds.contains(section.sectionId)) continue;
        seenIds.add(section.sectionId);
        sections.add(section);
      }

      if (!pageData.hasNext) break;
      currentBookmark = pageData.bookmark;
    }

    final capped = page >= maxPages && pendingBookmark != null;
    if (capped) {
      log.fetch(
          'Page cap reached ($maxPages) — ${sections.length} sections so far; bookmark retained');
    } else {
      log.fetch('Board sections fetched: ${sections.length}');
    }
    return BoardListing(
      items: sections,
      nextBookmark: capped ? pendingBookmark : null,
    );
  }

  /// Fetch the pins of one board section. Rows parse through the UNCHANGED
  /// pipeline ([PinItem.fromUserPinJson] — grid_item shape family); dedupe
  /// by pin id, first occurrence wins (Phase 07 G5 semantics).
  ///
  /// On a cap exit the raw cursor is returned WITH its full D-34 provenance
  /// tuple ([BoardPinsResult.bookmarkContext], resource
  /// `board_section_pins`) — the 09.4 contract. Reuse is ONLY on a full
  /// tuple match; mismatch → fresh extraction (fail-safe direction).
  Future<BoardPinsResult> fetchSectionPins({
    required String sectionId,
    required String username,
    required String boardSlug,
    int maxPages = 1,
    String? bookmark,
    CancelToken? cancelToken,
  }) =>
      _fetchPinFeed(
        def: PinterestResources.boardSectionPins,
        options: PinterestResourceOptions.boardSectionPins(sectionId: sectionId),
        username: username,
        boardSlug: boardSlug,
        maxPages: maxPages,
        bookmark: bookmark,
        cancelToken: cancelToken,
        label: 'section pins',
        resource: BookmarkContext.resourceBoardSectionPins,
      );

  /// Fetch a whole board's pins (board feed). Same contract as
  /// [fetchSectionPins] with the `board.pins` registry entry and resource
  /// tag `board_pins`.
  Future<BoardPinsResult> fetchBoardPins({
    required String boardId,
    required String username,
    required String boardSlug,
    int maxPages = 1,
    String? bookmark,
    CancelToken? cancelToken,
  }) =>
      _fetchPinFeed(
        def: PinterestResources.boardPins,
        options: PinterestResourceOptions.boardPins(boardId: boardId),
        username: username,
        boardSlug: boardSlug,
        maxPages: maxPages,
        bookmark: bookmark,
        cancelToken: cancelToken,
        label: 'board pins',
        resource: BookmarkContext.resourceBoardPins,
      );

  /// Shared pin-feed loop (section pins / board feed): capped pagination,
  /// pin-id dedupe, unchanged per-row parsing. An empty or failed page ends
  /// the loop; the cap-exit cursor (pendingBookmark from the last served
  /// page) governs whether a continuation exists.
  Future<BoardPinsResult> _fetchPinFeed({
    required PinterestResourceDef def,
    required Map<String, dynamic> options,
    required String username,
    required String boardSlug,
    required int maxPages,
    required String? bookmark,
    required CancelToken? cancelToken,
    required String label,
    required String resource,
  }) async {
    final sourceUrl =
        resolveSourceUrl(def, username: username, boardSlug: boardSlug);

    final pins = <PinItem>[];
    final seenPinIds = <String>{};
    String? currentBookmark = bookmark;
    String? pendingBookmark;
    var page = 0;

    while (page < maxPages) {
      page++;
      final pageData = await extractor.fetchResourcePage(
        def: def,
        options: options,
        sourceUrl: sourceUrl,
        bookmark: currentBookmark,
        cancelToken: cancelToken,
      );
      if (pageData == null) break;

      pendingBookmark = pageData.hasNext ? pageData.bookmark : null;

      for (final row in pageData.data) {
        if (row is! Map<String, dynamic>) continue;
        final pin = PinItem.fromUserPinJson(row);
        if (pin.pinId.isEmpty || seenPinIds.contains(pin.pinId)) continue;
        seenPinIds.add(pin.pinId);
        pins.add(pin);
      }

      if (!pageData.hasNext) break;
      currentBookmark = pageData.bookmark;
    }

    final capped = page >= maxPages && pendingBookmark != null;
    if (capped) {
      log.fetch(
          'Page cap reached ($maxPages) — ${pins.length} $label so far; bookmark retained');
    } else {
      log.fetch('$label fetched: ${pins.length}');
    }
    return BoardPinsResult(
      pins: pins,
      // 09.4 (D-34): the cursor travels with its full provenance tuple or
      // not at all. Board/section scope rides inside request_options
      // (board_id / section_id) — canonical-JSON comparison covers it.
      bookmarkContext: capped
          ? BookmarkContext(
              username: username,
              resource: resource,
              requestOptions: options,
              extractionMode: 'pins',
              maxPages: maxPages,
              bookmark: pendingBookmark,
            )
          : null,
      nextBookmark: capped ? pendingBookmark : null,
    );
  }
}
