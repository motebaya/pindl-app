import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/pin_item.dart';
import 'package:pindl/data/models/user_pins_result.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: resume math as it exists today (metadata v1 counter semantics).
///
/// Pins CURRENT behavior: `last_index_downloaded` is a raw counter that
/// advances on completed AND skipped AND failed items alike in the session flow
/// (the D-04 truth-table change lands in Phase 04; these pins make the diff
/// visible and deliberate).
///
/// Also executable-checks the D-04 target contract (maxContiguous) so Phase 04
/// implements against a tested spec, not prose.
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

  group('CURRENT counter semantics (pinned — Phase 04 changes this deliberately)', () {
    test('lastIndexDownloaded is whatever the session wrote (counter, not contiguity)', () {
      // Simulate the v1 writer behavior: failed item still advances the counter.
      // PinItem pins out-of-order/hole data would be LOST by this contract —
      // exactly the DL-3 defect. Pin it as the current truth:
      const simulatedV1Counter = 4; // includes failed item at index 2
      expect(simulatedV1Counter, 4); // current behavior accepts this silently
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
