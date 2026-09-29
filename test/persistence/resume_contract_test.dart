import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/pin_item.dart';
import 'package:pindl/data/models/user_pins_result.dart';

import '../helpers/fixture_loader.dart';

/// Phase 04 — persistence & resume contract (D-04 as code).
///
/// Gates:
///   G1: v1 files load unmodified (fixture-proven)
///   G2: last_index_downloaded = maxContiguous semantics implemented + asserted
///   G3: failed/cancelled items re-offered on continue (test-proven)
///   G4: no v2 write without `schema`; future/corrupt input takes the safe path
void main() {
  Author author() => const Author(username: 'fixtureuser', name: 'Fixture', userId: '111');

  List<PinItem> pins(int n) => List.generate(
        n,
        (i) => PinItem.fromUserPinJson({
          'id': '${100000000000000000 + i}',
          'title': 'pin $i',
          'images': {'orig': {'url': 'https://i.pinimg.com/originals/p$i.jpg'}},
          'videos': [],
        }),
      );

  group('G1 — v1 files load unmodified (tolerant reader)', () {
    test('v1 fixture: all fields load with current behavior', () {
      final r = MetadataReader.parseAndRead(jsonEncode(Fixtures.v1UserMetadata()));
      expect(r.isOk, isTrue);
      expect(r.schemaVersion, 1);
      expect(r.pins.length, 3);
      expect(r.successDownloaded, 2);
      expect(r.skipDownloaded, 1);
      expect(r.lastIndexDownloaded, 2);
      expect(r.wasInterrupted, isTrue);
      // v1 continue math = counter semantics (documented degradation)
      expect(r.continueStartIndex, 3);
      expect(r.reofferIndices, isEmpty); // v1 cannot know about holes
    });

    test('legacy UserPinsResult reader still agrees on the v1 fixture', () {
      final legacy = UserPinsResult.fromMetadataJson(Fixtures.v1UserMetadata());
      final versioned = MetadataReader.read(Fixtures.v1UserMetadata());
      expect(versioned.lastIndexDownloaded, legacy.lastIndexDownloaded);
      expect(versioned.successDownloaded, legacy.successDownloaded);
      expect(versioned.wasInterrupted, legacy.wasInterrupted);
    });
  });

  group('G4 — v2 writes always carry the schema field', () {
    test('buildV2Metadata emits schema: 2 + completion set + derived index', () {
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(4),
        completedIndices: {0, 1, 3},
        totalImages: 4,
        totalVideos: 0,
        successDownloaded: 3,
        skipDownloaded: 0,
        failedDownloaded: 1,
        wasInterrupted: false,
        mediaType: 'image',
      );
      expect(json['schema'], 2);
      expect(json['completed_indices'], [0, 1, 3]);
      expect(json['last_index_downloaded'], 1); // maxContiguous({0,1,3})
      final r = MetadataReader.read(json);
      expect(r.isOk, isTrue);
      expect(r.schemaVersion, 2);
      expect(r.lastIndexDownloaded, 1);
    });
  });

  group('G2 — maxContiguous semantics (out-of-order 3-worker goldens)', () {
    test('out-of-order completion: all done -> counter == maxContiguous', () {
      // 3 workers finish 0,2,3 then 1 (all complete)
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(4),
        completedIndices: {0, 2, 3, 1},
        totalImages: 4,
        totalVideos: 0,
        successDownloaded: 4,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      final r = MetadataReader.read(json);
      expect(r.lastIndexDownloaded, 3);
      expect(r.continueStartIndex, 4); // identical to v1 behavior when no holes
      expect(r.reofferIndices, isEmpty);
    });

    test('hole at index 2 (failed): maxContiguous stops at 1, 2 is re-offered', () {
      // 0 success, 1 skip, 2 FAILED, 3 success (out of order)
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(4),
        completedIndices: {0, 1, 3},
        totalImages: 4,
        totalVideos: 0,
        successDownloaded: 2,
        skipDownloaded: 1,
        failedDownloaded: 1,
        wasInterrupted: false,
      );
      final r = MetadataReader.read(json);
      expect(r.lastIndexDownloaded, 1); // NOT 3 (v1 counter would say 3)
      expect(r.continueStartIndex, 2); // G3: continue re-offers index 2
      expect(r.reofferIndices, {3}); // 3 done but beyond the hole
    });

    test('hole-then-fill: refilling the hole extends maxContiguous', () {
      // Session 1: {0,1,3} (2 failed) -> mc=1. Session 2 fills 2, adds 4.
      final s1 = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(5),
        completedIndices: {0, 1, 3},
        totalImages: 5,
        totalVideos: 0,
        successDownloaded: 2,
        skipDownloaded: 0,
        failedDownloaded: 1,
        wasInterrupted: false,
      );
      final r1 = MetadataReader.read(s1);
      expect(r1.lastIndexDownloaded, 1);

      final merged = {0, 1, 3, 2, 4}; // hole filled + new item done
      final s2 = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(5),
        completedIndices: merged,
        totalImages: 5,
        totalVideos: 0,
        successDownloaded: 4,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      final r2 = MetadataReader.read(s2);
      expect(r2.lastIndexDownloaded, 4);
      expect(r2.continueStartIndex, 5);
      expect(r2.reofferIndices, isEmpty);
    });

    test('all-failed tail: maxContiguous at last success', () {
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(7),
        completedIndices: {0, 1, 2, 5, 6},
        totalImages: 7,
        totalVideos: 0,
        successDownloaded: 5,
        skipDownloaded: 0,
        failedDownloaded: 2,
        wasInterrupted: true,
      );
      final r = MetadataReader.read(json);
      expect(r.lastIndexDownloaded, 2);
      expect(r.continueStartIndex, 3); // 3 and 4 re-offered
      expect(r.reofferIndices, {5, 6});
    });

    test('media-type switch: session set replaces (indices refer to different lists)', () {
      // Previous image-session set {0,1}; new video session starts from 0 —
      // the previous set is NOT merged into the new session's indices.
      // Simulated here at the contract level: the merged set passed to the
      // writer contains ONLY the current-type session completions.
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(3),
        completedIndices: {0}, // video session completed only its own index 0
        totalImages: 3,
        totalVideos: 3,
        successDownloaded: 1,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: 'video',
      );
      final r = MetadataReader.read(json);
      expect(r.mediaType, 'video');
      expect(r.completedIndices, {0});
      expect(r.continueStartIndex, 1);
    });
  });

  group('G3 — continue re-offers holes, never re-offers ≤ maxContiguous', () {
    test('reofferIndices is exactly the completed indices beyond the hole', () {
      final r = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(6),
        completedIndices: {0, 1, 2, 4},
        totalImages: 6,
        totalVideos: 0,
        successDownloaded: 4,
        skipDownloaded: 0,
        failedDownloaded: 1,
        wasInterrupted: false,
      );
      final read = MetadataReader.read(r);
      expect(read.continueStartIndex, 3); // item 3 (failed) re-offered first
      expect(read.reofferIndices, {4}); // done, but past the hole
      // Items ≤ maxContiguous (0,1,2) are NOT re-offered:
      expect(read.reofferIndices.any((i) => i <= 2), isFalse);
    });

    test('cancelled tail (interrupted session) is re-offered', () {
      final json = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(4),
        completedIndices: {0, 1},
        totalImages: 4,
        totalVideos: 0,
        successDownloaded: 2,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: true, // cancelled mid-session: 2,3 never completed
      );
      final r = MetadataReader.read(json);
      expect(r.continueStartIndex, 2);
      expect(r.reofferIndices, isEmpty); // 2,3 not in the set at all (never done)
    });
  });

  group('G4 — corruption / future-schema safe paths (04.4)', () {
    test('truncated JSON → corrupt (safe restart, no partial read)', () {
      final full = MetadataReader.buildV2Metadata(
        author: author(),
        pins: pins(2),
        completedIndices: {0},
        totalImages: 2,
        totalVideos: 0,
        successDownloaded: 1,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      final raw = jsonEncode(full);
      final r = MetadataReader.parseAndRead(raw.substring(0, raw.length ~/ 2));
      expect(r.isCorrupt, isTrue);
      expect(r.isOk, isFalse);
    });

    test('invalid JSON / non-object root → corrupt', () {
      expect(MetadataReader.parseAndRead('not json at all').isCorrupt, isTrue);
      expect(MetadataReader.parseAndRead('[1,2,3]').isCorrupt, isTrue);
      expect(MetadataReader.parseAndRead('"a string"').isCorrupt, isTrue);
      expect(MetadataReader.parseAndRead('').isCorrupt, isTrue);
    });

    test('future schema → futureSchema outcome, never silent reinterpretation', () {
      final r = MetadataReader.parseAndRead('{"schema": 3, "pins": []}');
      expect(r.isFutureSchema, isTrue);
      expect(r.schemaVersion, 3);
      expect(r.pins, isEmpty);
    });

    test('non-int schema value → corrupt (fail-closed)', () {
      expect(MetadataReader.parseAndRead('{"schema": "2"}').isCorrupt, isTrue);
    });

    test('v2 file without completed_indices → empty set (nothing provably complete)', () {
      final r = MetadataReader.parseAndRead(
          '{"schema": 2, "last_index_downloaded": 4, "success_downloaded": 5}');
      expect(r.isOk, isTrue);
      expect(r.schemaVersion, 2);
      expect(r.completedIndices, isEmpty);
      expect(r.lastIndexDownloaded, 4); // file's own value preserved
    });
  });
}
