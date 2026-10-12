import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Byte-level resume engine — Phase 06 (workstreams 06.2/06.3/06.4).
///
/// Contract: planning/phases/06-byte-level-resume.md; gate G0 PASSED (D-30):
/// i.pinimg.com + v1.pinimg.com verified 206 with exact Content-Range from the
/// device; ETags strong and stable. Evidence:
/// reports/phases/appendix/06-range-spike-evidence.txt.
///
/// Invariants (D-30, evidence-bound):
///   * Continue ONLY on a 206 whose Content-Range starts exactly at the
///     requested offset and whose total matches the sidecar total.
///   * Any other status (200 / 416 / 3xx / 4xx / 5xx), a validator mismatch,
///     or any structural anomaly => discard the partial file and download
///     from zero IN THE SAME CALL. A corrupt byte is never appended on faith;
///     the Phase 03 media validator remains the final backstop at import.
///   * Unsatifiable-range behavior on the CDN is non-deterministic (200-full
///     observed once, 416 observed once) — both map to "no resume".
///   * `Accept-Ranges` is NEVER a precondition (v1.pinimg.com answered 206
///     without it once) — the 206 itself is the only resume signal.
///   * Interrupted transfers PRESERVE `.part` + sidecar (cancel included);
///     the sidecar is reconciled to the actual on-disk length on every error
///     exit, so a crash can only ever fall back to a safe full restart.
///
/// The sidecar (`<part>.meta.json`, app-private cache) is the byte-level
/// resume truth — deliberately NOT Hive: `BackgroundTaskState` stays the
/// ephemeral progress mirror it is today (Phase 04 header restated), and no
/// schema migration is needed.
///
/// P5 (D-21 precedent): hand-rolled, zero new dependencies. The URL hash is a
/// non-cryptographic FNV-1a guard against sidecar/URL mismatch — it defends
/// against stale-state mixups, not adversaries.
class RangeResume {
  /// Downloads [url] to [partPath], resuming from a valid `.part` + sidecar
  /// pair when possible, otherwise downloading from zero.
  ///
  /// On success the part file is complete and the sidecar reflects it (the
  /// caller renames and deletes the sidecar). On network error the transfer's
  /// last consistent state is preserved and the error propagates (the caller's
  /// retry layer classifies it). Cancellation propagates as
  /// [DioExceptionType.cancel] with files preserved (06.4 semantics).
  static Future<void> download(
    Dio dio,
    String url,
    String partPath, {
    String? sidecarPath,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final sidecarFile = _sidecarPath(partPath, sidecarPath);
    final sidecar = ResumeSidecar.tryLoad(sidecarFile);
    final part = File(partPath);
    final expectedHash = hashUrl(url);

    final eligible = await _isEligible(sidecar, part, expectedHash);
    if (!eligible) {
      // Ineligible sidecar/part: stale state — delete both (retention rule).
      await _deleteQuietly(part);
      await _deleteSidecarQuietly(sidecarFile);
      await _streamToFile(
        dio,
        url,
        part,
        startFrom: 0,
        urlHash: hashUrl(url),
        sidecarFile: sidecarFile,
        cancelToken: cancelToken,
        onProgress: onProgress,
        onLog: onLog,
      );
      return;
    }

    final offset = sidecar!.offset;
    onLog?.call('resuming $url from byte $offset/${sidecar.total}');

    final Response<ResponseBody> resp;
    try {
      resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          // Never throw on status: 200/416 on a resume probe are design
          // outcomes (full restart), not exceptions.
          validateStatus: (_) => true,
          headers: {'Range': 'bytes=$offset-'},
        ),
        cancelToken: cancelToken,
      );
    } on DioException {
      // Probe itself failed (network drop): preserve state for the next try.
      rethrow;
    }

    switch (resp.statusCode) {
      case 206:
        final range = ContentRangeInfo.tryParse(resp.headers.value('content-range'));
        if (range == null ||
            range.firstByte != offset ||
            range.total != sidecar.total) {
          onLog?.call('resume rejected: Content-Range mismatch '
              '(${resp.headers.value('content-range')}) — full restart');
          return _restartFull(
            dio, url, part, sidecarFile, cancelToken, onProgress, onLog,
          );
        }
        final etag = resp.headers.value('etag');
        // Validator premise (D-30): ETag must confirm the SAME object. If the
        // sidecar carries an ETag, the response must carry the equal one — an
        // absent ETag cannot be verified and means restart.
        if (sidecar.etag != null && etag != sidecar.etag) {
          onLog?.call('resume rejected: ETag changed — full restart');
          return _restartFull(
            dio, url, part, sidecarFile, cancelToken, onProgress, onLog,
          );
        }
        await _appendToPart(
          part,
          resp.data!,
          startFrom: offset,
          total: sidecar.total,
          urlHash: sidecar.urlHash,
          etag: sidecar.etag,
          lastModified: sidecar.lastModified,
          sidecarFile: sidecarFile,
          cancelToken: cancelToken,
          onProgress: onProgress,
          onLog: onLog,
        );
        return;

      case 200:
        // Server ignored the Range header — restart from zero (G3 contract).
        onLog?.call('resume rejected: 200 (Range ignored) — full restart');
        return _restartFull(
          dio, url, part, sidecarFile, cancelToken, onProgress, onLog,
        );

      case 416:
        // Unsatisfiable range. The one benign case: the part is already
        // complete (interrupted between final byte and rename).
        if (sidecar.total > 0 && await part.length() == sidecar.total) {
          onLog?.call('resume: part already complete (416 at EOF)');
          return;
        }
        onLog?.call('resume rejected: 416 with incomplete part — full restart');
        return _restartFull(
          dio, url, part, sidecarFile, cancelToken, onProgress, onLog,
        );

      default:
        // 3xx/4xx/5xx on the probe: any anomaly => one clean full restart.
        onLog?.call('resume rejected: HTTP ${resp.statusCode} — full restart');
        return _restartFull(
          dio, url, part, sidecarFile, cancelToken, onProgress, onLog,
        );
    }
  }

  /// Fresh (from-zero) streaming download; also the restart path. Writes the
  /// sidecar per chunk so an interruption leaves a resumable state.
  static Future<void> _streamToFile(
    Dio dio,
    String url,
    File part, {
    required int startFrom,
    required String urlHash,
    required String sidecarFile,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final headers = <String, String>{
      if (startFrom > 0) 'Range': 'bytes=$startFrom-',
    };
    final Response<ResponseBody> resp;
    try {
      resp = await dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          headers: headers,
        ),
        cancelToken: cancelToken,
      );
    } on DioException {
      rethrow;
    }
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw DioException.connectionError(
        requestOptions: resp.requestOptions,
        reason: 'download failed: HTTP ${resp.statusCode}',
      );
    }
    final etag = resp.headers.value('etag');
    final lastModified = resp.headers.value('last-modified');
    final total = _totalFrom(resp);
    await _appendToPart(
      part,
      resp.data!,
      startFrom: startFrom,
      total: total,
      urlHash: urlHash,
      etag: etag,
      lastModified: lastModified,
      sidecarFile: sidecarFile,
      cancelToken: cancelToken,
      onProgress: onProgress,
      onLog: onLog,
    );
  }

  /// Restart helper for the resume-probe paths: discard partial state, then a
  /// single clean from-zero download inside the same call.
  static Future<void> _restartFull(
    Dio dio,
    String url,
    File part,
    String sidecarFile,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onLog,
  ) async {
    await _deleteQuietly(part);
    await _deleteSidecarQuietly(sidecarFile);
    await _streamToFile(
      dio,
      url,
      part,
      startFrom: 0,
      urlHash: hashUrl(url),
      sidecarFile: sidecarFile,
      cancelToken: cancelToken,
      onProgress: onProgress,
      onLog: onLog,
    );
  }

  /// Streams [body] into [part] from [startFrom], persisting the sidecar (and
  /// flushing) per chunk. On ANY error the sidecar is reconciled to the actual
  /// on-disk length before propagating — a crash can only fall back to a safe
  /// full restart, never a corrupt append.
  static Future<void> _appendToPart(
    File part,
    ResponseBody body, {
    required int startFrom,
    required int total,
    required String urlHash,
    required String? etag,
    required String? lastModified,
    required String sidecarFile,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onLog,
  }) async {
    final sink = part.openWrite(mode: FileMode.append);
    var written = startFrom;
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        written += chunk.length;
        // Flush + sidecar per chunk: sidecar always matches disk. Cheap for
        // the small JSON file; correctness over micro-throughput.
        await sink.flush();
        await ResumeSidecar(
          urlHash: urlHash,
          offset: written,
          total: total,
          etag: etag,
          lastModified: lastModified,
        ).save(sidecarFile);
        if (onProgress != null && total > 0) onProgress(written, total);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Reconcile the sidecar to what actually reached disk, then rethrow so
      // the caller's retry/cancel classification sees the original error.
      try {
        await sink.close();
      } catch (_) {}
      try {
        final actual = await part.length();
        await ResumeSidecar(
          urlHash: urlHash,
          offset: actual,
          total: total,
          etag: etag,
          lastModified: lastModified,
        ).save(sidecarFile);
      } catch (_) {}
      rethrow;
    }
    // Final reconcile.
    //
    // UNDER-shoot (fewer bytes than declared): the transfer is genuinely
    // incomplete — throw so the caller's retry layer re-runs it; the sidecar
    // marks a resumable state.
    if (total > 0 && written < total) {
      throw DioException.connectionError(
        reason: 'short body: got $written of $total bytes',
        requestOptions: RequestOptions(path: part.path),
      );
    }
    // OVER-shoot (more bytes than declared): the declared total is WRONG, not
    // the body (compressed transfer or misreported Content-Length). Real device
    // report: `short body: got 920 of 350 bytes` for a 920 B playlist whose CDN
    // header claimed 350 B — the sidecar then stored the bogus total, so every
    // retry failed identically and the item could never complete ("cannot be
    // solved by the library"). Accept the delivered bytes: they are a verified
    // 206 continuation (or a from-zero write), and the fail-closed media
    // validator still inspects the actual content before import.
    if (total > 0 && written > total) {
      onLog?.call('declared length $total contradicted by $written bytes '
          'received — treating declared length as unreliable');
    }
    // Completed (total reached): the sidecar has served its purpose and dies
    // here — the caller renames the part right after.
    final meta = File(sidecarFile);
    try {
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }

  /// Structural + identity reconciliation BEFORE any resume (contract: any
  /// mismatch => restart). Also acts as the retention policy gate: anything
  /// ineligible is deleted by the caller path. `offset == total` is eligible
  /// (transfer completed but rename never happened — the probe answers 416
  /// and the part is kept; a 200 probe restarts safely instead).
  static Future<bool> _isEligible(
    ResumeSidecar? s,
    File part,
    String expectedHash,
  ) async {
    if (s == null) return false;
    if (s.urlHash != expectedHash) return false; // sidecar/URL mismatch guard
    if (s.offset <= 0 || s.total <= 0) return false;
    if (s.offset > s.total) return false;
    if (!await part.exists()) return false;
    return await part.length() == s.offset;
  }

  static String _sidecarPath(String partPath, String? override) =>
      override ?? '$partPath.meta.json';

  static int _totalFrom(Response<ResponseBody> resp) {
    // A compressed response's Content-Length describes the WIRE body, not the
    // decoded bytes the stream yields — unusable as a completion total (3.1.1).
    final encoding =
        resp.headers.value('content-encoding')?.toLowerCase().trim();
    if (encoding != null && encoding.isNotEmpty && encoding != 'identity') {
      return -1;
    }
    final range = ContentRangeInfo.tryParse(resp.headers.value('content-range'));
    if (range != null) return range.total;
    final cl = resp.headers.value('content-length');
    return int.tryParse(cl ?? '') ?? -1;
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> _deleteSidecarQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// FNV-1a 64-bit, hex. Non-cryptographic on purpose: it guards against
  /// stale sidecar/URL mixups, not adversaries (see class doc). Public so
  /// tooling/tests can pre-seed or inspect sidecars for a given URL.
  static String hashUrl(String url) {
    var h = 0xcbf29ce484222325;
    for (final c in url.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }
}

/// Parsed Content-Range value ("bytes 0-1023/44409"). Null for malformed or
/// unsatisfiable ("bytes */44409") values — callers treat null as mismatch.
class ContentRangeInfo {
  final int firstByte;
  final int lastByte;
  final int total;
  const ContentRangeInfo(this.firstByte, this.lastByte, this.total);

  static ContentRangeInfo? tryParse(String? value) {
    if (value == null) return null;
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
    return ContentRangeInfo(first, last, total);
  }
}

/// Sidecar state file (`<part>.meta.json`): url hash, offset, total, ETag,
/// Last-Modified. App-private cache, ephemeral by design (deleted with the
/// part on import / validation failure / ineligible reuse).
class ResumeSidecar {
  static const schemaVersion = 1;

  final String urlHash;
  final int offset;
  final int total;
  final String? etag;
  final String? lastModified;

  const ResumeSidecar({
    required this.urlHash,
    required this.offset,
    required this.total,
    this.etag,
    this.lastModified,
  });

  Map<String, dynamic> toJson() => {
        'schema': schemaVersion,
        'url_hash': urlHash,
        'offset': offset,
        'total': total,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'last_modified': lastModified,
      };

  String serialize() => jsonEncode(toJson());

  Future<void> save(String path) async {
    await File(path).writeAsString(serialize(), flush: true);
  }

  /// Tolerant reader (D-26 spirit): anything malformed, foreign-schema, or
  /// non-integral returns null => caller takes the full-restart path.
  static ResumeSidecar? tryLoad(String path) {
    String raw;
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      raw = f.readAsStringSync();
    } catch (_) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['schema'] != schemaVersion) return null;
    final hash = decoded['url_hash'];
    final offset = decoded['offset'];
    final total = decoded['total'];
    if (hash is! String) return null;
    if (offset is! int || total is! int) return null;
    final etag = decoded['etag'];
    final lastModified = decoded['last_modified'];
    return ResumeSidecar(
      urlHash: hash,
      offset: offset,
      total: total,
      etag: etag is String ? etag : null,
      lastModified: lastModified is String ? lastModified : null,
    );
  }
}
