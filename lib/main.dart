import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/theme/app_theme.dart';
import 'data/models/background_task_state.dart';
import 'data/services/history_hive_store.dart';
import 'data/services/task_state_persistence.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/providers/history_provider.dart';
import 'presentation/providers/settings_provider.dart';
import 'presentation/providers/theme_provider.dart';

// Phase 05 (BG-1/DD-2/OQ-3 decision gate — Option B, D-27): the pretend
// WorkManager recovery machinery was REMOVED, not implemented. The no-op
// dispatcher advertised recovery that did not exist (P4 violation). Real
// interruption recovery is the metadata/Hive resume prompt at next app open
// (_checkInterruptedTasks) — honest by construction. Option A (a real
// background-isolate recovery notification) remains a documented future
// candidate requiring instrumented OEM evidence before landing.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // Initialize Hive (uses path_provider platform channel)
    await Hive.initFlutter();

    // Register Hive adapters (BackgroundTaskState = TypeId 1; history
    // adapters 2–4 registered inside HistoryHiveStore.open*).
    Hive.registerAdapter(BackgroundTaskStateAdapter());

    // Open Hive boxes
    await Hive.openBox<BackgroundTaskState>(TaskStatePersistence.boxName);

    // Initialize SharedPreferences (uses platform channel)
    final prefs = await SharedPreferences.getInstance();

    // Set preferred orientations
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    // Set system UI overlay style
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));

    // Phase 12.5 (PERF-2): histories open in Hive (with idempotent SP→Hive
    // migration) BEFORE overrides — the notifiers get O(1) stores.
    final extractionStore = await HistoryHiveStore.openExtraction(prefs);
    final downloadStore = await HistoryHiveStore.openDownloads(prefs);

    runApp(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          themeProvider.overrideWith((ref) => ThemeNotifier(prefs)),
          settingsProvider.overrideWith((ref) => SettingsNotifier(prefs)),
          historyProvider.overrideWith((ref) => HistoryNotifier(extractionStore)),
          downloadHistoryProvider
              .overrideWith((ref) => DownloadHistoryNotifier(downloadStore)),
        ],
        child: const PinDLApp(),
      ),
    );
  } catch (e, stackTrace) {
    // If plugin registration failed (e.g., FFmpegKit crash killing all channels),
    // Hive.initFlutter() or SharedPreferences.getInstance() will throw a
    // PlatformException. Without this catch, the app stays on the splash screen
    // forever because main() never reaches runApp().
    debugPrint('Fatal error during app initialization: $e');
    debugPrint('$stackTrace');
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFFFAFAFA),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'Failed to initialize PinDL',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$e',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                    textAlign: TextAlign.center,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Please restart the app or reinstall.',
                    style: TextStyle(fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Main app widget
class PinDLApp extends ConsumerWidget {
  const PinDLApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      title: 'PinDL',
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: const HomePage(),
    );
  }
}
