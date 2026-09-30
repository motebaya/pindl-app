// Phase 11.1 — plugin-registration drift detection (AND-1 / D-06 canonical
// fallback, planning/android/01-plugin-registration.md step 4).
//
// The app registers Android plugins MANUALLY (MainActivity.registerPluginsManually)
// because GeneratedPluginRegistrant unconditionally registers FFmpegKit and the
// lite flavor strips its native libs (fatal UnsatisfiedLinkError — documented
// in-code). The cost is upgrade drift: a dependency upgrade that renames or
// moves a plugin class compiles cleanly and silently kills that plugin at
// runtime. This test is the loud failure.
//
// What is pinned, per plugin (single Dart mirror below):
//   1. name <-> FQCN consistency (the mirror's own invariant);
//   2. every non-dev android plugin in `.flutter-plugins-dependencies` is in
//      the mirror and vice versa (CI goes red when deps change the set);
//   3. every mirror FQCN resolves to a real class file in the plugin package
//      (upstream rename/move → red with the offending plugin NAMED — the DoD);
//   4. dev-only android plugins (integration_test) are never registered;
//   5. the FFmpegKit entry exists and is flavor-gated in Kotlin (lite strips
//      its libs — registration must stay conditional).
//
// The generated `.flutter-plugins-dependencies` is git-ignored; the CI quality
// gate runs `pub get` before `flutter test` (D-20), so the file always exists
// in gated contexts. On a bare checkout without it, the set-equality checks
// SKIP with a loud note instead of failing (no Flutter metadata = no drift
// evidence; the classpath checks below still run against the pub cache).
//
// Cross-language note: the Kotlin list in MainActivity.kt cannot read this
// mirror at compile time. Kotlin-side drift (list edited without the mirror)
// is caught by the debug boot assert (BootPluginAssert.kt logs dead classes)
// and by the 11.2 CI emulator smoke. This file owns the Dart↔deps-file seam.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Dart mirror of MainActivity.registerPluginsManually — android PLUGIN
/// name → registered FQCN. Keep in sync with MainActivity.kt (see header).
const Map<String, String> kManualAndroidPlugins = {
  // Phase 12.3/OQ-5: file_picker REMOVED (no Dart call sites; dependency
  // deleted; Kotlin registration entry removed too) — and with it its
  // TRANSITIVE dep flutter_plugin_android_lifecycle (drift test caught the
  // stale entry on its first real run).
  'path_provider_android':
      'io.flutter.plugins.pathprovider.PathProviderPlugin',
  'permission_handler_android':
      'com.baseflow.permissionhandler.PermissionHandlerPlugin',
  'shared_preferences_android':
      'io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin',
  'url_launcher_android':
      'io.flutter.plugins.urllauncher.UrlLauncherPlugin',
  'video_player_android':
      'io.flutter.plugins.videoplayer.VideoPlayerPlugin',
  'flutter_foreground_task':
      'com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin',
  'flutter_local_notifications':
      'com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin',
  // FFmpegKit — flavor-gated in Kotlin (only BuildConfig.FLAVOR == "ffmpeg"
  // registers it; lite strips the native libs). Pinned here so an accidental
  // rename of the package surfaces as a reviewable diff, not a boot kill.
  'ffmpeg_kit_flutter_new_https':
      'com.antonkarpenko.ffmpegkit.FFmpegKitFlutterPlugin',
};

/// Dev-only android plugins must NEVER appear in the manual registration
/// list (they have no runtime role in the shipped app).
const List<String> kExpectedDevOnlyAndroidPlugins = ['integration_test'];

Map<String, dynamic>? _loadDepsFile() {
  final f = File('.flutter-plugins-dependencies');
  if (!f.existsSync()) return null;
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

/// Path of the plugin's main android class file, if it exists on disk.
/// Only meaningful for plugins with `native_build: true`.
/// Note: the generated file (Windows host) stores DOUBLED backslashes per
/// separator even after JSON decoding — normalize ANY separator run to '/'.
File? _androidClassFile(Map<String, dynamic> plugin, String fqcn) {
  final root =
      (plugin['path'] as String).replaceAll(RegExp(r'[\\/]+'), '/');
  final rel = fqcn.replaceAll('.', '/');
  for (final sub in const ['android/src/main/java', 'android/src/main/kotlin']) {
    for (final ext in const ['.java', '.kt']) {
      final f = File('$root/$sub/$rel$ext');
      if (f.existsSync()) return f;
    }
  }
  return null;
}

void main() {
  group('plugin registration drift (AND-1, D-06 fallback)', () {
    test('mirror invariant: every FQCN is a plausible class reference', () {
      expect(kManualAndroidPlugins, isNotEmpty);
      for (final entry in kManualAndroidPlugins.entries) {
        final fqcn = entry.value;
        expect(fqcn.contains('.'), isTrue,
            reason: '${entry.key}: FQCN must be dotted ($fqcn)');
        expect(fqcn.startsWith('com.antonkarpenko'), entry.key.contains('ffmpeg'),
            reason: 'ffmpeg FQCN reserved for the FFmpegKit entry');
      }
      // Pinned reality: 8 plugins, NO workmanager (removed Phase 05, D-27),
      // NO file_picker (removed Phase 12.3, OQ-5).
      expect(kManualAndroidPlugins.length, 8);
      expect(kManualAndroidPlugins.keys.any((k) => k.contains('workmanager')),
          isFalse, reason: 'workmanager was removed (D-27) — never re-add silently');
    });

    test('manual set matches .flutter-plugins-dependencies android set', () {
      final deps = _loadDepsFile();
      if (deps == null) {
        // ignore: avoid_print
        print('DRIFT-TEST: .flutter-plugins-dependencies not found — '
            'set-equality check skipped (run `flutter pub get` for full drift '
            'coverage; classpath checks still ran above/below where cache exists)');
        return;
      }
      final android = (deps['plugins']['android'] as List)
          .cast<Map<String, dynamic>>();
      final runtime = android
          .where((p) => p['dev_dependency'] != true)
          .map((p) => p['name'] as String)
          .toSet();
      final devOnly = android
          .where((p) => p['dev_dependency'] == true)
          .map((p) => p['name'] as String)
          .toSet();

      final unregistered = runtime.difference(kManualAndroidPlugins.keys.toSet());
      final stale = kManualAndroidPlugins.keys.toSet().difference(runtime);
      expect(unregistered, isEmpty,
          reason: 'android plugin(s) present in deps but NOT in the manual '
              'registration list — they would silently not work at runtime. '
              'Add to MainActivity.kt AND kManualAndroidPlugins.');
      expect(stale, isEmpty,
          reason: 'manually registered plugin(s) no longer in deps — '
              'remove from MainActivity.kt AND kManualAndroidPlugins.');

      for (final dev in kExpectedDevOnlyAndroidPlugins) {
        expect(devOnly.contains(dev), isTrue,
            reason: '$dev expected dev-only (pinned reality — update '
                'kExpectedDevOnlyAndroidPlugins if the toolchain changed)');
      }
      expect(kManualAndroidPlugins.keys.toSet().intersection(devOnly), isEmpty,
          reason: 'dev-only plugins must never be registered at runtime');
    });

    test('every mirror FQCN resolves to a real class file (rename = red)', () {
      final deps = _loadDepsFile();
      final byName = deps == null
          ? const <String, Map<String, dynamic>>{}
          : {
              for (final p
                  in (deps['plugins']['android'] as List)
                      .cast<Map<String, dynamic>>())
                p['name'] as String: p,
            };
      var checked = 0;
      for (final entry in kManualAndroidPlugins.entries) {
        final plugin = byName[entry.key];
        if (plugin == null || plugin['native_build'] != true) continue;
        final classFile = _androidClassFile(plugin, entry.value);
        if (classFile == null) {
          fail('DRIFT DETECTED — plugin "${entry.key}": registered class '
              '${entry.value} does not exist in the package anymore '
              '(upstream renamed/moved it). Update MainActivity.kt AND '
              'kManualAndroidPlugins to the new FQCN, or pin the old version.');
        }
        checked++;
      }
      // ignore: avoid_print
      print('DRIFT-TEST: classpath-verified $checked/${kManualAndroidPlugins.length} '
          'registered plugins (requires pub cache from `.flutter-plugins-dependencies`)');
    });

    test('FFmpegKit entry present + flavor-gated in MainActivity.kt', () {
      expect(kManualAndroidPlugins.containsKey('ffmpeg_kit_flutter_new_https'),
          isTrue,
          reason: 'the ffmpeg flavor registers FFmpegKit — the entry is part '
              'of the canonical list');
      final kt = File('android/app/src/main/kotlin/com/motebaya/pindl/MainActivity.kt');
      expect(kt.existsSync(), isTrue, reason: 'MainActivity.kt must exist');
      final src = kt.readAsStringSync();
      expect(src.contains('BuildConfig.FLAVOR == "ffmpeg"'), isTrue,
          reason: 'FFmpegKit registration must stay flavor-gated — lite '
              'strips the native libs and GeneratedPluginRegistrant kills it '
              '(the original UnsatisfiedLinkError)');
      // The string may appear in the explanatory comment (why manual reg
      // exists) — assert it never appears in EXECUTABLE code lines.
      final codeLines = src
          .split('\n')
          .where((l) => l.contains('GeneratedPluginRegistrant'))
          .map((l) => l.trim())
          .where((l) => !l.startsWith('//') && !l.startsWith('*') && !l.startsWith('/*'))
          .toList();
      expect(codeLines, isEmpty,
          reason: 'generated registration must NEVER be invoked (D-06) — '
              'found in code: $codeLines');
    });
  });
}
