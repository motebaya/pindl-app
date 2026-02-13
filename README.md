<div align="center">

<img src="assets/icons/app_icon.png" alt="PinDL Logo" width="100" height="100">

# PinDL

<small>A personal-use utility app for downloading publicly accessible Pinterest content.</small>

[![dart](https://img.shields.io/badge/Dart-3.10-0175C2?style=flat&logo=dart&logoColor=white)](https://dart.dev/)
[![flutter](https://img.shields.io/badge/Flutter-3.38-02569B?style=flat&logo=flutter&logoColor=white)](https://flutter.dev/)
[![kotlin](https://img.shields.io/badge/Kotlin-2.0-7F52FF?style=flat&logo=kotlin&logoColor=white)](https://kotlinlang.org/)
[![Android](https://img.shields.io/badge/Android-26%2B-3DDC84?style=flat&logo=android&logoColor=white)](https://developer.android.com)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![API](https://img.shields.io/badge/API-26%2B-brightgreen.svg?style=flat)](https://android-arsenal.com/api?level=26)

</div>

PinDL is a Flutter-based Android application that allows users to download publicly accessible images and videos from Pinterest. It supports downloading content from: **Individual Pins** (`URL` or `PIN ID`) and **User Profiles** (Bulk download from any public `Pinterest username`). The app features a beautiful Neumorphism (Soft UI) design with both light and dark themes.

- See also the CLI version of the same tool built using Node.JS: [motebaya/pinterest-js](https://github.com/motebaya/pinterest-js)

## How It Works

```mermaid
flowchart TD
    A[User Input] --> B{Short URL?}
    B -->|pin.it link| C[Resolve Short URL]
    B -->|No| D{Input Type?}

    C --> C1{Resolved Type?}
    C1 -->|Pin Page| D
    C1 -->|User Profile| C2[Update Input Field to @username]
    C2 --> C3[User Adjusts Settings & Submits Manually]
    C3 --> D

    D -->|Username| E[Fetch User Config]
    D -->|Pin URL/ID| F[Fetch Pin Data]

    E --> G[Get User Pins with Pagination]
    G --> H[Parse Media URLs]

    F --> I[Extract Media Info]
    I --> H

    H --> J{Media Type Filter}
    J -->|Images| K[Queue Image Downloads]
    J -->|Videos| L{Video Format?}

    L -->|Direct MP4| M[Queue MP4 Downloads]
    L -->|HLS .m3u8| N{Build Flavor?}

    N -->|FFmpeg Build| O[Parse HLS Master Playlist]
    O --> P[Select Best Video+Audio Variant]
    P --> Q["FFmpeg Demux/Remux (stream-copy)"]
    Q --> R[Output MP4]

    N -->|Lite Build| S[Re-fetch Pin as Single URL]
    S --> T{Direct MP4 Found?}
    T -->|Yes| U[Download Direct MP4]
    T -->|No| V[Skip / Error]

    K --> W[Download via Dio]
    M --> W
    U --> W

    W --> X{App in Background?}
    X -->|Yes| X1[Foreground Service Active]
    X1 --> X2[Progress Notification with Bar]
    X2 --> Y
    X -->|No| Y[Save to Downloads/PinDL]

    R --> Y
    Y --> Z[Update MediaStore]
    Z --> AA[Save Metadata JSON]

    AA --> AB{Interrupted?}
    AB -->|Yes| AC[Save Resume Stats]
    AB -->|No| AD{App in Background?}

    AD -->|Yes| AE[Completion Notification with Sound]
    AE --> AF[Complete]
    AD -->|No| AF

    AC --> AG[Continue Mode Available]
    AG --> AH{Same Media Type?}
    AH -->|Yes| AI[Resume from last_index_downloaded]
    AH -->|No| AJ[Start Fresh for New Type]
```

## Features

> [!IMPORTANT]
> **Feature full Explanation & Demo**: [See Here](SHOWCASE.md)

| Feature                              | Status |
| ------------------------------------ | ------ |
| Download from Pinterest username     | ✅     |
| Download single pins via URL         | ✅     |
| Download single pins via pin ID      | ✅     |
| Short URL resolution (pin.it)        | ✅     |
| Image download support               | ✅     |
| Video download support (720p)        | ✅     |
| HLS video conversion (FFmpeg build)  | ✅     |
| HLS fallback extraction (Lite build) | ✅     |
| Batch/bulk downloads                 | ✅     |
| Background downloads (foreground service) | ✅ |
| Progress notifications with bar      | ✅     |
| Completion notifications with sound  | ✅     |
| Resume interrupted downloads         | ✅     |
| Cross-session progress accumulation  | ✅     |
| Per-media-type continue mode         | ✅     |
| Task state persistence (Hive)        | ✅     |
| Crash recovery (WorkManager)         | ✅     |
| Metadata saving (JSON)               | ✅     |
| Skip existing files                  | ✅     |
| Overwrite mode                       | ✅     |
| Light theme                          | ✅     |
| Dark theme                           | ✅     |
| Download history                     | ✅     |
| Extraction history                   | ✅     |
| MediaStore integration (Android 10+) | ✅     |
| Video preview playback               | ✅     |
| Continue from last position          | ✅     |

## Project Structure

```
lib/
├── core/
│   ├── constants/          # App constants and Pinterest API config
│   ├── exceptions/         # Custom exception classes
│   ├── theme/              # App themes and Neumorphism styles
│   └── utils/              # Utility functions and validators
├── data/
│   ├── models/             # Data models (Pin, Author, BackgroundTaskState, etc.)
│   ├── parsers/            # Pinterest HTML/JSON parsers
│   └── services/           # API, download, notification, and persistence services
├── presentation/
│   ├── pages/              # UI screens (Home, History, About, etc.)
│   ├── providers/          # Riverpod state management + foreground service manager
│   └── widgets/            # Reusable Soft UI widgets
└── main.dart               # App entry point (Hive + WorkManager init)

android/
├── app/
│   ├── src/main/
│   │   ├── kotlin/         # Kotlin code (MainActivity, MediaChannelHandler)
│   │   └── res/drawable/   # Notification icons (ic_download_notification)
│   └── build.gradle.kts    # Android build configuration (core library desugaring)
└── key.properties          # Signing configuration (not in git)
```

## Building

### Prerequisites

- Flutter SDK 3.10.8 or higher
- Android SDK
- Java JDK 17
- Keytool (for release builds)

### Development/Debug Build

```bash
# Get dependencies
flutter pub get

# Run in debug mode
flutter run

# Build debug APK
flutter build apk --debug
```

The debug APK will be at: `build/app/outputs/flutter-apk/app-debug.apk`

### Production/Release Build

The app supports two build flavors:
- **lite**: Minimal build without FFmpeg (smaller APK, no HLS conversion)
- **ffmpeg**: Full build with FFmpeg support (HLS → MP4 conversion, includes `ffmpeg_kit_flutter_new_https`)

And two ABI build modes:
- **Standard**: Single APK with all ABIs (~larger file size)
- **Split ABI**: Separate APKs per architecture (armeabi-v7a, arm64-v8a, x86, x86_64) for smaller file sizes

#### Using Build Scripts (Recommended)

**PowerShell (Windows):**

```powershell
# First time: Generate keystore, clean, and build
.\build_prod.ps1 -GenerateKeyStore -Clean -BuildRelease -Flavor lite

# Build lite flavor (no FFmpeg)
.\build_prod.ps1 -BuildRelease -Flavor lite

# Build ffmpeg flavor (with FFmpeg support)
.\build_prod.ps1 -BuildRelease -Flavor ffmpeg

# Build with split ABI (smaller APKs per architecture)
.\build_prod.ps1 -BuildRelease -Flavor ffmpeg -SplitABI

# Build both flavors with split ABI
.\build_prod.ps1 -BuildRelease -Flavor all -SplitABI

# Clean only
.\build_prod.ps1 -Clean

# Show help
.\build_prod.ps1 -Help
```

**Bash (Linux/macOS):**

```bash
# Make script executable (first time only)
chmod +x build_prod.sh

# First time: Generate keystore, clean, and build
./build_prod.sh --generatekeystore --clean --build-release --flavor lite

# Build lite flavor (no FFmpeg)
./build_prod.sh --build-release --flavor lite

# Build ffmpeg flavor (with FFmpeg support)
./build_prod.sh --build-release --flavor ffmpeg

# Build with split ABI (smaller APKs per architecture)
./build_prod.sh --build-release --flavor ffmpeg --splitABI

# Build both flavors with split ABI
./build_prod.sh --build-release --flavor all --splitABI

# Clean only
./build_prod.sh --clean

# Show help
./build_prod.sh --help
```

**Build Flavors:**
- `lite`: ~15-20MB APK, no video format conversion (HLS videos stay as HLS)
- `ffmpeg`: ~50-60MB APK, includes FFmpeg for HLS → MP4 conversion
- `all`: Builds both flavors

**Split ABI Benefits:**
- Reduces APK size by ~40-60% per architecture
- Faster downloads and installation for end users
- Google Play automatically serves the correct APK for each device
- Supported ABIs: armeabi-v7a (32-bit ARM), arm64-v8a (64-bit ARM), x86 (32-bit Intel), x86_64 (64-bit Intel)

#### Manual Build (Without Scripts)

1. **Generate Keystore:**

```bash
keytool -genkey -v \
  -keystore android/pindl-release.jks \
  -alias pindl \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000
```

2. **Create `android/key.properties`:**

```properties
storePassword=your_store_password
keyPassword=your_key_password
keyAlias=pindl
storeFile=../pindl-release.jks
```

3. **Build Release APK:**

```bash
# Build lite flavor (no FFmpeg)
flutter build apk --flavor lite --dart-define=ENABLE_FFMPEG=false --release

# Build ffmpeg flavor (with FFmpeg)
flutter build apk --flavor ffmpeg --dart-define=ENABLE_FFMPEG=true --release

# Build with split ABI (add --split-per-abi flag)
flutter build apk --flavor ffmpeg --dart-define=ENABLE_FFMPEG=true --release --split-per-abi
```

**Output locations:**
- Standard build: `build/app/outputs/flutter-apk/app-{flavor}-release.apk`
- Split ABI build: `build/app/outputs/flutter-apk/app-{flavor}-{abi}-release.apk`

## Storage Structure

Downloaded files are saved to:

```
Downloads/
└── PinDL/
    ├── @username/
    │   ├── Images/         # Downloaded images
    │   ├── Videos/         # Downloaded videos
    │   └── <userId>.json   # User metadata with resume stats
    └── metadata/
        └── <pinId>.json    # Single pin metadata
```

## Legal Notice

This app is intended for **personal use only**. It only handles publicly accessible content. Users are responsible for ensuring their use complies with Pinterest's terms of service and applicable laws.

- Do not use this app for commercial purposes
- Respect content creators' rights
- Only download content you have permission to use

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
