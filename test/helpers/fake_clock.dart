/// Deterministic clock for timing tests (retry backoff matrices — Phase 03
/// implements against this contract; Phase 02 pins the expected semantics).
///
/// The Phase 00 canonical retry model (D-03):
///   3 total attempts; backoff before attempt 2 = 1s x 2^0 ±20% (0.8-1.2s),
///   before attempt 3 = 1s x 2^1 ±20% (1.6-2.4s); cancel aborts instantly.
class FakeClock {
  DateTime _now;
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 1, 1);

  DateTime get now => _now;

  /// Elapsed since [since], as a Duration.
  Duration elapsedSince(DateTime since) => _now.difference(since);

  /// Records that a delay of [d] was "waited" — in real code this would be
  /// injected into the retry util; here it advances the fake timeline.
  void wait(Duration d) => _now = _now.add(d);

  /// The two expected backoff windows from D-03, for assertions.
  static const Duration backoff1Base = Duration(seconds: 1);
  static const Duration backoff2Base = Duration(seconds: 2);
  static const Duration backoff1Min = Duration(milliseconds: 800);
  static const Duration backoff1Max = Duration(milliseconds: 1200);
  static const Duration backoff2Min = Duration(milliseconds: 1600);
  static const Duration backoff2Max = Duration(milliseconds: 2400);
}
