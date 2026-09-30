import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/controllers/board_controller.dart';
import 'package:pindl/data/controllers/extraction_controller.dart'
    show ControllerLog;
import 'package:pindl/data/services/pinterest_extractor_service.dart';
import 'package:pindl/data/pinterest/resources.dart';

void main() {
  group('board bookmark context (Phase 09.4 — D-34 tuple, board scope)', () {
    test('cap exit carries the FULL tuple; natural end carries none', () async {
      final result = await _cappedBoardPinsRun();

      expect(result.nextBookmark, isNotNull);
      final ctx = result.bookmarkContext;
      expect(ctx, isNotNull);
      expect(ctx!.resource, BookmarkContext.resourceBoardPins);
      expect(ctx.username, 'fixtureuser');
      expect(ctx.maxPages, 1);
      expect(ctx.bookmark, result.nextBookmark);
      // Board scope rides INSIDE request_options (registry builder).
      expect(ctx.requestOptions, containsPair('board_id', '111111111111111111'));
    });

    test('tuple round-trips through persistence JSON and still matches', () {
      final ctx = BookmarkContext(
        username: 'fixtureuser',
        resource: BookmarkContext.resourceBoardPins,
        requestOptions:
            PinterestResourceOptions.boardPins(boardId: '111111111111111111'),
        extractionMode: 'pins',
        maxPages: 3,
        bookmark: 'board-cursor-token',
      );
      final restored = BookmarkContext.tryParse(ctx.toJson());
      expect(restored, isNotNull);
      expect(restored!.matches(ctx), isTrue,
          reason: 'canonical-JSON comparison must survive a persist round-trip');
      expect(restored.bookmark, 'board-cursor-token');
    });

    test('REUSE only on full match — mismatch matrix rejects', () {
      final stored = BookmarkContext(
        username: 'fixtureuser',
        resource: BookmarkContext.resourceBoardPins,
        requestOptions:
            PinterestResourceOptions.boardPins(boardId: '111111111111111111'),
        extractionMode: 'pins',
        maxPages: 3,
        bookmark: 'board-cursor-token',
      );
      bool reuse(BookmarkContext fresh) => stored.matches(fresh);

      // Different board → reject (scope inside options).
      expect(
        reuse(_freshCtx(boardId: '999999999999999999')),
        isFalse,
        reason: 'a bookmark from board A is meaningless for board B',
      );
      // Different resource kind → reject.
      expect(
        stored.matches(_freshCtx(
            resource: BookmarkContext.resourceBoardSectionPins)),
        isFalse,
      );
      // Board vs user-pins resource → reject.
      expect(
        stored.matches(_freshCtx(resource: BookmarkContext.resourceUserPins)),
        isFalse,
      );
      // Different section → reject.
      expect(
        stored.matches(_freshCtx(
            resource: BookmarkContext.resourceBoardSectionPins,
            options:
                PinterestResourceOptions.boardSectionPins(sectionId: 'other'))),
        isFalse,
      );
      // Different maxPages → reject.
      expect(reuse(_freshCtx(maxPages: 9)), isFalse);
      // Different username (case-sensitive value, case-insensitive compare)
      // → reject for a different user.
      expect(reuse(_freshCtx(username: 'someoneelse')), isFalse);
    });

    test('same user different letter case MATCHES (session-cache convention)',
        () {
      final stored = BookmarkContext(
        username: 'FixtureUser',
        resource: BookmarkContext.resourceBoardPins,
        requestOptions:
            PinterestResourceOptions.boardPins(boardId: '111111111111111111'),
        extractionMode: 'pins',
        maxPages: 3,
        bookmark: 'board-cursor-token',
      );
      expect(
        stored.matches(_freshCtx(username: 'fixtureuser')),
        isTrue,
      );
    });

    test('corrupt/foreign context JSON → null (no reuse, D-26 spirit)', () {
      expect(BookmarkContext.tryParse(null), isNull);
      expect(BookmarkContext.tryParse('garbage'), isNull);
      expect(BookmarkContext.tryParse({
        'username': 'fixtureuser',
        'resource': BookmarkContext.resourceBoardPins,
        // missing request_options / bookmarks
      }), isNull);
      expect(BookmarkContext.tryParse({
        'username': 'fixtureuser',
        'resource': BookmarkContext.resourceBoardPins,
        'request_options': {'board_id': 'x'},
        'extraction_mode': 'pins',
        'max_pages': 3,
        'bookmarks': [], // empty → no cursor
      }), isNull);
    });

    test('natural end → no tuple (cap-exit-only contract holds for boards)',
        () async {
      final result = await _naturalEndBoardPinsRun();
      expect(result.nextBookmark, isNull);
      expect(result.bookmarkContext, isNull);
    });
  });
}

// ---------- helpers (scripted adapters, same pattern as board_fetch_test) --

BookmarkContext _freshCtx({
  String username = 'fixtureuser',
  String resource = BookmarkContext.resourceBoardPins,
  Map<String, dynamic>? options,
  String boardId = '111111111111111111',
  int maxPages = 3,
}) =>
    BookmarkContext(
      username: username,
      resource: resource,
      requestOptions: options ??
          PinterestResourceOptions.boardPins(boardId: boardId),
      extractionMode: 'pins',
      maxPages: maxPages,
      bookmark: 'any',
    );

Future<BoardPinsResult> _cappedBoardPinsRun() async {
  final adapter = _CapAdapter.scripts([
    _pinsEnvelope(
        bookmark: 'board-cursor-token',
        rows: [_gridItemPin(id: 'p1', video: false)]),
  ]);
  final controller = _controllerFor(adapter);
  return controller.fetchBoardPins(
    boardId: '111111111111111111',
    username: 'fixtureuser',
    boardSlug: 'fixture-board',
    maxPages: 1,
  );
}

Future<BoardPinsResult> _naturalEndBoardPinsRun() async {
  final adapter = _CapAdapter.scripts([
    _pinsEnvelope(bookmark: null, rows: [_gridItemPin(id: 'p1', video: false)]),
  ]);
  final controller = _controllerFor(adapter);
  return controller.fetchBoardPins(
    boardId: '111111111111111111',
    username: 'fixtureuser',
    boardSlug: 'fixture-board',
    maxPages: 3,
  );
}

BoardController _controllerFor(_CapAdapter adapter) =>
    BoardController(
      extractor: PinterestExtractorService(
          dio: Dio()..httpClientAdapter = adapter),
      log: const ControllerLog(
        init: _noop,
        fetch: _noop,
        parse: _noop,
        config: _noop,
        queue: _noop,
        complete: _noop,
      ),
    );

void _noop(String _) {}

Map<String, dynamic> _gridItemPin({required String id, required bool video}) => {
      'id': id,
      'title': 'pin $id',
      'created_at': 'Thu, 11 Dec 2025 04:04:36 +0000',
      'images': {
        'orig': {
          'url':
              'https://i.pinimg.com/originals/aa/bb/cc/aabbcc11223344556677889900112233.jpg',
          'width': 736,
          'height': 1104,
        }
      },
      'videos': [],
    };

Map<String, dynamic> _pinsEnvelope({
  required String? bookmark,
  required List<Map<String, dynamic>> rows,
}) =>
    {
      'resource_response': {
        'status': 'success',
        'code': 0,
        'data': rows,
        'bookmark': bookmark,
      }
    };

class _CapAdapter implements HttpClientAdapter {
  _CapAdapter.scripts(this.scripts);

  final List<Map<String, dynamic>> scripts;
  int served = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path.startsWith('/resource/')) {
      final body = served < scripts.length
          ? scripts[served++]
          : _pinsEnvelope(bookmark: null, rows: []);
      return ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    return ResponseBody.fromString(
      '<html><head><script>'
      '{"appVersion": "d0f0e6b", "profile_cover":{"id":"999"}}'
      '</script></head><body></body></html>',
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}
