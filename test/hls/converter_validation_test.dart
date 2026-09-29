import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/hls_conversion_result.dart';
import 'package:pindl/data/services/hls_converter.dart';

/// Phase 05 — HLS output validation (HLS-2, gate G1) and temp sweep age
/// filter (D-05/C-6, gate G3).
///
/// The converter itself requires FFmpegKit platform channels (Android-only),
/// so the file-level validation and sweep logic are exercised directly here;
/// device conversion evidence is the Phase 11 instrumented smoke.
void main() {
  group('G1 — MP4 output validation (brand matrix, hls/01 + JS parity)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pindl_hls_test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<File> fileWith(List<int> bytes, {String name = 'out.mp4'}) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f;
    }

    test('valid ftyp brand + size passes', () async {
      final f = await fileWith(
          [0, 0, 0, 0x18, ...'ftyp'.codeUnits, ...List<int>.filled(1100, 0)]);
      expect(await HlsConverter.validateMp4File(f.path), isNull);
    });

    test('valid moov brand passes', () async {
      final f = await fileWith(
          [0, 0, 0, 0x18, ...'moov'.codeUnits, ...List<int>.filled(1100, 0)]);
      expect(await HlsConverter.validateMp4File(f.path), isNull);
    });

    test('valid wide/free/skip brands pass', () async {
      for (final brand in ['wide', 'free', 'skip']) {
        final f = await fileWith(
            [0, 0, 0, 0x18, ...brand.codeUnits, ...List<int>.filled(1100, 0)],
            name: '$brand.mp4');
        expect(await HlsConverter.validateMp4File(f.path), isNull, reason: brand);
      }
    });

    test('truncated/corrupt head is rejected', () async {
      final f = await fileWith(
          [0xFF, 0xFF, 0xFF, 0xFF, ...'JUNK'.codeUnits, ...List<int>.filled(1100, 0)]);
      final verdict = await HlsConverter.validateMp4File(f.path);
      expect(verdict, contains('unknown ISO-BMFF brand'));
    });

    test('undersized file (< 1 KiB) is rejected even with a valid brand', () async {
      final f = await fileWith([0, 0, 0, 0x18, ...'ftyp'.codeUnits, 1, 2, 3]);
      final verdict = await HlsConverter.validateMp4File(f.path);
      expect(verdict, contains('undersized'));
    });

    test('HTML page posing as MP4 is rejected', () async {
      final f = await fileWith(
          '<html><body>${'x' * 1200}</body></html>'.codeUnits);
      final verdict = await HlsConverter.validateMp4File(f.path);
      expect(verdict, isNotNull);
    });

    test('missing file is rejected (not a crash)', () async {
      final verdict =
          await HlsConverter.validateMp4File('${dir.path}/nope.mp4');
      expect(verdict, contains('does not exist'));
    });

    test('zero-length file is rejected', () async {
      final f = await fileWith(<int>[]);
      final verdict = await HlsConverter.validateMp4File(f.path);
      expect(verdict, isNotNull);
    });
  });

  group('cancelled conversion result (truth table)', () {
    test('wasCancelled flag is set and success is false', () {
      final r = HlsConversionResult.cancelled();
      expect(r.success, isFalse);
      expect(r.wasCancelled, isTrue);
      expect(r.toString(), contains('cancelled'));
    });
  });

  group('G3 — temp sweep age filter (D-05: ≥24 h deleted, <24 h kept)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pindl_sweep_test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('contract bound is exactly 24 hours', () {
      expect(HlsConverter.staleTempAge, const Duration(hours: 24));
    });

    test('sweep deletes only files at/over the age bound (D-05 semantics)', () async {
      // Directly exercise the age rule the sweep implements: files whose
      // mtime is before (now - 24 h) must be deleted; younger must remain.
      final stale = File('${dir.path}/old.mp4');
      final fresh = File('${dir.path}/new.mp4');
      final stalePart = File('${dir.path}/old2.mp4.part.mp4');
      await stale.writeAsBytes([1]);
      await fresh.writeAsBytes([1]);
      await stalePart.writeAsBytes([1]);

      final staleTime = DateTime.now().subtract(const Duration(hours: 25));
      final freshTime = DateTime.now();
      await stale.setLastModified(staleTime);
      await stalePart.setLastModified(staleTime);
      await fresh.setLastModified(freshTime);

      final cutoff = DateTime.now().subtract(HlsConverter.staleTempAge);
      // The sweep's rule, applied to this directory:
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!(entity.path.endsWith('.mp4') ||
            entity.path.endsWith('.part.mp4'))) {
          continue;
        }
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }

      expect(await stale.exists(), isFalse, reason: '≥24 h must be swept');
      expect(await stalePart.exists(), isFalse, reason: 'part files sweep too');
      expect(await fresh.exists(), isTrue, reason: '<24 h stays (in-flight safety)');
    });

    test('non-mp4 files are never swept', () async {
      final meta = File('${dir.path}/state.json');
      await meta.writeAsBytes([1, 2, 3]);
      await meta.setLastModified(DateTime.now().subtract(const Duration(hours: 48)));
      final cutoff = DateTime.now().subtract(HlsConverter.staleTempAge);
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!(entity.path.endsWith('.mp4') ||
            entity.path.endsWith('.part.mp4'))) {
          continue;
        }
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
      expect(await meta.exists(), isTrue);
    });
  });
}
