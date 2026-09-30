import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/neumorphism_theme.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../data/models/board.dart';
import '../../data/models/history_item.dart';
import '../../data/models/job_state.dart';
import '../providers/history_provider.dart';
import '../providers/job_provider.dart';
import '../providers/log_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/board_picker.dart';
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

part 'home_page_preview.dart';
part 'home_page_results.dart';
part 'home_page_sections.dart';

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

  // Storage-permission, confirm-dialog, results, download-confirmation and
  // media-preview builders live in the private part below (same library,
  // same private access — zero behavior change, Phase 08.6 file split).
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

                            // Phase 10: boards mode routes submit + results
                            // to the board flow; feed flow untouched.
                            if (_inputType == 'username' && settings.boardsMode) ...[
                              _buildBoardSubmitRow(isDark, jobState),
                              if (jobState.discoveredBoards.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                _buildBoardResultsSection(isDark, jobState, settings),
                              ],
                            ] else ...[
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
