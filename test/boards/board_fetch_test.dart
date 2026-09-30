import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/exceptions/pinterest_exception.dart';
import 'package:pindl/data/controllers/board_controller.dart';
import 'package:pindl/data/controllers/extraction_controller.dart'
    show ControllerLog;
import 'package:pindl/data/models/pin_item.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';

import '../helpers/fixture_loader.dart';

void main() {
  group('board fetch via registry (Phase 09.3)', () {
    late PinterestExtractorService service;
    late _BoardAdapter adapter;
    late BoardController controller;
    final logs = <String>[];

    setUp(() {
      logs.clear();
      adapter = _BoardAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      service = PinterestExtractorService(dio: dio);
      controller = BoardController(
        extractor: service,
        log: ControllerLog(
          init: logs.add,
          fetch: logs.add,
          parse: logs.add,
          config: logs.add,
          queue: logs.add,
          complete: logs.add,
        ),
      );
    });

    test('fetchBoards parses FIXTURE rows; wire options are probe-validated',
        () async {
      final result = await controller.fetchBoards(
        userId: '111222333444555666',
        username: 'fixtureuser',
      );
      expect(result.items.length, 2);
      expect(result.items.first.boardId, '111111111111111111');
      expect(result.items.first.slug, 'fixture-board');
      expect(result.nextBookmark, isNull); // natural end
      expect(adapter.lastBoardsOptions, {
        'user_id': '111222333444555666',
        'username': 'fixtureuser',
        'field_set_key': 'profile_grid_item',
        'fetch_board_owner': true,
      });
      expect(adapter.lastPwsHandler, 'www/[username].js');
      expect(adapter.lastSourceUrl, '/fixtureuser/');
    });

    test('fetchBoards paginates, dedupes by boardId, first occurrence wins',
        () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: 'bm-2', rows: [
          _boardRow(id: '111', slug: 'one'),
          _boardRow(id: '222', slug: 'two'),
        ]),
        _boardsEnvelope(bookmark: 'bm-3', rows: [
          _boardRow(id: '222', slug: 'two'), // duplicate
          _boardRow(id: '333', slug: 'three'),
        ]),
        _boardsEnvelope(bookmark: null, rows: [
          _boardRow(id: '444', slug: 'four'),
        ]),
      ];
      final result = await controller.fetchBoards(
        userId: 'u',
        username: 'fixtureuser',
        maxPages: 5,
      );
      expect(result.items.map((b) => b.boardId).toList(),
          ['111', '222', '333', '444']);
      expect(result.nextBookmark, isNull);
      expect(adapter.boardFetches, 3, reason: 'follows bookmarks to natural end');
    });

    test('cap exit: maxPages=1 with a next bookmark → cursor returned', () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: 'bm-2',
            rows: [_boardRow(id: '111', slug: 'one')]),
      ];
      final result = await controller.fetchBoards(
        userId: 'u',
        username: 'fixtureuser',
        maxPages: 1,
      );
      expect(result.items, hasLength(1));
      expect(result.nextBookmark, 'bm-2');
    });

    test('natural end at exactly the cap → NO cursor (DISC-21 rule)', () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: null,
            rows: [_boardRow(id: '111', slug: 'one')]),
      ];
      final result = await controller.fetchBoards(
        userId: 'u',
        username: 'fixtureuser',
        maxPages: 1,
      );
      expect(result.nextBookmark, isNull);
    });

    test('bookmark sent on page 2+ only (user-pins convention)', () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: 'bm-2',
            rows: [_boardRow(id: '111', slug: 'one')]),
        _boardsEnvelope(bookmark: null,
            rows: [_boardRow(id: '222', slug: 'two')]),
      ];
      await controller.fetchBoards(
          userId: 'u', username: 'fixtureuser', maxPages: 5);
      expect(adapter.boardsBookmarks, [null, 'bm-2']);
    });

    test('failed page mid-feed returns rows fetched so far', () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: 'bm-2',
            rows: [_boardRow(id: '111', slug: 'one')]),
        _badStatusEnvelope(),
        _boardsEnvelope(bookmark: null,
            rows: [_boardRow(id: '999', slug: 'x')]),
      ];
      final result = await controller.fetchBoards(
        userId: 'u',
        username: 'fixtureuser',
        maxPages: 5,
      );
      expect(result.items.map((b) => b.boardId).toList(), ['111']);
      expect(result.nextBookmark, isNull, reason: 'failure is not a cap exit');
      expect(adapter.boardFetches, 2, reason: 'loop stops at the failed page');
    });

    test('rows without identity are skipped (tolerant reader)', () async {
      adapter.scriptBoards = [
        _boardsEnvelope(bookmark: null, rows: [
          {'name': 'no id here'},
          _boardRow(id: '111', slug: 'one'),
        ]),
      ];
      final result = await controller.fetchBoards(
        userId: 'u',
        username: 'fixtureuser',
      );
      expect(result.items.map((b) => b.boardId).toList(), ['111']);
    });

    test('fetchBoardSections parses FIXTURE rows incl. parent board id',
        () async {
      final result = await controller.fetchBoardSections(
        boardId: '111111111111111111',
        username: 'fixtureuser',
        boardSlug: 'fixture-board',
      );
      expect(result.items.length, 2);
      expect(result.items.first.sectionId, '333333333333333333');
      expect(result.items.first.boardId, '111111111111111111');
      expect(adapter.lastSectionOptions, {
        'board_id': '111111111111111111',
        'field_set_key': 'board_section_grid_item',
      });
      expect(adapter.lastPwsHandler, 'www/board/[slug].js');
      expect(adapter.lastSourceUrl, '/fixtureuser/fixture-board/');
    });

    test('fetchSectionPins parses grid_item rows through the UNCHANGED pipeline',
        () async {
      adapter.scriptSectionPins = [
        _pinsEnvelope(bookmark: null, rows: [
          _gridItemPin(id: 'p1', video: false),
          _gridItemPin(id: 'p2', video: true),
        ]),
      ];
      final result = await controller.fetchSectionPins(
        sectionId: '333333333333333333',
        username: 'fixtureuser',
        boardSlug: 'fixture-board',
      );
      expect(result.pins.length, 2);
      expect(result.nextBookmark, isNull);
      final video = result.pins.firstWhere((p) => p.pinId == 'p2');
      expect(video.hasVideo, isTrue);
      expect(adapter.lastSecPinsOptions, {
        'section_id': '333333333333333333',
        'field_set_key': 'grid_item',
        'redux_normalize_feed': true,
      });
    });

    test('board pins dedupe across pages', () async {
      adapter.scriptBoardPins = [
        _pinsEnvelope(bookmark: 'pbm-2', rows: [
          _gridItemPin(id: 'p1', video: false),
          _gridItemPin(id: 'dup', video: false),
        ]),
        _pinsEnvelope(bookmark: null, rows: [
          _gridItemPin(id: 'dup', video: false),
          _gridItemPin(id: 'p2', video: false),
        ]),
      ];
      final result = await controller.fetchBoardPins(
        boardId: '111111111111111111',
        username: 'fixtureuser',
        boardSlug: 'fixture-board',
        maxPages: 5,
      );
      expect(result.pins.map((p) => p.pinId).toList(), ['p1', 'dup', 'p2']);
      expect(result.nextBookmark, isNull, reason: 'natural end');
      expect(adapter.lastBoardPinsOptions,
          containsPair('board_id', '111111111111111111'));
      expect(adapter.lastBoardPinsOptions, containsPair('page_size', 25));
    });

    test('pin rows produce IDENTICAL results as direct user-pins parsing',
        () async {
      // Pipeline-reuse equivalence (contract 09.3 DoD): the same row parsed
      // via the board feed and via PinItem.fromUserPinJson directly is equal.
      final row = _gridItemPin(id: 'p9', video: true);
      adapter.scriptBoardPins = [
        _pinsEnvelope(bookmark: null, rows: [row]),
      ];
      final viaBoard = await controller.fetchBoardPins(
        boardId: 'b',
        username: 'fixtureuser',
        boardSlug: 'fixture-board',
      );
      final direct = PinItem.fromUserPinJson(row);
      expect(viaBoard.pins.single, direct);
    });

    test('empty first page → empty result, natural end (no crash)', () async {
      adapter.scriptSectionPins = [
        _pinsEnvelope(bookmark: null, rows: []),
      ];
      final result = await controller.fetchSectionPins(
        sectionId: 's',
        username: 'fixtureuser',
        boardSlug: 'fixture-board',
      );
      expect(result.pins, isEmpty);
      expect(result.nextBookmark, isNull);
    });

    test('cancel propagates as CancelledException', () async {
      final token = CancelToken();
      token.cancel('user');
      await expectLater(
        controller.fetchSectionPins(
          sectionId: 's',
          username: 'fixtureuser',
          boardSlug: 'fixture-board',
          cancelToken: token,
        ),
        throwsA(isA<CancelledException>()),
      );
    });
  });
}

// ---------- helpers ----------

Map<String, dynamic> _boardRow({required String id, required String slug}) => {
      'id': id,
      'url': '/fixtureuser/$slug/',
      'name': 'Board $slug',
      'pin_count': 3,
      'section_count': 0,
      'image_cover_url':
          'https://i.pinimg.com/236x/aa/bb/cc/aabbcc11223344556677889900112233.jpg',
    };

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
      'videos': video
          ? {
              'video_list': {
                'V_720P': {
                  'url':
                      'https://v1.pinimg.com/videos/mc/720p/aa/bb/cc/abc123.mp4',
                  'thumbnail':
                      'https://i.pinimg.com/videos/thumbnails/abc123.jpg',
                  'width': 1280,
                  'height': 720,
                }
              }
            }
          : [],
    };

Map<String, dynamic> _boardsEnvelope({
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

Map<String, dynamic> _badStatusEnvelope() => {
      'resource_response': {
        'status': 'error',
        'code': 1,
        'message': 'fixture failure',
        'data': [],
      }
    };

/// Scripted adapter: serves the /fixtureuser profile page (config) plus
/// per-resource scripted envelopes; FIXTURES back the default (scripted)
/// envelopes so wire shapes equal committed fixture shapes.
class _BoardAdapter implements HttpClientAdapter {
  List<Map<String, dynamic>> scriptBoards = [];
  List<Map<String, dynamic>> scriptSections = [];
  List<Map<String, dynamic>> scriptSectionPins = [];
  List<Map<String, dynamic>> scriptBoardPins = [];

  int boardFetches = 0;
  final List<String?> boardsBookmarks = [];
  Map<String, dynamic>? lastBoardsOptions;
  Map<String, dynamic>? lastSectionOptions;
  Map<String, dynamic>? lastSecPinsOptions;
  Map<String, dynamic>? lastBoardPinsOptions;
  String? lastPwsHandler;
  String? lastSourceUrl;

  Map<String, dynamic> _defaultFor(String path) {
    if (path == '/resource/BoardsResource/get/') {
      return Fixtures.boardsPage1();
    }
    if (path == '/resource/BoardSectionsResource/get/') {
      return Fixtures.boardSectionsPage1();
    }
    return _pinsEnvelope(bookmark: null, rows: []);
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPwsHandler = options.headers['x-pinterest-pws-handler'] as String?;
    lastSourceUrl = options.headers['x-pinterest-source-url'] as String?;

    final path = options.uri.path;
    Map<String, dynamic>? options_;
    if (path.startsWith('/resource/')) {
      final raw = options.uri.queryParameters['data']!;
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      options_ = envelope['options'] as Map<String, dynamic>;
    }

    if (path == '/resource/BoardsResource/get/') {
      lastBoardsOptions = options_;
      boardsBookmarks
          .add((options_!['bookmarks'] as List?)?.first as String?);
      boardFetches++;
      return _serve(scriptBoards.isNotEmpty
          ? scriptBoards.removeAt(0)
          : Fixtures.boardsPage1());
    }
    if (path == '/resource/BoardSectionsResource/get/') {
      lastSectionOptions = options_;
      return _serve(scriptSections.isNotEmpty
          ? scriptSections.removeAt(0)
          : Fixtures.boardSectionsPage1());
    }
    if (path == '/resource/BoardSectionPinsResource/get/') {
      lastSecPinsOptions = options_;
      return _serve(scriptSectionPins.isNotEmpty
          ? scriptSectionPins.removeAt(0)
          : _pinsEnvelope(bookmark: null, rows: []));
    }
    if (path == '/resource/BoardFeedResource/get/') {
      lastBoardPinsOptions = options_;
      return _serve(scriptBoardPins.isNotEmpty
          ? scriptBoardPins.removeAt(0)
          : _pinsEnvelope(bookmark: null, rows: []));
    }

    // profile page → config (userId + appVersion)
    return ResponseBody.fromString(
      '<html><head><script>'
      '{"appVersion": "d0f0e6b", "profile_cover":{"id":"999"}}'
      '</script></head><body></body></html>',
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }

  ResponseBody _serve(Map<String, dynamic> body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
}
