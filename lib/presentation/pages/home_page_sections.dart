// Part of `home_page.dart` (same library via `part`) — Phase 08.6
// HomePage orchestration reduction. This file carries the cohesive
// self-contained builder groups EXACTLY as they were (zero behavior change):
// storage-permission flow, generic confirm dialog, the results card, the
// download-confirmation block, and the media preview widgets.
part of 'home_page.dart';

/// Private extension hosting the split-out builder groups. Same library, so
/// private State members stay accessible; class members of _HomePageState
/// shadow extension names, keeping the call sites unchanged.
extension _HomePageSection on _HomePageState {
  Widget _buildSubmitRow(bool isDark, AppJobState jobState, SettingsState settings) {
    // No longer require outputPath since it's fixed to Downloads/PinDL
    // In continue mode, disable Submit (we already loaded metadata)
    final isContinueMode = settings.continueMode && jobState.isContinueMode;
    final canSubmit = !isContinueMode &&
        _inputController.text.isNotEmpty &&
        _inputError == null &&
        jobState.canSubmit &&
        !jobState.isExtracting;

    return Row(
      children: [
        Expanded(
          child: SoftButton(
            label: isContinueMode 
                ? 'Using saved data' 
                : (jobState.isExtracting ? 'Loading info...' : 'Submit'),
            icon: isContinueMode ? Icons.check : (jobState.isExtracting ? null : Icons.search),
            isLoading: jobState.isExtracting,
            isDisabled: !canSubmit || isContinueMode,
            onPressed: canSubmit
                ? () {
                    // Add pending history entry
                    ref.read(historyProvider.notifier).addPending(_inputController.text);
                    
                    ref.read(jobProvider.notifier).startExtraction(
                          input: _inputController.text,
                          mediaType: settings.mediaType,
                          saveMetadata: settings.saveMetadata, // REVISION 1: Save metadata after parsing
                          maxPages: settings.maxPages, // REVISION 6: Use max pages setting
                          verbose: settings.verbose,
                        );
                  }
                : null,
          ),
        ),
        if (jobState.isExtracting) ...[
          const SizedBox(width: 12),
          SoftIconButton(
            icon: Icons.stop,
            iconColor: AppColors.error,
            tooltip: 'Stop loading',
            onPressed: () => _showConfirmDialog(
              title: 'Stop Loading',
              message: 'Are you sure you want to cancel loading info?',
              onConfirm: () => ref.read(jobProvider.notifier).cancelExtraction(),
            ),
          ),
        ],
      ],
    );
  }

  /// Build media preview with independent border
  /// Shows preview based on user selection:
  /// - Image only: show thumbnail for video, image for image
  /// - Video only: show video player
  /// - Both: show both thumbnail and video
  Widget _buildWarningMessage(bool isDark, String message, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.warning,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build error message
  Widget _buildErrorMessage(bool isDark, String message, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultRow(bool isDark, String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              fontWeight: highlight ? FontWeight.w600 : FontWeight.normal,
              color: NeumorphismTheme.getSecondaryTextColor(isDark),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: highlight ? 14 : 12,
                fontWeight: highlight ? FontWeight.bold : FontWeight.w500,
                color: highlight ? AppColors.primary : NeumorphismTheme.getTextColor(isDark),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Download button section - below the info card
  /// When pressed: disabled + spinner + "Download" text + stop button appears
  /// In continue mode: shows "Continue Download" label
  /// In all-downloaded state: shows "All downloaded" with green checkmark

  /// Options grid - 2 columns, compact checkboxes
  /// Row 1: save metadata | overwrite
  /// Row 2: verbose logs  | continue (username) OR show preview (pin)
  Widget _buildOptionsGrid(bool isDark, SettingsState settings) {
    final isUrlInput = _inputType == 'pin';
    final isUsernameInput = _inputType == 'username';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Phase 10 (boards-ux plan §1): Feed | Boards mode switch —
        // username input only (boards are a profile-scoped resource).
        if (isUsernameInput) ...[
          _buildBoardModeSwitch(isDark, settings),
          const SizedBox(height: 10),
        ],

        // 2-column grid for options
        Row(
          children: [
            // Column 1
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1 Col 1: Save metadata
                  SoftCheckbox(
                    value: settings.saveMetadata,
                    label: 'Save metadata',
                    compact: true,
                    onChanged: (v) => ref.read(settingsProvider.notifier).setSaveMetadata(v),
                  ),
                  const SizedBox(height: 4),
                  // Row 2 Col 1: Verbose logs
                  SoftCheckbox(
                    value: settings.verbose,
                    label: 'Verbose logs',
                    compact: true,
                    onChanged: (v) => ref.read(settingsProvider.notifier).setVerbose(v),
                  ),
                ],
              ),
            ),
            // Column 2
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Row 1 Col 2: Overwrite
                  SoftCheckbox(
                    value: settings.overwrite,
                    label: 'Overwrite',
                    compact: true,
                    onChanged: (v) => ref.read(settingsProvider.notifier).setOverwrite(v),
                  ),
                  const SizedBox(height: 4),
                  // Row 2 Col 2: Continue (username) OR Show preview (pin)
                  if (isUsernameInput) ...[
                    SoftCheckbox(
                      value: settings.continueMode,
                      label: 'Continue',
                      compact: true,
                      onChanged: (v) async {
                        ref.read(settingsProvider.notifier).setContinueMode(v);
                        // If enabling continue mode, try to load existing metadata
                        if (v && _inputController.text.isNotEmpty) {
                          final success = await ref.read(jobProvider.notifier)
                              .loadExistingMetadata(_inputController.text);
                          if (!success && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'No metadata found for @${_inputController.text.replaceAll('@', '')}. Run a fresh download first.',
                                ),
                                backgroundColor: AppColors.warning,
                                duration: const Duration(seconds: 3),
                              ),
                            );
                            // Disable continue mode if no metadata found
                            ref.read(settingsProvider.notifier).setContinueMode(false);
                          }
                        } else if (!v) {
                          // Disable continue mode - reset job state
                          ref.read(jobProvider.notifier).reset();
                        }
                      },
                    ),
                  ] else if (isUrlInput) ...[
                    SoftCheckbox(
                      value: settings.showPreview,
                      label: 'Show preview',
                      compact: true,
                      onChanged: (v) => ref.read(settingsProvider.notifier).setShowPreview(v),
                    ),
                  ] else ...[
                    // Placeholder for alignment when no input type detected
                    const SizedBox(height: 24),
                  ],
                ],
              ),
            ),
          ],
        ),

        // Overwrite warning
        if (settings.overwrite) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber, size: 14, color: AppColors.warning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'All existing downloaded files will be overwritten',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 12),

        // Media type selection
        Text(
          'Media Type',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: NeumorphismTheme.getSecondaryTextColor(isDark),
          ),
        ),
        const SizedBox(height: 6),
        
        // For single pin (URL input): use checkboxes for multi-select
        // For username: use radio buttons (single select)
        if (isUrlInput) ...[
          // Multi-select checkboxes for single pin
          Row(
            children: [
              SoftCheckbox(
                value: settings.downloadImage,
                label: 'Image',
                compact: true,
                onChanged: (v) {
                  // Prevent unchecking if video is also unchecked
                  if (!v && !settings.downloadVideo) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                          'You must select either video or image, or select both.',
                        ),
                        backgroundColor: AppColors.warning,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                    return;
                  }
                  ref.read(settingsProvider.notifier).setDownloadImage(v);
                },
              ),
              const SizedBox(width: 24),
              SoftCheckbox(
                value: settings.downloadVideo,
                label: 'Video',
                compact: true,
                onChanged: (v) {
                  // Prevent unchecking if image is also unchecked
                  if (!v && !settings.downloadImage) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                          'You must select either video or image, or select both.',
                        ),
                        backgroundColor: AppColors.warning,
                        duration: const Duration(seconds: 3),
                      ),
                    );
                    return;
                  }
                  ref.read(settingsProvider.notifier).setDownloadVideo(v);
                },
              ),
            ],
          ),
        ] else ...[
          // Radio buttons for username (single select)
          Row(
            children: [
              SoftRadio<MediaType>(
                value: MediaType.image,
                groupValue: settings.mediaType,
                label: 'Image',
                compact: true,
                onChanged: (v) => ref.read(settingsProvider.notifier).setMediaType(v),
              ),
              const SizedBox(width: 24),
              SoftRadio<MediaType>(
                value: MediaType.video,
                groupValue: settings.mediaType,
                label: 'Video',
                compact: true,
                onChanged: (v) => ref.read(settingsProvider.notifier).setMediaType(v),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// REVISION 6: Max pages control with +/- buttons and slider
  /// Shows only for username input, above Submit button
  Widget _buildMaxPagesControl(bool isDark, SettingsState settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Numeric input with +/- buttons
            Container(
              width: 120,
              height: 40,
              decoration: BoxDecoration(
                color: NeumorphismTheme.getSurfaceColor(isDark),
                borderRadius: BorderRadius.circular(8),
                boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4),
              ),
              child: Row(
                children: [
                  // Minus button
                  InkWell(
                    onTap: settings.maxPages > 1
                        ? () => ref.read(settingsProvider.notifier).setMaxPages(settings.maxPages - 1)
                        : null,
                    child: Container(
                      width: 32,
                      height: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.remove,
                        size: 16,
                        color: settings.maxPages > 1
                            ? NeumorphismTheme.getTextColor(isDark)
                            : NeumorphismTheme.getSecondaryTextColor(isDark).withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  // Value display
                  Expanded(
                    child: Container(
                      alignment: Alignment.center,
                      child: Text(
                        '${settings.maxPages}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: NeumorphismTheme.getTextColor(isDark),
                        ),
                      ),
                    ),
                  ),
                  // Plus button
                  InkWell(
                    onTap: settings.maxPages < 100
                        ? () => ref.read(settingsProvider.notifier).setMaxPages(settings.maxPages + 1)
                        : null,
                    child: Container(
                      width: 32,
                      height: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add,
                        size: 16,
                        color: settings.maxPages < 100
                            ? NeumorphismTheme.getTextColor(isDark)
                            : NeumorphismTheme.getSecondaryTextColor(isDark).withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Slider
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: AppColors.primary,
                  inactiveTrackColor: NeumorphismTheme.getSurfaceColor(isDark),
                  thumbColor: AppColors.primary,
                  overlayColor: AppColors.primary.withValues(alpha: 0.2),
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                ),
                child: Slider(
                  value: settings.maxPages.toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setMaxPages(value.round());
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Help text
        Text(
          'Max pages: default 50, max 100, 1 page ≈ 15 items',
          style: TextStyle(
            fontSize: 10,
            color: NeumorphismTheme.getSecondaryTextColor(isDark),
          ),
        ),
      ],
    );
  }

  /// Submit row - only fetches info, does NOT download
  /// In continue mode, Submit is disabled (uses loaded metadata)

  // ── Storage permission management ──

  void _showStoragePermissionDialog() {
    _isPermissionDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final isDark = Theme.of(dialogContext).brightness == Brightness.dark;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: NeumorphismTheme.getCardColor(isDark),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(
                NeumorphismTheme.defaultBorderRadius,
              ),
            ),
            title: Row(
              children: [
                Icon(Icons.folder_open, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Storage Permission Required',
                    style: TextStyle(
                      color: NeumorphismTheme.getTextColor(isDark),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              'On Android 10+, storage access is strictly restricted.\n\n'
              'To save and load metadata, the app needs permission to '
              'read public output folders at:\n\n'
              'Download/PinDL/*\n\n'
              'Please tap "Allow" and enable "All files access" in '
              'system settings.',
              style: TextStyle(
                color: NeumorphismTheme.getSecondaryTextColor(isDark),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            actions: [
              SoftButton(
                label: 'Exit',
                icon: Icons.exit_to_app,
                accentColor: AppColors.error,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                onPressed: () => SystemNavigator.pop(),
              ),
              SoftButton(
                label: 'Allow',
                icon: Icons.check,
                accentColor: AppColors.success,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 10),
                onPressed: () {
                  ref
                      .read(downloadServiceProvider)
                      .requestManageStoragePermission();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showConfirmDialog({
    required String title,
    required String message,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onConfirm();
            },
            child: const Text('YES'),
          ),
        ],
      ),
    );
  }

  // ---- Phase 10: boards mode (boards-ux plan §1–2; D-38 flows) ----

  /// "Feed | Boards" mode switch — username input only. Pure UI state
  /// (settings), discovery submit routes on it.
  Widget _buildBoardModeSwitch(bool isDark, SettingsState settings) {
    final boardsMode = settings.boardsMode;
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: NeumorphismTheme.getSurfaceColor(isDark),
              borderRadius: BorderRadius.circular(10),
              boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.3),
            ),
            child: Row(
              children: [
                _boardModePill(isDark, 'Feed', !boardsMode,
                    () => ref.read(settingsProvider.notifier).setBoardsMode(false)),
                _boardModePill(isDark, 'Boards', boardsMode,
                    () => ref.read(settingsProvider.notifier).setBoardsMode(true)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _boardModePill(bool isDark, String label, bool selected,
      VoidCallback onTap) {
    final accentColor = NeumorphismTheme.getAccentColor(isDark);
    final cardColor = NeumorphismTheme.getCardColor(isDark);
    final textColor = NeumorphismTheme.getTextColor(isDark);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? accentColor : cardColor,
              borderRadius: BorderRadius.circular(8),
              boxShadow: selected
                  ? NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4)
                  : NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.3),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Board discovery submit row (Boards mode) — mirrors the feed submit
  /// row's disabled/loading states; routes to discoverBoards.
  Widget _buildBoardSubmitRow(bool isDark, AppJobState jobState) {
    final isBoardsExtracting = jobState.isDiscoveringBoards;
    final canSubmit = _inputController.text.isNotEmpty &&
        _inputError == null &&
        (jobState.canSubmit || jobState.status == JobStatus.idle) &&
        !isBoardsExtracting &&
        !jobState.isExtracting;

    return Row(
      children: [
        Expanded(
          child: SoftButton(
            label: isBoardsExtracting ? 'Finding boards...' : 'Find boards',
            icon: isBoardsExtracting ? null : Icons.dashboard_customize,
            isLoading: isBoardsExtracting,
            isDisabled: !canSubmit,
            onPressed: canSubmit
                ? () => ref.read(jobProvider.notifier).discoverBoards(
                      username: _inputController.text,
                      maxPages: 1,
                      verbose: ref.read(settingsProvider).verbose,
                    )
                : null,
          ),
        ),
        if (isBoardsExtracting) ...[
          const SizedBox(width: 12),
          SoftIconButton(
            icon: Icons.stop,
            iconColor: AppColors.error,
            tooltip: 'Stop board search',
            onPressed: () => ref.read(jobProvider.notifier).cancelBoardDiscovery(),
          ),
        ],
      ],
    );
  }

  /// Section lazy-load + selection update (picker callbacks → provider).
  void _onRequestSections(Board board) {
    final username = PinUrlValidator.normalizeUsername(_inputController.text);
    ref.read(jobProvider.notifier).loadBoardSections(
          boardId: board.boardId,
          username: username,
          boardSlug: board.slug,
        );
  }
}
