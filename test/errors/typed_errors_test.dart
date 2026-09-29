import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/exceptions/pinterest_exception.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';
import 'package:pindl/presentation/utils/error_messages.dart';

import '../helpers/fixture_loader.dart';

/// Phase 03 — typed extraction errors (PIN-1 / extraction plan 01) + UI
/// mapping (ui-ux/02). Gate G4: PinNotFound reachable as a typed error with
/// a user-facing label.
void main() {
  const pinId = '999888777666555444333222111000987654321';

  group('parser classification (sealed outcome)', () {
    test('PinNotFound fixture classifies as pinNotFound', () {
      final outcome = PinterestParser.parseMediaDataOrNull(Fixtures.pinNotFound(), pinId);
      expect(outcome.isPinNotFound, isTrue);
      expect(outcome.isSourceChanged, isFalse);
      expect(outcome.result, isNull);
    });

    test('no relay payload classifies as sourceChanged', () {
      final outcome = PinterestParser.parseMediaDataOrNull(
          '<html><body>no relay here</body></html>', pinId);
      expect(outcome.isSourceChanged, isTrue);
      expect(outcome.result, isNull);
    });

    test('image fixture classifies as success', () {
      final outcome = PinterestParser.parseMediaDataOrNull(Fixtures.pinImage(), pinId);
      expect(outcome.result, isNotNull);
      expect(outcome.isPinNotFound, isFalse);
      expect(outcome.isSourceChanged, isFalse);
    });

    test('stub-only (media-less record) stays a null result — neither NotFound nor Changed', () {
      final outcome = PinterestParser.parseMediaDataOrNull(Fixtures.pinStubOnly(), pinId);
      expect(outcome.result, isNull);
      expect(outcome.isPinNotFound, isFalse);
      expect(outcome.isSourceChanged, isFalse);
    });
  });

  group('UI mapping (ui-ux/02)', () {
    test('PinNotFound maps to the specific actionable copy', () {
      expect(
        userMessage(PinNotFoundException('Pin not found: x', code: 'E_PIN_NOT_FOUND')),
        "This pin was deleted or doesn't exist",
      );
    });

    test('NoMedia maps to its copy', () {
      expect(userMessage(NoMediaException('none', code: 'E_NO_MEDIA')),
          'No downloadable media found');
    });

    test('SourceChanged maps to update-needed copy', () {
      expect(userMessage(SourceChangedException('relay missing', code: 'E_NO_DATA')),
          "Pinterest's page structure changed — try updating the app");
    });

    test('network errors map per status', () {
      expect(userMessage(NetworkException('x', statusCode: 404)), contains('404'));
      expect(userMessage(NetworkException('x', statusCode: 429)), contains('429'));
      expect(userMessage(NetworkException('x', statusCode: 503)), contains('50'));
      expect(userMessage(NetworkException('x')), contains('Network'));
    });

    test('validation-failure DownloadExceptions map to honest copy', () {
      expect(
        userMessage(DownloadException('validation failed: downloaded content is a document, not media')),
        'Downloaded content was a web page, not media',
      );
      expect(userMessage(DownloadException('unexpected media host: evilpinimg.com')),
          'Blocked download from an unexpected host');
    });

    test('no raw exception internals leak through the mapping (lint-style)', () {
      final samples = <Object>[
        PinNotFoundException('Pin not found: 123'),
        NoMediaException('none'),
        SourceChangedException('payload gone'),
        ParseException('parse boom'),
        NetworkException('DioException connection refused', statusCode: 500),
        DownloadException('validation failed: undersized content (10 B < 256 B)'),
        ValidationException('Invalid pin ID or URL: garbage'),
        ExtractionException('Empty response from profile page'),
        StateError('Unexpected internal state'),
      ];
      for (final s in samples) {
        final msg = userMessage(s);
        expect(msg.contains('Exception:'), isFalse, reason: '$s leaked exception marker');
        expect(msg.contains('DioException'), isFalse, reason: '$s leaked DioException');
        expect(msg.length, lessThan(120), reason: 'user copy must stay short');
      }
    });

    test('unknown error falls back to generic copy with console pointer', () {
      expect(userMessage(StateError('boom')), 'Something went wrong — see console for details');
    });
  });
}
