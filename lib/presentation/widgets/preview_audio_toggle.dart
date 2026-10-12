import 'package:flutter/material.dart';

/// Preview audio toggle (3.1.1).
///
/// Device report: the speaker badge on the video preview was a static
/// `Icons.volume_off` with no gesture — the preview always autoplayed muted and
/// there was no way to unmute it. This widget is the real control: a tappable,
/// screen-reader-labelled button whose icon reflects the current state.
///
/// Extracted from `home_page_preview.dart` so the control (state, label, tap
/// wiring) is widget-testable without a live `VideoPlayerController`.
class PreviewAudioToggle extends StatelessWidget {
  /// True when the preview is muted (the icon then shows `volume_off`).
  final bool muted;

  /// Called with the REQUESTED new muted state on tap.
  final void Function(bool muted) onToggle;

  /// Icon/badge size.
  final double size;

  const PreviewAudioToggle({
    super.key,
    required this.muted,
    required this.onToggle,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    final label = muted ? 'Unmute preview' : 'Mute preview';
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () => onToggle(!muted),
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: muted ? 'Unmute' : 'Mute',
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              muted ? Icons.volume_off : Icons.volume_up,
              color: Colors.white,
              size: size,
            ),
          ),
        ),
      ),
    );
  }
}
