import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/neumorphism_theme.dart';

/// Neumorphism toggle switch with smooth animation
class SoftToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double height;

  const SoftToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.width = 56,
    this.height = 28,
  });

  @override
  State<SoftToggle> createState() => _SoftToggleState();
}

class _SoftToggleState extends State<SoftToggle>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _positionAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
      value: widget.value ? 1.0 : 0.0,
    );
    _setupAnimations();
  }

  void _setupAnimations() {
    _positionAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void didUpdateWidget(SoftToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trackColor = NeumorphismTheme.getSurfaceColor(isDark);
    final thumbInactiveColor = NeumorphismTheme.getCardColor(isDark);
    final thumbActiveColor =
        isDark ? AppColors.darkAccent : AppColors.lightAccent;

    return GestureDetector(
      onTap: () => widget.onChanged?.call(!widget.value),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final thumbSize = widget.height - 6;
          final maxSlide = widget.width - thumbSize - 6;
          final slidePosition = _positionAnimation.value * maxSlide;

          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(widget.height / 2),
              boxShadow:
                  NeumorphismTheme.getInsetShadows(isDark, intensity: 0.6),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 3 + slidePosition,
                  top: 3,
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      color: Color.lerp(
                        thumbInactiveColor,
                        thumbActiveColor,
                        _positionAnimation.value,
                      ),
                      borderRadius: BorderRadius.circular(thumbSize / 2),
                      boxShadow: NeumorphismTheme.getRaisedShadows(isDark,
                          intensity: 0.6),
                    ),
                    child: Center(
                      child: Icon(
                        widget.value ? Icons.light_mode : Icons.dark_mode,
                        size: thumbSize * 0.6,
                        color: widget.value
                            ? Colors.white
                            : NeumorphismTheme.getSecondaryTextColor(isDark),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
