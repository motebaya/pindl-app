import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/neumorphism_theme.dart';

/// Neumorphism text field with ROUNDED corners and inset style
class SoftTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? hintText;
  final String? labelText;
  final String? errorText;
  final bool enabled;
  final bool obscureText;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final int? maxLines;
  final FocusNode? focusNode;

  const SoftTextField({
    super.key,
    this.controller,
    this.hintText,
    this.labelText,
    this.errorText,
    this.enabled = true,
    this.obscureText = false,
    this.keyboardType,
    this.onChanged,
    this.onEditingComplete,
    this.prefixIcon,
    this.suffixIcon,
    this.maxLines = 1,
    this.focusNode,
  });

  @override
  State<SoftTextField> createState() => _SoftTextFieldState();
}

class _SoftTextFieldState extends State<SoftTextField> {
  late FocusNode _focusNode;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    } else {
      _focusNode.removeListener(_onFocusChange);
    }
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _hasFocus = _focusNode.hasFocus;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor = NeumorphismTheme.getSurfaceColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);
    final hintColor = NeumorphismTheme.getSecondaryTextColor(isDark);
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    
    // Modern rounded radius for neumorphism input
    const double borderRadius = 16.0;
    
    // Determine border/glow state
    List<BoxShadow> shadows;
    Border? border;
    
    if (hasError) {
      // Error state: red border + inset shadows
      shadows = NeumorphismTheme.getInsetShadows(isDark, intensity: 0.5);
      border = Border.all(color: AppColors.error, width: 2);
    } else if (_hasFocus) {
      // Focused state: blue glow effect + inset shadows
      shadows = [
        ...NeumorphismTheme.getInsetShadows(isDark, intensity: 0.5),
        BoxShadow(
          color: AppColors.primary.withOpacity(0.4),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ];
      border = Border.all(color: AppColors.primary, width: 2);
    } else {
      // Normal state: inset neumorphism look
      shadows = NeumorphismTheme.getInsetShadows(isDark, intensity: 0.6);
      border = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.labelText != null) ...[
          Text(
            widget.labelText!,
            style: TextStyle(
              color: hintColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
        ],
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: border,
            boxShadow: shadows,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius - (border != null ? 2 : 0)),
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              enabled: widget.enabled,
              obscureText: widget.obscureText,
              keyboardType: widget.keyboardType,
              onChanged: widget.onChanged,
              onEditingComplete: widget.onEditingComplete,
              maxLines: widget.maxLines,
              style: TextStyle(color: textColor),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(color: hintColor.withAlpha(153)),
                prefixIcon: widget.prefixIcon,
                suffixIcon: widget.suffixIcon,
                filled: true,
                fillColor: surfaceColor,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 4),
          Text(
            widget.errorText!,
            style: const TextStyle(
              color: AppColors.error,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
