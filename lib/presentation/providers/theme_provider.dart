import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Theme mode state notifier
class ThemeNotifier extends StateNotifier<ThemeMode> {
  static const _key = 'theme_mode';
  final SharedPreferences? _prefs;

  ThemeNotifier(this._prefs) : super(_loadInitialTheme(_prefs));

  static ThemeMode _loadInitialTheme(SharedPreferences? prefs) {
    final value = prefs?.getString(_key);
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  void setThemeMode(ThemeMode mode) {
    state = mode;
    _prefs?.setString(_key, mode.name);
  }

  void toggleTheme(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    if (state == ThemeMode.system) {
      // If system, toggle based on current brightness
      setThemeMode(
          brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
    } else {
      setThemeMode(state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
    }
  }

  bool isDark(BuildContext context) {
    if (state == ThemeMode.system) {
      return MediaQuery.of(context).platformBrightness == Brightness.dark;
    }
    return state == ThemeMode.dark;
  }
}

/// Provider for SharedPreferences
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) => null);

/// Provider for theme notifier
final themeProvider = StateNotifierProvider<ThemeNotifier, ThemeMode>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return ThemeNotifier(prefs);
});
