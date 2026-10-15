import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/job_state.dart';
import 'package:pindl/data/services/download_service.dart';
import 'package:pindl/data/services/log_service.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';
import 'package:pindl/presentation/providers/job_provider.dart';
import 'package:pindl/presentation/widgets/console_panel.dart';

import '../helpers/fixture_loader.dart';

/// 3.1.1+8 — "turning on Verbose logs adds nothing to the console".
///
/// Four separate breaks produced that report, and each is pinned here:
///   1. [LogLevel] had no `debug` member at all, so there was no level a
///      verbose line could even be filed under;
///   2. nothing consulted the setting when deciding what to emit — the old
///      `[DEBUG]` diagnostics were `print()`s, which on a release APK go to
///      logcat, never to the in-app console the user is looking at;
///   3. the Dio request/response interceptor was attached once in the
///      constructor, while `verbose` was still false, so a later
///      `verbose = true` could never produce API detail;
///   4. the extractor the app builds had NO log service at all, so even the
///      diagnostics it did produce were dropped.
///
/// Contract pinned: verbose OFF is exactly as concise as before (debug lines
/// are not even queued), verbose ON only ADDS lines, and no error/warning/
/// progress line is ever gated. Fully offline: scripted Dio adapter.
void main() {
  group('log service verbose gate', () {
    test('debug lines are dropped entirely while verbose is off', () async {
      final service = LogService();
      addTearDown(service.dispose);

      final streamed = <LogEntry>[];
      final sub = service.stream.listen(streamed.add);
      addTearDown(sub.cancel);

      service.debug('should not appear');
      expect(service.entries.where((e) => e.level == LogLevel.debug), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(streamed, isEmpty);
    });

    test('debug lines appear — and stream — once verbose is on', () async {
      final service = LogService(verbose: true);
      addTearDown(service.dispose);

      final streamed = <LogEntry>[];
      final sub = service.stream.listen(streamed.add);
      addTearDown(sub.cancel);

      service.debug('pin page id.pinterest.com: 2 relay payload(s)');

      final entry = service.entries.single;
      expect(entry.level, LogLevel.debug);
      expect(entry.message, 'pin page id.pinterest.com: 2 relay payload(s)');
      // The console renders the level name, so `debug` must read as [DEBUG].
      expect(entry.toString(), contains('[DEBUG]'));

      await Future<void>.delayed(Duration.zero);
      expect(streamed.single.level, LogLevel.debug);
    });

    test('only debug is gated: every other level survives verbose off', () {
      final service = LogService();
      addTearDown(service.dispose);

      service.init('init');
      service.validate('validate');
      service.config('config');
      service.fetch('fetch');
      service.parse('parse');
      service.queue('queue');
      service.downloading('downloading');
      service.saved('saved');
      service.skipped('skipped');
      service.error('error');
      service.interrupted('interrupted');
      service.complete('complete');
      service.debug('debug');

      final levels = service.entries.map((e) => e.level).toList();
      expect(levels, isNot(contains(LogLevel.debug)));
      expect(levels, containsAll(<LogLevel>[
        LogLevel.init,
        LogLevel.validate,
        LogLevel.config,
        LogLevel.fetch,
        LogLevel.parse,
        LogLevel.queue,
        LogLevel.downloading,
        LogLevel.saved,
        LogLevel.skipped,
        LogLevel.error,
        LogLevel.interrupted,
        LogLevel.complete,
      ]));
    });

    test('debug entries obey maxEntries trimming and clear()', () {
      final service = LogService(maxEntries: 3, verbose: true);
      addTearDown(service.dispose);

      for (var i = 0; i < 5; i++) {
        service.debug('line $i');
      }
      expect(service.entries, hasLength(3));
      expect(service.entries.first.message, 'line 2');
      expect(service.entries.last.message, 'line 4');

      service.clear();
      expect(service.entries, isEmpty);
    });

    testWidgets('the console panel renders verbose lines as [DEBUG]',
        (tester) async {
      final service = LogService();
      addTearDown(service.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConsolePanel(
            logStream: service.stream,
            initialEntries: service.entries,
          ),
        ),
      ));

      service.debug('hidden while off');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('hidden while off'), findsNothing);

      service.verbose = true;
      service.debug('selected media — video: x_720w.mp4 (direct MP4)');
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('[DEBUG]'), findsOneWidget);
      expect(
        find.textContaining('selected media — video: x_720w.mp4 (direct MP4)'),
        findsOneWidget,
      );
    });
  });

  group('extractor verbose wiring', () {
    const pinId = '1234567890123456789';
    const pinUrl = 'https://id.pinterest.com/pin/$pinId/';

    test('a verbose run shows the single-pin decision trace', () async {
      final adapter = _ScriptedAdapter(Fixtures.pinVideosNodeCamel());
      final logService = LogService(verbose: true);
      addTearDown(logService.dispose);
      final service = PinterestExtractorService(
        dio: Dio()..httpClientAdapter = adapter,
        verbose: true,
        logService: logService,
      );

      final result = await service.getPinMedia(pinIdOrUrl: pinUrl);
      expect(result.videoUrl, endsWith('fixture720w.mp4'));

      final debugLines = logService.entries
          .where((e) => e.level == LogLevel.debug)
          .map((e) => e.message)
          .toList();

      // Which pages are tried, what each carried, what was finally chosen —
      // this is what turns "the console shows nothing" into a report.
      expect(debugLines.any((m) => m.contains('single pin $pinId')), isTrue);
      expect(debugLines.any((m) => m.contains('relay payload(s)')), isTrue);
      expect(
        debugLines.any((m) =>
            m.contains('selected media') && m.contains('(direct MP4)')),
        isTrue,
      );
      // The Dio interceptor detail rides along while verbose is on.
      expect(debugLines.any((m) => m.contains('[DIO]')), isTrue);
      expect(adapter.hits, hasLength(1));
    });

    test('a non-verbose run adds no debug lines at all', () async {
      final adapter = _ScriptedAdapter(Fixtures.pinVideosNodeCamel());
      final logService = LogService();
      addTearDown(logService.dispose);
      final service = PinterestExtractorService(
        dio: Dio()..httpClientAdapter = adapter,
        logService: logService,
      );

      await service.getPinMedia(pinIdOrUrl: pinUrl);

      final messages = logService.entries.map((e) => e.message).toList();
      expect(
        messages.any((m) => m.startsWith('[DIO]')),
        isFalse,
        reason: 'the API interceptor must not be attached while verbose is off',
      );
      expect(messages.any((m) => m.contains('selected media')), isFalse);
      expect(
        logService.entries.any((e) => e.level == LogLevel.debug),
        isFalse,
      );
    });

    test('the verbose gate never hides a progress line', () async {
      // First host serves a payload-less page, the second the real one: the
      // "relay payload recovered" line is a FETCH line and must be visible in
      // both modes (the gate only removes DEBUG noise).
      String noPayload() => '<html><head><script>'
          'window.__PWS_RELAY_REGISTER_PENDING_REQUEST__=function(t){return t};'
          'window.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__=function(t,n){return n};'
          '</script></head><body></body></html>';

      for (final verbose in [false, true]) {
        final logService = LogService(verbose: verbose);
        addTearDown(logService.dispose);
        final adapter = _HostScriptedAdapter({
          'id.pinterest.com': noPayload(),
          'www.pinterest.com': Fixtures.pinVideosNodeCamel(),
        });
        final service = PinterestExtractorService(
          dio: Dio()..httpClientAdapter = adapter,
          verbose: verbose,
          logService: logService,
        );

        await service.getPinMedia(pinIdOrUrl: pinUrl);

        expect(
          logService.entries.any((e) =>
              e.level == LogLevel.fetch && e.message.contains('recovered')),
          isTrue,
          reason: 'verbose=$verbose must not swallow the fetch-level line',
        );
      }
    });

    test('flipping verbose after construction attaches the API interceptor',
        () async {
      final adapter = _ScriptedAdapter(Fixtures.pinVideosNodeCamel());
      final logService = LogService();
      addTearDown(logService.dispose);
      // Constructed non-verbose, exactly like the app's provider does.
      final service = PinterestExtractorService(
        dio: Dio()..httpClientAdapter = adapter,
        logService: logService,
      );

      // …and the setting arrives afterwards, exactly like JobNotifier does.
      service.verbose = true;
      logService.verbose = true;
      await service.getPinMedia(pinIdOrUrl: pinUrl);
      expect(
        logService.entries.any((e) => e.message.startsWith('[DIO]')),
        isTrue,
        reason: 'the interceptor must follow the live flag, not construction',
      );

      // Turning it off again detaches it and silences the debug sink.
      logService.clear();
      service.verbose = false;
      logService.verbose = false;
      await service.getPinMedia(pinIdOrUrl: pinUrl);
      expect(logService.entries, isEmpty);
    });
  });

  group('provider propagation of the setting', () {
    late LogService logService;
    late PinterestExtractorService extractor;
    late JobNotifier notifier;

    setUp(() {
      logService = LogService();
      extractor = PinterestExtractorService(
        dio: Dio()..httpClientAdapter = _ScriptedAdapter('<html></html>'),
      );
      notifier = JobNotifier(
        logService: logService,
        extractor: extractor,
        downloadService: DownloadService(),
      );
    });

    tearDown(() => logService.dispose());

    test('startExtraction hands the flag to both the extractor and the console',
        () async {
      await notifier.startExtraction(input: '', mediaType: MediaType.image, verbose: true);
      expect(extractor.verbose, isTrue);
      expect(logService.verbose, isTrue);

      await notifier.startExtraction(input: '', mediaType: MediaType.image);
      expect(extractor.verbose, isFalse);
      expect(logService.verbose, isFalse);
    });

    test('startDownload / startBoardDownload propagate it', () async {
      await notifier.startDownload(
        outputPath: 'Download',
        mediaType: MediaType.video,
        overwrite: false,
        verbose: true,
      );
      expect(extractor.verbose, isTrue);
      expect(logService.verbose, isTrue);

      await notifier.startBoardDownload(
        outputPath: 'Download',
        mediaType: MediaType.video,
        overwrite: false,
        username: 'someone',
        verbose: false,
      );
      expect(extractor.verbose, isFalse);
      expect(logService.verbose, isFalse);
    });

    test('discoverBoards and fetchMore propagate it', () async {
      await notifier.fetchMore(mediaType: MediaType.image, verbose: true);
      expect(extractor.verbose, isTrue);
      expect(logService.verbose, isTrue);

      await notifier.discoverBoards(username: 'someone', verbose: false);
      expect(extractor.verbose, isFalse);
      expect(logService.verbose, isFalse);
    });
  });
}

/// Serves one canned body for every request.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.body);

  final String body;
  final List<String> hits = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits.add(options.uri.toString());
    return ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}

/// Serves one canned body per host (unknown host -> 404-shaped empty body).
class _HostScriptedAdapter implements HttpClientAdapter {
  _HostScriptedAdapter(this.pagesByHost);

  final Map<String, String> pagesByHost;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = pagesByHost[options.uri.host];
    if (body == null) return ResponseBody.fromString('', 404);
    return ResponseBody.fromString(
      body,
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}
