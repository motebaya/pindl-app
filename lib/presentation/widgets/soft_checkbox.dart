import 'package:flutter/material.dart';
import '../../core/theme/neumorphism_theme.dart';

/// Neumorphism checkbox - supports compact mode for grid layouts
/// Labels use PlaypenSans-Bold for clear visibility
class SoftCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final bool enabled;
  final bool compact;

  const SoftCheckbox({
    super.key,
    required this.value,
    this.onChanged,
    this.label,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = NeumorphismTheme.getCardColor(isDark);
    final accentColor = NeumorphismTheme.getAccentColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);

    // Size based on compact mode
    final double boxSize = compact ? 18 : 22;
    final double iconSize = compact ? 12 : 16;
    final double fontSize = compact ? 12 : 14;
    final double spacing = compact ? 6 : 10;

    return GestureDetector(
      onTap: enabled ? () => onChanged?.call(!value) : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: compact 
            ? const EdgeInsets.symmetric(vertical: 4) 
            : EdgeInsets.zero,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: boxSize,
              height: boxSize,
              decoration: BoxDecoration(
                color: value ? accentColor : cardColor,
                borderRadius: BorderRadius.circular(compact ? 4 : 6),
                boxShadow: value
                    ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4)
                    : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.5),
              ),
              child: value
                  ? Icon(
                      Icons.check,
                      size: iconSize,
                      color: Colors.white,
                    )
                  : null,
            ),
            if (label != null) ...[
              SizedBox(width: spacing),
              Text(
                label!,
                style: TextStyle(
                  color: enabled
                      ? textColor
                      : NeumorphismTheme.getSecondaryTextColor(isDark),
                  fontSize: fontSize,
                  fontFamily: 'PlaypenSans',
                  fontWeight: FontWeight.w700, // Bold
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Neumorphism radio button - supports compact mode for grid layouts
/// Labels use PlaypenSans-Bold for clear visibility
class SoftRadio<T> extends StatelessWidget {
  final T value;
  final T groupValue;
  final ValueChanged<T>? onChanged;
  final String? label;
  final bool enabled;
  final bool compact;

  const SoftRadio({
    super.key,
    required this.value,
    required this.groupValue,
    this.onChanged,
    this.label,
    this.enabled = true,
    this.compact = false,
  });

  bool get _isSelected => value == groupValue;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = NeumorphismTheme.getCardColor(isDark);
    final accentColor = NeumorphismTheme.getAccentColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);

    // Size based on compact mode
    final double boxSize = compact ? 18 : 22;
    final double innerSize = compact ? 9 : 12;
    final double fontSize = compact ? 12 : 14;
    final double spacing = compact ? 6 : 10;

    return GestureDetector(
      onTap: enabled ? () => onChanged?.call(value) : null,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: compact 
            ? const EdgeInsets.symmetric(vertical: 4) 
            : EdgeInsets.zero,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: boxSize,
              height: boxSize,
              decoration: BoxDecoration(
                color: cardColor,
                shape: BoxShape.circle,
                boxShadow: _isSelected
                    ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4)
                    : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.5),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: _isSelected ? innerSize : 0,
                  height: _isSelected ? innerSize : 0,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            if (label != null) ...[
              SizedBox(width: spacing),
              Text(
                label!,
                style: TextStyle(
                  color: enabled
                      ? textColor
                      : NeumorphismTheme.getSecondaryTextColor(isDark),
                  fontSize: fontSize,
                  fontFamily: 'PlaypenSans',
                  fontWeight: FontWeight.w700, // Bold
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
