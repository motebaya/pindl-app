/// Canonical resume contract (Phase 04) — Phase 00 D-04/REC-05 as code.
///
/// TRUTH TABLE (extension only via change-control record — contract change):
/// ```text
/// success        = complete
/// explicit skip  = complete
/// failed         = INCOMPLETE → hole → re-offered on continue
/// cancelled      = INCOMPLETE → hole → re-offered on continue
/// last_index_downloaded := maxContiguous(completedSet)
/// continue starts at last_index_downloaded + 1
/// ```
///
/// The metadata file (completion set) is AUTHORITATIVE for resume state;
/// in-memory session state is advisory. Storage layering (PER-4):
/// metadata JSON = resume truth; Hive = ephemeral progress; UI logs elsewhere.
///
/// Schema rules (persistence/01, PER-3):
///   v1 (no `schema` key) → reads with v1 counter semantics (documented
///   degradation, no worse than today);
///   `schema: 2` → completion set + truth table apply;
///   `schema > 2` → [MetadataFutureSchema] outcome — read-only/upgrade
///   prompt, NEVER silent reinterpretation;
///   corrupt/truncated JSON → [MetadataCorrupt] outcome — safe restart,
///   NEVER partial interpretation.
library;

import 'dart:convert';

import '../../data/models/author.dart';
import '../../data/models/pin_item.dart';
import 'board_resume.dart';

/// Request-scoped bookmark provenance (Phase 07 gate 07.4, D-34; design:
/// planning/extraction/08-bookmark-context-design.md).
///
/// A Pinterest bookmark token is meaningful ONLY for the exact request that
/// produced it. A stored bookmark is reusable ONLY when its full context
/// matches the new request — never globally reusable. Any mismatch → no
/// reuse, re-extract from page 1 (fail-safe direction).
class BookmarkContext {
  static const resourceUserPins = 'user_pins';

  /// Phase 09 board resources — same tuple contract, board scope travels
  /// inside `request_options` (`board_id` / `section_id` keys, registry
  /// builders are the single source of these option sets).
  static const resourceBoardPins = 'board_pins';
  static const resourceBoardSectionPins = 'board_section_pins';

  final String username;
  final String resource;
  final Map<String, dynamic> requestOptions;
  final String extractionMode;
  final int maxPages;
  final String bookmark;

  const BookmarkContext({
    required this.username,
    required this.resource,
    required this.requestOptions,
    required this.extractionMode,
    required this.maxPages,
    required this.bookmark,
  });

  /// Canonical JSON string with sorted keys — map ordering must never fake
  /// a match or a mismatch.
  static String _canonicalJson(Map<String, dynamic> map) {
    final sorted = <String, dynamic>{};
    final keys = map.keys.toList()..sort();
    for (final k in keys) {
      final v = map[k];
      sorted[k] = v is Map<String, dynamic> ? _canonicalMap(v) : v;
    }
    return jsonEncode(sorted);
  }

  static Map<String, dynamic> _canonicalMap(Map<String, dynamic> map) {
    final sorted = <String, dynamic>{};
    final keys = map.keys.toList()..sort();
    for (final k in keys) {
      final v = map[k];
      sorted[k] = v is Map<String, dynamic> ? _canonicalMap(v) : v;
    }
    return sorted;
  }

  /// Full-context match against the request being considered. Username is
  /// case-insensitive (session-cache convention); options compared as
  /// canonical JSON.
  bool matches(BookmarkContext fresh) {
    if (resource != fresh.resource) return false;
    if (username.toLowerCase() != fresh.username.toLowerCase()) return false;
    if (extractionMode != fresh.extractionMode) return false;
    if (maxPages != fresh.maxPages) return false;
    if (_canonicalJson(requestOptions) !=
        _canonicalJson(fresh.requestOptions)) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'username': username,
        'resource': resource,
        'request_options': requestOptions,
        'extraction_mode': extractionMode,
        'max_pages': maxPages,
        'bookmarks': [bookmark],
      };

  /// Tolerant reader: anything malformed → null (no reuse), never an
  /// exception (D-26 spirit).
  static BookmarkContext? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final username = json['username'];
    final resource = json['resource'];
    final options = json['request_options'];
    final mode = json['extraction_mode'];
    final maxPages = json['max_pages'];
    final bookmarks = json['bookmarks'];
    if (username is! String ||
        resource is! String ||
        options is! Map<String, dynamic> ||
        mode is! String ||
        maxPages is! int ||
        bookmarks is! List<dynamic> ||
        bookmarks.isEmpty ||
        bookmarks.first is! String) {
      return null;
    }
    return BookmarkContext(
      username: username,
      resource: resource,
      requestOptions: options,
      extractionMode: mode,
      maxPages: maxPages,
      bookmark: bookmarks.first as String,
    );
  }
}

/// Largest N such that every index 0..N is in [s]; -1 when empty.
/// (Executable spec ported from the Phase 02 resume tests.)
int maxContiguous(Set<int> s) {
  var n = -1;
  while (s.contains(n + 1)) {
    n++;
  }
  return n;
}

/// Result of a versioned metadata read.
class MetadataReadResult {
  final int schemaVersion;
  final Author? author;
  final List<PinItem> pins;
  final int totalImages;
  final int totalVideos;
  final int successDownloaded;
  final int skipDownloaded;
  final int failedDownloaded;
  final int lastIndexDownloaded;
  final bool wasInterrupted;
  final String? mediaType;
  final String? savedAt;
  final String? status;

  /// v2 only: explicit completion set. null for v1 (counter semantics).
  final Set<int>? completedIndices;

  /// One of: ok (v1 or v2) / corrupt / futureSchema.
  final MetadataReadOutcome outcome;

  /// The raw decoded JSON map (ok reads only) — callers needing fields the
  /// typed result does not carry (e.g. legacy legacy reader paths) use this.
  final Map<String, dynamic>? jsonMap;

  /// Phase 07 (07.5): capped-extraction continuation, present only when a
  /// run ended at the page cap with a next bookmark. v2-additive.
  final String? nextBookmark;
  final BookmarkContext? bookmarkContext;

  /// Phase 09.5: board-scoped resume block, v2-additive. Present (non-null)
  /// only when the file carries one; user-feed files read as null.
  final BoardResume? boardResume;

  /// Feed/Board carousel migration: the coordinate space `completed_indices`
  /// lives in. [MetadataReader.feedItemPlanExpanded] means "absolute indices
  /// over the EXPANDED item plan (one item per carousel slide)"; null/absent
  /// means the pre-migration pin-level space. The resume path must NOT
  /// interpret one space as the other (see `feed_plan_migration.dart`).
  final String? itemPlan;

  const MetadataReadResult._({
    required this.schemaVersion,
    required this.outcome,
    this.author,
    this.pins = const [],
    this.totalImages = 0,
    this.totalVideos = 0,
    this.successDownloaded = 0,
    this.skipDownloaded = 0,
    this.failedDownloaded = 0,
    this.lastIndexDownloaded = -1,
    this.wasInterrupted = false,
    this.mediaType,
    this.savedAt,
    this.status,
    this.completedIndices,
    this.jsonMap,
    this.nextBookmark,
    this.bookmarkContext,
    this.boardResume,
    this.itemPlan,
  });

  const MetadataReadResult.corrupt()
      : this._(schemaVersion: 0, outcome: MetadataReadOutcome.corrupt);

  const MetadataReadResult.futureSchema(int version)
      : this._(schemaVersion: version, outcome: MetadataReadOutcome.futureSchema);

  bool get isOk => outcome == MetadataReadOutcome.ok;
  bool get isCorrupt => outcome == MetadataReadOutcome.corrupt;
  bool get isFutureSchema => outcome == MetadataReadOutcome.futureSchema;

  /// Continue-mode start index per the contract.
  /// v2: maxContiguous(completedIndices). v1: last_index_downloaded
  /// (counter semantics — documented degradation).
  int get continueStartIndex {
    if (schemaVersion >= 2 && completedIndices != null) {
      return maxContiguous(completedIndices!) + 1;
    }
    return lastIndexDownloaded + 1;
  }

  /// Indices that must be re-offered on continue (the holes):
  /// completed per truth table but not contiguous with 0..maxContiguous.
  /// Empty for v1 (counter semantics cannot know about holes).
  Set<int> get reofferIndices {
    if (schemaVersion >= 2 && completedIndices != null) {
      final mc = maxContiguous(completedIndices!);
      return completedIndices!.where((i) => i > mc).toSet();
    }
    return {};
  }
}

enum MetadataReadOutcome { ok, corrupt, futureSchema }

/// Versioned metadata reader (persistence/01).
///
/// - No `schema` key → v1 path: identical to the legacy
///   `UserPinsResult.fromMetadataJson` defaults (fixture-proven).
/// - `schema: 2` → v2 path: `completed_indices` governs resume math.
/// - `schema > 2` (or non-int schema) → future-schema outcome.
/// - Does NOT parse JSON — the caller decodes and routes parse failures
///   to [corrupt] explicitly (never silent defaults).
class MetadataReader {
  MetadataReader._();

  static const int currentSchemaVersion = 2;

  /// Feed/Board carousel migration: value of the v2-additive `item_plan`
  /// field written by this version. Records without the field are pre-
  /// migration (one item per pin) and are re-projected before compare.
  static const String feedItemPlanExpanded = 'pin-expanded';

  /// Decode-and-read entry point for raw file content (04.4 corruption
  /// handling): truncated/invalid JSON or a non-object root → corrupt
  /// outcome (safe restart), never an exception reaching the caller and
  /// never partial interpretation.
  static MetadataReadResult parseAndRead(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) return corrupt();
      return read(decoded);
    } catch (_) {
      return corrupt();
    }
  }

  static MetadataReadResult read(Map<String, dynamic> json) {
    final schema = json['schema'];
    if (schema != null && schema is! int) {
      return const MetadataReadResult.corrupt();
    }
    if (schema is int && schema > currentSchemaVersion) {
      return MetadataReadResult.futureSchema(schema);
    }

    final version = schema as int? ?? 1;
    final pins = (json['pins'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .map(PinItem.fromJson)
            .toList() ??
        const [];
    final authorJson = json['author'] as Map<String, dynamic>?;

    Set<int>? completed;
    if (version >= 2) {
      final raw = json['completed_indices'];
      if (raw is List<dynamic>) {
        completed = raw.whereType<int>().toSet();
      } else {
        completed = {}; // v2 file without the array: nothing provably complete
      }
    }

    // Phase 07 (07.5): bookmark provenance. The two fields travel together
    // (D-34) — a next_bookmark without a parsable context is IGNORED (the
    // D-24 dead-field lesson), and a context without a token is unusable.
    String? nextBookmark;
    BookmarkContext? bookmarkContext;
    if (version >= 2) {
      final bm = json['next_bookmark'];
      final ctx = BookmarkContext.tryParse(json['bookmark_context']);
      if (bm is String && bm.isNotEmpty && ctx != null) {
        nextBookmark = bm;
        bookmarkContext = ctx;
      }
    }

    // Phase 09.5: board resume block (v2-additive). Malformed → skipped
    // entries / empty block (D-26 spirit); absent → null (user-feed files).
    BoardResume? boardResume;
    if (version >= 2 && json['board_resume'] != null) {
      boardResume = BoardResume.tryParse(json['board_resume']);
    }

    final lastIndex = json['last_index_downloaded'] as int? ?? -1;

    // Feed/Board carousel migration: additive item-plan marker. A non-string
    // or empty value is treated as absent (never as "expanded").
    final itemPlanRaw = json['item_plan'];
    final itemPlan = itemPlanRaw is String && itemPlanRaw.isNotEmpty
        ? itemPlanRaw
        : null;

    // v2 keeps lastIndexDownloaded as the v1-compatible derived field;
    // when absent from the file, derive it from the completion set.
    final effectiveLastIndex =
        version >= 2 ? (json['last_index_downloaded'] as int? ?? maxContiguous(completed!)) : lastIndex;

    return MetadataReadResult._(
      schemaVersion: version,
      outcome: MetadataReadOutcome.ok,
      author: authorJson != null ? Author.fromJson(authorJson) : null,
      pins: pins,
      totalImages: json['totalImages'] as int? ?? 0,
      totalVideos: json['totalVideos'] as int? ?? 0,
      successDownloaded: json['success_downloaded'] as int? ?? 0,
      skipDownloaded: json['skip_downloaded'] as int? ?? 0,
      failedDownloaded: json['failed_downloaded'] as int? ?? 0,
      lastIndexDownloaded: effectiveLastIndex,
      wasInterrupted: json['was_interrupted'] as bool? ?? false,
      mediaType: json['media_type'] as String?,
      savedAt: json['saved_at'] as String?,
      status: json['status'] as String?,
      completedIndices: completed,
      jsonMap: json,
      nextBookmark: nextBookmark,
      bookmarkContext: bookmarkContext,
      boardResume: boardResume,
      itemPlan: itemPlan,
    );
  }

  static MetadataReadResult corrupt() => const MetadataReadResult.corrupt();

  /// Assemble a v2 metadata map from session outcomes.
  ///
  /// [completedIndices] must contain ONLY indices completed per the truth
  /// table (success | explicit skip). The writer asserts the contract.
  static Map<String, dynamic> buildV2Metadata({
    required Author author,
    required List<PinItem> pins,
    required Set<int> completedIndices,
    required int totalImages,
    required int totalVideos,
    required int successDownloaded,
    required int skipDownloaded,
    required int failedDownloaded,
    required bool wasInterrupted,
    String? mediaType,
    String? status,
    String? nextBookmark,
    BookmarkContext? bookmarkContext,
    BoardResume? boardResume,
    String? itemPlan,
  }) {
    return {
      'schema': currentSchemaVersion,
      'author': author.toJson(),
      'pins': pins.map((p) => p.toJson()).toList(),
      'totalImages': totalImages,
      'totalVideos': totalVideos,
      'completed_indices': completedIndices.toList()..sort(),
      'success_downloaded': successDownloaded,
      'skip_downloaded': skipDownloaded,
      'failed_downloaded': failedDownloaded,
      // v1-compatible derived field (old app reads this and behaves today-like)
      'last_index_downloaded': maxContiguous(completedIndices),
      'was_interrupted': wasInterrupted,
      'media_type': ?mediaType,
      'status': ?status,
      // Phase 07 (D-34): the pair travels together or not at all.
      if (nextBookmark != null && bookmarkContext != null) ...{
        'next_bookmark': nextBookmark,
        'bookmark_context': bookmarkContext.toJson(),
      },
      // Phase 09.5: board resume block, v2-additive — absent for user-feed
      // files (backward compatible: readers without board support ignore it).
      if (boardResume != null) 'board_resume': boardResume.toJson(),
      // Feed/Board carousel migration: records the coordinate space of
      // `completed_indices` so a later continue can never mis-read it.
      'item_plan': ?itemPlan,
      'saved_at': DateTime.now().toIso8601String(),
    };
  }
}
