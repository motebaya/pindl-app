import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/pin_item.dart';
import 'package:pindl/data/models/user_pins_result.dart';

import '../helpers/fixture_loader.dart';

/// Resume math — Phase 04 contract now LIVE (was Phase 02 characterization).
///
/// PHASE 04 FLIPS (deliberate, documented in reports/phases/04):
/// - the session writer emits schema v2 (completion set + derived
///   last_index_downloaded = maxContiguous) — the D-04 truth table governs;
/// - v1 FILES still read with raw counter semantics (documented degradation,
///   no worse than before) — asserted executably below instead of the old
///   tautological counter pin;
/// - the maxContiguous executable spec is now implemented in
///   `core/persistence/metadata_schema.dart` and contract-tested there
///   (test/persistence/resume_contract_test.dart); the spec tests here stay
///   as the original source-of-truth record.
void main() {
  group('metadata v1 round-trip (current schema, no version field)', () {
    test('v1 fixture loads into UserPinsResult with resume stats', () {
      final result = UserPinsResult.fromMetadataJson(Fixtures.v1UserMetadata());
      expect(result.pins.length, 3);
      expect(result.successDownloaded, 2);
      expect(result.skipDownloaded, 1);
      expect(result.failedDownloaded, 0);
      expect(result.lastIndexDownloaded, 2);
      expect(result.wasInterrupted, isTrue);
      expect(result.author.username, 'fixtureuser');
    });

    test('missing fields degrade to safe defaults', () {
      final result = UserPinsResult.fromMetadataJson({});
      expect(result.pins, isEmpty);
      expect(result.lastIndexDownloaded, -1);
      expect(result.wasInterrupted, isFalse);
    });
  });

  group('v1 counter semantics (Phase 04 flip: v2 contract live, v1 degraded deliberately)', () {
    test('v1 files keep counter semantics — continue starts at counter + 1', () {
      // v1 limitation preserved verbatim: a counter of 4 that includes a
      // failed item at index 2 means continue starts at 5 — item 2 is NOT
      // re-offered (v1 cannot know about holes; no worse than before).
      // v2 files are hole-aware (see test/persistence/resume_contract_test.dart).
      final r = MetadataReader.parseAndRead(
          jsonEncode({'success_downloaded': 4, 'last_index_downloaded': 4}));
      expect(r.schemaVersion, 1);
      expect(r.continueStartIndex, 5);
      expect(r.reofferIndices, isEmpty);
    });
  });

  group('D-04 target contract: maxContiguous (executable spec for Phase 04)', () {
    test('no holes -> counter == maxContiguous', () {
      expect(maxContiguous({0, 1, 2, 3}), 3);
    });

    test('hole at index 2 -> maxContiguous stops at 1', () {
      expect(maxContiguous({0, 1, 3}), 1); // failed item at 2 -> re-offered
    });

    test('all-failed tail -> maxContiguous at last success', () {
      expect(maxContiguous({0, 1, 2, 5, 6}), 2);
    });

    test('empty set -> -1 (nothing done)', () {
      expect(maxContiguous({}), -1);
    });

    test('failed/cancelled are NOT in the set (truth table)', () {
      // success + explicit skip = complete; failed/cancelled = incomplete.
      final completed = {0, 2}; // 0=success, 1=failed(excluded), 2=skipped
      expect(maxContiguous(completed), 0); // continue re-offers 1, then 2 is already done
    });
  });
}

/// D-04 contract helper: largest N such that every index 0..N is in [s].
/// Phase 04 must implement this in the resume coordinator (from this tested spec).
int maxContiguous(Set<int> s) {
  var n = -1;
  while (s.contains(n + 1)) {
    n++;
  }
  return n;
}

/// Re-export guard: keep Author/PinItem imports meaningfully used in the future
/// hole/continue goldens (Phase 04 extends this file).
// ignore: unused_element
final _ = Author(username: 'x', name: 'x', userId: '1');
// ignore: unused_element
final _pins = <PinItem>[];
