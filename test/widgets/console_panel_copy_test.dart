import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/services/log_service.dart';
import 'package:pindl/presentation/widgets/console_panel.dart';

/// 3.1.1 device-report fix: the console content must be copyable so a user who
/// hits an error can hand the log over verbatim.
///
/// Two mechanisms are pinned here:
///   1. the log area is wrapped in a `SelectionArea` (text selection/copy);
///   2. the header's copy-all action writes the exact rendered lines to the
///      system clipboard.
void main() {
  group('console panel copyability (3.1.1)', () {
    late List<MethodCall> clipboardWrites;
    late LogService logService;

    setUp(() {
      clipboardWrites = [];
      logService = LogService();
      // The clipboard lives on the platform channel; capture the writes so the
      // assertion is on the real payload, not on a mock's return value.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform,
              (MethodCall call) async {
        if (call.method == 'Clipboard.setData') clipboardWrites.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      logService.dispose();
    });

    Future<void> pumpPanel(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ConsolePanel(
            logStream: logService.stream,
            initialEntries: logService.entries,
            height: 200,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('log area is selectable (SelectionArea wraps the log list)',
        (tester) async {
      logService.error('Failed: 727331408611432034_video.mp4');
      await pumpPanel(tester);

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.textContaining('727331408611432034_video.mp4'), findsOneWidget);
    });

    testWidgets('copy-all writes every rendered line to the clipboard',
        (tester) async {
      logService.fetch('fetching pin page');
      logService.error('Failed: short body: got 920 of 350 bytes');
      await pumpPanel(tester);

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pumpAndSettle();

      expect(clipboardWrites, hasLength(1));
      final text =
          (clipboardWrites.single.arguments as Map<Object?, Object?>)['text']
              as String;
      final lines = text.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], contains('[FETCH] fetching pin page'));
      expect(lines[1], contains('[ERROR] Failed: short body: got 920 of 350 bytes'));
    });

    testWidgets('copy-all is inert on an empty console (no clipboard write)',
        (tester) async {
      await pumpPanel(tester);

      expect(find.text('No logs yet...'), findsOneWidget);
      expect(find.byType(SelectionArea), findsNothing);

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pumpAndSettle();
      expect(clipboardWrites, isEmpty);
    });

    testWidgets('live stream entries become selectable too', (tester) async {
      await pumpPanel(tester);
      logService.error('Download failed: The connection errored');
      // The log stream is a broadcast controller: the event lands in a
      // microtask, so the widget rebuilds on the frame after that.
      await tester.pump();
      await tester.pump();

      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.textContaining('Download failed'), findsOneWidget);
      expect(find.text('No logs yet...'), findsNothing);
    });
  });
}
