// Phase 10.6 device evidence instrument (integration_test scaffold per D-33 —
// NEVER part of the offline unit suite or CI).
//
// Drives the REAL boards flow end-to-end on the emulator against the LIVE
// Pinterest API: boards mode routing → discovery → picker render → selection.
// The mode-switch TAP path is widget-tested (board_picker_test /
// selection model tests); here the setting is set programmatically because
// scripted taps on a live device race the real IME (documented in the
// seam-6 checkpoint).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pindl/main.dart' as app;
import 'package:pindl/presentation/pages/home_page.dart';
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
    print('BOARDS_E2E: PASS (discovery + selection verified on device)');
  });
}
