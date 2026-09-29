import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/services/pinterest_extractor_service.dart';

/// Phase 03 03.1 — PAR-X1 session reset fix (plan extraction/04, option 2:
/// the service owns its cache invariant).
///
/// Gate G1 DoD: extraction for user A then user B in one session must fetch
/// B's config with B's identity; the feed returned is B's. Same-username
/// re-extraction must NOT refetch (perf invariant).
///
/// Fully offline: static Dio adapter, no sockets.
void main() {
  group('session config cache (PAR-X1)', () {
    test('A→A cache hit; A→B refetch with B identity; feed follows identity', () async {
      final adapter = _SessionAdapter({
        'usera': '111',
        'userb': '222',
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final service = PinterestExtractorService(dio: dio, verbose: true);

      // 1st A: profile fetched once.
      final r1 = await service.getUserPins(username: 'usera');
      expect(r1.author.userId, '111');

      // 2nd A: cache hit — no new profile fetch (perf invariant).
      final r2 = await service.getUserPins(username: 'usera');
      expect(r2.author.userId, '111');
      expect(adapter.profileFetches, ['usera']);

      // 3rd B (the PAR-X1 bug): config refetched for B; resource carries
      // B's userId; feed is B's.
      final r3 = await service.getUserPins(username: 'userb');
      expect(adapter.profileFetches, ['usera', 'userb']); // refetch happened
      expect(r3.author.userId, '222'); // feed is B's
      expect(
        adapter.resourceIdentities.last,
        {'username': 'userb', 'user_id': '222'},
        reason: 'resource payload must carry B identity after switch',
      );

      // 4th B: cache hit again.
      await service.getUserPins(username: 'userb');
      expect(adapter.profileFetches, ['usera', 'userb']);

      // 5th A: switching back refetches A.
      final r5 = await service.getUserPins(username: 'usera');
      expect(adapter.profileFetches, ['usera', 'userb', 'usera']);
      expect(r5.author.userId, '111');

      // Every resource request carried the identity matching its username.
      for (final id in adapter.resourceIdentities) {
        expect(id['user_id'], adapter.identities[id['username']]);
      }
    });
  });
}

/// Static adapter: serves per-username profile HTML and a one-pin resource
/// response whose native_creator identity matches the requesting username.
class _SessionAdapter implements HttpClientAdapter {
  _SessionAdapter(this.identities);

  final Map<String, String> identities;
  final List<String> profileFetches = [];
  final List<Map<String, String>> resourceIdentities = [];

  String _profileHtml(String userId) {
    return '<html><head><script>'
        '{"appVersion": "d0f0e6b", "profile_cover":{"id":"$userId"}}'
        '</script></head><body></body></html>';
  }

  String _pinsJson(String username, String userId) {
    return jsonEncode({
      'resource_response': {
        'status': 'success',
        'data': [
          {
            'id': 'p1_$username',
            'title': 'pin of $username',
            'native_creator': {
              'username': username,
              'full_name': 'User $userId',
              'id': userId,
            },
          },
        ],
        'bookmark': null,
      },
    });
  }

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
      // uri.queryParameters is DECODED (options.queryParameters keeps the
      // raw encoded string when the URL was passed pre-built).
      final dataParam = options.uri.queryParameters['data'];
      final decoded = jsonDecode(dataParam!) as Map<String, dynamic>;
      final opts = decoded['options'] as Map<String, dynamic>;
      final username = opts['username'] as String;
      final userId = identities[username]!;
      resourceIdentities.add({'username': username, 'user_id': opts['user_id'] as String});
      return ResponseBody.fromString(
        _pinsJson(username, userId),
        200,
        headers: {Headers.contentTypeHeader: ['application/json']},
      );
    }
    // Profile page: path is '/<username>'
    final username = path.substring(1);
    profileFetches.add(username);
    return ResponseBody.fromString(
      _profileHtml(identities[username]!),
      200,
      headers: {Headers.contentTypeHeader: ['text/html']},
    );
  }
}
