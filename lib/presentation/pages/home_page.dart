import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/neumorphism_theme.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../data/models/history_item.dart';
import '../../data/models/job_state.dart';
import '../providers/history_provider.dart';
import '../providers/job_provider.dart';
import '../providers/log_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/console_panel.dart';
import '../widgets/soft_button.dart';
import '../widgets/soft_card.dart';
import '../widgets/soft_checkbox.dart';
import '../widgets/soft_text_field.dart';
import '../widgets/soft_toggle.dart';
import 'about_page.dart';
import 'downloads_page.dart';
import 'history_page.dart';
import '../providers/foreground_service_manager.dart';
import '../../data/services/task_state_persistence.dart';

/// Main home page - Single page app design
/// Flow: Submit (fetch info) -> Result Info -> Download (confirm)
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> with WidgetsBindingObserver {
  final _inputController = TextEditingController();
  String? _inputError;
  String? _inputType;
  
  // Video player controller for preview
  VideoPlayerController? _videoController;
  String? _currentVideoUrl;
  bool _isVideoInitialized = false;

  // Storage permission state
  bool _hasStoragePermission = true;
  bool _isPermissionDialogShowing = false;

  // Foreground service manager for background execution
  ForegroundServiceManager? _foregroundServiceManager;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check storage permission after first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkStoragePermission();
      _initForegroundService();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inputController.dispose();
    _disposeVideoController();
    _foregroundServiceManager?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recheckStoragePermission();
    }
    // Delegate lifecycle events to foreground service manager
    _foregroundServiceManager?.didChangeAppLifecycleState(state);
  }

  // ── Foreground service initialization ──

  void _initForegroundService() {
    final persistence = ref.read(taskStatePersistenceProvider);
    _foregroundServiceManager = ForegroundServiceManager(
      ref: ref,
      persistence: persistence,
    );
    _foregroundServiceManager!.init();

    // Wire foreground service callbacks to JobNotifier
    final jobNotifier = ref.read(jobProvider.notifier);
    jobNotifier.onTaskStarted = () {
      _foregroundServiceManager?.onTaskStarted();
    };
    jobNotifier.onTaskCompleted = ({required String taskType}) {
      _foregroundServiceManager?.onTaskCompleted(taskType: taskType);
    };
    jobNotifier.onExtractionProgress = ({
      required String username,
      required int itemCount,
      required int currentPage,
      required int maxPage,
    }) {
      _foregroundServiceManager?.updateExtractionNotification(
        username: username,
        itemCount: itemCount,
        currentPage: currentPage,
        maxPage: maxPage,
      );
    };

    // Wire short URL resolution callback to update the input field
    jobNotifier.onInputResolved = ({
      required String resolvedInput,
      required bool isUsername,
    }) {
      if (mounted) {
        setState(() {
          _inputController.text = isUsername ? '@$resolvedInput' : resolvedInput;
          _inputType = isUsername ? 'username' : 'pin';
          _inputError = null;
        });
      }
    };

    // Check for interrupted tasks from previous session
    _checkInterruptedTasks(persistence);
  }

  /// Check Hive for interrupted tasks and prompt user to resume.
  Future<void> _checkInterruptedTasks(dynamic persistence) async {
    try {
      final taskPersistence = persistence as TaskStatePersistence;
      // Ensure box is open
      await taskPersistence.init();
      if (!taskPersistence.hasInterruptedTask()) return;

      final task = taskPersistence.getActiveTask();
      if (task == null) return;

      if (!mounted) return;

      final shouldResume = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Resume Interrupted Task?'),
          content: Text(
            task.taskType == 'extraction'
                ? 'An extraction for @${task.username ?? 'unknown'} was interrupted.\n'
                  'Progress: page ${task.currentPage}/${task.maxPages}, '
                  '${task.totalItems} items collected.'
                : 'A download was interrupted.\n'
                  'Progress: ${task.currentIndex}/${task.totalItems} items\n'
                  'Success: ${task.successCount}, Skipped: ${task.skippedCount}, '
                  'Failed: ${task.failedCount}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Discard'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Resume'),
            ),
          ],
        ),
      );

      if (shouldResume == true) {
        // Resume is handled by the next extraction/download which reads
        // persisted state. The user can re-enter the username and continue mode
        // will pick up from last saved metadata.
        // For now, pre-fill the input field with the username.
        if (task.username != null && task.username!.isNotEmpty) {
          _inputController.text = task.username!;
        }
      } else {
        // User declined — clear the interrupted state
        await taskPersistence.clearActiveTask();
      }
    } catch (e) {
      debugPrint('Error checking interrupted tasks: $e');
    }
  }

  // ── Storage permission management ──

  Future<void> _checkStoragePermission() async {
    if (!Platform.isAndroid) return;

    final hasPermission =
        await ref.read(downloadServiceProvider).hasManageStoragePermission();
    if (!hasPermission && mounted) {
      setState(() => _hasStoragePermission = false);
      _showStoragePermissionDialog();
    }
  }

  Future<void> _recheckStoragePermission() async {
    if (!Platform.isAndroid || _hasStoragePermission) return;

    final hasPermission =
        await ref.read(downloadServiceProvider).hasManageStoragePermission();
    if (hasPermission && mounted) {
      setState(() => _hasStoragePermission = true);
      if (_isPermissionDialogShowing) {
        Navigator.of(context).pop();
        _isPermissionDialogShowing = false;
      }
    }
  }

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

  void _disposeVideoController() {
    _videoController?.dispose();
    _videoController = null;
    _currentVideoUrl = null;
    _isVideoInitialized = false;
  }
  
  Future<void> _initVideoController(String videoUrl) async {
    // Skip if same URL already loaded
    if (_currentVideoUrl == videoUrl && _isVideoInitialized) return;
    
    // Dispose old controller
    _disposeVideoController();
    _currentVideoUrl = videoUrl;
    
    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      
      await _videoController!.initialize();
      _videoController!.setLooping(true);
      _videoController!.setVolume(0); // Muted autoplay
      await _videoController!.play();
      
      if (mounted) {
        setState(() {
          _isVideoInitialized = true;
        });
      }
    } catch (e) {
      debugPrint('Video init error: $e');
      _disposeVideoController();
    }
  }

  void _validateInput(String value) {
    setState(() {
      if (value.isEmpty) {
        _inputError = null;
        _inputType = null;
        // Reset continue mode when input becomes empty
        ref.read(settingsProvider.notifier).setContinueMode(false);
        ref.read(jobProvider.notifier).reset();
        return;
      }

      final type = PinUrlValidator.detectInputType(value);
      if (type == null) {
        _inputError = 'Invalid input. Enter @username or pin URL';
        _inputType = null;
      } else {
        _inputError = null;
        _inputType = type;
      }
    });
  }
  
  /// Clear input and reset related state
  void _clearInput() {
    _inputController.clear();
    setState(() {
      _inputError = null;
      _inputType = null;
    });
    // Dispose video preview if any
    _disposeVideoController();
    // Reset continue mode when input is cleared
    ref.read(settingsProvider.notifier).setContinueMode(false);
    // Reset job state if it depends on input
    ref.read(jobProvider.notifier).reset();
  }
  
  /// Static output path display - downloads go to Downloads/PinDL via MediaStore
  Widget _buildOutputPath(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: NeumorphismTheme.getSurfaceColor(isDark),
        borderRadius: BorderRadius.circular(8),
        boxShadow: NeumorphismTheme.getInsetShadows(isDark, intensity: 0.4),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 16,
            color: NeumorphismTheme.getSecondaryTextColor(isDark),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Output: Downloads/PinDL',
              style: TextStyle(
                fontSize: 13,
                color: NeumorphismTheme.getTextColor(isDark),
              ),
            ),
          ),
        ],
      ),
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeMode = ref.watch(themeProvider);
    final settings = ref.watch(settingsProvider);
    final jobState = ref.watch(jobProvider);
    final logService = ref.watch(logServiceProvider);
    
    // Listen for job state changes to update history
    ref.listen<AppJobState>(jobProvider, (previous, next) {
      // Update extraction history when transitioning from fetchingInfo to another state
      if (previous?.status == JobStatus.fetchingInfo && 
          next.status != JobStatus.fetchingInfo) {
        if (next.status == JobStatus.readyToDownload) {
          ref.read(historyProvider.notifier).updateLast(HistoryStatus.success);
        } else if (next.status == JobStatus.failed) {
          ref.read(historyProvider.notifier).updateLast(
            HistoryStatus.failed, 
            errorMessage: next.error,
          );
        } else if (next.status == JobStatus.cancelled) {
          ref.read(historyProvider.notifier).updateLast(HistoryStatus.cancelled);
        }
      }
    });

    return GestureDetector(
      // Dismiss keyboard when tapping outside input area
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: NeumorphismTheme.getBackgroundColor(isDark),
        // REVISION 5: Allow page to scroll when keyboard appears
        resizeToAvoidBottomInset: true,
        body: SafeArea(
          child: Column(
            children: [
              // Top bar
              _buildTopBar(isDark, themeMode),

              // Main content - scrollable
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Main card with all controls
                      SoftCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Card header row: History (left), Welcome text (center), Downloads (right)
                            _buildCardHeader(isDark),
                            const SizedBox(height: 16),

                            // Input field (FIRST)
                            _buildInputSection(isDark, jobState),
                            const SizedBox(height: 16),

                            // Static output path display (SECOND)
                            _buildOutputPath(isDark),
                            const SizedBox(height: 16),

                            // Options grid (2 columns, compact)
                            _buildOptionsGrid(isDark, settings),
                            const SizedBox(height: 16),

                            // REVISION 6: Max pages control (only for username input)
                            if (_inputType == 'username') ...[
                              _buildMaxPagesControl(isDark, settings),
                              const SizedBox(height: 16),
                            ],

                            // Submit row (fetch info only)
                            _buildSubmitRow(isDark, jobState, settings),

                            // Result info card (shown after submit success)
                            if (jobState.hasResults) ...[
                              const SizedBox(height: 16),
                              _buildResultsSection(isDark, jobState, settings),
                            ],

                            // Download confirmation row (shown after info loaded)
                            if (jobState.hasResults) ...[
                              const SizedBox(height: 16),
                              _buildDownloadConfirmation(isDark, jobState, settings),
                            ],

                            const SizedBox(height: 16),

                            // Console panel
                            ConsolePanel(
                              logStream: logService.stream,
                              initialEntries: logService.entries,
                              height: 180,
                            ),
                          ],
                        ),
                      ),
                      // Extra padding at bottom for keyboard
                      SizedBox(height: MediaQuery.of(context).viewInsets.bottom > 0 ? 16 : 0),
                    ],
                  ),
                ),
              ),

              // Footer - only show when keyboard is not visible
              if (MediaQuery.of(context).viewInsets.bottom == 0)
                _buildFooter(isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark, ThemeMode themeMode) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // App icon (left)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: NeumorphismTheme.getCardColor(isDark),
              borderRadius: BorderRadius.circular(8),
              boxShadow: NeumorphismTheme.getRaisedShadows(isDark, intensity: 0.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/icons/app_icon.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
          ),

          // Expanded spacer for centering title
          const Expanded(child: SizedBox()),

          // Title (center)
          Text(
            'PinDL',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: NeumorphismTheme.getTextColor(isDark),
            ),
          ),

          // Expanded spacer for centering title
          const Expanded(child: SizedBox()),

          // Theme toggle (right)
          SoftToggle(
            value: themeMode == ThemeMode.light ||
                (themeMode == ThemeMode.system &&
                    MediaQuery.of(context).platformBrightness == Brightness.light),
            onChanged: (_) => ref.read(themeProvider.notifier).toggleTheme(context),
          ),
          const SizedBox(width: 8),

          // About button (right)
          SoftIconButton(
            icon: Icons.info_outline,
            tooltip: 'About',
            size: 36,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardHeader(bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // History button (left)
        SoftIconButton(
          icon: Icons.history,
          tooltip: 'History',
          size: 36,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const HistoryPage()),
          ),
        ),

        // Welcome text (center)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Welcome to PinDL. Please make sure the URL or username you enter is public and visible to anyone.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: NeumorphismTheme.getSecondaryTextColor(isDark),
                height: 1.4,
              ),
            ),
          ),
        ),

        // Downloads button (right)
        SoftIconButton(
          icon: Icons.download,
          tooltip: 'Downloads',
          size: 36,
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DownloadsPage()),
          ),
        ),
      ],
    );
  }

  Widget _buildInputSection(bool isDark, AppJobState jobState) {
    final isDisabled = jobState.isExtracting || jobState.isDownloading;
    final hasText = _inputController.text.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Type label above the field (USER or PIN)
        if (_inputType != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              _inputType == 'username' ? 'USER' : 'PIN',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.success,
              ),
            ),
          ),
        SoftTextField(
          controller: _inputController,
          hintText: 'Enter @username or pin URL (pin.it / pinterest.com/pin/...)',
          enabled: !isDisabled,
          errorText: _inputError,
          onChanged: _validateInput,
          // Clear icon inside the field (right side)
          suffixIcon: hasText && !isDisabled
              ? IconButton(
                  icon: Icon(
                    Icons.clear,
                    size: 18,
                    color: NeumorphismTheme.getSecondaryTextColor(isDark),
                  ),
                  onPressed: _clearInput,
                  tooltip: 'Clear input',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              : null,
        ),
      ],
    );
  }

  /// Options grid - 2 columns, compact checkboxes
  /// Row 1: save metadata | overwrite
  /// Row 2: verbose logs  | continue (username) OR show preview (pin)
  Widget _buildOptionsGrid(bool isDark, SettingsState settings) {
    final isUrlInput = _inputType == 'pin';
    final isUsernameInput = _inputType == 'username';
    final jobState = ref.watch(jobProvider);
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              color: AppColors.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.warning.withOpacity(0.3)),
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
                            : NeumorphismTheme.getSecondaryTextColor(isDark).withOpacity(0.5),
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
                            : NeumorphismTheme.getSecondaryTextColor(isDark).withOpacity(0.5),
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
                  overlayColor: AppColors.primary.withOpacity(0.2),
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
        ],
      ),
    );
  }

  /// Build media preview with independent border
  /// Shows preview based on user selection:
  /// - Image only: show thumbnail for video, image for image
  /// - Video only: show video player
  /// - Both: show both thumbnail and video
  Widget _buildMediaPreview(bool isDark, dynamic singleResult) {
    final settings = ref.watch(settingsProvider);
    final hasVideo = singleResult.hasVideoContent ?? false;
    final hasImage = singleResult.hasImage ?? false;
    final thumbnail = singleResult.thumbnail as String?;
    final imageUrl = singleResult.imageUrl as String?;
    final videoUrl = singleResult.videoUrl as String?;
    
    final showImage = settings.downloadImage;
    final showVideo = settings.downloadVideo && hasVideo;
    
    // Determine what preview(s) to show
    if (showImage && showVideo) {
      // Show BOTH thumbnail AND video preview
      return Column(
        children: [
          // Thumbnail/image preview
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  _buildImagePreview(thumbnail ?? imageUrl ?? ''),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.image, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'THUMBNAIL',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Video preview
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: _buildVideoPreview(thumbnail ?? '', videoUrl),
            ),
          ),
        ],
      );
    } else if (showVideo && hasVideo) {
      // Show only video preview
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _buildVideoPreview(thumbnail ?? '', videoUrl),
        ),
      );
    } else if (showImage) {
      // Show image/thumbnail preview (for video URLs, this shows the thumbnail)
      final previewUrl = hasVideo ? (thumbnail ?? imageUrl) : imageUrl;
      if (previewUrl == null) return const SizedBox.shrink();
      
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: NeumorphismTheme.getAccentColor(isDark).withOpacity(0.5),
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              _buildImagePreview(previewUrl),
              if (hasVideo)
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.image, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text(
                          'THUMBNAIL',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    
    return const SizedBox.shrink();
  }

  /// Build image preview
  Widget _buildImagePreview(String imageUrl) {
    return Image.network(
      imageUrl,
      height: 180,
      width: double.infinity,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return SizedBox(
          height: 180,
          child: Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
              strokeWidth: 2,
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return SizedBox(
          height: 180,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image, size: 40, color: AppColors.error),
                const SizedBox(height: 8),
                Text(
                  'Failed to load preview',
                  style: TextStyle(fontSize: 12, color: AppColors.error),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Build video preview with actual video playback (autoplay, muted, looped)
  Widget _buildVideoPreview(String thumbnailUrl, String? videoUrl) {
    // Initialize video controller if we have a video URL
    if (videoUrl != null && videoUrl.isNotEmpty) {
      // Use post-frame callback to avoid calling setState during build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initVideoController(videoUrl);
      });
    }
    
    return Stack(
      alignment: Alignment.center,
      children: [
        // Show video player if initialized, otherwise show thumbnail
        if (_isVideoInitialized && _videoController != null)
          SizedBox(
            height: 180,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: _videoController!.value.size.width,
                height: _videoController!.value.size.height,
                child: VideoPlayer(_videoController!),
              ),
            ),
          )
        else
          Image.network(
            thumbnailUrl,
            height: 180,
            width: double.infinity,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return SizedBox(
                height: 180,
                child: Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                        : null,
                    strokeWidth: 2,
                  ),
                ),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              return SizedBox(
                height: 180,
                child: Center(
                  child: Icon(Icons.videocam_off, size: 40, color: AppColors.error),
                ),
              );
            },
          ),
        
        // Show loading indicator while video is initializing
        if (videoUrl != null && !_isVideoInitialized)
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(15),
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 2,
              ),
            ),
          ),
        
        // Video indicator badge
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Text(
                  _isVideoInitialized ? 'PLAYING' : 'VIDEO',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Muted indicator
        if (_isVideoInitialized)
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.volume_off, color: Colors.white, size: 16),
            ),
          ),
      ],
    );
  }

  /// Build warning message
  Widget _buildWarningMessage(bool isDark, String message, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.warning.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning.withOpacity(0.3)),
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
        color: AppColors.error.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withOpacity(0.3)),
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

  Widget _buildStatItem(bool isDark, String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: NeumorphismTheme.getSecondaryTextColor(isDark),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(bool isDark) {
    final textColor = NeumorphismTheme.getSecondaryTextColor(isDark);
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Built with ',
            style: TextStyle(
              fontSize: 12,
              color: textColor,
            ),
          ),
          const Text('\u{1F375}', style: TextStyle(fontSize: 12)), // Tea emoji
          Text(
            ' by ',
            style: TextStyle(
              fontSize: 12,
              color: textColor,
            ),
          ),
          GestureDetector(
            onTap: () => _launchUrl('https://t.me/dvinchii'),
            child: Text(
              'davins',
              style: TextStyle(
                fontSize: 12,
                color: textColor, // Same color as surrounding text
                decoration: TextDecoration.underline,
                decorationColor: textColor.withOpacity(0.5),
              ),
            ),
          ),
          Text(
            ' | \u00a9 2026',
            style: TextStyle(
              fontSize: 12,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not open: $url'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening link: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }
}
