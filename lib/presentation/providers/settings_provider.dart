import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/job_state.dart';

/// Settings state with multi-select media type support for single pins
class SettingsState {
  final bool saveMetadata;
  final bool overwrite;
  final bool verbose;
  final MediaType mediaType;
  
  // For single pin: allow selecting both image and video
  final bool downloadImage;
  final bool downloadVideo;
  
  // Preview settings
  final bool showPreview;
  
  // Continue mode for resuming interrupted downloads
  final bool continueMode;
  
  // Max pages for username fetching (1-100, default 50)
  final int maxPages;

  const SettingsState({
    this.saveMetadata = false,
    this.overwrite = false,
    this.verbose = false,
    this.mediaType = MediaType.image,
    this.downloadImage = true,
    this.downloadVideo = false,
    this.showPreview = true,
    this.continueMode = false,
    this.maxPages = 50,
  });

  SettingsState copyWith({
    bool? saveMetadata,
    bool? overwrite,
    bool? verbose,
    MediaType? mediaType,
    bool? downloadImage,
    bool? downloadVideo,
    bool? showPreview,
    bool? continueMode,
    int? maxPages,
  }) {
    return SettingsState(
      saveMetadata: saveMetadata ?? this.saveMetadata,
      overwrite: overwrite ?? this.overwrite,
      verbose: verbose ?? this.verbose,
      mediaType: mediaType ?? this.mediaType,
      downloadImage: downloadImage ?? this.downloadImage,
      downloadVideo: downloadVideo ?? this.downloadVideo,
      showPreview: showPreview ?? this.showPreview,
      continueMode: continueMode ?? this.continueMode,
      maxPages: maxPages ?? this.maxPages,
    );
  }
}

/// Settings state notifier
class SettingsNotifier extends StateNotifier<SettingsState> {
  static const _metadataKey = 'save_metadata';
  static const _overwriteKey = 'overwrite';
  static const _verboseKey = 'verbose';
  static const _mediaTypeKey = 'media_type';
  static const _downloadImageKey = 'download_image';
  static const _downloadVideoKey = 'download_video';
  static const _showPreviewKey = 'show_preview';
  static const _continueModeKey = 'continue_mode';
  static const _maxPagesKey = 'max_pages';

  final SharedPreferences? _prefs;

  SettingsNotifier(this._prefs) : super(_loadInitialState(_prefs));

  static SettingsState _loadInitialState(SharedPreferences? prefs) {
    if (prefs == null) return const SettingsState();

    return SettingsState(
      saveMetadata: prefs.getBool(_metadataKey) ?? false,
      overwrite: prefs.getBool(_overwriteKey) ?? false,
      verbose: prefs.getBool(_verboseKey) ?? false,
      mediaType: MediaType.values.firstWhere(
        (e) => e.name == prefs.getString(_mediaTypeKey),
        orElse: () => MediaType.image,
      ),
      downloadImage: prefs.getBool(_downloadImageKey) ?? true,
      downloadVideo: prefs.getBool(_downloadVideoKey) ?? false,
      showPreview: prefs.getBool(_showPreviewKey) ?? true,
      continueMode: prefs.getBool(_continueModeKey) ?? false,
      maxPages: prefs.getInt(_maxPagesKey) ?? 50,
    );
  }

  void setSaveMetadata(bool value) {
    state = state.copyWith(saveMetadata: value);
    _prefs?.setBool(_metadataKey, value);
  }

  void setOverwrite(bool value) {
    state = state.copyWith(overwrite: value);
    _prefs?.setBool(_overwriteKey, value);
  }

  void setVerbose(bool value) {
    state = state.copyWith(verbose: value);
    _prefs?.setBool(_verboseKey, value);
  }

  void setMediaType(MediaType type) {
    state = state.copyWith(mediaType: type);
    _prefs?.setString(_mediaTypeKey, type.name);
  }

  void setDownloadImage(bool value) {
    state = state.copyWith(downloadImage: value);
    _prefs?.setBool(_downloadImageKey, value);
  }

  void setDownloadVideo(bool value) {
    state = state.copyWith(downloadVideo: value);
    _prefs?.setBool(_downloadVideoKey, value);
  }

  void setShowPreview(bool value) {
    state = state.copyWith(showPreview: value);
    _prefs?.setBool(_showPreviewKey, value);
  }

  void setContinueMode(bool value) {
    state = state.copyWith(continueMode: value);
    _prefs?.setBool(_continueModeKey, value);
  }

  void setMaxPages(int value) {
    // Clamp to valid range
    final clamped = value.clamp(1, 100);
    state = state.copyWith(maxPages: clamped);
    _prefs?.setInt(_maxPagesKey, clamped);
  }
}

/// Provider for settings
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  // This will be overridden in main.dart with actual SharedPreferences
  return SettingsNotifier(null);
});
