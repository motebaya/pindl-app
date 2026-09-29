import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';

import '../exceptions/pinterest_exception.dart';

/// Bounded, classified retry with exponential backoff.
///
/// Canonical model — Phase 00 D-03 (correction C-4 applied):
///   * 3 TOTAL attempts (not 3 retries);
///   * backoff before attempt 2 = 1 s × 2^0 ± 20 % (0.8–1.2 s);
///   * backoff before attempt 3 = 1 s × 2^1 ± 20 % (1.6–2.4 s);
///   * worst in-flight backoff ≈ 3.6 s (the superseded "≤ ~7 s" bound was
///     mis-modeled — see planning/extraction/03-retries.md C-4 note);
///   * 429 = capped long-backoff ([maxBackoff], default 10 s) instead of the
///     standard schedule;
///   * cancellation aborts instantly and is NEVER retried;
///   * all wrapped call sites are GETs (retry-safe, CONFIRMED in corpus).
///
/// Dependency-free on purpose (P5: a small util beats a package).
///
/// Deterministic tests: inject [delay] (capture durations instead of waiting)
/// and [random] (fixed value 0.5 yields the exact nominal backoff windows).
Future<T> retry<T>(
  Future<T> Function() fn, {
  int attempts = 3,
  Duration baseDelay = const Duration(seconds: 1),
  double jitterFraction = 0.2,
  Duration maxBackoff = const Duration(seconds: 10),
  bool Function(Object error)? isRetryable,
  void Function(String message)? onLog,
  Random? random,
  Future<void> Function(Duration delay)? delay,
  CancelToken? cancelToken,
}) async {
  final rng = random ?? Random();
  final wait = delay ?? ((d) => _sleep(d, cancelToken));
  final retryable = isRetryable ?? defaultIsRetryable;

  var attempt = 0;
  while (true) {
    attempt++;
    try {
      return await fn();
    } catch (e) {
      // Cancellation always wins — abort instantly, never retried.
      if (_isCancellation(e)) rethrow;
      if (attempt >= attempts || !retryable(e)) rethrow;

      final rateLimited = e is DioException && e.response?.statusCode == 429;
      final backoff = computeBackoff(
        attempt: attempt,
        baseDelay: baseDelay,
        jitterFraction: jitterFraction,
        maxBackoff: maxBackoff,
        rateLimited: rateLimited,
        rng: rng,
      );

      onLog?.call(
        'attempt $attempt/$attempts failed (${_describe(e)}) — '
        'retrying in ${(backoff.inMilliseconds / 1000).toStringAsFixed(1)} s',
      );
      await wait(backoff);
      // Cancellation wins even if a custom [delay] implementation swallowed
      // the cancel signal — never start another attempt after a cancel.
      if (cancelToken?.isCancelled ?? false) throw CancelledException();
    }
  }
}

/// Backoff sleep that aborts instantly when [token] is cancelled
/// (D-03: cancellation always wins — mid-backoff cancel does not wait
/// out the remaining window).
Future<void> _sleep(Duration d, CancelToken? token) async {
  if (token == null) {
    await Future<void>.delayed(d);
    return;
  }
  var settled = false;
  final completer = Completer<void>();
  final timer = Timer(d, () {
    if (!settled) {
      settled = true;
      completer.complete();
    }
  });
  unawaited(token.whenCancel.then((_) {
    if (!settled) {
      settled = true;
      timer.cancel();
      completer.complete();
    }
  }));
  await completer.future;
  if (token.isCancelled) throw CancelledException();
}

/// Backoff before retry attempt [attempt] + 1.
///
/// Standard: baseDelay × 2^(attempt−1) × (1 ± [jitterFraction]).
/// Rate-limited (429): the capped long-backoff [maxBackoff].
Duration computeBackoff({
  required int attempt,
  required Duration baseDelay,
  required double jitterFraction,
  required Duration maxBackoff,
  required bool rateLimited,
  Random? rng,
}) {
  if (rateLimited) return maxBackoff;
  final r = (rng ?? Random()).nextDouble();
  final jitter = 1.0 + (r * 2 - 1) * jitterFraction;
  final factor = pow(2, attempt - 1).toDouble();
  final millis = (baseDelay.inMilliseconds * factor * jitter).round();
  return Duration(milliseconds: min(millis, maxBackoff.inMilliseconds));
}

/// Canonical classification (Phase 02 contract matrix):
/// retryable — connection/send/receive timeouts, connection errors, 429, 5xx;
/// non-retryable — other 4xx, cancellation, bad certificates, everything else.
bool defaultIsRetryable(Object error) {
  if (error is! DioException) return false;
  switch (error.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionError:
      return true;
    case DioExceptionType.badResponse:
      final code = error.response?.statusCode;
      return code == 429 || (code != null && code >= 500);
    default:
      return false; // cancel, badCertificate, unknown
  }
}

bool _isCancellation(Object error) {
  if (error is CancelledException) return true;
  return error is DioException && error.type == DioExceptionType.cancel;
}

String _describe(Object error) {
  if (error is DioException) {
    final code = error.response?.statusCode;
    return code != null ? 'HTTP $code' : (error.type.name);
  }
  return error.runtimeType.toString();
}
