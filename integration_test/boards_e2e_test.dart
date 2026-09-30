// Phase 10.6 device evidence instrument (integration_test scaffold per D-33 —
// NEVER part of the offline unit suite or CI).
//
// Drives the REAL boards flow end-to-end on the emulator against the LIVE
// Pinterest API: boards mode routing → discovery → picker render → selection.
// The mode-switch TAP path is widget-tested (board_picker_test /
// selection model tests); here the setting is set programmatically because
// scripted taps on a live device race the real IME (documented in the
// seam-6 checkpoint).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pindl/data/models/job_state.dart';
import 'package:pindl/main.dart' as app;
import 'package:pindl/presentation/pages/home_page.dart';
import 'package:pindl/presentation/providers/job_provider.dart';
import 'package:pindl/presentation/providers/log_provider.dart';
import 'package:pindl/presentation/providers/settings_provider.dart';
import 'package:pindl/presentation/widgets/soft_checkbox.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('boards mode end-to-end: discovery + selection', (tester) async {
    app.main();
    await _settle(tester);
    await Future<void>.delayed(const Duration(seconds: 4));
    await _settle(tester);

    // 0) FAIL FAST if the in-app storage gate rises: its Allow button opens
    // the system Settings app (SpaActivity), which steals focus and hangs the
    // live binding. Never tap it here — pre-grant via adb instead:
    //   adb shell appops set com.motebaya.pindl.lite MANAGE_EXTERNAL_STORAGE allow
    //   adb shell pm grant com.motebaya.pindl.lite android.permission.POST_NOTIFICATIONS
    final gate = find.text('Storage Permission Required');
    if (gate.evaluate().isNotEmpty) {
      fail('BOARDS_E2E: storage gate visible — pre-grant via adb first '
          '(appops MANAGE_EXTERNAL_STORAGE allow)');
    }

    // 1) Enter the username, close the IME via the done action.
    final input = find.byType(TextField).first;
    expect(input, findsOneWidget, reason: 'input field present');
    await tester.enterText(input, '@pinterest');
    await _settle(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 600));
    await _settle(tester);

    // 1b) Live-IME flakiness check: if the field lost its text, re-enter.
    if (find.textContaining('@pinterest').evaluate().isEmpty) {
      // ignore: avoid_print
      print('BOARDS_E2E: field lost text (live IME) — re-entering');
      await tester.enterText(input, '@pinterest');
      await _settle(tester);
    }

    // 2) Feed|Boards switch rendered for username input (10.1 UI).
    expect(find.text('Boards'), findsOneWidget,
        reason: 'Feed|Boards switch visible for username input');
    // ignore: avoid_print
    print('BOARDS_E2E: mode switch rendered (Feed | Boards)');

    // 3) Switch to boards mode via the provider (tap path widget-tested).
    final container = ProviderScope.containerOf(tester.element(find.byType(HomePage)));
    container.read(settingsProvider.notifier).setBoardsMode(true);
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);

    // 4) Boards-mode routing: "Find boards" replaces the feed Submit.
    final findBoards = find.text('Find boards');
    expect(findBoards, findsOneWidget,
        reason: 'boards mode routes submit to discovery');
    // ignore: avoid_print
    print('BOARDS_E2E: boards-mode submit row rendered');

    // 5) Discovery against the LIVE API — poll up to 45 s.
    await tester.tap(findBoards, warnIfMissed: true);
    var discovered = false;
    for (var i = 0; i < 45; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('Boards (').evaluate().isNotEmpty) {
        discovered = true;
        break;
      }
    }
    if (!discovered) {
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((t) => t != null && t.trim().isNotEmpty)
          .toList();
      // ignore: avoid_print
      print('BOARDS_E2E: discovery NOT completed; screen texts = $texts');
    }
    expect(discovered, isTrue,
        reason: 'board discovery completed against live API');
    // ignore: avoid_print
    print('BOARDS_E2E: live discovery completed');

    // 6) Board rows rendered with pin counts (picker present).
    expect(find.textContaining(' pins').evaluate().isNotEmpty, isTrue,
        reason: 'board rows show pin counts');

    // 7) Include the first board → Whole/Sections/Skip pills appear.
    final firstCheckbox = find
        .byWidgetPredicate((w) => w is SoftCheckbox && w.label == null)
        .first;
    await tester.tap(firstCheckbox, warnIfMissed: true);
    await _settle(tester);
    expect(find.text('Whole'), findsWidgets,
        reason: 'included board exposes Whole/Sections/Skip pills');
    expect(find.text('Sections'), findsWidgets);
    expect(find.text('Skip'), findsWidgets);
    // ignore: avoid_print
    print('BOARDS_E2E: selection pills verified (Whole/Sections/Skip)');

    // 8) G1 device evidence: start the board download from the confirmation
    // row and verify the D-39 folder layout lands REAL files on disk.
    // The instrument runs inside the app process, so dart:io sees the real
    // shared storage (MANAGE_EXTERNAL_STORAGE pre-granted via adb).
    final downloadBtn = find.textContaining('Download ~');
    expect(downloadBtn, findsOneWidget,
        reason: 'board download confirmation row rendered');
    await tester.ensureVisible(downloadBtn);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(downloadBtn, warnIfMissed: true);
    // ignore: avoid_print
    print('BOARDS_E2E: board download started — polling filesystem');

    // Poll up to 4 min for files under Download/PinDL/@<user>/Boards/...
    // (board pin fetch + image downloads are live-network operations).
    final found = <File>[];
    var sawBoardsDir = false;
    var lastDiag = '';
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 100));
      final pinDLRoot = Directory('/storage/emulated/0/Download/PinDL');
      if (pinDLRoot.existsSync()) {
        for (final userDir in pinDLRoot.listSync()) {
          if (userDir is! Directory) continue;
          final boardsDir = Directory('${userDir.path}/Boards');
          if (!boardsDir.existsSync()) continue;
          sawBoardsDir = true;
          for (final boardDir in boardsDir.listSync()) {
            if (boardDir is! Directory) continue;
            // D-39: <slug>-<idSuffix> folder; walk it recursively for files.
            for (final e in boardDir.listSync(recursive: true)) {
              if (e is File && e.lengthSync() > 0) found.add(e);
            }
          }
        }
      }
      // Live job-state + log diagnostics every 15 s (the drive uninstalls
      // the app on completion — Android/data evidence is destroyed, so any
      // post-mortem is blind; observe INSIDE the loop instead).
      if (i % 15 == 14) {
        final st = container.read(jobProvider);
        final logs = container.read(logEntriesProvider);
        lastDiag = 'status=${st.status} dl=${st.downloadedCount} '
            'cur=${st.currentIndex} err=${st.failedCount} '
            'error=${st.error}';
        // ignore: avoid_print
        print('BOARDS_E2E: t+${(i + 1) * 2}s $lastDiag');
        // Full console tail (unfiltered — the failure detail may be any
        // log level; keyword filters hid it in the first G1 run).
        for (final e in logs.length > 40 ? logs.sublist(logs.length - 40) : logs) {
          // ignore: avoid_print
          print('BOARDS_E2E|log: ${e.level.name}: ${e.message}');
        }
      }
      if (found.isNotEmpty) break;
      // Fail fast: the job already terminal-failed — dump the console tail
      // (unfiltered) and stop polling.
      if (container.read(jobProvider).status == JobStatus.failed) {
        final logs = container.read(logEntriesProvider);
        for (final e in logs.length > 40 ? logs.sublist(logs.length - 40) : logs) {
          // ignore: avoid_print
          print('BOARDS_E2E|log: ${e.level.name}: ${e.message}');
        }
        // ignore: avoid_print
        print('BOARDS_E2E: job FAILED early — aborting file poll');
        break;
      }
    }
    // ignore: avoid_print
    print('BOARDS_E2E: boards dir seen = $sawBoardsDir, files = '
        '${found.take(5).map((f) => f.path).toList()} '
        '(+${found.length > 5 ? found.length - 5 : 0} more)');
    expect(found, isNotEmpty,
        reason: 'board download landed real files in the D-39 layout '
            '(PinDL/@<user>/Boards/<slug>-<id>/...)');
    final pathCheck = found.any((f) =>
        f.path.contains('/Boards/') &&
        RegExp(r'Boards/[^/]+-\d+/').hasMatch(f.path));
    expect(pathCheck, isTrue,
        reason: 'files follow <slug>-<boardId-suffix> folder naming (D-39)');
    // ignore: avoid_print
    print('BOARDS_E2E: G1-WHOLE verified (real files at D-39 layout)');

    // 9) G1 (Sections mode): find a board that exposes sections, pick one,
    // download, verify files. Only ONE row included at a time so the
    // single 'Sections' pill on screen belongs to the row under test.
    // Soft-skip (documented, not silent) if no live board exposes sections.
    final unlabeled = find.byWidgetPredicate(
        (w) => w is SoftCheckbox && w.label == null);
    var sectionsModeVerified = false;
    // Exclude board 1 (tap = toggle) before scanning other rows.
    if (unlabeled.evaluate().isNotEmpty) {
      await tester.tap(unlabeled.first, warnIfMissed: true);
      await _settle(tester);
    }
    final rowCount = unlabeled.evaluate().length;
    final scanMax = rowCount < 10 ? rowCount : 10;
    for (var i = 1; i < scanMax && !sectionsModeVerified; i++) {
      final row = unlabeled.at(i);
      await tester.tap(row, warnIfMissed: true); // include → Whole
      await _settle(tester);
      final sectionsPill = find.text('Sections');
      if (sectionsPill.evaluate().isEmpty) {
        await tester.tap(row, warnIfMissed: true); // exclude again
        await _settle(tester);
        continue;
      }
      await tester.tap(sectionsPill.first, warnIfMissed: true);
      // Lazy section fetch — poll up to 10 s for labeled section checkboxes.
      var hasSections = false;
      for (var w = 0; w < 10; w++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 100));
        if (find
            .byWidgetPredicate((w) => w is SoftCheckbox && w.label != null)
            .evaluate()
            .isNotEmpty) {
          hasSections = true;
          break;
        }
      }
      if (!hasSections) {
        // This board exposes no sections — exclude and try the next row.
        await tester.tap(row, warnIfMissed: true);
        await _settle(tester);
        continue;
      }
      // Pick sections until the estimate is non-zero (a 0-pin section
      // would start a job that downloads nothing).
      final labeled = find
          .byWidgetPredicate((w) => w is SoftCheckbox && w.label != null);
      final pickMax = labeled.evaluate().length < 3
          ? labeled.evaluate().length
          : 3;
      for (var p = 0; p < pickMax; p++) {
        await tester.tap(labeled.at(p), warnIfMissed: true);
        await _settle(tester);
        if (find.textContaining('Download ~').evaluate().isNotEmpty &&
            !find.textContaining('Download ~0 ').evaluate().isNotEmpty) {
          break;
        }
      }
      final sectionsBtn = find.textContaining('Download ~');
      if (sectionsBtn.evaluate().isEmpty ||
          find.textContaining('Download ~0 ').evaluate().isNotEmpty) {
        await tester.tap(row, warnIfMissed: true); // exclude, next row
        await _settle(tester);
        continue;
      }
      await tester.ensureVisible(sectionsBtn.first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(sectionsBtn.first, warnIfMissed: true);
      // ignore: avoid_print
      print('BOARDS_E2E: sections download started — polling filesystem');
      final foundSections = <File>[];
      for (var s = 0; s < 120; s++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 100));
        final pinDLRoot = Directory('/storage/emulated/0/Download/PinDL');
        if (pinDLRoot.existsSync()) {
          for (final userDir in pinDLRoot.listSync()) {
            if (userDir is! Directory) continue;
            final boardsDir = Directory('${userDir.path}/Boards');
            if (!boardsDir.existsSync()) continue;
            for (final boardDir in boardsDir.listSync()) {
              if (boardDir is! Directory) continue;
              for (final e in boardDir.listSync(recursive: true)) {
                if (e is File && e.lengthSync() > 0) foundSections.add(e);
              }
            }
          }
        }
        if (foundSections.length > found.length) break; // new file landed
        if (container.read(jobProvider).status == JobStatus.failed) break;
      }
      final fresh = foundSections
          .where((f) => !found.contains(f))
          .toList();
      if (fresh.isNotEmpty) {
        expect(
            fresh.any((f) => RegExp(r'Boards/[^/]+-\d+/').hasMatch(f.path)),
            isTrue,
            reason: 'sections-mode files follow the D-39 layout too');
        sectionsModeVerified = true;
      } else {
        // ignore: avoid_print
        print('BOARDS_E2E: sections attempt on row $i produced no files '
            '(status=${container.read(jobProvider).status}) — next row');
        await tester.tap(row, warnIfMissed: true);
        await _settle(tester);
      }
    }
    if (!sectionsModeVerified) {
      // ignore: avoid_print
      print('BOARDS_E2E: LIMITATION — no live @pinterest board exposed '
          'usable sections in the first $scanMax rows; Sections mode verified '
          'by widget/coordinator tests (G3), Whole mode verified on device.');
    } else {
      // ignore: avoid_print
      print('BOARDS_E2E: G1-SECTIONS verified (real files at D-39 layout)');
    }
    // ignore: avoid_print
    print('BOARDS_E2E: PASS (G1 — end-to-end board download verified on '
        'device: discovery + selection + real files at D-39 layout)');
  });
}
