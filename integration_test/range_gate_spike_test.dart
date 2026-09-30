// G0 Range verification spike — Phase 06 hard gate (06.1).
//
// Contract: planning/phases/06-byte-level-resume.md — the gate requires
// DEVICE-verified evidence: requests must be issued by dio on the device
// network stack (emulator-5554), not by a host-side client.
//
// Evidence lines are prefixed EVIDENCE| and captured from the runner console
// into reports/phases/appendix/06-range-spike-evidence.txt.
//
// This is a one-shot evidence instrument: it is NOT part of the unit suite,
// never runs in CI, and must not be extended into a regression harness
// (local-HTTP matrix lives in test/ per workstream 06.3).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _userAgent = 'PinDL-RangeSpike/1.0 (Android; PinDL phase-06 G0)';

// Live CDN objects harvested from public pinterest.com pages on 2026-09-29
// (image: /originals/ PNG; video: /videos/ mp4). Both hosts are on the SEC-2
// allowlist; the spike only reads, never imports.
const _imageUrl =
    'https://i.pinimg.com/originals/d5/3b/01/d53b014d86a6b6761bf649a0ed813c2b.png';
const _videoUrl =
    'https://v1.pinimg.com/videos/iht/expMp4/13/22/fc/1322fc6cda00fa97bbd5822a7474dd93_720w.mp4';

Dio _dio() => Dio(BaseOptions(
      // Mirrors production DownloadService timeouts (30 s / 5 min); the spike
      // tightens receiveTimeout only to fail fast if a host stalls.
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {'User-Agent': _userAgent},
      // Never throw on status: the spike asserts statuses explicitly so a
      // 200-with-body or 416 is recorded, not crashed.
      validateStatus: (_) => true,
    ));

/// dio normalizes header lookups case-insensitively; value() is null when absent.
String? _header(Headers h, String name) => h.value(name);

/// Parsed Content-Range ("bytes 0-1023/44409"). Null for malformed/unknown (*).
class ContentRange {
  final int firstByte;
  final int lastByte;
  final int total;
  const ContentRange(this.firstByte, this.lastByte, this.total);
}

ContentRange? parseContentRange(String value) {
  final noPrefix = value.startsWith('bytes ') ? value.substring(6) : value;
  final slash = noPrefix.indexOf('/');
  if (slash < 0) return null;
  final rangePart = noPrefix.substring(0, slash);
  final totalPart = noPrefix.substring(slash + 1);
  final dash = rangePart.indexOf('-');
  if (dash < 0) return null;
  final first = int.tryParse(rangePart.substring(0, dash));
  final last = int.tryParse(rangePart.substring(dash + 1));
  final total = int.tryParse(totalPart);
  if (first == null || last == null || total == null) return null;
  return ContentRange(first, last, total);
}

void _ev(String msg) => debugPrint('EVIDENCE|$msg');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G0: CDN honors HTTP Range on i.pinimg.com and v1.pinimg.com',
      (tester) async {
    final dio = _dio();

    // --- 1. Image host: ranged request, window bytes=0-1023 ---------------
    final imgRes = await dio.get<List<int>>(_imageUrl,
        options: Options(
            headers: {'Range': 'bytes=0-1023'},
            responseType: ResponseType.bytes));
    final imgRange = _header(imgRes.headers, 'content-range');
    final imgEtag = _header(imgRes.headers, 'etag');
    _ev('IMG window=0-1023 status=${imgRes.statusCode} contentRange=$imgRange '
        'contentLength=${_header(imgRes.headers, 'content-length')} '
        'acceptRanges=${_header(imgRes.headers, 'accept-ranges')} etag=$imgEtag');
    expect(imgRes.statusCode, 206, reason: 'image host must answer 206');
    final imgParsed = parseContentRange(imgRange!);
    expect(imgParsed, isNotNull, reason: 'Content-Range must parse');
    expect(imgParsed!.firstByte, 0, reason: 'Content-Range first byte');
    expect(imgParsed.lastByte, 1023, reason: 'Content-Range last byte');
    expect(imgParsed.total, greaterThan(1024),
        reason: 'total must exceed window');
    expect(imgRes.data!.length, 1024,
        reason: 'body length must equal the requested window');

    final imgTotal = imgParsed.total;
    final imgPrefix = imgRes.data!;

    // --- 2. Image host: unsatisfiable range (beyond EOF) ------------------
    // Design datum: whatever the CDN answers here, the resume engine must
    // treat any non-206 as "no resume" (200 = full restart; 416 = restart).
    final imgOob = await dio.get<List<int>>(_imageUrl,
        options: Options(
            headers: {'Range': 'bytes=${imgTotal + 1000}-'},
            responseType: ResponseType.bytes));
    _ev('IMG out-of-range status=${imgOob.statusCode} '
        'contentLength=${_header(imgOob.headers, 'content-length')} '
        'contentRange=${_header(imgOob.headers, 'content-range')}');
    expect(imgOob.statusCode, anyOf(200, 206, 416),
        reason: 'record CDN behavior at EOF (200 = ignores bad range)');

    // --- 3. Video host: ranged request ------------------------------------
    final vidRes = await dio.get<List<int>>(_videoUrl,
        options: Options(
            headers: {'Range': 'bytes=0-1023'},
            responseType: ResponseType.bytes));
    final vidRange = _header(vidRes.headers, 'content-range');
    _ev('VID window=0-1023 status=${vidRes.statusCode} contentRange=$vidRange '
        'contentLength=${_header(vidRes.headers, 'content-length')} '
        'acceptRanges=${_header(vidRes.headers, 'accept-ranges')} '
        'etag=${_header(vidRes.headers, 'etag')}');
    expect(vidRes.statusCode, 206, reason: 'video host must answer 206');
    final vidParsed = parseContentRange(vidRange!);
    expect(vidParsed, isNotNull);
    expect(vidParsed!.firstByte, 0);
    expect(vidParsed.lastByte, 1023);
    expect(vidRes.data!.length, 1024);

    // --- 4. Resume shape on-device: prefix + ranged remainder == full -----
    // 4a. mid-file window: exact inclusive byte semantics.
    final mid = await dio.get<List<int>>(_imageUrl,
        options: Options(
            headers: {'Range': 'bytes=4096-8191'},
            responseType: ResponseType.bytes));
    final midRange = _header(mid.headers, 'content-range');
    final midEtag = _header(mid.headers, 'etag');
    _ev('IMG window=4096-8191 status=${mid.statusCode} contentRange=$midRange '
        'contentLength=${_header(mid.headers, 'content-length')} etag=$midEtag');
    expect(mid.statusCode, 206);
    final midParsed = parseContentRange(midRange!);
    expect(midParsed!.firstByte, 4096);
    expect(midParsed.lastByte, 8191);
    expect(mid.data!.length, 4096);
    expect(midEtag, imgEtag,
        reason: 'ETag must be stable across ranged requests (validator premise)');

    // 4b. remainder from the prefix offset (the exact resume request shape).
    final rest = await dio.get<List<int>>(_imageUrl,
        options: Options(
            headers: {'Range': 'bytes=1024-'},
            responseType: ResponseType.bytes));
    final restRange = _header(rest.headers, 'content-range');
    final restEtag = _header(rest.headers, 'etag');
    _ev('IMG window=1024- status=${rest.statusCode} contentRange=$restRange '
        'contentLength=${_header(rest.headers, 'content-length')} etag=$restEtag');
    expect(rest.statusCode, 206);
    expect(parseContentRange(restRange!)!.firstByte, 1024);
    expect(restEtag, imgEtag, reason: 'ETag stable across the resume request');

    // 4c. full object for byte-identity comparison (what a 200 fallback gets).
    final full = await dio.get<List<int>>(_imageUrl,
        options: Options(responseType: ResponseType.bytes));
    _ev('IMG full status=${full.statusCode} '
        'contentLength=${_header(full.headers, 'content-length')}');
    expect(full.statusCode, 200);
    expect(full.data!.length, imgTotal,
        reason: 'full body must equal the Content-Range total');

    final reassembled = <int>[...imgPrefix, ...rest.data!];
    expect(reassembled.length, full.data!.length);
    var identical = true;
    for (var i = 0; i < full.data!.length; i++) {
      if (reassembled[i] != full.data![i]) {
        identical = false;
        break;
      }
    }
    _ev('RESUME byte-identical=$identical '
        '(prefix 1024 + ranged remainder ${rest.data!.length} vs full ${full.data!.length})');
    expect(identical, isTrue,
        reason:
            'prefix + ranged remainder must reproduce the full object byte-for-byte');

    // --- 5. Disk-append proof in the app temp dir (production .part shape) -
    final tmp = await getTemporaryDirectory();
    final partFile = File('${tmp.path}/pindl_g0_spike.part');
    await partFile.writeAsBytes(imgPrefix);
    final sink = partFile.openWrite(mode: FileMode.append);
    sink.add(rest.data!);
    await sink.flush();
    await sink.close();
    final appendedLength = await partFile.length();
    final appendedBytes = await partFile.readAsBytes();
    final diskIdentical =
        appendedBytes.length == full.data!.length &&
            _bytesEqual(appendedBytes, full.data!);
    _ev('DISK part-append length=$appendedLength (expect $imgTotal) '
        'byte-identical=$diskIdentical');
    expect(appendedLength, imgTotal);
    expect(diskIdentical, isTrue,
        reason: 'appended .part must equal full object');
    await partFile.delete();

    _ev('VERDICT PASS image-host=206 video-host=206 resume-shape=byte-exact');
  });
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
