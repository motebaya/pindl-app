# Getting Started

PinDL is a personal-use Android app for downloading publicly accessible Pinterest images and videos. It is distributed through this repository's GitHub Releases — there is no Play Store build.

_Applies to PinDL 3.1.1._

## Requirements

- An Android 7.0+ device (minimum API 24). There is no iOS or desktop build.

## Install a release APK

1. Open the [releases page](https://github.com/motebaya/pindl-app/releases) and download the APK for the latest release.
2. Pick the right file:

| Choice | Pick this | Notes |
|---|---|---|
| Most phones | `PinDL-lite-arm64-v8a-…apk` | Small, fast, recommended |
| Older 32-bit phones | `…-armeabi-v7a-…apk` | |
| Emulators | `…-x86_64-…apk` | |
| Unsure / any device | `…-universal-…apk` | Largest |

   Two variants exist: **lite** (no video conversion) and **ffmpeg** (can convert HLS videos to MP4). See [Downloads](downloads.md) for what that means in practice.
3. On first install, Android will warn about installing from outside the Play Store ("unknown sources" / install unknown apps). Allow it for your browser or file manager.
4. When you first submit a download, the app asks for **All files access** so it can save into your public `Downloads` folder. On Android 13+ the app may also ask for **notification permission** so background progress and completion alerts can be shown.

## Building from source (optional)

You need Flutter (stable, Dart 3.10), the Android SDK, and JDK 17. See [Development](development.md) for the exact commands.

## First run

1. Launch **PinDL**.
2. Paste one of: a pin URL, a pin ID, a `@username`, or a `pin.it` short link (short links are resolved automatically; if one resolves to a profile, the input field is updated and you submit it yourself).
3. Submit. The app fetches the content, shows a preview/result card, and downloads into `Downloads/PinDL/…`.
4. If a previous session was interrupted, the app offers to resume or discard it on the next launch.

For the full input/mode walkthrough see [Usage](usage.md).
