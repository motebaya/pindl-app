import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/services/hls_service.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: HlsService playlist parsing/selection.
/// Pins CURRENT selection: highest resolution (pixels), fallback bandwidth;
/// default audio track of the variant's group. No live traffic — the Dio
/// adapter is stubbed with fixture content.
void main() {
  test('master with variants: picks 1080p (highest resolution) + default audio', () async {
    final dio = _stubDio({'https://cdn.example/hls/master.m3u8': Fixtures.masterVariants()});
    final svc = HlsService(dio: dio);
    final result = await svc.fetchAndParse('https://cdn.example/hls/master.m3u8');

    expect(result.success, isTrue);
    expect(result.videoVariantUrl, 'https://cdn.example/hls/video/1080p/stream.m3u8');
    expect(result.width, 1920);
    expect(result.height, 1080);
    expect(result.bandwidth, 5294898);
    expect(result.audioUrl, 'https://cdn.example/hls/audio/eng/stream.m3u8'); // DEFAULT=YES
  });

  test('muxed master (no audio group): variant only, audio null', () async {
    final dio = _stubDio({'https://cdn.example/hls/muxed.m3u8': Fixtures.masterMuxed()});
    final svc = HlsService(dio: dio);
    final result = await svc.fetchAndParse('https://cdn.example/hls/muxed.m3u8');

    expect(result.success, isTrue);
    expect(result.videoVariantUrl, 'https://cdn.example/hls/video/muxed-720p.m3u8');
    expect(result.audioUrl, isNull);
  });

  test('empty playlist -> error result', () async {
    final dio = _stubDio({'https://cdn.example/hls/empty.m3u8': ''});
    final svc = HlsService(dio: dio);
    final result = await svc.fetchAndParse('https://cdn.example/hls/empty.m3u8');
    expect(result.success, isFalse);
    expect(result.errorMessage, 'Empty playlist content');
  });

  test('playlist with no variants -> error result', () async {
    const onlyMedia = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:5.0,\nseg-0.ts\n';
    final dio = _stubDio({'https://cdn.example/hls/mediaonly.m3u8': onlyMedia});
    final svc = HlsService(dio: dio);
    final result = await svc.fetchAndParse('https://cdn.example/hls/mediaonly.m3u8');
    expect(result.success, isFalse);
    expect(result.errorMessage, 'No variants found in master playlist');
  });

  test('media playlist fixture shape (segments, discontinuity, no endlist)', () {
    final content = Fixtures.mediaPlaylist();
    expect(content.contains('#EXT-X-DISCONTINUITY'), isTrue);
    expect(content.contains('#EXT-X-ENDLIST'), isFalse); // live-truncated source
    final segments = content.split('\n').where((l) => l.trim().endsWith('.ts')).length;
    expect(segments, 4);
  });
}

/// Dio stub serving fixture strings (deterministic, offline).
Dio _stubDio(Map<String, String> routes) {
  final dio = Dio();
  dio.httpClientAdapter = _StaticAdapter(routes);
  return dio;
}

class _StaticAdapter implements HttpClientAdapter {
  final Map<String, String> routes;
  _StaticAdapter(this.routes);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = routes[options.uri.toString()];
    if (body == null) {
      return ResponseBody.fromString('not found', 404, headers: {
        Headers.contentTypeHeader: ['text/plain'],
      });
    }
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/vnd.apple.mpegurl'],
    });
  }
}
