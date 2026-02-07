import 'package:flutter/material.dart';

/// App color palette for Neumorphism theme
class AppColors {
  AppColors._();

  // Primary color - BLUE
  static const Color primary = Color(0xFF4A90D9);  // Modern neutral blue
  static const Color primaryLight = Color(0xFF7AB8FF);
  static const Color primaryDark = Color(0xFF2C5F8A);

  // Light theme colors
  static const Color lightBackground = Color(0xFFE8E8E8);
  static const Color lightSurface = Color(0xFFE0E0E0);
  static const Color lightCard = Color(0xFFE4E4E4);
  static const Color lightShadowDark = Color(0xFFBEBEBE);
  static const Color lightShadowLight = Color(0xFFFFFFFF);
  static const Color lightAccent = Color(0xFF4A90D9);  // Blue accent
  static const Color lightText = Color(0xFF424242);
  static const Color lightTextSecondary = Color(0xFF757575);

  // Dark theme colors
  static const Color darkBackground = Color(0xFF2D2D2D);
  static const Color darkSurface = Color(0xFF333333);
  static const Color darkCard = Color(0xFF3A3A3A);
  static const Color darkShadowDark = Color(0xFF1A1A1A);
  static const Color darkShadowLight = Color(0xFF404040);
  static const Color darkAccent = Color(0xFF5C9CE5);  // Blue accent for dark
  static const Color darkText = Color(0xFFE0E0E0);
  static const Color darkTextSecondary = Color(0xFFBDBDBD);

  // Shared colors
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFE57373);
  static const Color warning = Color(0xFFFFB74D);  // Yellow for warnings only
  static const Color info = Color(0xFF64B5F6);

  // Console colors
  static const Color consoleInit = Color(0xFF00BCD4);
  static const Color consoleValidate = Color(0xFF009688);
  static const Color consoleConfig = Color(0xFF9C27B0);
  static const Color consoleFetch = Color(0xFF2196F3);
  static const Color consoleParse = Color(0xFF3F51B5);
  static const Color consoleQueue = Color(0xFFFF9800);
  static const Color consoleDownloading = Color(0xFFFFC107);
  static const Color consoleSaved = Color(0xFF4CAF50);
  static const Color consoleSkipped = Color(0xFFCDDC39);
  static const Color consoleError = Color(0xFFF44336);
  static const Color consoleInterrupted = Color(0xFFFF5722);
  static const Color consoleComplete = Color(0xFF8BC34A);
}
