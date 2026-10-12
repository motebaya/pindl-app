import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/network/range_resume.dart';

/// 3.1.1 — declared-length hardening (RangeResume).
///
/// Device report: `Download failed: The connection errored: short body: got 920
/// of 350 bytes` on retry of a file that had already transferred 920 bytes. The
/// CDN had declared a total of 350 bytes; `written != total` then threw, the
/// sidecar kept the bogus total, and every retry failed identically — the item
/// could never complete.
///
/// Contract now:
///   * fewer bytes than declared -> still a hard error (real truncation);
///   * MORE bytes than declared -> the DECLARED value is wrong, accept the
///     delivered bytes and let the media validator judge the content;
///   * a compressed response (non-identity content-encoding) declares a WIRE
///     length that cannot describe the decoded stream -> total unknown.
///
/// Fully offline: a scripted adapter, no sockets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pindl_declared_len');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  const url = 'https://i.pinimg.com/media.bin';
  final body = List<int>.generate(920, (i) => i % 251);

  test('oversized body vs declared total: accepted, no short-body error',
      () async {
    final partPath = '${tmp.path}/overshoot.part';
    final logs = <String>[];
    final dio = Dio()
      ..httpClientAdapter = _LengthAdapter(
        body: body,
        declaredContentLength: 350, // live CDN header (device report)
      );

    await RangeResume.download(dio, url, partPath, onLog: logs.add);

    expect(File(partPath).lengthSync(), 920);
    expect(File('$partPath.meta.json').existsSync(), isFalse,
        reason: 'a completed part consumes its sidecar');
    expect(logs.any((l) => l.contains('unreliable')), isTrue,
        reason: 'the contradiction must be logged, not swallowed');
  });

  test('undersized body vs declared total: still fails (real truncation)',
      () async {
    final partPath = '${tmp.path}/undershoot.part';
    final dio = Dio()
      ..httpClientAdapter = _LengthAdapter(
        body: body.sublist(0, 100),
        declaredContentLength: 920,
      );

    await expectLater(
      RangeResume.download(dio, url, partPath),
      throwsA(isA<DioException>()),
    );
    // Resume state preserved and reconciled to what actually landed.
    final sidecar = ResumeSidecar.tryLoad('$partPath.meta.json');
    expect(sidecar!.offset, 100);
    expect(File(partPath).lengthSync(), 100);
  });

  test('compressed response: declared wire length is ignored', () async {
    final partPath = '${tmp.path}/gzip.part';
    final dio = Dio()
      ..httpClientAdapter = _LengthAdapter(
        body: body,
        declaredContentLength: 350,
        contentEncoding: 'gzip',
      );

    await RangeResume.download(dio, url, partPath);

    // No exception: the wire length is not comparable with decoded bytes.
    expect(File(partPath).lengthSync(), 920);
  });

  test('resume probe on a compressed response also skips total enforcement',
      () async {
    final partPath = '${tmp.path}/gzip_resume.part';
    await File(partPath).writeAsBytes(body.sublist(0, 300));
    await File('$partPath.meta.json').writeAsString(
      '{"schema":1,"url_hash":"${RangeResume.hashUrl(url)}","offset":300,"total":920}',
    );
    final dio = Dio()
      ..httpClientAdapter = _LengthAdapter(
        body: body,
        declaredContentLength: 350,
        contentEncoding: 'gzip',
      );

    await RangeResume.download(dio, url, partPath);

    expect(File(partPath).lengthSync(), greaterThanOrEqualTo(300));
  });
}

/// Adapter that serves [body] with a DELIBERATELY wrong Content-Length, and an
/// optional non-identity content-encoding.
class _LengthAdapter implements HttpClientAdapter {
  final List<int> body;
  final int declaredContentLength;
  final String? contentEncoding;

  _LengthAdapter({
    required this.body,
    required this.declaredContentLength,
    this.contentEncoding,
  });

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final range = options.headers['Range'] as String?;
    final headers = <String, List<String>>{
      Headers.contentLengthHeader: ['$declaredContentLength'],
      if (contentEncoding != null) 'content-encoding': [contentEncoding!],
    };
    if (range == null) {
      return ResponseBody.fromBytes(
        Uint8List.fromList(body),
        200,
        headers: headers,
      );
    }
    final offset = int.parse(range.substring(6).replaceAll('-', ''));
    headers['content-range'] = ['bytes $offset-${body.length - 1}/${body.length}'];
    return ResponseBody.fromBytes(
      Uint8List.fromList(body.sublist(offset)),
      206,
      headers: headers,
    );
  }
}
