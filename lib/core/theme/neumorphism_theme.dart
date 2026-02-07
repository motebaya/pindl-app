import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Neumorphism theme configuration
class NeumorphismTheme {
  NeumorphismTheme._();

  /// Get shadow configuration for raised elements
  static List<BoxShadow> getRaisedShadows(bool isDark, {double intensity = 1.0}) {
    if (isDark) {
      return [
        BoxShadow(
          color: AppColors.darkShadowDark.withOpacity(0.5 * intensity),
          offset: Offset(4 * intensity, 4 * intensity),
          blurRadius: 8 * intensity,
        ),
        BoxShadow(
          color: AppColors.darkShadowLight.withOpacity(0.1 * intensity),
          offset: Offset(-4 * intensity, -4 * intensity),
          blurRadius: 8 * intensity,
        ),
      ];
    }
    return [
      BoxShadow(
        color: AppColors.lightShadowDark.withOpacity(0.5 * intensity),
        offset: Offset(4 * intensity, 4 * intensity),
        blurRadius: 8 * intensity,
      ),
      BoxShadow(
        color: AppColors.lightShadowLight.withOpacity(0.9 * intensity),
        offset: Offset(-4 * intensity, -4 * intensity),
        blurRadius: 8 * intensity,
      ),
    ];
  }

  /// Get shadow configuration for pressed/inset elements
  static List<BoxShadow> getInsetShadows(bool isDark, {double intensity = 1.0}) {
    if (isDark) {
      return [
        BoxShadow(
          color: AppColors.darkShadowDark.withOpacity(0.6 * intensity),
          offset: Offset(2 * intensity, 2 * intensity),
          blurRadius: 4 * intensity,
        ),
        BoxShadow(
          color: AppColors.darkShadowLight.withOpacity(0.05 * intensity),
          offset: Offset(-2 * intensity, -2 * intensity),
          blurRadius: 4 * intensity,
        ),
      ];
    }
    return [
      BoxShadow(
        color: AppColors.lightShadowDark.withOpacity(0.4 * intensity),
        offset: Offset(2 * intensity, 2 * intensity),
        blurRadius: 4 * intensity,
      ),
      BoxShadow(
        color: AppColors.lightShadowLight.withOpacity(0.9 * intensity),
        offset: Offset(-2 * intensity, -2 * intensity),
        blurRadius: 4 * intensity,
      ),
    ];
  }

  /// Get background color based on theme
  static Color getBackgroundColor(bool isDark) {
    return isDark ? AppColors.darkBackground : AppColors.lightBackground;
  }

  /// Get surface color based on theme
  static Color getSurfaceColor(bool isDark) {
    return isDark ? AppColors.darkSurface : AppColors.lightSurface;
  }

  /// Get card color based on theme
  static Color getCardColor(bool isDark) {
    return isDark ? AppColors.darkCard : AppColors.lightCard;
  }

  /// Get accent color based on theme
  static Color getAccentColor(bool isDark) {
    return isDark ? AppColors.darkAccent : AppColors.lightAccent;
  }

  /// Get text color based on theme
  static Color getTextColor(bool isDark) {
    return isDark ? AppColors.darkText : AppColors.lightText;
  }

  /// Get secondary text color based on theme
  static Color getSecondaryTextColor(bool isDark) {
    return isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary;
  }

  /// Default border radius for neumorphism elements
  static const double defaultBorderRadius = 16.0;

  /// Small border radius
  static const double smallBorderRadius = 8.0;

  /// Large border radius
  static const double largeBorderRadius = 24.0;
}
