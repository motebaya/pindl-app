// Phase 11.2 — CI emulator smoke (contract 11.2, REL-2; D-33 scaffold).
//
// Boots the REAL app on the emulator and pings the critical platform
// channels through the production DownloadService, so a registration
// regression (AND-1 silent-kill class) fails the job instead of shipping:
//   1. UI engine alive — home page renders.
//   2. hasManageStoragePermission — bool answer through com.motebaya.pindl/media.
//   3. listFilesInFolder — list answer (may be empty; the type is the proof).
//   4. fileExistsInDownloads — definitive negative through the full native path.
//
// Permission pre-requisite (CI job + local runs, BEFORE this test):
//   adb shell pm grant com.motebaya.pindl.lite android.permission.POST_NOTIFICATIONS
//   adb shell appops set com.motebaya.pindl.lite MANAGE_EXTERNAL_STORAGE allow
// Grant → assert TRUE (a regression in the permission plumbing must be red).
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pindl/data/services/download_service.dart';
import 'package:pindl/main.dart' as app;
import 'package:pindl/presentation/pages/home_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('smoke: engine alive + critical channels respond', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(seconds: 4));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 1) UI engine alive: the home page rendered (no channel-less dead frame).
    expect(find.byType(HomePage), findsOneWidget,
        reason: 'home page rendered — engine + widget tree alive');
    print('SMOKE: home page rendered');

    final service = DownloadService();

    // 2) Storage-permission channel round-trip (bool answer; true because the
    // runner grants MANAGE_EXTERNAL_STORAGE via appops before this runs).
    final hasPerm = await service.hasManageStoragePermission();
    expect(hasPerm, isTrue,
        reason: 'media channel answered AND MANAGE_EXTERNAL_STORAGE is '
            'granted (pre-granted via adb) — if false, either the channel is '
            'dead or the runner skipped the grant');
    print('SMOKE: hasManageStoragePermission = $hasPerm');

    // 3) Listing channel round-trip: a list answer (even empty) proves the
    // MediaStore/file bridge responds with well-formed data. The service's
    // .cast<String>() yields a CastList — runtime type is NOT List<String>,
    // so assert the container type with a CALLED matcher and the declared
    // element type per item.
    final listed = await service.listFilesInFolder('PinDL');
    expect(listed, isA<List>(),
        reason: 'listFilesInFolder returns a list through the channel');
    for (final e in listed) {
      expect(e, isA<String>(), reason: 'listing elements are file names');
    }
    print('SMOKE: listFilesInFolder(PinDL) -> ${listed.length} entries');

    // 4) Existence channel: definitive negative through the full native path.
    final exists = await service
        .fileExistsInDownloads('pindl-smoke-definitely-missing.bin', 'PinDL');
    expect(exists, isFalse,
        reason: 'nonexistent file reports false through the channel');
    print('SMOKE: fileExists(missing) = $exists');

    print('SMOKE: PASS (engine alive; media channel round-trips verified)');
  });
}
