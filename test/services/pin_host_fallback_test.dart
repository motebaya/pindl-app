import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/exceptions/pinterest_exception.dart';
import 'package:pindl/data/services/log_service.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';

/// 3.1.1 — bounded retry plan across pin hosts for single-pin extraction.
///
/// Live evidence (reports/3.1.1-device-bugfix.md): the SSR relay payload is
/// NOT served on every response. Six identical requests to
/// `https://id.pinterest.com/pin/617837642695441979/` returned 2, 2, 2, 2, 0, 0
/// relay invocations, so a single attempt reported `E_NO_DATA` for a public,
/// extractable pin roughly a third of the time (the user's report). The
/// extractor now walks a bounded plan: the given URL plus each known pin host,
/// repeated twice. Contract pinned here:
///   * payload on the primary host -> one request, no retry;
///   * payload only on the alternate host -> recovered, the retry is logged;
///   * payload missing then present -> recovered on the retry round;
///   * payload on neither after the whole plan -> E_NO_DATA naming the hosts;
///   * a PinNotFound record short-circuits (never "no payload").
///
/// Fully offline: scripted Dio adapter, no sockets.
void main() {
  const pinId = '3025924747245513';
  const pinUrl = 'https://id.pinterest.com/pin/$pinId/';

  /// A page with the relay FUNCTION DEFINITION only — the live shape of a page
  /// that carries no payload (this is exactly why the regex finds nothing).
  const noPayload = '<html><head><script>'
      'window.__PWS_RELAY_REGISTER_PENDING_REQUEST__=function(t){return t};'
      'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__=function(t,n){return n};'
      '</script></head><body></body></html>';

  /// A page with a real relay invocation carrying an image.
  String withImage(String url) => '<html><body><script>'
      'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k:1", '
      '{"data":{"pin_closeup":{"data":{"entityId":"$pinId",'
      '"title":"Fallback Pin",'
      '"imageLargeUrl":"$url",'
      '"pinner":{"username":"pinner","entityId":"42"}}}}})'
      '</script></body></html>';

  const notFound = '<html><body><script>'
      'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k:1", '
      '{"data":{"pin_closeup":{"data":{"error":{"code":"PIN_NOT_FOUND",'
      '"message":"Pin not found"}}}}})'
      '</script></body></html>';

  test('payload on the primary host: no fallback request', () async {
    final adapter = _PinHostAdapter({
      'id.pinterest.com': withImage('https://i.pinimg.com/originals/aa/bb/cc/x.jpg'),
    });
    final service = PinterestExtractorService(dio: Dio()..httpClientAdapter = adapter);

    final result = await service.getPinMedia(pinIdOrUrl: pinUrl);

    expect(result.imageUrl, contains('/originals/'));
    expect(adapter.requested, ['id.pinterest.com']);
  });

  test('no payload on the primary host: www fallback recovers the pin',
      () async {
    final adapter = _PinHostAdapter({
      'id.pinterest.com': noPayload,
      'www.pinterest.com': withImage('https://i.pinimg.com/originals/dd/ee/ff/y.jpg'),
    });
    final logService = LogService();
    final service = PinterestExtractorService(
      dio: Dio()..httpClientAdapter = adapter,
      logService: logService,
    );

    final result = await service.getPinMedia(pinIdOrUrl: pinUrl);

    expect(result.imageUrl, contains('/originals/'));
    expect(adapter.requested, ['id.pinterest.com', 'www.pinterest.com']);
    expect(
      logService.entries.map((e) => e.message).any((m) => m.contains('relay payload recovered')),
      isTrue,
    );
    logService.dispose();
  });

  test('no payload on either host: E_NO_DATA naming both hosts', () async {
    final adapter = _PinHostAdapter({
      'id.pinterest.com': noPayload,
      'www.pinterest.com': noPayload,
    });
    final service = PinterestExtractorService(dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      service.getPinMedia(pinIdOrUrl: pinUrl),
      throwsA(isA<SourceChangedException>()
          .having((e) => e.code, 'code', 'E_NO_DATA')
          .having((e) => e.message, 'message',
              allOf(contains('id.pinterest.com'), contains('www.pinterest.com')))),
    );
    // The whole bounded plan, then give up (2 rounds over 2 hosts).
    expect(adapter.requested, hasLength(PinterestExtractorService.maxRelayAttempts * 2));
  });

  test('payload missing on the first round, present on the retry: recovered',
      () async {
    // The live flakiness: the same URL answered with and without a payload.
    final adapter = _PinHostAdapter(
      {
        'id.pinterest.com': noPayload,
        'www.pinterest.com': noPayload,
      },
      // The SECOND request to that host serves the real page (the
      // payload-carrying backend variant), exactly like the live capture.
      payloadAfter: {'id.pinterest.com': 2},
      payloadBody: withImage('https://i.pinimg.com/originals/aa/bb/cc/retry.jpg'),
    );
    final logService = LogService();
    final service = PinterestExtractorService(
      dio: Dio()..httpClientAdapter = adapter,
      logService: logService,
    );

    final result = await service.getPinMedia(pinIdOrUrl: pinUrl);

    expect(result.imageUrl, contains('retry.jpg'));
    expect(adapter.requested.length, greaterThan(2),
        reason: 'the flaky response must trigger the retry round');
    expect(
      logService.entries.map((e) => e.message).any((m) => m.contains('recovered')),
      isTrue,
    );
  });

  test('a PinNotFound record short-circuits (no fallback request)', () async {
    final adapter = _PinHostAdapter({
      'id.pinterest.com': notFound,
      'www.pinterest.com': withImage('https://i.pinimg.com/originals/aa/bb/cc/x.jpg'),
    });
    final service = PinterestExtractorService(dio: Dio()..httpClientAdapter = adapter);

    await expectLater(
      service.getPinMedia(pinIdOrUrl: pinUrl),
      throwsA(isA<PinNotFoundException>()
          .having((e) => e.code, 'code', 'E_PIN_NOT_FOUND')),
    );
    expect(adapter.requested, ['id.pinterest.com'],
        reason: 'a deleted pin must not trigger a second host fetch');
  });

  test('getPinVideo/getPinImage share the fallback path', () async {
    final adapter = _PinHostAdapter({
      'id.pinterest.com': noPayload,
      'www.pinterest.com': '<html><body><script>'
          'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__("k:1", '
          '{"data":{"pin_closeup":{"data":{"entityId":"$pinId",'
          '"imageLargeUrl":"https://i.pinimg.com/originals/aa/bb/cc/x.jpg",'
          '"storyPinData":{"pages":[{"blocks":[{"videoDataV2":'
          '{"videoList720P":{"v720P":{"url":"https://v1.pinimg.com/videos/iht/expMp4/aa/bb/cc/x_720w.mp4"}}}}]}]},'
          '"pinner":{"username":"p","entityId":"42"}}}}})'
          '</script></body></html>',
    });
    final service = PinterestExtractorService(dio: Dio()..httpClientAdapter = adapter);

    final video = await service.getPinVideo(pinIdOrUrl: pinUrl);
    expect(video.videoUrl, endsWith('_720w.mp4'));
    expect(video.videoIsHls, isFalse);
  });
}

/// Serves one canned body per host (anything else -> 404-shaped empty body).
/// [payloadAfter] simulates the live flakiness: from that host's Nth request
/// onward, [payloadBody] is served instead of the payload-less page.
class _PinHostAdapter implements HttpClientAdapter {
  _PinHostAdapter(
    this.pagesByHost, {
    this.payloadAfter = const {},
    this.payloadBody,
  });

  final Map<String, String> pagesByHost;
  final Map<String, int> payloadAfter;
  final String? payloadBody;
  final List<String> requested = [];
  final Map<String, int> _hits = {};

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final host = options.uri.host;
    requested.add(host);
    final hits = (_hits[host] ?? 0) + 1;
    _hits[host] = hits;
    final threshold = payloadAfter[host];
    final body = (threshold != null && hits >= threshold && payloadBody != null)
        ? payloadBody
        : pagesByHost[host];
    if (body == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}

