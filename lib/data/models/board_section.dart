import 'package:equatable/equatable.dart';

/// Board section — Phase 09.2 dumb model (P3). Identity mirrors the
/// [Board] split (**LABELED DESIGN DECISION**, not an observed Pinterest
/// contract): [sectionId] is the canonical request key (probe-validated:
/// `BoardSectionPinsResource` options carry `section_id`); [slug] is the
/// display/path identity from the row's own `slug` field.
///
/// Tolerant reader per the D-26 spirit: odd/missing fields degrade, rows
/// without an id produce null (callers skip).
class BoardSection extends Equatable {
  /// Canonical identity (numeric id as string).
  final String sectionId;

  /// Display/path identity from the listing row.
  final String slug;

  /// Section display title.
  final String title;

  /// Parent board id (probe rows carry a `board` object; kept for
  /// board-scoped resume keying in 09.5).
  final String? boardId;

  /// Public pin count as reported by the row (display hint).
  final int pinCount;

  /// Section description, if any.
  final String? description;

  const BoardSection({
    required this.sectionId,
    required this.slug,
    required this.title,
    this.boardId,
    this.pinCount = 0,
    this.description,
  });

  /// Parse a `BoardSectionsResource` listing row (probe-validated shape:
  /// id, slug, title, pin_count, description, board{id,…}, …).
  static BoardSection? fromListingRow(Map<String, dynamic> json) {
    final sectionId = json['id']?.toString();
    if (sectionId == null || sectionId.isEmpty) return null;
    final board = json['board'] as Map<String, dynamic>?;
    return BoardSection(
      sectionId: sectionId,
      slug: json['slug'] as String? ?? '',
      title: json['title'] as String? ?? '',
      boardId: board?['id']?.toString(),
      pinCount: _intOf(json['pin_count']),
      description: json['description'] as String?,
    );
  }

  /// Tolerant int read: num as-is, numeric strings parsed, else 0.
  static int _intOf(Object? v) =>
      v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

  /// v2-additive serialization (boardId travels for 09.5 keying).
  Map<String, dynamic> toJson() => {
        'sectionId': sectionId,
        'slug': slug,
        'title': title,
        if (boardId != null) 'boardId': boardId,
        'pinCount': pinCount,
        if (description != null) 'description': description,
      };

  factory BoardSection.fromJson(Map<String, dynamic> json) => BoardSection(
        sectionId: json['sectionId']?.toString() ?? '',
        slug: json['slug'] as String? ?? '',
        title: json['title'] as String? ?? '',
        boardId: json['boardId']?.toString(),
        pinCount: _intOf(json['pinCount']),
        description: json['description'] as String?,
      );

  BoardSection copyWith({
    String? sectionId,
    String? slug,
    String? title,
    String? boardId,
    int? pinCount,
    String? description,
  }) =>
      BoardSection(
        sectionId: sectionId ?? this.sectionId,
        slug: slug ?? this.slug,
        title: title ?? this.title,
        boardId: boardId ?? this.boardId,
        pinCount: pinCount ?? this.pinCount,
        description: description ?? this.description,
      );

  @override
  List<Object?> get props =>
      [sectionId, slug, title, boardId, pinCount, description];

  @override
  String toString() =>
      'BoardSection($sectionId, /$slug/, "$title", pins: $pinCount)';
}
