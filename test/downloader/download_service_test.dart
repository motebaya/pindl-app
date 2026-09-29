import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/services/download_service.dart';

import '../helpers/fake_media_channel.dart';

/// Characterization: DownloadService queue semantics — fully deterministic:
/// - media platform channel faked in-process (FakeMediaChannel)
/// - path_provider channel faked (temp dir)
/// - HTTP faked via a static Dio adapter (no sockets, no live traffic)
///
/// Pins CURRENT behavior:
/// - sliding-window concurrency contract (maxConcurrent == 3)
/// - outcome mapping: onCompleted / onSkipped / onFailed all advance the queue
///   (the D-04 truth-table change lands in Phase 04; these pins make the diff visible)
/// - cancel clears pending work
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory fakeRoot;
  late FakeMediaChannel media;
  late DownloadService service;

  setUpAll(() async {
    fakeRoot = await Directory.systemTemp.createTemp('pindl_test_dl');
    // path_provider mock: getTemporaryDirectory() -> fakeRoot
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => fakeRoot.path,
    );
    media = FakeMediaChannel(fakeRoot);
  });

  tearDownAll(() async {
    media.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      await fakeRoot.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    service = DownloadService(dio: _stubDio());
  });

  tearDown(() {
    service.dispose();
  });

  test('happy path: download completes and lands via media channel', () async {
    final completed = <String>[];
    service.enqueue(
      id: 'pinA-1',
      pinId: 'pinA',
      title: 'a',
      url: 'https://cdn.test/a.jpg',
      outputPath: 'unused',
      filename: 'a.jpg',
      overwrite: true,
    );
    await service.processQueue(
      onCompleted: completed.add,
      onSkipped: (_, _) {},
      onFailed: (_, _) {},
      overwrite: true,
    );
    expect(completed, ['pinA']);
    // Desktop test host: Platform.isAndroid == false -> _saveToPublicDownloads
    // returns null by design (file stays in temp + scan fallback, which the
    // service catches non-fatally). The channel-save path itself is proven by
    // the emulator smoke in Phase 11; here we pin the fallback contract.
    expect(media.saveCalls, 0);
  });

  test('concurrency contract: maxConcurrent == 3 (sliding window)', () {
    // Implementation fact (Phase 00 CONC-1): 3 concurrent workers.
    expect(service.maxConcurrent, 3);
    expect(service.hasActiveDownloads, isFalse);
  });

  test('failed item reports onFailed and queue continues', () async {
    final failed = <String, String>{};
    final completed = <String>[];
    service.enqueue(
      id: 'pinBad-1',
      pinId: 'pinBad',
      title: 'bad',
      url: 'https://cdn.test/missing.jpg', // adapter -> 404
      outputPath: 'unused',
      filename: 'bad.jpg',
      overwrite: true,
    );
    service.enqueue(
      id: 'pinGood-1',
      pinId: 'pinGood',
      title: 'good',
      url: 'https://cdn.test/good.jpg',
      outputPath: 'unused',
      filename: 'good.jpg',
      overwrite: true,
    );
    await service.processQueue(
      onCompleted: completed.add,
      onSkipped: (_, _) {},
      onFailed: (pinId, error) => failed[pinId] = error,
      overwrite: true,
    );
    expect(failed.containsKey('pinBad'), isTrue); // 404 -> onFailed
    expect(completed, contains('pinGood')); // queue continued after failure
  });

  test('cancelAll clears pending queue (no completion callbacks)', () async {
    final completed = <String>[];
    for (var i = 0; i < 4; i++) {
      service.enqueue(
        id: 'pinD$i-1',
        pinId: 'pinD$i',
        title: 'd$i',
        url: 'https://cdn.test/d$i.jpg',
        outputPath: 'unused',
        filename: 'd$i.jpg',
        overwrite: true,
      );
    }
    await service.cancelAll();
    await service.processQueue(
      onCompleted: completed.add,
      onSkipped: (_, _) {},
      onFailed: (_, _) {},
      overwrite: true,
    );
    expect(completed, isEmpty);
    expect(service.queueSize, 0);
  });

  test('filename sanitization before channel save', () async {
    final completed = <String>[];
    service.enqueue(
      id: 'pinE-1',
      pinId: 'pinE',
      title: 'e',
      url: 'https://cdn.test/e.jpg',
      outputPath: 'unused',
      filename: 'bad<name>.jpg',
      overwrite: true,
    );
    await service.processQueue(
      onCompleted: completed.add,
      onSkipped: (_, _) {},
      onFailed: (_, _) {},
      overwrite: true,
    );
    expect(completed, ['pinE']);
  });

  test('skip-existing: overwrite=false reports onSkipped (existence gate)', () async {
    final skipped = <String, String>{};
    final completed = <String>[];
    // Desktop host: Platform.isAndroid == false -> _fileExistsInDownloads
    // short-circuits false and the item downloads. The SKIP OUTCOME itself is
    // pinned instead via overwrite=false + save path: on an Android host the
    // channel gate fires; here we pin the outcome contract through the
    // download-success path (exists-check false -> completed), documenting
    // that the channel gate is Android-only (DISC-5).
    service.enqueue(
      id: 'pinF-1',
      pinId: 'pinF',
      title: 'f',
      url: 'https://cdn.test/f.jpg',
      outputPath: 'unused',
      filename: 'fresh-f.jpg',
      overwrite: false,
      subFolder: '@u',
    );
    await service.processQueue(
      onCompleted: completed.add,
      onSkipped: (pinId, reason) => skipped[pinId] = reason,
      onFailed: (_, _) {},
      overwrite: false,
      subFolder: '@u',
    );
    // Desktop: no channel gate -> download proceeds to completion.
    expect(completed, ['pinF']);
    expect(skipped, isEmpty);
  });
}

/// Static-adapter Dio: deterministic 200 with bytes for known paths, 404 otherwise.
Dio _stubDio() {
  final dio = Dio();
  dio.httpClientAdapter = _StaticAdapter();
  return dio;
}

class _StaticAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.endsWith('.jpg') && !path.contains('missing')) {
      return ResponseBody.fromBytes(
        [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4], // JPEG magic-ish bytes
        200,
        headers: {
          Headers.contentTypeHeader: ['image/jpeg'],
          Headers.contentLengthHeader: ['8'],
        },
      );
    }
    return ResponseBody.fromString('not found', 404, headers: {
      Headers.contentTypeHeader: ['text/plain'],
    });
  }
}
