# Release Notes

## 3.1.0

### TL;DR (Recommended)

- **Recommended:** Download **PinDL-lite-arm64-v8a-v3.1.0-b7.apk**  
  Works on almost all modern Android phones.
- If you need advanced HLS processing, choose the **ffmpeg** variant.

### App variant

- **Lite** -> Smaller size, faster startup, recommended for most users (universal ≈ 59 MB).
- **FFmpeg** -> Larger size, includes advanced video processing (universal ≈ 136 MB).

### CPU architecture

- **arm64-v8a** -> Most Android phones (recommended)
- **armeabi-v7a** -> Older phones (32-bit)
- **x86_64** -> Emulator only
- **universal** -> Works everywhere, but larger size

Not sure? Choose **arm64-v8a**.

### Highlights

- **Boards are here.** Paste a Pinterest username, pick boards (or individual sections), and
  download whole boards in one go — files land in per-board folders under `Download/PinDL/@<username>/Boards/`.
- **Better video quality.** For pins offering multiple renditions, PinDL now picks the best
  available MP4 and prefers the newer HLS master stream — the same pin may yield a
  higher-quality file than before.
- **Carousel pins fully supported.** Multi-image pins now download one file per image
  (`<pinId>_image_1..n`) instead of only the first.
- **Large downloads resume at the byte level.** Interrupted big downloads continue where
  they stopped instead of starting over.

### What's New

- Boards & sections mode: live board discovery, per-board Whole / Sections / Skip choices,
  and sequential downloads with aggregated progress.
- Better rendition picks: best available MP4 (720P → 960P → 480P → 360P) instead of always
  preferring 720P, and the newer HLS master stream (V_HLSV4) preferred over the older mobile
  HLS stream when only HLS is offered.
- Feed quality: duplicate pins across pages are removed, and capped feeds show a
  "Fetch more" button instead of silently stopping.
- Downloads are verified before saving (file signature + size checks), so corrupted or
  unexpected responses are rejected instead of saved as broken files.
- Clearer errors for missing or changed pins, and switching between profiles no longer
  reuses the previous profile's cached pages.
- Interrupted download sessions resume more accurately: completed items are never
  re-downloaded, and failed or cancelled ones are re-offered.
- Progress notifications update at a steady rate instead of flooding the notification shade.

### Reliability

- Large media downloads resume at the byte level after interruptions (HTTP Range requests,
  verified against the Pinterest media CDN). If the server response is inconsistent,
  the download restarts cleanly instead of producing a corrupt file.
- On the lite build, HLS-only videos are skipped up front with a clear reason
  ("requires FFmpeg build") instead of failing mid-download.

### Removed / Impact

- **Behavioral change:** the same pin can now produce a different (better) file than in
  2.1.x, because better renditions are preferred.
- **Behavioral change:** Android 13+ may request notification permission for background
  task notifications.
- **Compatibility:** minimum supported Android version remains API 24 (Android 7.0+).
