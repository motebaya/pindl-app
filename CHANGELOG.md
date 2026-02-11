# Changelog

All notable changes to PinDL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-02-11

### Added

- **Multi-flavor build system**: `lite` (no FFmpeg, ~20MB) and `ffmpeg` (with FFmpeg HLS conversion, ~40-55MB) flavors with distinct application IDs.
- **Split-per-ABI builds**: `--split-per-abi` support in both PowerShell and Bash build scripts for smaller per-architecture APKs.
- **HLS video support**: Full HLS-to-MP4 conversion pipeline for Pinterest videos using `ffmpeg_kit_flutter_new_https`.
  - `BuildConfig` compile-time feature flag (`ENABLE_FFMPEG`).
  - `HlsService`: Fetches and parses HLS master playlists, selects optimal video/audio streams.
  - `HlsConverter`: Wraps FFmpeg for stream-copy muxing (no re-encoding) with Pinterest-specific `.cmfv`/`.cmfa` segment handling.
  - `HlsConversionResult`: Shared result model for conversion outcomes.
- **Storage permission management**: Mandatory `MANAGE_EXTERNAL_STORAGE` permission dialog on app startup with Exit/Allow buttons; auto-dismisses when permission is granted after returning from system settings.
- **Continue mode**: Resume interrupted username downloads using saved metadata; result card shows previous session stats and remaining items.
- **Max pages control**: Stepper + slider (1-100) for username extraction, visible only for username input.
- **Verbose logs parameter**: Passed to `startExtraction()` at call time instead of via Riverpod provider watch.
- **Defensive error handling in `main.dart`**: try-catch around Hive/SharedPreferences init; shows a fallback error screen instead of hanging on splash forever.
- **ProGuard keep rules**: `-keep` rules for `com.antonkarpenko.ffmpegkit.**` and `com.arthenica.ffmpegkit.**` to prevent R8 from stripping JNI classes.
- **Manual plugin registration**: `MainActivity.kt` conditionally registers `FFmpegKitFlutterPlugin` only for the `ffmpeg` flavor, preventing `UnsatisfiedLinkError` in lite builds.
- **Overwrite parameter**: Threaded through download service and platform channel to native `saveToPublicDirectory`.
- **`deleteFile` method channel**: New platform channel handler for file deletion with MediaStore cleanup.

### Changed

- **`MainActivity.kt` storage rewrite**: All READ operations now use direct `java.io.File` access instead of MediaStore queries, fixing a critical bug where files became invisible after app reinstall due to MediaStore ownership scoping.
- **`PinterestExtractorService.verbose`**: Changed from `final` to mutable field; updated imperatively before extraction instead of via Riverpod provider watch, preventing the provider invalidation cascade that destroyed the result card.
- **`pinterestExtractorProvider`**: No longer watches `settingsProvider.select((s) => s.verbose)`; created once and never invalidated by settings changes.
- **`PinItem` video extraction**: Added HLS fallback logic matching Node.js `Pinterest.js:206-238` — tries `story_pin_data.pages[0].blocks[0].video.video_list` when `videos` is null; prefers direct MP4, falls back to HLS with `needConvert=true`.
- **`VideoUrl`**: Added `needConvert` field and `isHls` getter for HLS stream detection.
- **`JobNotifier.startExtraction()`**: Now accepts `verbose`, `saveMetadata`, and `maxPages` parameters directly.
- **`SettingsState`**: Added `maxPages` (int, 1-100, default 50) with persistence.
- **`build_prod.ps1` / `build_prod.sh`**: Refactored for `-Flavor` (lite/ffmpeg/all) and `-SplitABI` parameters.
- **`build.gradle.kts`**: Added product flavors, `buildFeatures.buildConfig = true`, `minSdk = 24`, and `androidComponents` block for stripping FFmpeg `.so` from lite.
- **`about_page.dart`**: Version display updated to 2.0.0.
- **Result card layout**: Avatar shown as rounded square on left with stats on right (username mode).
- **Home page**: `resizeToAvoidBottomInset: true` so page scrolls with keyboard; footer hides when keyboard is visible.
- **Storage permission dialog**: Removed "Deny" button — only "Exit" and "Allow" remain (mandatory permission).

### Fixed

- **Splash screen stuck (all variants)**: Fixed by replacing `GeneratedPluginRegistrant` with manual plugin registration that skips FFmpegKit in lite flavor.
- **JNI RegisterNatives failure (ffmpeg flavor)**: Fixed by adding ProGuard keep rules for FFmpegKit classes.
- **Platform channel death cascade**: FFmpegKit crash no longer kills path_provider/shared_preferences channels.
- **Verbose logs checkbox clearing result card**: Fixed by decoupling `pinterestExtractorProvider` from `settingsProvider` watch; toggling verbose no longer triggers Riverpod invalidation cascade.
- **Metadata duplication (`(1).json` files)**: Fixed by moving storage permission request to app startup instead of inside `loadExistingMetadata()`.
- **Files invisible after reinstall**: Fixed by switching read operations from MediaStore queries to direct file access.

### Removed

- **Dead file**: `lib/data/services/hls_converter_stub.dart` — never imported anywhere.
- **Dead class**: `JobState` from `job_state.dart` — superseded by `AppJobState`; only `JobStatus` and `MediaType` enums retained.
- **Dead members**: 25 unused methods/getters/factories removed from `DownloadTask`, `UserPinsResult`, `FormatUtils`, `VideoUrl`, and `AppJobState` (~450 lines total).
- **Redundant permission check**: Removed 11-line permission block from `loadExistingMetadata()` in `job_provider.dart`.
