// G4 device evidence — full interruption cycle on-device (single drive run;
// the flutter harness uninstalls the app between runs, which wipes app-private
// data — DISC-17). The resume engine holds NO process state: all continuity is
// the `.part` + sidecar on disk, so the second RangeResume.download call with
// fresh objects below IS the production "retried after interruption" path.
//
// Evidence lines (EVIDENCE|) are captured into
// reports/phases/appendix/06-range-spike-evidence.txt (G4 section).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pindl/core/network/range_resume.dart';

const _videoUrl =
    'https://v1.pinimg.com/videos/iht/expMp4/13/22/fc/1322fc6cda00fa97bbd5822a7474dd93_720w.mp4';

void _ev(String msg) => debugPrint('EVIDENCE|$msg');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('G4: cancel mid-transfer, then resume at recorded offset',
      (tester) async {
    final tmp = await getTemporaryDirectory();
    final partPath = '${tmp.path}/pindl_g4_resume.mp4.part';
    for (final f in [File(partPath), File('$partPath.meta.json')]) {
      if (await f.exists()) await f.delete();
    }

    // --- Leg 1: real CDN download, cancelled after the 1 MB mark ----------
    final token = CancelToken();
    final dio1 = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
    ));
    await expectLater(
      RangeResume.download(
        dio1,
        _videoUrl,
        partPath,
        cancelToken: token,
        onProgress: (received, total) {
          if (received > 1000000 && !token.isCancelled) {
            token.cancel('G4: simulated interruption');
          }
        },
      ),
      throwsA(isA<DioException>()),
    );
    final cancelledAt = await File(partPath).length();
    final sidecar1 = ResumeSidecar.tryLoad('$partPath.meta.json');
    _ev('G4-LEG1 cancelled-at=$cancelledAt sidecar-offset=${sidecar1?.offset} '
        'preserved=${await File(partPath).exists() && sidecar1 != null}');
    expect(cancelledAt, greaterThan(1000000));
    expect(sidecar1!.offset, cancelledAt);

    // --- Leg 2: fresh objects (the "next run" path) resumes from disk state
    String? observedRange;
    final dio2 = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
    ));
    dio2.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final r = options.headers['Range'];
        if (r != null) observedRange = r;
        handler.next(options);
      },
    ));
    await RangeResume.download(dio2, _videoUrl, partPath);

    final finalLen = await File(partPath).length();
    _ev('G4-LEG2 probe=$observedRange resumed-from=${sidecar1.offset} '
        'final-length=$finalLen expected=${sidecar1.total} '
        'byte-exact=${finalLen == sidecar1.total} sidecar-consumed='
        '${!File('$partPath.meta.json').existsSync()}');
    expect(observedRange, 'bytes=${sidecar1.offset}-',
        reason: 'the retry must probe exactly at the recorded offset');
    expect(finalLen, sidecar1.total, reason: 'resume must complete byte-exact');
    expect(File('$partPath.meta.json').existsSync(), isFalse);

    await File(partPath).delete();
    _ev('G4-VERDICT PASS cancel-preserve-resume confirmed on device '
        '(offset $cancelledAt of ${sidecar1.total})');
  });
}
