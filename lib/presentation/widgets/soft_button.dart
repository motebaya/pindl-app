import 'package:flutter/material.dart';
import '../../core/theme/neumorphism_theme.dart';

/// Neumorphism button with soft shadows and press animation
class SoftButton extends StatefulWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final bool isDisabled;
  final Color? accentColor;
  final double? width;
  final double? height;
  final EdgeInsets? padding;

  const SoftButton({
    super.key,
    this.label,
    this.icon,
    this.onPressed,
    this.isLoading = false,
    this.isDisabled = false,
    this.accentColor,
    this.width,
    this.height,
    this.padding,
  });

  @override
  State<SoftButton> createState() => _SoftButtonState();
}

class _SoftButtonState extends State<SoftButton>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.98).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isEnabled =>
      !widget.isDisabled && !widget.isLoading && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = NeumorphismTheme.getCardColor(isDark);
    final textColor = _isEnabled
        ? NeumorphismTheme.getTextColor(isDark)
        : NeumorphismTheme.getSecondaryTextColor(isDark);

    return GestureDetector(
      onTapDown: _isEnabled ? (_) => _handleTapDown() : null,
      onTapUp: _isEnabled ? (_) => _handleTapUp() : null,
      onTapCancel: _isEnabled ? _handleTapCancel : null,
      onTap: _isEnabled ? widget.onPressed : null,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnimation.value,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: widget.width,
            height: widget.height,
            padding: widget.padding ??
                const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: baseColor,
              borderRadius: BorderRadius.circular(12),
              boxShadow: _isPressed
                  ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.5)
                  : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.isLoading) ...[
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(textColor),
                    ),
                  ),
                  if (widget.label != null) const SizedBox(width: 8),
                ] else if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 18,
                    color: widget.accentColor ?? textColor,
                  ),
                  if (widget.label != null) const SizedBox(width: 8),
                ],
                if (widget.label != null)
                  Flexible(
                    child: Text(
                      widget.label!,
                      style: TextStyle(
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleTapDown() {
    setState(() => _isPressed = true);
    _controller.forward();
  }

  void _handleTapUp() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }
}

/// Icon-only soft button
class SoftIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isDisabled;
  final double size;
  final Color? iconColor;
  final String? tooltip;

  const SoftIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.isDisabled = false,
    this.size = 40,
    this.iconColor,
    this.tooltip,
  });

  @override
  State<SoftIconButton> createState() => _SoftIconButtonState();
}

class _SoftIconButtonState extends State<SoftIconButton> {
  bool _isPressed = false;

  bool get _isEnabled => !widget.isDisabled && widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = NeumorphismTheme.getCardColor(isDark);
    final iconColor = widget.iconColor ??
        (_isEnabled
            ? NeumorphismTheme.getTextColor(isDark)
            : NeumorphismTheme.getSecondaryTextColor(isDark));

    Widget button = GestureDetector(
      onTapDown: _isEnabled ? (_) => setState(() => _isPressed = true) : null,
      onTapUp: _isEnabled ? (_) => setState(() => _isPressed = false) : null,
      onTapCancel: _isEnabled ? () => setState(() => _isPressed = false) : null,
      onTap: _isEnabled ? widget.onPressed : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: baseColor,
          borderRadius: BorderRadius.circular(widget.size / 4),
          boxShadow: _isPressed
              ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.5)
              : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.6),
        ),
        child: Center(
          child: Icon(
            widget.icon,
            size: widget.size * 0.5,
            color: iconColor,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      button = Tooltip(
        message: widget.tooltip!,
        child: button,
      );
    }

    return button;
  }
}
