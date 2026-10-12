/// Feed/Board carousel migration — re-projection of a STORED completion record
/// onto the item plan the current run will use.
///
/// Why this exists (OQ-13): before this migration a feed/board run emitted
/// exactly ONE item per pin, so a stored `completed_indices` array was a set of
/// PIN-level positions. Carousel expansion makes one pin own several positions,
/// so the same array means something different. Reading a legacy array as if it
/// were expanded (or vice versa) either skips media that was never downloaded
/// (silent loss) or re-downloads work that is already on disk. Neither is
/// acceptable, so the two coordinate spaces are converted explicitly here.
///
/// Rules (decision D-53; plan `planning/feed-carousel-migration.md`, evidence in
/// `reports/3.1.1-carousel-migration-and-versioning.md`):
///
///  * The plan has no multi-item pin → **identity**. A job whose pins carry no
///    slides resumes in its own (pin-level) space, byte-identical to the old
///    behavior — that is the "resume a job created by an older version" case.
///  * `item_plan == 'pin-expanded'` → **identity**. The stored array was
///    written by this version in the expanded space.
///  * Otherwise (legacy array + expanded plan) → each legacy index j is the
///    j-th item of the PRE-MIGRATION plan (one item per pin, rebuilt by
///    [legacyPlanItems] so the mapping cannot drift from history) and is
///    translated to that pin's FIRST expanded item, and ONLY when the two
///    items denote the same image (same Pinterest file name — the rendition
///    token is a resize directive over one hash, live-verified 2026-10-12).
///    A mismatch, an unknown identity, or an out-of-range index is DROPPED, so
///    the item is simply re-offered: possibly one extra download, never a
///    skipped slide.
///
/// Accepted costs (recorded, not hidden): the legacy run saved a carousel pin's
/// primary image as `<pinId>_image.<ext>`, the expanded plan names it
/// `<pinId>_image_1.<ext>` (single-pin carousel naming, D-48), so a resumed
/// carousel pin can re-download that one image once and leave the old file
/// behind. The direction is deliberate: extra work over lost media.
library;

import '../../core/persistence/metadata_schema.dart';
import '../models/job_state.dart';
import '../models/pin_item.dart';
import 'download_coordinator.dart';

/// Outcome of one re-projection.
class StoredCompletionMapping {
  /// Completed item indices in [PlannedDownload] (expanded-plan) coordinates.
  final Set<int> completedIndices;

  /// True when a legacy pin-level record was translated into the expanded
  /// space (false = identity: same coordinates in, same coordinates out).
  final bool translated;

  /// Legacy indices deliberately not carried over (out of range, or the
  /// mapped item could not be proven to be the same image). These items are
  /// re-offered on the next run.
  final int dropped;

  const StoredCompletionMapping({
    required this.completedIndices,
    required this.translated,
    required this.dropped,
  });

  @override
  String toString() => 'StoredCompletionMapping(done: ${completedIndices.length}, '
      'translated: $translated, dropped: $dropped)';
}

/// The PRE-MIGRATION item sequence: one item per pin, in pin order — image mode
/// uses the primary image with the video-thumbnail fallback, video mode uses the
/// video. Byte-identical to `planFeedItems` on a pin list without carousels
/// (parity-pinned by test), which is what makes it a faithful model of the
/// arrays written by 3.1.0/3.1.1.
List<({String pinId, String url})> legacyPlanItems({
  required List<PinItem> pins,
  required MediaType mediaType,
}) {
  final isVideoOnly = mediaType == MediaType.video;
  final items = <({String pinId, String url})>[];
  for (final pin in pins) {
    if (isVideoOnly) {
      final url = pin.videoUrl?.url;
      if (pin.hasVideo && url != null) items.add((pinId: pin.pinId, url: url));
    } else if (pin.hasImage && pin.imageUrl != null) {
      items.add((pinId: pin.pinId, url: pin.imageUrl!));
    } else if (pin.hasVideo && pin.thumbnail != null) {
      items.add((pinId: pin.pinId, url: pin.thumbnail!));
    }
  }
  return items;
}

/// The Pinterest image identity of a URL: its file name. Two URLs that differ
/// only in the rendition token (`736x` vs `originals`) still denote ONE image,
/// so they share an identity. Null when the URL cannot establish one.
String? pinterestImageIdentity(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  final name = segments.last.toLowerCase();
  return name.contains('.') ? name : null;
}

/// Re-project a stored completion record onto [plannedItems].
///
/// [pins] must be the SAME pin sequence the plan was built from (the plan keeps
/// pin order, and carousel slides stay adjacent inside their pin).
StoredCompletionMapping mapStoredCompletionToPlan({
  required List<PlannedDownload> plannedItems,
  required List<PinItem> pins,
  required Set<int> storedCompleted,
  required String? storedItemPlan,
  required MediaType mediaType,
}) {
  final hasMultiItemPin = plannedItems.any((i) => i.slotIndex != null);
  if (!hasMultiItemPin ||
      storedItemPlan == MetadataReader.feedItemPlanExpanded) {
    return StoredCompletionMapping(
      completedIndices: storedCompleted,
      translated: false,
      dropped: 0,
    );
  }

  // First expanded index of each pin (the plan keeps pin order and groups a
  // pin's slides together).
  final firstIndexByPin = <String, int>{};
  for (var i = 0; i < plannedItems.length; i++) {
    firstIndexByPin.putIfAbsent(plannedItems[i].pinId, () => i);
  }

  final legacy = legacyPlanItems(pins: pins, mediaType: mediaType);
  final out = <int>{};
  var dropped = 0;
  for (final legacyIndex in storedCompleted) {
    if (legacyIndex < 0 || legacyIndex >= legacy.length) {
      dropped++;
      continue;
    }
    final legacyItem = legacy[legacyIndex];
    final firstIndex = firstIndexByPin[legacyItem.pinId];
    if (firstIndex == null) {
      // The pin is not in the current plan (media type mismatch / filtered):
      // nothing to carry over.
      dropped++;
      continue;
    }
    final planIdentity = pinterestImageIdentity(plannedItems[firstIndex].url);
    final legacyIdentity = pinterestImageIdentity(legacyItem.url);
    if (planIdentity != null && planIdentity == legacyIdentity) {
      out.add(firstIndex);
    } else {
      dropped++;
    }
  }

  return StoredCompletionMapping(
    completedIndices: out,
    translated: true,
    dropped: dropped,
  );
}
