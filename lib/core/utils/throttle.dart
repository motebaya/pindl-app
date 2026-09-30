import 'dart:async';

/// Phase 12.2 (PERF-4): rate-limits notification updates to [interval].
///
/// Leading-edge + trailing-edge semantics — the plan's two requirements:
/// - leading: the first call fires immediately (progress bar appears at once);
/// - trailing: the LAST call always fires after [interval] (final state is
///   never lost — the bar never sticks at 99%).
/// Calls inside the window are dropped (that's the throttle), except the
/// newest one, which is parked for the trailing delivery.
///
/// [cancel] drops a pending trailing call without firing (cancel/completion
/// path — no post-completion update may appear).
class Throttler {
  final Duration interval;
  Timer? _timer;
  bool _ready = true;

  Throttler(this.interval);

  /// Returns true when the call is delivered now (leading or trailing edge),
  /// false when it was swallowed by the window.
  bool call(void Function() action) {
    if (_ready) {
      _ready = false;
      _timer = Timer(interval, () {
        final pending = _pending;
        _pending = null;
        if (pending != null) {
          // Trailing delivery; window restarts.
          pending();
        } else {
          _ready = true;
        }
      });
      action();
      return true;
    }
    _pending = action;
    return false;
  }

  void Function()? _pending;

  /// Drop any pending trailing call (cancel/completion path).
  void cancel() {
    _pending = null;
  }

  /// Test/diagnostic hook.
  bool get hasPending => _pending != null;

  void dispose() {
    _timer?.cancel();
    _pending = null;
  }
}
