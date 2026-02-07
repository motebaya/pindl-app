import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/neumorphism_theme.dart';
import '../../data/models/history_item.dart';
import '../providers/history_provider.dart';
import '../widgets/soft_button.dart';
import '../widgets/soft_card.dart';

/// Downloads page showing download history
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  bool _isClearing = false;

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _clearAll() {
    setState(() => _isClearing = true);
    Future.delayed(const Duration(milliseconds: 300), () {
      ref.read(downloadHistoryProvider.notifier).clearAll();
      if (mounted) setState(() => _isClearing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final historyState = ref.watch(downloadHistoryProvider);

    return Scaffold(
      backgroundColor: NeumorphismTheme.getBackgroundColor(isDark),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _buildTopBar(context, isDark, historyState),

            // Content
            Expanded(
              child: historyState.items.isEmpty
                  ? _buildEmptyState(isDark)
                  : _buildHistoryList(isDark, historyState),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, bool isDark, DownloadHistoryState historyState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SoftIconButton(
            icon: Icons.arrow_back,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Downloads',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: NeumorphismTheme.getTextColor(isDark),
                  ),
                ),
                Text(
                  'showing ${historyState.items.length} items of max 1000',
                  style: TextStyle(
                    fontSize: 11,
                    color: NeumorphismTheme.getSecondaryTextColor(isDark),
                  ),
                ),
              ],
            ),
          ),
          // Sort toggle
          SoftIconButton(
            icon: historyState.sortDescending
                ? Icons.arrow_downward
                : Icons.arrow_upward,
            tooltip: historyState.sortDescending ? 'Newest first' : 'Oldest first',
            onPressed: () => ref.read(downloadHistoryProvider.notifier).toggleSort(),
          ),
          const SizedBox(width: 8),
          // Clear all
          if (historyState.items.isNotEmpty)
            SoftIconButton(
              icon: Icons.delete_outline,
              iconColor: AppColors.error,
              tooltip: 'Clear all',
              onPressed: _clearAll,
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SoftCard(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download_done,
                  size: 48,
                  color: NeumorphismTheme.getSecondaryTextColor(isDark),
                ),
                const SizedBox(height: 16),
                Text(
                  'No Downloads Yet',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: NeumorphismTheme.getTextColor(isDark),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your download history will appear here',
                  style: TextStyle(
                    fontSize: 14,
                    color: NeumorphismTheme.getSecondaryTextColor(isDark),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryList(bool isDark, DownloadHistoryState historyState) {
    final items = historyState.sortedItems;

    return AnimatedOpacity(
      opacity: _isClearing ? 0 : 1,
      duration: const Duration(milliseconds: 300),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        separatorBuilder: (_, __) => Divider(
          height: 24,
          color: NeumorphismTheme.getSecondaryTextColor(isDark).withOpacity(0.3),
        ),
        itemBuilder: (context, index) {
          final item = items[index];
          return _buildHistoryItem(isDark, item);
        },
      ),
    );
  }

  Widget _buildHistoryItem(bool isDark, DownloadHistoryItem item) {
    final statusColor = _getStatusColor(item.status);
    
    return GestureDetector(
      onLongPress: () => _copyToClipboard(item.toDisplayString()),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NeumorphismTheme.getSurfaceColor(isDark),
          borderRadius: BorderRadius.circular(8),
          boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.3),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Filename
            Text(
              item.filename,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: NeumorphismTheme.getTextColor(isDark),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            // URL
            Text(
              item.url,
              style: TextStyle(
                fontSize: 12,
                color: NeumorphismTheme.getSecondaryTextColor(isDark),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            // Status and date
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    item.status.name,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'date: ${item.toDisplayString().split('date: ').last}',
                    style: TextStyle(
                      fontSize: 11,
                      color: NeumorphismTheme.getSecondaryTextColor(isDark),
                    ),
                  ),
                ),
              ],
            ),
            // Long press hint
            const SizedBox(height: 4),
            Text(
              'Long press to copy',
              style: TextStyle(
                fontSize: 10,
                fontStyle: FontStyle.italic,
                color: NeumorphismTheme.getSecondaryTextColor(isDark).withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 200.ms).slideX(begin: 0.05);
  }

  Color _getStatusColor(HistoryStatus status) {
    switch (status) {
      case HistoryStatus.success:
        return AppColors.success;
      case HistoryStatus.failed:
        return AppColors.error;
      case HistoryStatus.cancelled:
        return AppColors.warning;
      case HistoryStatus.pending:
        return AppColors.primary;
      case HistoryStatus.skipped:
        return AppColors.warning;
    }
  }
}
