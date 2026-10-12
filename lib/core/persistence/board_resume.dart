import 'metadata_schema.dart';

/// Board-scoped resume block (Phase 09.5) — v2-ADDITIVE metadata field
/// (`board_resume`), per the boards-extraction plan §7 (per board+mediaType
/// `completed_indices`, DL-3 structure reused) with the G5 refinement:
/// keyed by **boardId** (canonical identity), slug travels for display only.
///
/// Truth table UNCHANGED (D-04): success | explicit skip = complete;
/// failed | cancelled = incomplete → re-offered on continue. The completion
/// math reuses [maxContiguous] verbatim — no board-specific arithmetic.
/// Media-type gating (D-25): each type keeps its OWN set — a cross-type
/// continue cannot corrupt the other type's record.
///
/// Tolerant reader per D-26: malformed entries/fields degrade to safe
/// defaults or are skipped — never an exception, never partial semantics.
class BoardTypeResume {
  /// Indices completed per the truth table (success | explicit skip ONLY).
  final Set<int> completedIndices;

  final int successDownloaded;
  final int skipDownloaded;
  final int failedDownloaded;

  /// Feed/Board carousel migration: how many ITEMS the run planned when this
  /// record was written (one per pin, plus one per carousel slide). `null` for
  /// records written before the migration — the completeness check then falls
  /// back to the legacy pin-count comparison.
  final int? items;

  /// Coordinate space marker, mirroring the metadata `item_plan` field
  /// ([MetadataReader.feedItemPlanExpanded] once carousel slides count as
  /// items). `null` = pre-migration pin-level indices.
  final String? plan;

  const BoardTypeResume({
    required this.completedIndices,
    this.successDownloaded = 0,
    this.skipDownloaded = 0,
    this.failedDownloaded = 0,
    this.items,
    this.plan,
  });

  /// Continue-mode start index for this board+type (contract: same math as
  /// the user-feed v2 path).
  int get continueStartIndex => maxContiguous(completedIndices) + 1;

  /// Completed-but-non-contiguous indices (the holes) — re-offered on
  /// continue. Failed/cancelled items never enter [completedIndices], so
  /// they are re-offered by construction (D-04).
  Set<int> get reofferIndices {
    final mc = maxContiguous(completedIndices);
    return completedIndices.where((i) => i > mc).toSet();
  }  Map<String, dynamic> toJson() => {
        'completed_indices': completedIndices.toList()..sort(),
        'success_downloaded': successDownloaded,
        'skip_downloaded': skipDownloaded,
        'failed_downloaded': failedDownloaded,
        if (items != null) 'items': items,
        if (plan != null) 'plan': plan,
      };

  static BoardTypeResume? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final raw = json['completed_indices'];
    final indices = raw is List<dynamic> ? raw.whereType<int>().toSet() : <int>{};
    final rawItems = json['items'];
    final rawPlan = json['plan'];
    return BoardTypeResume(
      completedIndices: indices,
      successDownloaded: json['success_downloaded'] is int
          ? json['success_downloaded'] as int
          : 0,
      skipDownloaded:
          json['skip_downloaded'] is int ? json['skip_downloaded'] as int : 0,
      failedDownloaded: json['failed_downloaded'] is int
          ? json['failed_downloaded'] as int
          : 0,
      items: rawItems is int && rawItems >= 0 ? rawItems : null,
      plan: rawPlan is String && rawPlan.isNotEmpty ? rawPlan : null,
    );
  }

  @override
  String toString() =>
      'BoardTypeResume(done: ${completedIndices.length}, fail: $failedDownloaded)';
}

/// One board's resume entry: identity + per-media-type blocks.
class BoardResumeEntry {
  /// Canonical identity (G5 design decision — request/resume key).
  final String boardId;

  /// Display/path identity; never a key.
  final String? boardSlug;

  /// Per-media-type resume blocks, keyed by media type name
  /// (`image` / `video` — the MediaType enum names).
  final Map<String, BoardTypeResume> types;

  const BoardResumeEntry({
    required this.boardId,
    this.boardSlug,
    required this.types,
  });

  BoardTypeResume? typeFor(String mediaType) => types[mediaType];

  Map<String, dynamic> toJson() => {
        'board_id': boardId,
        if (boardSlug != null) 'board_slug': boardSlug,
        'types': {
          for (final e in types.entries) e.key: e.value.toJson(),
        },
      };

  static BoardResumeEntry? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final boardId = json['board_id']?.toString();
    if (boardId == null || boardId.isEmpty) return null; // skip: no identity
    final rawTypes = json['types'];
    final types = <String, BoardTypeResume>{};
    if (rawTypes is Map<String, dynamic>) {
      rawTypes.forEach((k, v) {
        final parsed = BoardTypeResume.tryParse(v);
        if (parsed != null) types[k] = parsed;
      });
    }
    return BoardResumeEntry(
      boardId: boardId,
      boardSlug: json['board_slug'] as String?,
      types: types,
    );
  }
}

/// The whole `board_resume` metadata block.
class BoardResume {
  final List<BoardResumeEntry> entries;

  const BoardResume({required this.entries});

  BoardResumeEntry? entryFor(String boardId) {
    for (final e in entries) {
      if (e.boardId == boardId) return e;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  /// Tolerant whole-block read: non-map / malformed → entries skipped or
  /// empty block — never an exception (D-26 spirit).
  static BoardResume tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return const BoardResume(entries: []);
    final raw = json['entries'];
    final entries = <BoardResumeEntry>[];
    if (raw is List<dynamic>) {
      for (final item in raw) {
        final parsed = BoardResumeEntry.tryParse(item);
        if (parsed != null) entries.add(parsed);
      }
    }
    return BoardResume(entries: entries);
  }
}
