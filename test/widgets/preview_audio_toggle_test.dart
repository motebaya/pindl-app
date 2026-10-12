import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/presentation/widgets/preview_audio_toggle.dart';

/// 3.1.1 device-report fix: the speaker badge on the video preview was a static
/// `Icons.volume_off` with no gesture, so a preview could never be unmuted.
/// The control must be a real button whose icon and label track its state.
void main() {
  group('preview audio toggle (3.1.1)', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool muted,
      required void Function(bool) onToggle,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PreviewAudioToggle(muted: muted, onToggle: onToggle),
        ),
      ));
    }

    testWidgets('muted state shows the off icon and announces "Unmute preview"',
        (tester) async {
      await pump(tester, muted: true, onToggle: (_) {});
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(find.byIcon(Icons.volume_up), findsNothing);

      final semantics = tester.getSemantics(find.byType(PreviewAudioToggle));
      expect(semantics.label, 'Unmute preview');
    });

    testWidgets('unmuted state shows the on icon and announces "Mute preview"',
        (tester) async {
      await pump(tester, muted: false, onToggle: (_) {});
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(find.byIcon(Icons.volume_off), findsNothing);

      final semantics = tester.getSemantics(find.byType(PreviewAudioToggle));
      expect(semantics.label, 'Mute preview');
    });

    testWidgets('tapping a muted toggle requests unmute', (tester) async {
      final requests = <bool>[];
      await pump(tester, muted: true, onToggle: requests.add);

      await tester.tap(find.byType(PreviewAudioToggle));
      await tester.pump();

      expect(requests, [false]);
    });

    testWidgets('tapping an unmuted toggle requests mute', (tester) async {
      final requests = <bool>[];
      await pump(tester, muted: false, onToggle: requests.add);

      await tester.tap(find.byType(PreviewAudioToggle));
      await tester.pump();

      expect(requests, [true]);
    });

    testWidgets('the whole badge is the hit target, not just the glyph',
        (tester) async {
      final requests = <bool>[];
      await pump(tester, muted: true, onToggle: requests.add);

      // Tap a corner of the padded badge: the GestureDetector is opaque, so the
      // decoration area must register the tap (the old static Icon had none).
      final rect = tester.getRect(find.byType(PreviewAudioToggle));
      await tester.tapAt(rect.topLeft + const Offset(3, 3));
      await tester.pump();

      expect(requests, [false]);
    });
  });
}
