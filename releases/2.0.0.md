# Release Notes

## 2.0.0 - 2026-02-11

### TL;DR (Recommended)

- **Recommended:** Download **PinDL-lite-arm64-v8a.apk**  
  Works on almost all modern Android phones.

### App variant

- **Lite** → Smaller size, faster, recommended for most users.
- **FFmpeg** → Larger size, includes advanced video processing.

### CPU architecture

- **arm64-v8a** → Most Android phones (recommended)
- **armeabi-v7a** → Older phones (32-bit)
- **x86_64** → Emulator only
- **universal** → Works everywhere, but larger size

Not sure? Choose **arm64-v8a**.

### Highlights

- Choose between a smaller **lite** build or a full **ffmpeg** build with Pinterest HLS-to-MP4 support.
- Improved overall download reliability, with better startup stability and session recovery.

### What’s New

- Added **Continue mode** to resume interrupted username downloads, including prior-session stats and remaining items.
- Added a **Max pages** control (1-100) for username extraction so you can limit how much content is fetched.
- Added an upfront **storage access** flow (Allow/Exit) to reduce later download failures.

### Improvements & Fixes

- Addressed major user-facing reliability issues in one pass: startup hangs/crashes, result reset when toggling verbose logs, duplicate metadata files, and downloaded files not appearing after reinstall.

### Removed / Impact

- **Removed:** unused legacy components and redundant old paths (including the HLS stub file, deprecated `JobState`, unused helper members, and the redundant metadata permission-check path). This is cleanup-focused and is not expected to break normal user workflows.
- **Impactful compatibility update:** minimum supported Android version is now API 24 (Android 7.0+).
