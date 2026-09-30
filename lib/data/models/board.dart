import 'package:equatable/equatable.dart';

/// Board identity split — Phase 09 G5 **LABELED DESIGN DECISION**, not an
/// observed Pinterest contract: [boardId] (the numeric row `id`) is the
/// canonical identity ALL board-scoped resource requests are keyed by
/// (probe-validated: request options carry `board_id`/`section_id`, never
/// slugs); [slug] is the display/path identity parsed from the row `url`
/// (`/<user>/<slug>/`) — user-editable and collision-prone, so never used
/// as a request key. Upgrading either half to an observed contract requires
/// a decision record with evidence attached.
///
/// Dumb model per P3; tolerant reader per the D-26 spirit (missing/odd
/// fields degrade to nulls/empties, never throw).
class Board extends Equatable {
  /// Canonical identity (numeric id as string).
  final String boardId;

  /// Display/path identity, parsed from the row `url` (`/<user>/<slug>/`).
  final String slug;

  /// Board display name.
  final String name;

  /// Public pin count as reported by the listing row (display hint).
  final int pinCount;

  /// Section count as reported by the listing row (display hint).
  final int sectionCount;

  /// Cover image URL (largest variant the row carries), if any.
  final String? coverImageUrl;

  /// Board description, if any.
  final String? description;

  const Board({
    required this.boardId,
    required this.slug,
    required this.name,
    this.pinCount = 0,
    this.sectionCount = 0,
    this.coverImageUrl,
    this.description,
  });

  /// Parse a `BoardsResource` listing row (probe-validated shape: id, url,
  /// name, pin_count, section_count, image_cover_url, …). Tolerant:
  /// missing/`null` fields fall back per-field; rows without ANY identity
  /// (no id) produce null — callers skip them.
  static Board? fromListingRow(Map<String, dynamic> json) {
    final boardId = json['id']?.toString();
    if (boardId == null || boardId.isEmpty) return null;
    return Board(
      boardId: boardId,
      slug: _slugFromUrl(json['url'] as String?) ?? '',
      name: json['name'] as String? ?? '',
      pinCount: _intOf(json['pin_count']),
      sectionCount: _intOf(json['section_count']),
      coverImageUrl: (json['image_cover_hd_url'] as String?) ??
          (json['image_cover_url'] as String?),
      description: json['description'] as String?,
    );
  }

  /// `/<user>/<slug>/` → `slug`. Tolerant: null/odd shapes → null.
  static String? _slugFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final parts = url.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return parts.last;
  }

  /// Tolerant int read: num as-is, numeric strings parsed, else 0.
  static int _intOf(Object? v) =>
      v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

  /// v2-additive serialization for downstream persistence (09.5 resume
  /// keys use boardId; slug travels for display only).
  Map<String, dynamic> toJson() => {
        'boardId': boardId,
        'slug': slug,
        'name': name,
        'pinCount': pinCount,
        'sectionCount': sectionCount,
        if (coverImageUrl != null) 'coverImageUrl': coverImageUrl,
        if (description != null) 'description': description,
      };

  factory Board.fromJson(Map<String, dynamic> json) => Board(
        boardId: json['boardId']?.toString() ?? '',
        slug: json['slug'] as String? ?? '',
        name: json['name'] as String? ?? '',
        pinCount: _intOf(json['pinCount']),
        sectionCount: _intOf(json['sectionCount']),
        coverImageUrl: json['coverImageUrl'] as String?,
        description: json['description'] as String?,
      );

  Board copyWith({
    String? boardId,
    String? slug,
    String? name,
    int? pinCount,
    int? sectionCount,
    String? coverImageUrl,
    String? description,
  }) =>
      Board(
        boardId: boardId ?? this.boardId,
        slug: slug ?? this.slug,
        name: name ?? this.name,
        pinCount: pinCount ?? this.pinCount,
        sectionCount: sectionCount ?? this.sectionCount,
        coverImageUrl: coverImageUrl ?? this.coverImageUrl,
        description: description ?? this.description,
      );

  @override
  List<Object?> get props =>
      [boardId, slug, name, pinCount, sectionCount, coverImageUrl, description];

  @override
  String toString() => 'Board($boardId, /$slug/, "$name", pins: $pinCount)';
}
