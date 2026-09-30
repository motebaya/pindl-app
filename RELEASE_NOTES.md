# Release Notes

## 3.1.0 (unreleased — content staged in Phase 07)

### Behavior change (intended)

- **Better video quality picks.** For pins offering multiple renditions, PinDL now
  downloads the best available MP4 (720P → 960P → 480P → 360P) instead of always
  preferring 720P, and prefers the **V_HLSV4** HLS stream over V_HLSV3_MOBILE when
  only HLS is offered (newer master, usually higher quality). The same pin may
  therefore yield a different (better) file than before.
- **Carousel pins fully supported.** Multi-image pins now download one file per
  image (`<pinId>_image_1..n`) instead of only the first.
- **Feed quality:** duplicate pins across pages are removed; capped feeds show a
  "Fetch more" button instead of silently stopping (the continuation cursor is
  stored together with its full request context and reused only on an exact match).

### Reliability (carried from 2.1.x work)

- Large downloads resume at the byte level after interruptions (Range requests,
  verified against the Pinterest CDN) — see phase 06 evidence appendix.

## 2.1.0 - 2026-02-12

### TL;DR (Recommended)

- **Recommended:** Download **PinDL-lite-arm64-v8a-v2.1.0-b6.apk**  
  Works on almost all modern Android phones.
- If you need advanced HLS processing, choose the **ffmpeg** variant.

### App variant

- **Lite** -> Smaller size, faster startup, recommended for most users.
- **FFmpeg** -> Larger size, includes advanced video processing.

### CPU architecture

- **arm64-v8a** -> Most Android phones (recommended)
- **armeabi-v7a** -> Older phones (32-bit)
- **x86_64** -> Emulator only
- **universal** -> Works everywhere, but larger size

Not sure? Choose **arm64-v8a**.

### Highlights

- Extraction and downloads now continue reliably in the background using a foreground service.
- Interrupted tasks are persisted and can be resumed when you reopen the app.
- Notifications now include progress bars and completion alerts while the app is backgrounded.

### What’s New

- Added background task state persistence (`BackgroundTaskState` + Hive) with resume/discard prompt on next launch.
- Added lifecycle-aware foreground service management.
- Added robust `pin.it` redirect cleanup to resolve canonical pin URLs or usernames before extraction.
- Added deterministic filename generation (`<pinId>_image`, `<pinId>_thumbnail`, `<pinId>_video`) for predictable outputs.
- Added GitHub Actions workflow for automatic build, tag, and APK release on `main` pushes.

### Improvements & Fixes

- Continue mode is now media-type aware, preventing image/video completion state conflicts.
- Main Android media-channel logic was extracted to `MediaChannelHandler` for cleaner activity code and background reuse.
- Added `flutter_local_notifications` support + Android desugaring for consistent progress/completion notifications.
- Download queue now supports pause/resume orchestration for background lifecycle handling.
- `continueMode` now always starts unchecked on cold start (no stale persisted toggle).

### Removed / Impact

- **Behavioral change:** Android 13+ may request notification permission for background task notifications.
- **Compatibility:** minimum supported Android version remains API 24 (Android 7.0+).
