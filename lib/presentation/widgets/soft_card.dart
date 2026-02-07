import 'package:flutter/material.dart';
import '../../core/theme/neumorphism_theme.dart';

/// Neumorphism card widget with soft shadows
class SoftCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final EdgeInsets? margin;
  final double borderRadius;
  final bool isInset;
  final Color? color;
  final double shadowIntensity;

  const SoftCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.isInset = false,
    this.color,
    this.shadowIntensity = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = color ?? NeumorphismTheme.getCardColor(isDark);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: margin,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: baseColor,
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: isInset
            ? NeumorphismTheme.getInsetShadows(isDark, intensity: shadowIntensity)
            : NeumorphismTheme.getRaisedShadows(isDark, intensity: shadowIntensity),
      ),
      child: child,
    );
  }
}
