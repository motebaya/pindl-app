import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/exceptions/pinterest_exception.dart';
import 'package:pindl/core/network/retry.dart';

import '../helpers/fake_clock.dart';

/// Phase 03 — retry util (D-03 canonical model, correction C-4 applied).
/// Deterministic: durations are captured via [capturedDelays], not slept;
/// Random is fixed to 0.5 → exact nominal windows (0.8–1.2 s / 1.6–2.4 s
/// collapse to 1.0 s / 2.0 s).
void main() {
  group('D-03 arithmetic (integration against the real util)', () {
    test('3 TOTAL attempts: attempt 1 immediate, backoffs 1s and 2s', () async {
      final delays = <Duration>[];
      var attempts = 0;
      final sw = Stopwatch()..start();

      await retry<int>(
        () {
          attempts++;
          if (attempts < 3) throw _dio(500);
          return Future.value(attempts);
        },
        delay: (d) async => delays.add(d),
        random: _FixedRandom(0.5),
        onLog: (_) {},
      );

      expect(attempts, 3); // 3 TOTAL (not 3 retries)
      expect(delays.length, 2); // exactly two backoffs
      expect(delays[0].inMilliseconds, FakeClock.backoff1Base.inMilliseconds);
      expect(delays[1].inMilliseconds, FakeClock.backoff2Base.inMilliseconds);
      final worst = FakeClock.backoff1Max + FakeClock.backoff2Max;
      expect(worst, const Duration(milliseconds: 3600)); // C-4: not ~7 s
      sw.stop(); // no real sleeping happened
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('404 fails immediately — no retries, no backoff', () async {
      final delays = <Duration>[];
      var attempts = 0;

      await expectLater(
        retry<int>(
          () {
            attempts++;
            throw _dio(404);
          },
          delay: (d) async => delays.add(d),
          random: _FixedRandom(0.5),
        ),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
      expect(delays, isEmpty);
    });

    test('429 → capped long-backoff (maxBackoff), then success', () async {
      final delays = <Duration>[];
      var attempts = 0;

      final result = await retry<String>(
        () {
          attempts++;
          if (attempts == 1) throw _dio(429);
          return Future.value('ok');
        },
        maxBackoff: const Duration(seconds: 10),
        delay: (d) async => delays.add(d),
        random: _FixedRandom(0.5),
        onLog: (_) {},
      );

      expect(result, 'ok');
      expect(attempts, 2);
      expect(delays.single, const Duration(seconds: 10)); // capped, not 1s
    });

    test('cancel mid-backoff aborts instantly (no further attempts)', () async {
      final token = CancelToken();
      final delays = <Duration>[];
      var attempts = 0;

      final run = retry<int>(
        () {
          attempts++;
          throw _dio(500);
        },
        cancelToken: token,
        delay: (d) async {
          delays.add(d);
          token.cancel('user cancelled'); // cancel DURING backoff
          await Future<void>.delayed(const Duration(milliseconds: 5));
        },
        random: _FixedRandom(0.5),
        onLog: (_) {},
      );

      await expectLater(run, throwsA(isA<CancelledException>()));
      expect(attempts, 1); // never reached attempt 2
      expect(delays.length, 1);
    });

    test('cancel (DioException.cancel) is never retried', () async {
      final delays = <Duration>[];
      var attempts = 0;

      await expectLater(
        retry<int>(
          () {
            attempts++;
            throw _dioCancel();
          },
          delay: (d) async => delays.add(d),
        ),
        throwsA(isA<DioException>()),
      );
      expect(attempts, 1);
      expect(delays, isEmpty);
    });

    test('5xx timeouts classify retryable, 4xx (except 429) do not', () async {
      final retryable = [_dio(500), _dio(503), _dioTimeout()];
      for (final e in retryable) {
        var attempts = 0;
        await retry<void>(
          () {
            attempts++;
            throw e;
          },
          attempts: 2,
          delay: (_) async {},
          random: _FixedRandom(0.5),
          onLog: (_) {},
        ).then((_) {}, onError: (_) {});
        expect(attempts, 2, reason: '${e.response?.statusCode} should retry');
      }

      var attempts401 = 0;
      await retry<void>(
        () {
          attempts401++;
          throw _dio(401);
        },
        delay: (_) async {},
      ).catchError((_) {});
      expect(attempts401, 1); // non-retryable
    });

    test('jitter bounds: windows stay within D-03 min/max over 200 draws', () {
      for (var i = 0; i < 200; i++) {
        final b1 = computeBackoff(
          attempt: 1,
          baseDelay: const Duration(seconds: 1),
          jitterFraction: 0.2,
          maxBackoff: const Duration(seconds: 10),
          rateLimited: false,
          rng: Random(),
        );
        expect(b1.inMilliseconds, inInclusiveRange(800, 1200));
        final b2 = computeBackoff(
          attempt: 2,
          baseDelay: const Duration(seconds: 1),
          jitterFraction: 0.2,
          maxBackoff: const Duration(seconds: 10),
          rateLimited: false,
          rng: Random(),
        );
        expect(b2.inMilliseconds, inInclusiveRange(1600, 2400));
      }
    });
  });
}

DioException _dio(int code) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: code,
      ),
    );

DioException _dioCancel() => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.cancel,
    );

DioException _dioTimeout() => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.connectionTimeout,
    );


class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  bool nextBool() => _value >= 0.5;

  @override
  int nextInt(int max) => (max * _value).floor();

  @override
  double nextDouble() => _value;
}
