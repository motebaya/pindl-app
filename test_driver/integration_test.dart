// Standard integration_test driver — enables `flutter drive` runs, which keep
// the app installed between runs (unlike `flutter test integration_test/...`).
// Used by the Phase 06 G4 two-process device evidence (step1 -> step2).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
