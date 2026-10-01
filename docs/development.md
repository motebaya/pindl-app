# Development

Practical contributor guide for building, testing, and releasing PinDL.

## Requirements

- Flutter stable (Dart 3.10 — matches `pubspec.yaml` `environment.sdk`), Flutter 3.47.x is what releases are built with
- Android SDK + JDK 17
- A device or emulator (API 24+; CI smoke uses an API 30 emulator) only for the integration instruments

## Daily commands

```bash
flutter pub get          # dependencies
flutter analyze          # static analysis — expected clean: 0 errors, 0 warnings
flutter test             # unit suite (~309 tests) — fully offline, no device needed
```

The unit suite is deterministic: network calls are served by local static adapters, so it never touches the real network.

## Integration instruments (device only)

The `integration_test/` folder contains device evidence instruments (channel smoke, resume cycle, boards end-to-end, a range-support probe) driven with `flutter drive` through `test_driver/integration_test.dart`. They are development instruments — they are not part of `flutter test` and do not gate CI. Run one, for example:

```bash
flutter test integration_test/smoke_channels_test.dart \
  --flavor lite --debug
```

The boards end-to-end instrument needs a live device/emulator with storage permissions pre-granted; see the comments at the top of each instrument file for their setup notes.

## Build flavors

Two flavors exist, selected with `--flavor` and the `ENABLE_FFMPEG` dart-define:

```bash
# debug
flutter build apk --debug --flavor lite
flutter build apk --debug --flavor ffmpeg

# release (per flavor)
flutter build apk --release --flavor lite   --dart-define=ENABLE_FFMPEG=false
flutter build apk --release --flavor ffmpeg --dart-define=ENABLE_FFMPEG=true

# split per ABI (smaller per-device APKs)
flutter build apk --release --flavor lite --dart-define=ENABLE_FFMPEG=false --split-per-abi
```

Outputs land in `build/app/outputs/flutter-apk/` (`app-<flavor>-release.apk` universal, `app-<abi>-<flavor>-release.apk` split).

The `lite` flavor omits FFmpeg and skips HLS-only videos with an explicit message; `ffmpeg` includes `ffmpeg_kit_flutter_new_https` for HLS → MP4 conversion.

Helper scripts `build_prod.sh` (Linux/macOS) and `build_prod.ps1` (Windows) wrap clean/release builds; see their header comments for flags.

## Android setup notes

- `minSdk` 24; the manifest declares foreground service, storage, and notification permissions.
- Release signing reads `android/key.properties`. The repository contains a **placeholder template only** — real keystore material is never committed. For local release builds you must supply your own keystore and fill that file (see the placeholder's comments); for debug builds no signing setup is needed. CI reconstructs signing from GitHub Secrets at release time.
- `android/key.properties` and `*.jks` are gitignored; keep it that way.

## Release flow (maintainers)

Releases are automated from CI (`.github/workflows/release-on-push.yml`):

1. The version lives in `pubspec.yaml` as `X.Y.Z+N`. Before bumping, `git fetch --tags` and confirm the previous release tag exists locally.
2. Push to `main` triggers the workflow, which:
   - derives the tag `vX.Y.Z-bN` from the pubspec version and skips if that tag already exists,
   - runs `flutter test` as a quality gate,
   - builds all four APK sets (lite/ffmpeg × split-per-ABI/universal),
   - creates and pushes the tag, then a GitHub Release whose body is `RELEASE_NOTES.md`, uploading the APKs from `dist/`.
3. Tags are created by CI after successful builds — never tag releases manually, and never commit APKs.

`RELEASE_NOTES.md` holds the current release only; `CHANGELOG.md` accumulates history; `releases/*.md` are archives of past bodies. Keep all three in that role.

A second workflow job runs the host suite plus a channels smoke on an API-30 emulator on every push to `main`; failure logs are retained for 14 days.

## Conventions

- Analyzer-clean is the bar: no new warnings; production code does not call `print` (use the log service / debug prints as the surrounding code does).
- Tests are characterization-first: parser/selection/resume behavior is pinned by fixtures under `test/fixtures/`, so behavior changes show up as deliberate diffs.
- Formatting: don't reformat unrelated code; keep diffs focused.
