import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';

/// Phase 07 (07.5) — bookmark persistence + provenance (gates G4 + cap DoD).
///
/// D-34 invariant under test: a stored bookmark is reusable ONLY on full
/// context match; the bookmark is returned ONLY on a cap exit (never on a
/// natural end, even at the same page number). Fully offline (static adapter).
void main() {
  group('cap-reached semantics (07.5 DoD)', () {
    test('cap exit returns the pending bookmark', () async {
      final adapter = _PagerAdapter(totalPages: 5, maxPagesServed: 3);
      final service = _service(adapter);
      final result = await service.getUserPins(username: 'capuser', maxPages: 3);
      expect(result.bookmark, isNotNull,
          reason: 'cap exit must retain the continuation cursor');
      expect(result.pins.map((p) => p.pinId), ['p1', 'p2', 'p3']);
    });

    test('natural end at the same page count returns NO bookmark', () async {
      final adapter = _PagerAdapter(totalPages: 3, maxPagesServed: 3);
      final service = _service(adapter);
      final result = await service.getUserPins(username: 'enduser', maxPages: 3);
      expect(result.bookmark, isNull,
          reason: 'feed exhausted — nothing to continue (stale-token guard)');
      expect(result.pins.map((p) => p.pinId), ['p1', 'p2', 'p3']);
    });

    test('resume run (bookmark passed in) can itself end capped', () async {
      final adapter = _PagerAdapter(totalPages: 9, maxPagesServed: 3);
      final service = _service(adapter);
      final first = await service.getUserPins(username: 'longuser', maxPages: 3);
      expect(first.bookmark, isNotNull);
      final second = await service.getUserPins(
          username: 'longuser', bookmark: first.bookmark, maxPages: 3);
      expect(second.bookmark, isNotNull);
      expect(second.pins.map((p) => p.pinId).first, 'p4',
          reason: 'continuation starts at the cursor page');
    });

    test('canonicalRequestOptions mirrors the wire payload options', () async {
      final adapter = _PagerAdapter(totalPages: 1, maxPagesServed: 1);
      final service = _service(adapter);
      await service.getUserPins(username: 'optsuser', maxPages: 1);
      final opts = service.canonicalRequestOptions('optsuser');
      expect(opts['username'], 'optsuser');
      expect(opts['field_set_key'], 'grid_item');
      expect(opts.containsKey('bookmarks'), isFalse,
          reason: 'bookmarks ride per-page, context stores the token itself');
      // What the service would send next matches what the context would store.
      expect(adapter.lastResourceOptions, isNotNull);
      for (final key in adapter.lastResourceOptions!.keys) {
        if (key == 'bookmarks') continue;
        expect(opts[key], adapter.lastResourceOptions![key],
            reason: 'option $key must be identical to the wire payload');
      }
    });
  });

  group('BookmarkContext provenance (gate G4)', () {
    final options = <String, dynamic>{
      'exclude_add_pin_rep': true,
      'field_set_key': 'grid_item',
      'user_id': '111',
      'username': 'usera',
    };

    BookmarkContext ctx({
      String username = 'usera',
      String resource = BookmarkContext.resourceUserPins,
      Map<String, dynamic>? requestOptions,
      String mode = 'image',
      int maxPages = 50,
      String bookmark = 'bm-1',
    }) =>
        BookmarkContext(
          username: username,
          resource: resource,
          requestOptions: requestOptions ?? options,
          extractionMode: mode,
          maxPages: maxPages,
          bookmark: bookmark,
        );

    test('full match reuses', () {
      expect(ctx().matches(ctx()), isTrue);
    });

    test('username mismatch never reuses (case-insensitive compare)', () {
      expect(ctx().matches(ctx(username: 'userb')), isFalse);
      expect(ctx().matches(ctx(username: 'USERA')), isTrue);
    });

    test('resource mismatch never reuses', () {
      expect(ctx().matches(ctx(resource: 'board_pins')), isFalse);
    });

    test('extraction mode mismatch never reuses', () {
      expect(ctx().matches(ctx(mode: 'video')), isFalse);
    });

    test('max_pages mismatch never reuses', () {
      expect(ctx().matches(ctx(maxPages: 25)), isFalse);
    });

    test('request options mismatch never reuses (user drift)', () {
      expect(ctx().matches(ctx(requestOptions: {...options, 'user_id': '222'})),
          isFalse);
    });

    test('options compared canonical (map order irrelevant)', () {
      final reordered = <String, dynamic>{
        'username': 'usera',
        'user_id': '111',
        'field_set_key': 'grid_item',
        'exclude_add_pin_rep': true,
      };
      expect(ctx().matches(ctx(requestOptions: reordered)), isTrue);
    });
  });

  group('metadata round-trip (07.5 DoD)', () {
    test('next_bookmark + context survive a writer/reader cycle', () {
      final ctx = BookmarkContext(
        username: 'usera',
        resource: BookmarkContext.resourceUserPins,
        requestOptions: {'username': 'usera', 'user_id': '111'},
        extractionMode: 'image',
        maxPages: 50,
        bookmark: 'bm-token-1',
      );
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'usera', name: 'A', userId: '111'),
        pins: const [],
        completedIndices: {0, 1},
        totalImages: 2,
        totalVideos: 0,
        successDownloaded: 2,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: 'image',
        nextBookmark: 'bm-token-1',
        bookmarkContext: ctx,
      );
      final read = MetadataReader.read(json);
      expect(read.nextBookmark, 'bm-token-1');
      expect(read.bookmarkContext, isNotNull);
      expect(read.bookmarkContext!.username, 'usera');
      expect(read.bookmarkContext!.bookmark, 'bm-token-1');
      expect(read.bookmarkContext!.matches(ctx), isTrue);
    });

    test('next_bookmark WITHOUT a parsable context is ignored (D-34)', () {
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: const [],
        completedIndices: const {},
        totalImages: 0,
        totalVideos: 0,
        successDownloaded: 0,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      json['next_bookmark'] = 'orphan-token';
      json['bookmark_context'] = {'malformed': true};
      final read = MetadataReader.read(json);
      expect(read.nextBookmark, isNull,
          reason: 'the pair travels together or not at all (D-34)');
      expect(read.bookmarkContext, isNull);
    });

    test('corrupt context never throws — safe no-reuse', () {
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: const [],
        completedIndices: const {},
        totalImages: 0,
        totalVideos: 0,
        successDownloaded: 0,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      json['next_bookmark'] = 'tok';
      json['bookmark_context'] = {
        'username': 'u',
        'resource': 'user_pins',
        'request_options': 'not-a-map',
        'extraction_mode': 'image',
        'max_pages': 'fifty',
        'bookmarks': [],
      };
      final read = MetadataReader.read(json);
      expect(read.nextBookmark, isNull);
      expect(read.bookmarkContext, isNull);
    });
  });
}

PinterestExtractorService _service(_PagerAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return PinterestExtractorService(dio: dio, verbose: false);
}

/// Static adapter serving `totalPages` pages of one-pin responses; keeps
/// serving its LAST page beyond exhaustion (so a natural-end run sees
/// bookmark=null on its final page) and records the last resource options.
class _PagerAdapter implements HttpClientAdapter {
  _PagerAdapter({required this.totalPages, required this.maxPagesServed});

  final int totalPages;
  final int maxPagesServed;
  Map<String, dynamic>? lastResourceOptions;

  Map<String, dynamic> _pin(int n) => {
        'id': 'p$n',
        'title': 'pin $n',
        'images': {
          'orig': {'url': 'https://i.pinimg.com/originals/p$n.jpg'}
        },
        'native_creator': {
          'username': 'user',
          'full_name': 'User',
          'id': '999',
        },
      };

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
      final dataParam = options.uri.queryParameters['data'];
      final decoded = jsonDecode(dataParam!) as Map<String, dynamic>;
      lastResourceOptions =
          (decoded['options'] as Map<String, dynamic>? ?? {})
            ..remove('bookmarks');
      final pageIdx = servedPages;
      servedPages++;
      final isLast = pageIdx >= totalPages - 1;
      final body = {
        'resource_response': {
          'status': 'success',
          'data': [_pin(pageIdx + 1)],
          'bookmark': isLast ? null : 'bm-${pageIdx + 2}',
        },
      };
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

  int servedPages = 0;
  int get maxPages => maxPagesServed;
}
