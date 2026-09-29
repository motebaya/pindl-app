import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/validation/media_validator.dart';

/// Phase 03 — fail-closed content validation matrix (DL-2/SEC-4), gate G2.
/// Table-driven per downloader/02 plan (port of JS validate.js table).
void main() {
  Uint8List head(List<int> bytes) => Uint8List.fromList(bytes);

  group('MagicBytes.detect', () {
    test('JPEG signature', () {
      expect(MagicBytes.detect(head([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), 'image');
    });
    test('PNG signature', () {
      expect(
          MagicBytes.detect(head([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0])), 'image');
    });
    test('GIF signature', () {
      expect(MagicBytes.detect(head([0x47, 0x49, 0x46, 0x38, 0, 0, 0, 0, 0, 0, 0, 0, 0])), 'image');
    });
    test('WEBP (RIFF+WEBP) signature', () {
      expect(
          MagicBytes.detect(head(
              [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0])),
          'image');
    });
    test('BMP signature', () {
      expect(MagicBytes.detect(head([0x42, 0x4D, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), 'image');
    });
    test('WEBM (EBML) signature', () {
      expect(
          MagicBytes.detect(head([0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0, 0, 0, 0, 0, 0])), 'video');
    });
    test('MP4 (ISO-BMFF ftyp) signature', () {
      expect(
          MagicBytes.detect(head([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0, 0])),
          'video');
    });
    test('HTML text is unknown', () {
      expect(MagicBytes.detect(head('<html><body>hi</body></html>'.codeUnits)), isNull);
    });
    test('too-short head is unknown (not a crash)', () {
      expect(MagicBytes.detect(head([0xFF, 0xD8])), isNull);
    });
  });

  group('ResponseHeaderGuard', () {
    test('non-200 rejected', () {
      final r = ResponseHeaderGuard.check(statusCode: 404);
      expect(r.ok, isFalse);
      expect(r.reason, contains('non-200'));
    });
    test('zero content-length rejected', () {
      expect(ResponseHeaderGuard.check(statusCode: 200, contentLength: 0).ok, isFalse);
    });
    test('document content-types rejected', () {
      for (final ct in ['text/html', 'text/xml', 'text/plain', 'application/xml']) {
        final r = ResponseHeaderGuard.check(statusCode: 200, contentType: ct);
        expect(r.ok, isFalse, reason: ct);
        expect(r.reason, contains('document'));
      }
    });
  });

  group('validateDownloaded — fail-closed matrix', () {
    test('valid JPEG passes for image expectation', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(400, 0)]),
        size: 4096,
        expect: MediaExpectation.image,
      );
      expect(r.ok, isTrue);
    });

    test('valid MP4 passes for video expectation', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0, ...List<int>.filled(300, 0)]),
        size: 4096,
        expect: MediaExpectation.video,
      );
      expect(r.ok, isTrue);
    });

    test('HTML error page as media FAILS (the false-success killer)', () {
      final r = MediaValidator.validateDownloaded(
        head: head('<!DOCTYPE html><html><body>error</body></html>'.codeUnits),
        size: 4096,
        expect: MediaExpectation.image,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('document'));
    });

    test('undersized content fails at the 256 B floor', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]),
        size: 8,
        expect: MediaExpectation.image,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('undersized'));
    });

    test('wrong super-type fails: JPEG body expected as video', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(300, 0)]),
        size: 4096,
        expect: MediaExpectation.video,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('wrong content type'));
    });

    test('zero bytes rejected via header guard (content-length 0)', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0, 0, 0, 0]),
        size: 0,
        expect: MediaExpectation.image,
      );
      expect(r.ok, isFalse);
    });

    test('unknown signature: fail-closed for images', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        size: 4096,
        expect: MediaExpectation.image,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('unknown image signature'));
    });

    test('unknown signature: tolerated for videos (JS nuance, headers passed)', () {
      final r = MediaValidator.validateDownloaded(
        head: head([0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
        size: 4096,
        expect: MediaExpectation.video,
      );
      expect(r.ok, isTrue);
    });
  });
}
