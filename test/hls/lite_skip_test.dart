import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/models/author.dart';

/// Phase 05.5 — Lite honesty for HLS-only items (HLS-4, gate G5).
///
/// The lite flavor now SKIPS HLS items upfront with the explicit reason
/// "HLS video — requires FFmpeg build" (instead of the old guaranteed-failure
/// fallback fetch). Explicit skip = COMPLETE per the D-04 truth
/// table, so the skipped HLS indices enter the completion set and are NOT
/// re-offered on continue (re-downloading them in lite would just re-skip).
///
/// The skip branch lives in job_provider (flavor-conditional); its resume
/// semantics are contract-tested here against the real schema module.
void main() {
  group('G5 — lite HLS skip: resume semantics of skipped-unsupported', () {
    test('skipped HLS indices are complete — continue does not re-offer them', () {
      // Session (lite): items 0,1 success; item 2 is HLS -> skipped with
      // reason; item 3 success. All four enter the completion set.
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: const [],
        completedIndices: {0, 1, 2, 3},
        totalImages: 0,
        totalVideos: 4,
        successDownloaded: 3,
        skipDownloaded: 1, // the honest skip lands in skip_downloaded
        failedDownloaded: 0, // NOT inflated by the old fake failure
        wasInterrupted: false,
        mediaType: 'video',
      );
      final r = MetadataReader.read(json);
      expect(r.lastIndexDownloaded, 3);
      expect(r.continueStartIndex, 4);
      expect(r.reofferIndices, isEmpty); // skip = complete: never re-offered
      expect(r.failedDownloaded, 0);
      expect(r.skipDownloaded, 1);
    });

    test('failedCount is NOT inflated by skipped HLS items (honesty contract)', () {
      // The old behavior manufactured a failure per HLS item; the new one
      // emits skip-with-reason. Counter split pinned:
      //   old: failed_downloaded += n_hls (dishonest)
      //   new: skip_downloaded += n_hls, reason "requires FFmpeg build"
      const hlsSkipped = 3;
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: const [],
        completedIndices: {0, 1, 2},
        totalImages: 0,
        totalVideos: 3,
        successDownloaded: 0,
        skipDownloaded: hlsSkipped,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: 'video',
      );
      final r = MetadataReader.read(json);
      expect(r.skipDownloaded, 3);
      expect(r.failedDownloaded, 0);
    });
  });
}
