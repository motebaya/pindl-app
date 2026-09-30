import 'dart:convert';

/// Pinterest resource registry — Dart port of the JS `resources.js` pattern
/// (Phase 09.1). One entry per resource: endpoint path, per-resource
/// `x-pinterest-pws-handler`, `source_url`, and the exact `data` payload.
///
/// Payload shapes are LIVE-VALIDATED (probe 2026-09-30, desktop web session,
/// same request machinery as `UserActivityPinsResource` — all four endpoints
/// returned `status=success, code=0` with list data and paginating bookmarks
/// for feed-ish resources). Committed fixtures stay SYNTHETIC per the
/// fixtures README PII rule; this header records the evidence basis.
/// NOTE: the JS `resources.js` file itself is cited by the parity audits but
/// is not present in this repo — option keys mirror the audited machinery and
/// the probe-validated shapes (see checkpoint-2026-09-30-phase-09-start).
///
/// Identity NOTE (Phase 09 G5, design decision — NOT an observed Pinterest
/// contract): board identity = `boardId` (numeric id); slug = display/path
/// identity parsed from the row `url` field (`/<user>/<slug>/`).
///
/// ZERO UI: this file is domain-only (P3) — no widgets, no channels, no dio.
class PinterestResourceDef {
  /// Registry key (JS resources.js naming): e.g. `user.boards`.
  final String name;

  /// Endpoint path appended to the host: `/resource/<Name>/get/`.
  final String resourcePath;

  /// Per-resource `x-pinterest-pws-handler` header value.
  final String pwsHandler;

  /// Default `x-pinterest-source-url` / referer path for this resource.
  final String sourceUrl;

  const PinterestResourceDef({
    required this.name,
    required this.resourcePath,
    required this.pwsHandler,
    required this.sourceUrl,
  });

  /// Build the full request URL exactly like the user-pins machinery
  /// (`_fetchSinglePage`): GET `<path>?source_url=…&data=…&_=…` with the
  /// `{options, context}` envelope JSON-encoded, then component-encoded.
  String buildUrl({
    required Map<String, dynamic> options,
    String? sourceUrlOverride,
    int? timestampMs,
  }) {
    final data = {'options': options, 'context': {}};
    final sourceUrl = sourceUrlOverride ?? this.sourceUrl;
    final encodedSourceUrl = Uri.encodeComponent(sourceUrl);
    final encodedData = Uri.encodeComponent(jsonEncode(data));
    final timestamp = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return '$resourcePath?source_url=$encodedSourceUrl&data=$encodedData&_=$timestamp';
  }

  @override
  String toString() => 'PinterestResourceDef($name -> $resourcePath)';
}

/// The four board/section resources (Phase 09 contract scope — no other
/// resource types without a classification record).
abstract final class PinterestResources {
  /// `user.boards` — list a user's public boards.
  /// Probe: 200/success, rows carry id/url/name/pin_count/section_count/
  /// image_cover_url/owner (+ ~30 more keys — models take the subset).
  static const userBoards = PinterestResourceDef(
    name: 'user.boards',
    resourcePath: '/resource/BoardsResource/get/',
    pwsHandler: 'www/[username].js',
    sourceUrl: '/:username/',
  );

  /// `board.sections` — list a board's sections.
  /// Probe: 200/success, rows carry id/slug/title/pin_count/preview_pins;
  /// paginates (bookmark present when more pages exist).
  static const boardSections = PinterestResourceDef(
    name: 'board.sections',
    resourcePath: '/resource/BoardSectionsResource/get/',
    pwsHandler: 'www/board/[slug].js',
    sourceUrl: '/:username/:board_slug/',
  );

  /// `board.sectionPins` — pins of one board section.
  /// Probe: 200/success, rows are grid_item pins (same shape family as
  /// UserActivityPinsResource rows — JS ROW_NORMALIZERS maps this to
  /// normalizePin); paginates.
  static const boardSectionPins = PinterestResourceDef(
    name: 'board.sectionPins',
    resourcePath: '/resource/BoardSectionPinsResource/get/',
    pwsHandler: 'www/board/[slug].js',
    sourceUrl: '/:username/:board_slug/',
  );

  /// `board.pins` — whole-board feed.
  /// Probe: 200/success, grid_item pin rows; paginates (600-char bookmark).
  static const boardPins = PinterestResourceDef(
    name: 'board.pins',
    resourcePath: '/resource/BoardFeedResource/get/',
    pwsHandler: 'www/board/[slug].js',
    sourceUrl: '/:username/:board_slug/',
  );

  /// All registry entries (order: profile-outward).
  static const List<PinterestResourceDef> all = [
    userBoards,
    boardSections,
    boardSectionPins,
    boardPins,
  ];
}

/// Request-option builders — one per registry entry. Keys mirror the
/// probe-validated payloads (live 2026-09-30); `bookmarks` is added by the
/// paginator (09.4), matching the user-pins convention of omitting the key
/// when no bookmark exists.
abstract final class PinterestResourceOptions {
  /// Options for [PinterestResources.userBoards].
  static Map<String, dynamic> userBoards({
    required String userId,
    required String username,
  }) =>
      {
        'user_id': userId,
        'username': username,
        'field_set_key': 'profile_grid_item',
        'fetch_board_owner': true,
      };

  /// Options for [PinterestResources.boardSections].
  static Map<String, dynamic> boardSections({required String boardId}) => {
        'board_id': boardId,
        'field_set_key': 'board_section_grid_item',
      };

  /// Options for [PinterestResources.boardSectionPins].
  static Map<String, dynamic> boardSectionPins({required String sectionId}) => {
        'section_id': sectionId,
        'field_set_key': 'grid_item',
        'redux_normalize_feed': true,
      };

  /// Options for [PinterestResources.boardPins].
  static Map<String, dynamic> boardPins({required String boardId}) => {
        'board_id': boardId,
        'page_size': 25,
        'field_set_key': 'grid_item',
        'redux_normalize_feed': true,
      };
}

/// Resolve a def's source_url template against actual values
/// (`:username` / `:board_slug` placeholders).
String resolveSourceUrl(
  PinterestResourceDef def, {
  String? username,
  String? boardSlug,
}) =>
    def.sourceUrl
        .replaceFirst(':board_slug', boardSlug ?? '')
        .replaceFirst(':username', username ?? '');
