import 'package:flutter/widgets.dart';

/// Phase 10.5 (accessibility plan §2): reduced-motion respect.
///
/// True when animations should RUN. False when the OS requests animations
/// be disabled (Android "remove animations", iOS Reduce Motion). Gate
/// NON-ESSENTIAL transitions behind this — list-item entrance effects,
/// fades. Never gate essential state feedback (spinners on async ops,
/// progress bars).
bool motionEnabled(BuildContext context) {
  final disabled = MediaQuery.maybeDisableAnimationsOf(context);
  return disabled != true;
}
