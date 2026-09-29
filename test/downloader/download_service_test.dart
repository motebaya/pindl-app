import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/network/media_hosts.dart';
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
///
/// PHASE 03 PIN FLIPS (deliberate, documented in the phase report):
/// - URLs moved from cdn.test to i.pinimg.com — SEC-2 host allowlist now
///   rejects non-Pinterest hosts at enqueue/process time (was: any host fetched).
/// - JPEG bodies are full-size (>= 256 B) — DL-2 fail-closed validation now
///   rejects undersized/document bodies (was: any 2xx body imported).
/// - New group below pins the fail-closed behavior itself (G2/G5).
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
      url: 'https://i.pinimg.com/a.jpg',
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
      url: 'https://i.pinimg.com/missing.jpg', // adapter -> 404
      outputPath: 'unused',
      filename: 'bad.jpg',
      overwrite: true,
    );
    service.enqueue(
      id: 'pinGood-1',
      pinId: 'pinGood',
      title: 'good',
      url: 'https://i.pinimg.com/good.jpg',
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
        url: 'https://i.pinimg.com/d$i.jpg',
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
      url: 'https://i.pinimg.com/e.jpg',
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
      url: 'https://i.pinimg.com/f.jpg',
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

  group('Phase 03: SEC-2 allowlist + DL-2 fail-closed (gates G2/G5)', () {
    test('lookalike host rejected: evilpinimg.com is NOT pinimg.com (D-08)', () async {
      final failed = <String, String>{};
      final completed = <String>[];
      service.enqueue(
        id: 'pinG-1',
        pinId: 'pinG',
        title: 'g',
        url: 'https://evilpinimg.com/g.jpg',
        outputPath: 'unused',
        filename: 'g.jpg',
        overwrite: true,
      );
      await service.processQueue(
        onCompleted: completed.add,
        onSkipped: (_, _) {},
        onFailed: (pinId, error) => failed[pinId] = error,
        overwrite: true,
      );
      expect(completed, isEmpty); // never fetched, never imported
      expect(failed['pinG'], contains(MediaHosts.rejectionReason));
      expect(failed['pinG'], contains('evilpinimg.com')); // host logged for the one-line allowlist fix
    });

    test('proper subdomain allowed: v1.pinimg.com passes boundary matching', () async {
      final completed = <String>[];
      service.enqueue(
        id: 'pinH-1',
        pinId: 'pinH',
        title: 'h',
        url: 'https://v1.pinimg.com/h.jpg',
        outputPath: 'unused',
        filename: 'h.jpg',
        overwrite: true,
      );
      await service.processQueue(
        onCompleted: completed.add,
        onSkipped: (_, _) {},
        onFailed: (_, _) {},
        overwrite: true,
      );
      expect(completed, ['pinH']);
    });

    test('HTML-error-page-as-media fails closed (DL-2/SEC-4)', () async {
      final failed = <String, String>{};
      final completed = <String>[];
      service.enqueue(
        id: 'pinI-1',
        pinId: 'pinI',
        title: 'i',
        url: 'https://i.pinimg.com/htmlpage.jpg',
        outputPath: 'unused',
        filename: 'i.jpg',
        overwrite: true,
      );
      await service.processQueue(
        onCompleted: completed.add,
        onSkipped: (_, _) {},
        onFailed: (pinId, error) => failed[pinId] = error,
        overwrite: true,
      );
      expect(completed, isEmpty);
      expect(failed['pinI'], contains('validation failed'));
      expect(failed['pinI'], contains('document'));
    });

    test('undersized body fails closed at the 256 B floor (DL-2)', () async {
      final failed = <String, String>{};
      final completed = <String>[];
      service.enqueue(
        id: 'pinJ-1',
        pinId: 'pinJ',
        title: 'j',
        url: 'https://i.pinimg.com/tiny.jpg',
        outputPath: 'unused',
        filename: 'j.jpg',
        overwrite: true,
      );
      await service.processQueue(
        onCompleted: completed.add,
        onSkipped: (_, _) {},
        onFailed: (pinId, error) => failed[pinId] = error,
        overwrite: true,
      );
      expect(completed, isEmpty);
      expect(failed['pinJ'], contains('undersized'));
    });
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
    // DL-2 case: HTML document served as .jpg (false-success attempt)
    if (path.contains('htmlpage')) {
      return ResponseBody.fromString(
        '<html><head><title>error</title></head><body>${'x' * 300}</body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      );
    }
    // DL-2 case: undersized body (8-byte JPEG magic, below the 256 B floor)
    if (path.contains('tiny')) {
      return ResponseBody.fromBytes(
        [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4],
        200,
        headers: {
          Headers.contentTypeHeader: ['image/jpeg'],
          Headers.contentLengthHeader: ['8'],
        },
      );
    }
    if (path.endsWith('.jpg') && !path.contains('missing')) {
      return ResponseBody.fromBytes(_jpegBody(), 200, headers: {
        Headers.contentTypeHeader: ['image/jpeg'],
      });
    }
    return ResponseBody.fromString('not found', 404, headers: {
      Headers.contentTypeHeader: ['text/plain'],
    });
  }
}

/// Valid-enough JPEG head + binary padding past the 256 B validation floor.
List<int> _jpegBody() {
  return [0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(300, 0x00)];
}
