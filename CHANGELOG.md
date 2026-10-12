# Changelog

All notable changes to PinDL will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.1] - 2026-10-12

Defect release from a real-device QA pass (`PinDL-ffmpeg-arm64-v8a-v3.1.0-b7.apk`, Poco X6 Pro,
Android 16 / API 36). User-facing release blurbs for 3.0.0 and 3.1.0 live in `RELEASE_NOTES.md`;
this entry records the fixes.

### Fixed

- **Video downloads from single pins**: an HLS video pin (`.m3u8` master playlist) was saved as a
  `<pinId>_video.mp4` file whose contents were the playlist text (~920 B, unplayable) with no error
  shown. Downloads now route by media type: progressive MP4 is fetched directly, and HLS is parsed
  and converted to MP4 with FFmpeg before it is imported. On the lite variant an HLS video is now an
  explicit, honest skip instead of a corrupt file.
- **"short body: got 920 of 350 bytes" download loop**: the completion check trusted the server's
  declared `Content-Length`; when the CDN under-declared the body, every retry failed identically.
  A body larger than the declared length is now accepted (with a log line), downloads request
  `Accept-Encoding: identity` so the length is comparable, and a declared length is ignored whenever
  the response is compressed.
- **Playlists and text accepted as video**: the fail-closed content check now rejects HLS playlists
  (`#EXTM3U`) and any other plain-text body for both images and videos, so a manifest or an error
  payload can never be imported as media.
- **"No relay payload on pin page" (E_NO_DATA) on public pins**: the Pinterest pin page does not
  serve its data payload on every response. Extraction now retries across the known pin hosts
  (bounded) and only reports E_NO_DATA after the whole plan is exhausted, naming the hosts tried.
- **Video quality on video pins**: a pin whose records offer both an HLS stream and a direct MP4 now
  yields the direct MP4 instead of the playlist rendition; every `videoDataV2` group in the record
  is considered, not just the first one found.
- **Thumbnail-quality images (60×60 / 6 KB)**: image renditions are now ranked by resolution instead
  of server key order, and a thumbnail-sized Pinterest URL is rewritten to the full-resolution
  `/originals/` rendition before download.
- **Multi-image (carousel) pins offered and downloaded only one image**: the item count and preview
  now show every slide, and the download writes one indexed file per slide
  (`<pinId>_image_<n>.<ext>`).
- **Video preview could not be unmuted**: the speaker badge on the preview was a static icon with no
  gesture. It is now a real toggle that unmutes/mutes the playing preview.

### Added

- **Console: selectable text and a one-tap "copy all logs" action**, so an error can be copied out
  verbatim.
- **Console capability banner**: the first log line states whether this build can convert HLS
  (`ffmpeg` build) or not (`lite` build).

## [2.1.0] - 2026-02-12

### Added

- **Foreground service + background notification runtime**:
  - Added `ForegroundServiceManager` to keep extraction/download alive while app is backgrounded.
  - Added `NotificationHelper` with progress notifications, completion heads-up, and `ic_download_notification.xml` icon.
  - Added Android 13+ notification permission request flow and lifecycle-aware service start/stop.
- **Task state persistence with Hive**:
  - Added `BackgroundTaskState` + hand-written `BackgroundTaskStateAdapter`.
  - Added `TaskStatePersistence` service for active task storage, throttled byte-progress writes, and interrupted-task lookup.
  - Added interrupted-task resume/discard prompt on app startup.
- **Release automation and release archives**:
  - Added `.github/workflows/release-on-push.yml` for auto build/tag/release on `main` push.
  - Added release note archives: `releases/2.0.0.md` and `releases/2.1.0.md`.
- **URL cleaning and deterministic naming utilities**:
  - Added `PinUrlValidator.cleanRedirectedUrl()`, `PinUrlValidator.isShortUrl()`, and `ResolvedInput` for `pin.it` redirects.
  - Added `FormatUtils.extensionFromUrl()` and `FormatUtils.pinFilename()` for deterministic naming (`<pinId>_image`, `<pinId>_thumbnail`, `<pinId>_video`).
- **`MediaChannelHandler.kt`**: Extracted media MethodChannel operations from `MainActivity` for reuse across foreground/background engine flows.
- **Download queue pause/resume**: Added `DownloadService.pauseQueue()` and `resumeQueue()` for lifecycle-aware queue control.

### Changed

- **`AndroidManifest.xml`**: Added `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED` permissions and foreground service declaration (`dataSync`).
- **`MainActivity.kt`**: Delegates media channel handling to `MediaChannelHandler`; manual plugin registration now includes foreground task, WorkManager, and local notifications.
- **`android/app/build.gradle.kts`**: Enabled core library desugaring and added `desugar_jdk_libs` dependency for notification/time API compatibility.
- **`main.dart`**: Registers `BackgroundTaskStateAdapter`, opens `background_tasks` Hive box, and initializes WorkManager callback dispatcher.
- **`job_provider.dart`**:
  - Resolves `pin.it` links before routing extraction and updates UI input with canonical pin/username.
  - Persists extraction/download state and per-item progress for resume/recovery.
  - Uses per-media completion flags and media-type-aware continue-mode calculations.
  - Uses deterministic pin-based filenames for image/video/thumbnail output.
- **`home_page.dart`**: Integrates foreground service lifecycle delegation, interrupted-task resume dialog, short-url input update callback, and per-media all-downloaded gating.
- **`settings_provider.dart`**: `continueMode` is no longer persisted and now always resets to `false` on cold start.
- **`pinterest_extractor_service.dart`**: Short-url resolver now returns raw redirect URL for cleaner downstream normalization; profile extraction error text is more actionable.
- **`android/gradle.properties`**: Set `kotlin.incremental=false` to fix cross-drive (C:/F:) Kotlin cache issues.
- **`pubspec.yaml` / `pubspec.lock`**: Added `flutter_foreground_task`, `workmanager`, `flutter_local_notifications` and transitive dependencies; app version bumped to `2.1.0+6`.
- **`.gitignore`**: Added ignores for `workflow*.md` and `trash/*`.
- **`about_page.dart`**: Version label updated to `2.1.0`.

### Fixed

- Redirected Pinterest URLs with extra segments/query params (e.g. `/sent/`, invite params) are now normalized correctly.
- Continue-mode completion logic no longer misclassifies completion when switching media types.
- Interrupted extraction/download sessions now preserve recoverable progress state via persisted task metadata.

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
