# Release Notes

## 3.1.1

Fixes a set of defects reported from a real-device QA pass, and finishes carousel support for
profile and board downloads. It also carries the feature work that had not been published before
(boards, byte-level resume, better rendition picks), so everything below ships together in this
release.

### TL;DR (Recommended)

- **Recommended:** Download **PinDL-lite-arm64-v8a-v3.1.1-b8.apk**
  Works on almost all modern Android phones.
- If you need HLS video conversion, choose the **ffmpeg** variant.

### App variant

- **Lite** → Smaller size, faster startup, recommended for most users (universal ≈ 59 MB).
  HLS-only videos are skipped with a clear reason instead of being saved.
- **FFmpeg** → Larger size, includes HLS → MP4 conversion (universal ≈ 136 MB).

### CPU architecture

- **arm64-v8a** → Most Android phones (recommended)
- **armeabi-v7a** → Older phones (32-bit)
- **x86_64** → Emulator only
- **universal** → Works everywhere, but larger size

Not sure? Choose **arm64-v8a**.

### Fixed in 3.1.1

- **Videos from single pins now download as videos.** An HLS video pin (`.m3u8`) used to be saved
  as a `<pinId>_video.mp4` file containing playlist text (~920 B, unplayable) with no error shown.
  Progressive MP4 is now fetched directly, and HLS is parsed and converted to MP4 before saving
  (ffmpeg variant). On the lite variant an HLS video is an explicit, honest skip.
- **“short body” retry loop is gone.** A download could fail forever when the CDN under-declared a
  body’s length; the declared length is now advisory and a longer body is accepted.
- **Manifests can no longer be imported as media.** Playlists and other plain-text responses are
  rejected for both images and videos.
- **“No data on pin page” for public pins.** Pin-page extraction now retries across the known
  hosts, bounded, and only reports the failure after the whole plan is exhausted.
- **Video pins pick the best rendition**, including when the pin page offers several records where
  only some carry a direct MP4.
- **Images download at full resolution.** Renditions are ranked by resolution instead of server
  key order, and a thumbnail-sized URL is rewritten to the full-resolution `/originals/` image.
- **Carousel (multi-image) pins download every slide — in your profile feed and in boards too.**
  Previously only the single-pin view expanded a carousel; a carousel pin reached through a
  username or board feed saved just its first image. Each slide is now downloaded as its own file
  (`<pinId>_image_<n>.<ext>`), progress counts slides individually, and an interrupted carousel
  resumes without re-downloading finished slides or skipping missing ones.
- **The preview’s speaker badge is a real mute/unmute toggle** (it was a static icon).
- **The console is selectable and has “copy all logs”**, and it opens with a line stating whether
  this build can convert HLS — so a wrong APK variant is visible instead of silent.

### Also in this release

- **Boards & sections mode:** live board discovery, per-board Whole / Sections / Skip choices, and
  sequential downloads with aggregated progress, into
  `Download/PinDL/@<username>/Boards/<board>-<id>/`.
- **Better rendition picks** for videos (best available MP4, newer HLS master stream preferred when
  only HLS is offered).
- **Feed quality:** duplicate pins across pages are removed, and capped feeds offer
  “Fetch more” instead of silently stopping.
- **Downloads are verified before saving** (file signature + size checks), so corrupted or
  unexpected responses are rejected rather than written as broken files.
- **Byte-level resume** for large downloads: an interrupted transfer continues from where it
  stopped instead of starting over.
- **Clearer errors** for missing or changed pins, and per-profile session isolation.

### Known limitations

- **Lite variant does not convert HLS:** HLS-only videos are skipped with the reason
  “requires FFmpeg build”.
- **Minimum Android version: API 24 (Android 7.0+).**
- **Sideload distribution only** — no Play Store build is produced by this repository.
