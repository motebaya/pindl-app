import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_clock.dart';

/// Contract tests for bounded retries (Phase 00 canonical model D-03).
///
/// These tests define the REQUIRED Phase 03 behavior:
///   3 TOTAL attempts; backoff before attempt 2 = 1s x2^0 ±20% (0.8–1.2 s),
///   before attempt 3 = 1s x2^1 ±20% (1.6–2.4 s); worst in-flight backoff ≈3.6 s;
///   429 = capped long-backoff; cancellation aborts instantly.
///
/// They assert the arithmetic contract of the model itself today (so the model
/// is executable, not just prose). When Phase 03 lands `core/network/retry.dart`,
/// these become integration assertions against the real util (pins updated
/// deliberately then).
void main() {
  group('D-03 canonical retry arithmetic', () {
    test('backoff windows match the model', () {
      expect(FakeClock.backoff1Base, const Duration(seconds: 1));
      expect(FakeClock.backoff2Base, const Duration(seconds: 2));
      expect(FakeClock.backoff1Min, const Duration(milliseconds: 800));
      expect(FakeClock.backoff1Max, const Duration(milliseconds: 1200));
      expect(FakeClock.backoff2Min, const Duration(milliseconds: 1600));
      expect(FakeClock.backoff2Max, const Duration(milliseconds: 2400));
    });

    test('worst-case in-flight backoff = 1.2s + 2.4s = 3.6s', () {
      final worst = FakeClock.backoff1Max + FakeClock.backoff2Max;
      expect(worst, const Duration(milliseconds: 3600));
      expect(worst.inSeconds, 3); // "~7 s" superseded by D-03/REC-04
    });

    test('attempt schedule: 1 immediate, 2 after first backoff, 3 after second', () {
      final clock = FakeClock();
      final attemptTimes = <DateTime>[];
      final backoffs = [
        FakeClock.backoff1Base, // real impl: ±20% jitter
        FakeClock.backoff2Base,
      ];
      attemptTimes.add(clock.now);
      for (final b in backoffs) {
        clock.wait(b);
        attemptTimes.add(clock.now);
      }
      expect(attemptTimes.length, 3); // 3 TOTAL attempts (not 3 retries)
      expect(attemptTimes[1].difference(attemptTimes[0]), FakeClock.backoff1Base);
      expect(attemptTimes[2].difference(attemptTimes[1]), FakeClock.backoff2Base);
    });

    test('jitter bounds contain the nominal backoff', () {
      // nominal 1s must lie within [0.8s, 1.2s]; nominal 2s within [1.6s, 2.4s]
      expect(
        FakeClock.backoff1Base >= FakeClock.backoff1Min &&
            FakeClock.backoff1Base <= FakeClock.backoff1Max,
        isTrue,
      );
      expect(
        FakeClock.backoff2Base >= FakeClock.backoff2Min &&
            FakeClock.backoff2Base <= FakeClock.backoff2Max,
        isTrue,
      );
    });
  });

  group('retryable classification contract (Phase 03 input)', () {
    test('documented matrix holds', () {
      const retryable = {'connectionTimeout', 'sendTimeout', 'receiveTimeout', 'badResponse:429', 'badResponse:500', 'badResponse:503', 'connectionError'};
      const nonRetryable = {'badResponse:400', 'badResponse:404', 'cancel', 'badCertificate'};
      for (final r in retryable) {
        expect(isRetryableContract(r), isTrue, reason: '$r should be retryable');
      }
      for (final n in nonRetryable) {
        expect(isRetryableContract(n), isFalse, reason: '$n must not be retried');
      }
    });
  });
}

/// The classification contract Phase 03 must implement (4xx except 429 is
/// non-retryable; cancel never retried; 429/5xx/network retried).
bool isRetryableContract(String kind) {
  if (kind == 'cancel') return false;
  if (kind == 'badCertificate') return false;
  final codeMatch = RegExp(r'badResponse:(\d+)').firstMatch(kind);
  if (codeMatch != null) {
    final code = int.parse(codeMatch.group(1)!);
    return code == 429 || code >= 500;
  }
  return true; // timeouts / connection errors
}
