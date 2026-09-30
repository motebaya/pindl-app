import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';

/// Phase 07 (07.2) — feed dedupe (gate G5, JS dedupeById port).
///
/// Pinterest bookmark overlap can repeat rows across pages; first occurrence
/// must win, in page order. Fully offline: static adapter, deterministic pages.
void main() {
  group('feed dedupe (gate G5)', () {
    test('duplicate pin across pages appears once; unique pins preserved',
        () async {
      final adapter = _DedupAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = PinterestExtractorService(dio: dio, verbose: true);

      final result = await service.getUserPins(username: 'dedupuser');

      // Adapter serves 3 pages: [p1, p2], [p2, p3], [p3, p4] — p2 and p3
      // repeat across page boundaries.
      final ids = result.pins.map((p) => p.pinId).toList();
      expect(ids, ['p1', 'p2', 'p3', 'p4'],
          reason: 'duplicates dropped, first occurrence order kept');
    });
  });
}

class _DedupAdapter implements HttpClientAdapter {
  final List<String> profileFetches = [];
  int page = 0;

  Map<String, dynamic> _pin(String id) => {
        'id': id,
        'title': 'pin $id',
        'images': {
          'orig': {'url': 'https://i.pinimg.com/originals/$id.jpg'}
        },
        'native_creator': {
          'username': 'dedupuser',
          'full_name': 'Dedup User',
          'id': '999',
        },
      };

  Map<String, dynamic> _page(int index, List<String> ids, String? bookmark) => {
        'resource_response': {
          'status': 'success',
          'data': [for (final id in ids) _pin(id)],
          'bookmark': bookmark,
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
      final pages = [
        _page(1, ['p1', 'p2'], 'bm-2'),
        _page(2, ['p2', 'p3'], 'bm-3'),
        _page(3, ['p3', 'p4'], null),
      ];
      final body = pages[page.clamp(0, pages.length - 1)];
      page++;
      return ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    final username = path.substring(1);
    profileFetches.add(username);
    return ResponseBody.fromString(
      '<html><head><script>'
      '{"appVersion": "d0f0e6b", "profile_cover":{"id":"999"}}'
      '</script></head><body></body></html>',
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}
