import 'dart:io';
import 'dart:typed_data';

/// Fail-closed download content validation (DL-2 / SEC-4).
///
/// One implementation serves both download paths (`DownloadService`) and the
/// HLS conversion output (HLS-2). Ported from the JS reference
/// `core/downloader/validate.js`: header pre-check → magic-byte signature →
/// super-type match → minimum size → fail-closed for images / tolerant for
/// videos.
///
/// Ground truth is the byte signature — headers lie (SEC-3 × SEC-4).
/// Validation reads only the first 512 B + total size (no full-file scan).

/// Expected media super-type for a download.
enum MediaExpectation { image, video }

/// Result of validating one download.
class ValidationResult {
  final bool ok;
  final String? reason;

  const ValidationResult._(this.ok, this.reason);

  static const ValidationResult valid = ValidationResult._(true, null);
  const ValidationResult.invalid(String reason) : this._(false, reason);

  @override
  String toString() => ok ? 'valid' : 'invalid: $reason';
}

/// Header-level guard before any byte-level work (JS ResponseHeaderGuard).
class ResponseHeaderGuard {
  /// Content types that indicate a document, never media.
  static const List<String> _documentPrefixes = [
    'text/html',
    'text/xml',
    'text/plain',
    'application/xhtml',
    'application/xml',
  ];

  /// Pre-check headers for an expected [expect] media type.
  ///
  /// [contentType]/[contentLength] may be null (absent headers) — the
  /// signature check remains the ground truth; headers can only fail a
  /// download early, never pass one.
  static ValidationResult check({
    required int statusCode,
    String? contentType,
    int? contentLength,
    MediaExpectation? expect,
  }) {
    if (statusCode != 200) {
      return ValidationResult.invalid('non-200 status: $statusCode');
    }
    if (contentLength == 0) {
      return ValidationResult.invalid('zero content-length');
    }
    final ct = contentType?.toLowerCase();
    if (ct != null) {
      for (final doc in _documentPrefixes) {
        if (ct.startsWith(doc)) {
          return ValidationResult.invalid('document content-type: $ct');
        }
      }
      if (expect != null) {
        final want = expect == MediaExpectation.image ? 'image/' : 'video/';
        // Content-Type only REJECTS on obvious mismatch; CDN values vary
        // (e.g. application/octet-stream) and must not fail a good body.
        if (!ct.startsWith(want) && ct.startsWith('image/') || ct.startsWith('text/')) {
          if (!ct.startsWith(want)) {
            return ValidationResult.invalid('content-type $ct does not match expected ${expect.name}');
          }
        }
      }
    }
    return ValidationResult.valid;
  }
}

/// Byte-signature detection over the first bytes of a body/file.
class MagicBytes {
  static const int _jpegHead = 0xFFD8;
  static const int _pngHead = 0x89504E47;
  static const int _gifHead = 0x47494638; // 'GIF8'
  static const int _riffHead = 0x52494646; // 'RIFF'
  static const int _webpMark = 0x57454250; // 'WEBP'
  static const int _bmpHead = 0x424D; // 'BM'
  static const int _webmHead = 0x1A45DFA3;
  static const int _ftypOffset = 4;

  /// Detect the media super-type of a byte head, or null if unknown.
  static String? detect(Uint8List head) {
    if (head.length < 12) return null;
    if ((head[0] << 8) | head[1] == _jpegHead) return 'image';
    if (_readU32(head, 0) == _pngHead) return 'image';
    if (_readU32(head, 0) == _gifHead) return 'image';
    if (_readU32(head, 0) == _riffHead && _readU32(head, 8) == _webpMark) {
      return 'image';
    }
    if ((head[0] << 8) | head[1] == _bmpHead) return 'image';
    if (_readU32(head, 0) == _webmHead) return 'video';
    // ISO-BMFF container: bytes 4-8 == 'ftyp' (covers MP4/cmfv/MOV bases)
    if (_readU32(head, _ftypOffset) == 0x66747970) return 'video';
    return null;
  }

  static int _readU32(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];
}

/// Full fail-closed validation pipeline (JS validateDownloaded).
///
/// [head]   first bytes of the downloaded body (up to 512 B).
/// [size]   total downloaded size in bytes.
/// [contentType]/[statusCode] header context (early-reject only).
/// [expect] super-type requirement; unknown signatures fail images
///          immediately and are tolerated for videos only when headers
///          passed and the size floor is met (JS nuance, fail-closed
///          images / tolerant videos).
class MediaValidator {
  /// Default minimum size for any media (JS floor).
  static const int minBytes = 256;

  static const List<String> _documentPrefixes = [
    'text/html',
    'text/xml',
    'text/plain',
    'application/xhtml',
    'application/xml',
  ];

  static ValidationResult validateDownloaded({
    required Uint8List head,
    required int size,
    int statusCode = 200,
    String? contentType,
    MediaExpectation? expect,
  }) {
    final headerCheck = ResponseHeaderGuard.check(
      statusCode: statusCode,
      contentType: contentType,
      contentLength: size,
    );
    if (!headerCheck.ok) return headerCheck;

    if (size < minBytes) {
      return ValidationResult.invalid('undersized content ($size B < $minBytes B)');
    }

    final detected = MagicBytes.detect(head);

    // HTML pages disguised as media: signatures miss them, but their head
    // bytes are text — refuse explicitly with the diagnosable reason.
    if (detected == null && _looksLikeDocument(head)) {
      return ValidationResult.invalid('downloaded content is a document, not media');
    }

    if (detected != null) {
      if (expect != null && detected != expect.name) {
        return ValidationResult.invalid(
          'wrong content type: got $detected, expected ${expect.name}',
        );
      }
      return ValidationResult.valid;
    }

    // Unknown signature: fail-closed for images, tolerant for videos
    // (JS nuance — video containers vary; header guard already passed).
    if (expect == MediaExpectation.image) {
      return ValidationResult.invalid('unknown image signature');
    }
    return ValidationResult.valid;
  }

  /// Validate a finished file on disk (reads first 512 B only).
  static Future<ValidationResult> validateFile(
    String path, {
    int statusCode = 200,
    String? contentType,
    MediaExpectation? expect,
  }) async {
    final file = File(path);
    final size = await file.length();
    final raf = await file.open();
    try {
      final headBytes = await raf.read(512);
      return validateDownloaded(
        head: headBytes,
        size: size,
        statusCode: statusCode,
        contentType: contentType,
        expect: expect,
      );
    } finally {
      await raf.close();
    }
  }

  static bool _looksLikeDocument(Uint8List head) {
    for (final b in head) {
      if (b == 0) return false; // binary container, just unknown
    }
    final text = String.fromCharCodes(head).trimLeft().toLowerCase();
    for (final prefix in _documentPrefixes) {
      if (text.startsWith(prefix)) return true;
    }
    return text.startsWith('<!doctype') || text.startsWith('<html');
  }
}
