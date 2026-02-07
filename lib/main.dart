import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/theme/app_theme.dart';
import 'presentation/pages/home_page.dart';
import 'presentation/providers/history_provider.dart';
import 'presentation/providers/settings_provider.dart';
import 'presentation/providers/theme_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive
  await Hive.initFlutter();

  // Initialize SharedPreferences
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

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        themeProvider.overrideWith((ref) => ThemeNotifier(prefs)),
        settingsProvider.overrideWith((ref) => SettingsNotifier(prefs)),
        historyProvider.overrideWith((ref) => HistoryNotifier(prefs)),
        downloadHistoryProvider.overrideWith((ref) => DownloadHistoryNotifier(prefs)),
      ],
      child: const PinDLApp(),
    ),
  );
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
