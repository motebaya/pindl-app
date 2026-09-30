import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/network/range_resume.dart';
import 'package:pindl/data/services/download_service.dart';

/// Phase 06 — byte-level resume matrix (workstreams 06.2/06.3/06.4).
///
/// Every contract outcome is exercised against a scripted Dio adapter:
/// 206-happy resume, 200 Range-ignored fallback (G3), 416 EOF vs incomplete,
/// Content-Range offset/total mismatch, ETag change / absent, corrupt and
/// future-schema sidecars, sidecar/URL mismatch, diverged part, network-error
/// preservation, mid-stream failure reconciliation, cancel preservation, and
/// the DownloadService composition (retry x resume x validation).
///
/// Fully offline-deterministic: no sockets, path_provider faked to a temp dir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late Directory fakeTmp;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('pindl_range_test');
    fakeTmp = Directory('${tempRoot.path}/cache');
    await fakeTmp.create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => fakeTmp.path,
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  tearDown(() async {
    // Fresh state per test: clear the fake temp dir.
    if (await fakeTmp.exists()) {
      await for (final e in fakeTmp.list()) {
        await e.delete(recursive: true);
      }
    }
  });

  const url = 'https://i.pinimg.com/a.jpg';
  final fullBody = Uint8List.fromList(
      [0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(300, 0xAB)]); // 304 B JPEG

  String partPathFor(String name) => '${fakeTmp.path}/$name';

  /// Pre-seeds an interrupted transfer: `.part` with the first [offset] bytes
  /// of [fullBody] + a matching sidecar. Returns the sidecar path.
  Future<String> seedInterrupted(
    String partPath, {
    int offset = 100,
    String? etag = '"etag-1"',
    String? urlHash,
    int? total,
  }) async {
    await File(partPath).writeAsBytes(fullBody.sublist(0, offset));
    final sidecarPath = '$partPath.meta.json';
    await File(sidecarPath).writeAsString(jsonEncode({
      'schema': 1,
      'url_hash': urlHash ?? RangeResume.hashUrl(url),
      'offset': offset,
      'total': total ?? fullBody.length,
      'etag': ?etag,
    }));
    return sidecarPath;
  }

  Future<List<int>> readPart(String partPath) => File(partPath).readAsBytes();

  group('RangeResume: from-zero + happy resume (G1)', () {
    test('no sidecar -> plain from-zero download, sidecar written + cleaned',
        () async {
      final partPath = partPathFor('fresh_a.jpg.part');
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(1));
      expect(probes.single.headers['Range'], isNull); // no resume attempted
      expect(await readPart(partPath), equals(fullBody));
      expect(File('$partPath.meta.json').existsSync(), isFalse);
    });

    test('progress events flow with known total', () async {
      final partPath = partPathFor('fresh_progress.jpg.part');
      final dio = Dio()..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);
      final events = <(int, int)>[];

      await RangeResume.download(dio, url, partPath,
          onProgress: (r, t) => events.add((r, t)));

      // Byte-exact outcome is asserted above; here the determinism contract is
      // only that events flow with the known total and end at full length.
      expect(events, isNotEmpty);
      expect(events.last.$2, fullBody.length);
      expect(events.last.$1, fullBody.length);
    });

    test('valid interrupted state + 206 -> appends remainder, byte-exact',
        () async {
      final partPath = partPathFor('resume_ok.jpg.part');
      final sidecarPath =
          await seedInterrupted(partPath); // first 100 bytes + sidecar
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          etag: '"etag-1"',
          rangeRemainder: fullBody.sublist(100),
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(1));
      expect(probes.single.headers['Range'], 'bytes=100-');
      final result = await readPart(partPath);
      expect(result.length, fullBody.length);
      expect(result, equals(fullBody)); // byte-identical reassembly
      expect(File(sidecarPath).existsSync(), isFalse); // sidecar consumed
    });
  });

  group('RangeResume: safe-restart matrix (G3 + anomaly rule)', () {
    test('probe 200 (Range ignored) -> full restart from zero', () async {
      final partPath = partPathFor('r200.jpg.part');
      await seedInterrupted(partPath);
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeStatus: 200, // server ignores Range
          rangeRemainder: fullBody,
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(2)); // probe + clean restart
      expect(probes.last.headers['Range'], isNull);
      expect(await readPart(partPath), equals(fullBody));
    });

    test('probe 416 with incomplete part -> full restart', () async {
      final partPath = partPathFor('r416a.jpg.part');
      await seedInterrupted(partPath);
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeStatus: 416,
          rangeHeaders: {'content-range': 'bytes */${fullBody.length}'},
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(2));
      expect(await readPart(partPath), equals(fullBody));
    });

    test('probe 416 with COMPLETE part -> kept, no second fetch', () async {
      // Interrupted between final byte and rename: the part is whole.
      final partPath = partPathFor('r416b.jpg.part');
      await seedInterrupted(partPath, offset: fullBody.length);
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeStatus: 416,
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(1)); // only the probe
      expect(await readPart(partPath), equals(fullBody)); // intact
    });

    test('probe 206 at wrong offset -> full restart', () async {
      final partPath = partPathFor('r_off.jpg.part');
      await seedInterrupted(partPath, offset: 100);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeRemainder: fullBody.sublist(50), // server sent wrong window
          rangeOverride: (req) => 'bytes 50-303/304',
        );

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('probe 206 with wrong total -> full restart', () async {
      final partPath = partPathFor('r_tot.jpg.part');
      await seedInterrupted(partPath, offset: 100);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeRemainder: fullBody.sublist(100),
          rangeOverride: (req) => 'bytes 100-303/999', // total changed
        );

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('ETag changed -> full restart (validator mismatch)', () async {
      final partPath = partPathFor('r_etag.jpg.part');
      await seedInterrupted(partPath, etag: '"etag-OLD"');
      final probes = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          etag: '"etag-NEW"', // object replaced server-side
          rangeRemainder: fullBody.sublist(100),
          onGet: (o) => probes.add(o),
        );

      await RangeResume.download(dio, url, partPath);

      expect(probes, hasLength(2)); // probe + full restart
      expect(await readPart(partPath), equals(fullBody));
    });

    test('sidecar ETag absent + response ETag present -> restart (unverifiable)',
        () async {
      final partPath = partPathFor('r_noetag.jpg.part');
      await seedInterrupted(partPath, etag: null);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          etag: '"etag-1"',
          rangeRemainder: fullBody.sublist(100),
        );

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('corrupt sidecar JSON -> state discarded, clean from-zero',
        () async {
      final partPath = partPathFor('r_corrupt.jpg.part');
      await File(partPath).writeAsBytes(fullBody.sublist(0, 100));
      await File('$partPath.meta.json').writeAsString('{not json');
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          onGet: (o) {},
        );

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('future-schema sidecar -> restart (D-26 spirit)', () async {
      final partPath = partPathFor('r_future.jpg.part');
      await File(partPath).writeAsBytes(fullBody.sublist(0, 100));
      await File('$partPath.meta.json').writeAsString(jsonEncode({
        'schema': 99,
        'url_hash': RangeResume.hashUrl(url),
        'offset': 100,
        'total': fullBody.length,
      }));
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('sidecar/URL hash mismatch -> restart (stale-state guard)', () async {
      final partPath = partPathFor('r_hash.jpg.part');
      await seedInterrupted(partPath, urlHash: 'deadbeefdeadbeef');
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('part longer than sidecar offset (diverged) -> restart', () async {
      final partPath = partPathFor('r_diverged.jpg.part');
      await seedInterrupted(partPath, offset: 100);
      await File(partPath).writeAsBytes(fullBody.sublist(0, 150)); // > sidecar
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('orphan part without sidecar -> deleted, from zero', () async {
      final partPath = partPathFor('r_orphan.jpg.part');
      await File(partPath).writeAsBytes(fullBody.sublist(0, 100));
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });

    test('probe 5xx -> full restart (any anomaly)', () async {
      final partPath = partPathFor('r_5xx.jpg.part');
      await seedInterrupted(partPath);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          rangeStatus: 503,
          onGet: (o) {},
        );

      await RangeResume.download(dio, url, partPath);

      expect(await readPart(partPath), equals(fullBody));
    });
  });

  group('RangeResume: preservation semantics (06.4 / G2-adjacent)', () {
    test('network error on probe -> .part + sidecar preserved untouched',
        () async {
      final partPath = partPathFor('p_net.jpg.part');
      final sidecarPath = await seedInterrupted(partPath);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          probeError: DioException.connectionError(
            requestOptions: RequestOptions(path: url),
            reason: 'airplane mode',
          ),
        );

      await expectLater(
        RangeResume.download(dio, url, partPath),
        throwsA(isA<DioException>()),
      );

      expect(File(partPath).existsSync(), isTrue);
      expect(File(partPath).lengthSync(), 100);
      expect(File(sidecarPath).existsSync(), isTrue);
    });

    test('pre-cancelled token -> cancel propagates, state preserved',
        () async {
      final partPath = partPathFor('p_cancel.jpg.part');
      final sidecarPath = await seedInterrupted(partPath);
      final token = CancelToken();
      token.cancel('user cancel');
      final dio = Dio()..httpClientAdapter = _ScriptedAdapter(fullBody: fullBody);

      await expectLater(
        RangeResume.download(dio, url, partPath, cancelToken: token),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );

      expect(File(partPath).existsSync(), isTrue);
      expect(File(sidecarPath).existsSync(), isTrue);
    });

    test('mid-stream failure -> sidecar reconciled to actual disk bytes',
        () async {
      final partPath = partPathFor('p_mid.jpg.part');
      await seedInterrupted(partPath, offset: 100);
      final dio = Dio()
        ..httpClientAdapter = _ScriptedAdapter(
          fullBody: fullBody,
          etag: '"etag-1"',
          rangeRemainder: null, // signals the erroring stream below
          rangeStreamChunks: [40, 50], // 90 more bytes, then die
        );

      await expectLater(
        RangeResume.download(dio, url, partPath),
        throwsA(isA<DioException>()),
      );

      final sidecar =
          ResumeSidecar.tryLoad('$partPath.meta.json');
      expect(sidecar, isNotNull);
      expect(sidecar!.offset, 190); // 100 + 40 + 50 actually on disk
      expect(File(partPath).lengthSync(), 190);
    });

    test('sidecar round-trip: save -> tryLoad equality', () async {
      final p = '${fakeTmp.path}/rt.meta.json';
      const s = ResumeSidecar(
        urlHash: 'abc123',
        offset: 42,
        total: 100,
        etag: '"e"',
        lastModified: 'Tue, 29 Sep 2026 00:00:00 GMT',
      );
      await s.save(p);
      final loaded = ResumeSidecar.tryLoad(p);
      expect(loaded!.urlHash, s.urlHash);
      expect(loaded.offset, s.offset);
      expect(loaded.total, s.total);
      expect(loaded.etag, s.etag);
      expect(loaded.lastModified, s.lastModified);
    });
  });

  group('DownloadService composition (06.4): retry x resume x validation', () {
    test('mid-transfer network drop -> retry resumes at offset, completes',
        () async {
      final pinId = 'pinR';
      final tempPath = '${fakeTmp.path}/${pinId}_r.jpg';
      final partPath = '$tempPath.part';
      final adapter = _ScriptedAdapter(
        fullBody: fullBody,
        etag: '"etag-1"',
        failFirstFullAfterBytes: 120, // run 1: die mid-transfer
      );
      final service = DownloadService(dio: Dio()..httpClientAdapter = adapter);

      service.enqueue(
        id: '$pinId-1',
        pinId: pinId,
        title: 'r',
        url: url,
        outputPath: 'unused',
        filename: 'r.jpg',
        overwrite: true,
      );
      final completed = <String>[];
      await service.processQueue(
        onCompleted: completed.add,
        onSkipped: (_, _) {},
        onFailed: (_, _) {},
        overwrite: true,
      );
      service.dispose();

      expect(completed, [pinId]);
      // Attempt 2 resumed: a Range probe at the failed offset must exist.
      final resumeProbe = adapter.requests
          .where((o) => o.headers['Range'] != null)
          .toList();
      expect(resumeProbe, hasLength(1));
      expect(resumeProbe.single.headers['Range'], 'bytes=120-');
      // Completed file validated + no leftover part state in temp.
      expect(File(tempPath).existsSync(), isTrue);
      expect(await readPart(tempPath), equals(fullBody));
      expect(File('$partPath.meta.json').existsSync(), isFalse);
      expect(File(partPath).existsSync(), isFalse);
    });

    test('cancel mid-transfer preserves .part + sidecar (06.4)', () async {
      final pinId = 'pinC';
      final tempPath = '${fakeTmp.path}/${pinId}_c.jpg';
      final partPath = '$tempPath.part';
      final adapter = _ScriptedAdapter(
        fullBody: fullBody,
        failFirstFullAfterBytes: 120,
        holdProbeOnError: true, // keep attempt 2 in-flight until cancelled
      );
      final service = DownloadService(dio: Dio()..httpClientAdapter = adapter);

      service.enqueue(
        id: '$pinId-1',
        pinId: pinId,
        title: 'c',
        url: url,
        outputPath: 'unused',
        filename: 'c.jpg',
        overwrite: true,
      );
      final queueDone = service.processQueue(
        onCompleted: (_) {},
        onSkipped: (_, _) {},
        onFailed: (_, _) {},
        overwrite: true,
      );
      // Wait until the first (failing) attempt has died and the retry is
      // parked in backoff/hold, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await service.cancelAll();
      await queueDone;
      service.dispose();

      expect(File(partPath).existsSync(), isTrue,
          reason: 'cancel must preserve the resume state');
      expect(File('$partPath.meta.json').existsSync(), isTrue);
      expect(File(partPath).lengthSync(), 120);
    });
  });
}

/// Scripted in-process adapter. GET behavior:
///  * full-body request -> 200 + [fullBody] (optionally truncated at
///    [failFirstFullAfterBytes], then a connection error — one run only);
///  * ranged request -> [rangeStatus] (default 206) with Content-Range from
///    [rangeOverride] or derived from the request offset + [rangeRemainder].
class _ScriptedAdapter implements HttpClientAdapter {
  final Uint8List fullBody;
  final String? etag;
  final int rangeStatus;
  final Uint8List? rangeRemainder;
  final List<int>? rangeStreamChunks;
  final String Function(RequestOptions)? rangeOverride;
  final Map<String, String>? rangeHeaders;
  final void Function(RequestOptions)? onGet;
  final DioException? probeError;
  final int? failFirstFullAfterBytes;
  final bool holdProbeOnError;

  final List<RequestOptions> requests = [];
  bool _fullFailedOnce = false;
  Completer<void>? _hold;

  _ScriptedAdapter({
    required this.fullBody,
    this.etag,
    this.rangeStatus = 206,
    this.rangeRemainder,
    this.rangeStreamChunks,
    this.rangeOverride,
    this.rangeHeaders,
    this.onGet,
    this.probeError,
    this.failFirstFullAfterBytes,
    this.holdProbeOnError = false,
  });

  Map<String, List<String>> _headers({int? contentLength}) => {
        Headers.contentTypeHeader: ['image/jpeg'],
        if (etag != null) 'etag': [etag!],
        if (contentLength != null) Headers.contentLengthHeader: ['$contentLength'],
      };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    onGet?.call(options);
    final range = options.headers['Range'] as String?;

    if (range == null) {
      // Full-body transfer.
      if (failFirstFullAfterBytes != null && !_fullFailedOnce) {
        _fullFailedOnce = true;
        final cut = failFirstFullAfterBytes!;
        return ResponseBody(
          Stream.fromIterable([fullBody.sublist(0, cut)])
              .transform(_AppendError()),
          200,
          headers: _headers(contentLength: cut),
        );
      }
      return ResponseBody.fromBytes(fullBody, 200,
          headers: _headers(contentLength: fullBody.length));
    }

    // Ranged (resume-probe) request.
    if (probeError != null) throw probeError!;
    if (holdProbeOnError) {
      // Simulate an in-flight transfer that never finishes until released —
      // used to hold the retry attempt while the test cancels.
      _hold = Completer<void>();
      if (cancelFuture != null) {
        unawaited(cancelFuture.whenComplete(() {
          if (!(_hold?.isCompleted ?? true)) _hold!.complete();
        }));
      }
      await _hold!.future;
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: 'cancelled while in flight',
      );
    }

    final offset = int.parse(range.substring('bytes='.length).replaceAll('-', ''));
    final status = rangeStatus;
    final contentRange =
        rangeOverride?.call(options) ?? 'bytes $offset-${fullBody.length - 1}/${fullBody.length}';
    final hdrs = {
      ..._headers(),
      'content-range': [contentRange],
      if (rangeHeaders != null)
        for (final e in rangeHeaders!.entries) e.key: [e.value],
    };

    if (status == 416 || status >= 300) {
      return ResponseBody.fromString('err', status, headers: hdrs);
    }
    if (status == 200) {
      // Range ignored: serve the whole body.
      return ResponseBody.fromBytes(fullBody, 200,
          headers: _headers(contentLength: fullBody.length));
    }
    final body = rangeStreamChunks != null
        ? Stream<Uint8List>.fromIterable(
                rangeStreamChunks!.map((n) => Uint8List.fromList(
                    List<int>.filled(n, 0xCD))))
            .transform(_AppendError())
        : Stream<Uint8List>.fromIterable(
            [Uint8List.fromList(rangeRemainder ?? fullBody.sublist(offset))]);
    return ResponseBody(body, status, headers: hdrs);
  }

  @override
  void close({bool force = false}) {}
}

/// Stream transformer that appends a connection error after the mapped chunks
/// (simulates a mid-transfer drop).
class _AppendError extends StreamTransformerBase<Uint8List, Uint8List> {
  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) async* {
    await for (final c in stream) {
      yield c;
    }
    throw DioException.connectionError(
      requestOptions: RequestOptions(path: 'scripted'),
      reason: 'scripted mid-transfer drop',
    );
  }
}
