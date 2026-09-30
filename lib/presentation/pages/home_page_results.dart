// Part of `home_page.dart` (same library via `part`) — Phase 08.6 file
// split: the results card + download-confirmation group.
part of 'home_page.dart';

extension _HomePageResults on _HomePageState {
  /// Result info card - shows extracted metadata
  /// Displays: username, name, user ID, and total items to download
  /// For single pin: shows image/video preview with independent border
  /// For username: shows avatar preview
  /// In continue mode: shows remaining items and previous stats
  Widget _buildResultsSection(bool isDark, AppJobState jobState, SettingsState settings) {
    final isSinglePin = jobState.singlePinResult != null;
    final singleResult = jobState.singlePinResult;
    final isUsernameMode = jobState.isUsername && !isSinglePin;
    final isContinueMode = jobState.isContinueMode;
    
    // Calculate total to download based on selected media type
    int totalToDownload;
    int remainingToDownload;
    if (isSinglePin) {
      // For single pin with multi-select
      int count = 0;
      if (settings.downloadImage && (singleResult?.hasImage ?? false)) count++;
      if (settings.downloadVideo && (singleResult?.hasVideoContent ?? false)) count++;
      totalToDownload = count;
      remainingToDownload = count;
    } else {
      totalToDownload = settings.mediaType == MediaType.video 
          ? jobState.totalVideos 
          : jobState.totalImages;
      remainingToDownload = settings.mediaType == MediaType.video 
          ? jobState.remainingVideos 
          : jobState.remainingImages;
    }
    
    // Check if all items are already downloaded:
    // 1. Continue mode with 0 remaining items for this media type
    // 2. Per-type completion flag set (unless overwrite is enabled)
    final allDownloadedContinue = isContinueMode && remainingToDownload == 0;
    final bool currentTypeFullyDownloaded;
    if (isSinglePin) {
      final imagesDone = !settings.downloadImage || jobState.imagesFullyDownloaded;
      final videosDone = !settings.downloadVideo || jobState.videosFullyDownloaded;
      currentTypeFullyDownloaded = imagesDone && videosDone;
    } else {
      currentTypeFullyDownloaded = settings.mediaType == MediaType.video
          ? jobState.videosFullyDownloaded
          : jobState.imagesFullyDownloaded;
    }
    final typeBlocked = currentTypeFullyDownloaded && !settings.overwrite;
    final allDownloaded = allDownloadedContinue || typeBlocked;
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NeumorphismTheme.getSurfaceColor(isDark),
        borderRadius: BorderRadius.circular(12),
        boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                allDownloaded 
                    ? Icons.close 
                    : (isContinueMode ? Icons.refresh : Icons.check_circle_outline),
                size: 14,
                color: allDownloaded 
                    ? AppColors.error 
                    : (isContinueMode ? AppColors.primary : AppColors.success),
              ),
              const SizedBox(width: 6),
              Text(
                allDownloaded 
                    ? 'No items to continue' 
                    : (isContinueMode ? 'Ready to Continue' : 'Ready to Download'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: NeumorphismTheme.getSecondaryTextColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          
          // REVISION 4: Avatar on LEFT, stats on RIGHT (username mode only)
          if (isUsernameMode && jobState.author != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar - rounded square (left)
                if (jobState.author?.avatarUrl != null)
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12), // Rounded square
                      border: Border.all(
                        color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
                        width: 2,
                      ),
                      boxShadow: NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.5),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.network(
                        jobState.author!.avatarUrl!,
                        width: 70,
                        height: 70,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: loadingProgress.expectedTotalBytes != null
                                  ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                  : null,
                              strokeWidth: 2,
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: NeumorphismTheme.getSurfaceColor(isDark),
                            child: Icon(
                              Icons.person,
                              size: 35,
                              color: NeumorphismTheme.getSecondaryTextColor(isDark),
                            ),
                          );
                        },
                      ),
                    ),
                  )
                else
                  Container(
                    width: 70,
                    height: 70,
                    decoration: BoxDecoration(
                      color: NeumorphismTheme.getSurfaceColor(isDark),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.person,
                      size: 35,
                      color: NeumorphismTheme.getSecondaryTextColor(isDark),
                    ),
                  ),
                const SizedBox(width: 12),
                // Stats on RIGHT
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildResultRow(isDark, 'Username', '@${jobState.author!.username}'),
                      _buildResultRow(isDark, 'Name', jobState.author!.name),
                      _buildResultRow(isDark, 'User ID', jobState.author!.userId),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          
          // Author info for single pin (non-username mode)
          if (!isUsernameMode && jobState.author != null) ...[
            _buildResultRow(isDark, 'Username', '@${jobState.author!.username}'),
            _buildResultRow(isDark, 'Name', jobState.author!.name),
            _buildResultRow(isDark, 'User ID', jobState.author!.userId),
          ],
          
          const Divider(height: 16),
          
          // Continue mode: show accumulated progress from all previous sessions
          if (isContinueMode && isUsernameMode) ...[
            _buildResultRow(
              isDark, 
              'Total Progress',
              '${jobState.previousDownloaded} downloaded, ${jobState.previousSkipped} skipped, ${jobState.previousFailed} failed',
            ),
            if (jobState.wasInterrupted) ...[
              Container(
                margin: const EdgeInsets.only(top: 4, bottom: 4),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: AppColors.warning.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber, size: 12, color: AppColors.warning),
                    const SizedBox(width: 4),
                    Text(
                      'Previous session was interrupted',
                      style: TextStyle(fontSize: 10, color: AppColors.warning),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 12),
          ],
          
          // Total/Remaining to download
          _buildResultRow(
            isDark, 
            isContinueMode ? 'Remaining Items' : 'Total to Download', 
            isSinglePin
                ? '$totalToDownload item${totalToDownload != 1 ? 's' : ''}'
                : isContinueMode
                    ? '$remainingToDownload ${settings.mediaType.name}${remainingToDownload != 1 ? 's' : ''} (of $totalToDownload total)'
                    : '$totalToDownload ${settings.mediaType.name}${totalToDownload != 1 ? 's' : ''}',
            highlight: true,
          ),
          
          // Media preview for single pin
          if (isSinglePin && settings.showPreview && singleResult != null) ...[
            const SizedBox(height: 12),
            _buildMediaPreview(isDark, singleResult),
          ],
          
          // Warning messages for single pin
          if (isSinglePin && singleResult != null) ...[
            // Warning: Image selected but only video available
            if (settings.downloadImage && !singleResult.hasImage && singleResult.hasVideoContent) ...[
              const SizedBox(height: 8),
              _buildWarningMessage(
                isDark,
                'No image available. Thumbnail will be downloaded instead.',
                Icons.image_not_supported,
              ),
            ],
            // Error: Video selected but no video available
            if (settings.downloadVideo && !singleResult.hasVideoContent) ...[
              const SizedBox(height: 8),
              _buildErrorMessage(
                isDark,
                'No video available for this pin.',
                Icons.videocam_off,
              ),
            ],
          ],

          // Phase 07 (07.5): "Fetch more" — shown only when the last feed
          // extraction ended capped and left a resumable bookmark context.
          // The provider re-verifies the full provenance on press (D-34).
          if (isUsernameMode && jobState.canFetchMore && !jobState.isDownloading) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  ref.read(jobProvider.notifier).fetchMore(
                        mediaType: settings.mediaType,
                        maxPages: settings.maxPages,
                        saveMetadata: settings.saveMetadata,
                      );
                },
                icon: const Icon(Icons.download_for_offline_outlined, size: 16),
                label: const Text(
                  'Fetch more',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDownloadConfirmation(bool isDark, AppJobState jobState, SettingsState settings) {
    // outputPath is no longer required - we use a fixed path Downloads/PinDL
    final canDownload = jobState.canDownload;
    final isDownloading = jobState.isDownloading;
    final isCompleted = jobState.status == JobStatus.completed;
    final isContinueMode = jobState.isContinueMode;
    final isSinglePin = jobState.singlePinResult != null;
    
    // Calculate remaining items for continue mode
    final remainingToDownload = settings.mediaType == MediaType.video 
        ? jobState.remainingVideos 
        : jobState.remainingImages;
    final allDownloadedContinue = isContinueMode && remainingToDownload == 0;
    
    // Per-type completion check: disable button if this media type was already
    // fully downloaded in the current session (or loaded from metadata).
    // Overwrite mode bypasses this — user explicitly wants to re-download.
    final bool currentTypeFullyDownloaded;
    if (isSinglePin) {
      // Single pin: check per-checkbox flags
      final imagesDone = !settings.downloadImage || jobState.imagesFullyDownloaded;
      final videosDone = !settings.downloadVideo || jobState.videosFullyDownloaded;
      currentTypeFullyDownloaded = imagesDone && videosDone;
    } else {
      // Username mode: check per-radio selection
      currentTypeFullyDownloaded = settings.mediaType == MediaType.video
          ? jobState.videosFullyDownloaded
          : jobState.imagesFullyDownloaded;
    }
    final typeBlocked = currentTypeFullyDownloaded && !settings.overwrite;
    
    final allDownloaded = allDownloadedContinue || typeBlocked;
    
    // Use a dummy path - actual path is handled by MediaStore in download_service
    const outputPath = 'Downloads/PinDL';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: SoftButton(
                // Show different states based on continue mode
                label: allDownloaded 
                    ? 'All downloaded' 
                    : (isContinueMode ? 'Continue Download' : 'Download'),
                icon: isDownloading 
                    ? null 
                    : (allDownloaded 
                        ? Icons.check_circle 
                        : (isContinueMode ? Icons.play_arrow : Icons.download)),
                accentColor: allDownloaded ? AppColors.success : null,
                isLoading: isDownloading,
                isDisabled: allDownloaded || isDownloading || (!canDownload),
                onPressed: (canDownload && !allDownloaded)
                    ? () {
                        ref.read(jobProvider.notifier).startDownload(
                              outputPath: outputPath,
                              mediaType: settings.mediaType,
                              overwrite: settings.overwrite,
                              downloadImage: settings.downloadImage,
                              downloadVideo: settings.downloadVideo,
                              saveMetadata: settings.saveMetadata,
                            );
                      }
                    : null,
              ),
            ),
            // Stop button appears next to download button when downloading
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: isDownloading
                  ? Row(
                      children: [
                        const SizedBox(width: 12),
                        SoftIconButton(
                          icon: Icons.stop,
                          iconColor: AppColors.error,
                          tooltip: 'Stop download',
                          onPressed: () => _showConfirmDialog(
                            title: 'Stop Download',
                            message:
                                'This will interrupt all downloads. You may be able to resume if metadata is enabled. Continue?',
                            onConfirm: () => ref.read(jobProvider.notifier).cancelDownload(),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
        
        // Green info message when all items are already downloaded
        if (allDownloaded) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.success.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.success.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 14, color: AppColors.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'All items have already been downloaded. Run a fresh download with overwrite mode if you want to re-download.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        // Progress stats (shown during download, after completion, or after interruption)
        if (isDownloading || isCompleted || jobState.status == JobStatus.cancelled) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: NeumorphismTheme.getSurfaceColor(isDark),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(isDark, 'Downloaded', '${jobState.downloadedCount}', AppColors.success),
                _buildStatItem(isDark, 'Skipped', '${jobState.skippedCount}', AppColors.warning),
                _buildStatItem(isDark, 'Failed', '${jobState.failedCount}', AppColors.error),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Phase 10 (boards-ux plan §2, §4): board discovery results — the
  /// BoardPicker plus aggregated estimate totals. Download wiring for board
  /// jobs lands with 10.2/10.3 (D-38 sequential per-board flows).
  Widget _buildBoardResultsSection(
      bool isDark, AppJobState jobState, SettingsState settings) {
    final selection = jobState.boardSelection;
    final boardsMode = settings.boardsMode;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NeumorphismTheme.getSurfaceColor(isDark),
        borderRadius: BorderRadius.circular(12),
        boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.dashboard_customize,
                size: 14,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Boards (${jobState.discoveredBoards.length})'
                '${selection.boardCount > 0 ? ' · ${selection.boardCount} selected · ~${selection.estimatedPins} pins' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: NeumorphismTheme.getSecondaryTextColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          BoardPicker(
            boards: jobState.discoveredBoards,
            sectionsByBoard: jobState.boardSections,
            selection: selection,
            onChanged: (s) =>
                ref.read(jobProvider.notifier).updateBoardSelection(s),
            onRequestSections: _onRequestSections,
          ),
          if (boardsMode && selection.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Select boards to download — Whole board or pick sections.',
                style: TextStyle(
                  fontSize: 11,
                  color: NeumorphismTheme.getSecondaryTextColor(isDark),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
