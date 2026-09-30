import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:ui' show CheckedState, Tristate;
import 'package:pindl/presentation/widgets/soft_checkbox.dart';
import 'package:pindl/presentation/widgets/soft_toggle.dart';

void main() {
  group('soft widget semantics (Phase 10.5 — UX-5)', () {
    testWidgets('SoftToggle exposes toggled state + label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SoftToggle(
            value: true,
            onChanged: (_) {},
            semanticLabel: 'Dark theme',
          ),
        ),
      ));

      final semantics = tester.getSemantics(find.byType(SoftToggle));
      expect(semantics.flagsCollection.isToggled != Tristate.none, isTrue);
      expect(semantics.flagsCollection.isToggled == Tristate.isTrue, isTrue);
      expect(semantics.label, 'Dark theme');
    });

    testWidgets('SoftToggle untoggled state is announced', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SoftToggle(value: false, semanticLabel: 'Verbose logs'),
        ),
      ));
      final semantics = tester.getSemantics(find.byType(SoftToggle));
      expect(semantics.flagsCollection.isToggled != Tristate.none, isTrue);
      expect(semantics.flagsCollection.isToggled == Tristate.isTrue, isFalse);
    });

    testWidgets('Semantics tap toggles the control', (tester) async {
      var value = false;
      await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SoftToggle(
              value: value,
              semanticLabel: 'Continue',
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ));
      // Toggle via the gesture surface (a11y services route taps here).
      await tester.tap(find.byType(SoftToggle));
      await tester.pump();
      final semantics = tester.getSemantics(find.byType(SoftToggle));
      expect(semantics.flagsCollection.isToggled == Tristate.isTrue, isTrue);
    });

    testWidgets('SoftCheckbox exposes checked state + label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SoftCheckbox(
            value: true,
            label: 'Save metadata',
            onChanged: (_) {},
          ),
        ),
      ));
      final semantics = tester.getSemantics(find.byType(SoftCheckbox));
      expect(semantics.flagsCollection.isChecked != CheckedState.none, isTrue);
      expect(semantics.flagsCollection.isChecked == CheckedState.isTrue, isTrue);
      expect(semantics.label, 'Save metadata');
    });

    testWidgets('SoftCheckbox unchecked announces not-checked', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SoftCheckbox(value: false, label: 'Overwrite'),
        ),
      ));
      final semantics = tester.getSemantics(find.byType(SoftCheckbox));
      expect(semantics.flagsCollection.isChecked != CheckedState.none, isTrue);
      expect(semantics.flagsCollection.isChecked == CheckedState.isTrue, isFalse);
    });

    testWidgets('SoftRadio exposes selected state + label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SoftRadio<String>(
                value: 'whole',
                groupValue: 'whole',
                label: 'Whole board',
                onChanged: (_) {},
              ),
              SoftRadio<String>(
                value: 'sections',
                groupValue: 'whole',
                label: 'Pick sections',
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ));
      final selected =
          tester.getSemantics(find.byWidgetPredicate((w) => w is SoftRadio<String> && w.value == 'whole'));
      final unselected =
          tester.getSemantics(find.byWidgetPredicate((w) => w is SoftRadio<String> && w.value == 'sections'));
      expect(selected.flagsCollection.isSelected != Tristate.none, isTrue);
      expect(selected.flagsCollection.isSelected == Tristate.isTrue, isTrue);
      expect(unselected.flagsCollection.isSelected == Tristate.isTrue, isFalse);
    });
  });
}
