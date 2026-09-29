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

    final lastIndex = json['last_index_downloaded'] as int? ?? -1;

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
      'saved_at': DateTime.now().toIso8601String(),
    };
  }
}
