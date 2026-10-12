import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/neumorphism_theme.dart';
import '../../data/services/log_service.dart';

/// Console panel widget for displaying logs
class ConsolePanel extends StatefulWidget {
  final Stream<LogEntry> logStream;
  final List<LogEntry> initialEntries;
  final int maxLines;
  final double height;

  const ConsolePanel({
    super.key,
    required this.logStream,
    this.initialEntries = const [],
    this.maxLines = 300,
    this.height = 200,
  });

  @override
  State<ConsolePanel> createState() => _ConsolePanelState();
}

class _ConsolePanelState extends State<ConsolePanel> {
  final _scrollController = ScrollController();
  final _logs = <LogEntry>[];
  bool _autoScroll = true;
  StreamSubscription<LogEntry>? _subscription;

  @override
  void initState() {
    super.initState();
    _logs.addAll(widget.initialEntries);
    _subscription = widget.logStream.listen(_addLog);
  }

  /// Plain-text rendering of one log line — the exact string the user sees.
  String _lineText(LogEntry entry) =>
      '[${_formatTime(entry.timestamp)}] [${entry.level.name.toUpperCase()}] '
      '${entry.message}';

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  Future<void> _copyAll() async {
    final text = _logs.map(_lineText).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied ${_logs.length} log line(s)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _addLog(LogEntry entry) {
    setState(() {
      _logs.add(entry);
      if (_logs.length > widget.maxLines) {
        _logs.removeRange(0, _logs.length - widget.maxLines);
      }
    });

    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0);
    final borderColor = isDark ? Colors.grey.shade800 : Colors.grey.shade300;
    final headerColor =
        isDark ? Colors.grey.shade900 : Colors.grey.shade200;

    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.5),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: headerColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 14,
                  color: isDark ? Colors.green.shade400 : Colors.green.shade700,
                ),
                const SizedBox(width: 6),
                Text(
                  'Console',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                  ),
                ),
                const Spacer(),
                // 3.1.1: one-tap copy of the whole console so a user hitting an
                // error can hand the log over without selecting line by line.
                _ConsoleAction(
                  icon: Icons.copy_all_outlined,
                  tooltip: 'Copy all logs',
                  isDark: isDark,
                  onTap: _logs.isEmpty ? null : _copyAll,
                ),
                _ConsoleAction(
                  icon: _autoScroll
                      ? Icons.vertical_align_bottom
                      : Icons.pause,
                  tooltip: _autoScroll ? 'Pause scroll' : 'Auto scroll',
                  isDark: isDark,
                  onTap: () => setState(() => _autoScroll = !_autoScroll),
                ),
                _ConsoleAction(
                  icon: Icons.delete_outline,
                  tooltip: 'Clear logs',
                  isDark: isDark,
                  onTap: () => setState(() => _logs.clear()),
                ),
              ],
            ),
          ),
          // Log content — selectable (3.1.1): users must be able to copy an
          // error out of the console verbatim.
          Expanded(
            child: _logs.isEmpty
                ? Center(
                    child: Text(
                      'No logs yet...',
                      style: TextStyle(
                        color: isDark
                            ? Colors.grey.shade600
                            : Colors.grey.shade500,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        final log = _logs[index];
                        return _LogLine(entry: log, isDark: isDark);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Small header action button (console panel chrome).
class _ConsoleAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isDark;
  final VoidCallback? onTap;

  const _ConsoleAction({
    required this.icon,
    required this.tooltip,
    required this.isDark,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Icon(
              icon,
              size: 16,
              color: onTap == null
                  ? (isDark ? Colors.grey.shade700 : Colors.grey.shade400)
                  : (isDark ? Colors.grey.shade400 : Colors.grey.shade700),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final LogEntry entry;
  final bool isDark;

  const _LogLine({required this.entry, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? Colors.grey.shade300 : Colors.grey.shade800;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: textColor,
          ),
          children: [
            TextSpan(
              text: '[${_formatTime(entry.timestamp)}] ',
              style: TextStyle(color: Colors.blue.shade400),
            ),
            TextSpan(
              text: '[${entry.level.name.toUpperCase()}] ',
              style: TextStyle(color: entry.color),
            ),
            TextSpan(text: entry.message),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }
}
