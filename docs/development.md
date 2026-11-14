# Development

Practical contributor guide for building, testing, and releasing PinDL.

## Requirements

- **Flutter 3.47.5** (stable, Dart 3.13.4 — satisfies `pubspec.yaml` `environment.sdk` `^3.10.8`). Releases and CI are pinned to exactly this version — see [Release flow](#release-flow-maintainers)
- Android SDK + JDK 17
- A device or emulator (API 24+) only for the integration instruments

## Daily commands

```bash
flutter pub get          # dependencies
flutter analyze          # static analysis — expected clean: 0 errors, 0 warnings
flutter test             # unit suite (~435 tests) — fully offline, no device needed
```

The unit suite is deterministic: network calls are served by local static adapters, so it never touches the real network.

## Integration instruments (device only)

The `integration_test/` folder contains device evidence instruments (channel smoke, resume cycle, boards end-to-end, a range-support probe, and an HLS → FFmpegKit probe) driven with `flutter drive` through `test_driver/integration_test.dart`. They are development instruments — they are not part of `flutter test` and do not gate CI. Run one, for example:

```bash
flutter drive --driver=test_driver/integration_test.dart \
  -t integration_test/smoke_channels_test.dart \
  --flavor lite --debug -d <device-or-emulator-id>
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
   - derives the tag `vX.Y.Z-bN` from the pubspec version and skips if that **release** is already published (a run that tagged but never published is retried, reusing its tag),
   - fails before building if any of the four signing secrets is missing, since a missing keystore silently falls back to debug signing,
   - runs `flutter test` as the one host gate,
   - builds all four APK sets (lite/ffmpeg × split-per-ABI/universal) and requires all eight artifacts,
   - creates and pushes the tag, then a GitHub Release whose body is `RELEASE_NOTES.md`, uploading the APKs from `dist/`.
3. Tags are created by CI after successful builds — never tag releases manually, and never commit APKs.

`RELEASE_NOTES.md` holds the current release only and becomes the GitHub Release body; `CHANGELOG.md` accumulates full history. Keep both in that role.

The workflow pins Flutter **3.47.5** on purpose: the repository's Gradle wrapper is 8.14 with AGP 8.11.1, and a newer Flutter stable ships a Gradle plugin that requires Gradle ≥ 9.3.1, which AGP 8.11 does not support. Moving to a newer Flutter is a deliberate upgrade (wrapper + AGP + a full re-validation), after which the `flutter-version` pin in the workflow is bumped in the same change.

CI does release automation only. Device-level validation (the `integration_test/` instruments, including the channels smoke) is run locally against a real device — see [the instruments section above](#integration-instruments-device-only) — and is never repeated in the workflow.

## Conventions

- Analyzer-clean is the bar: no new warnings and no new `print` calls in production code — the console log service is the normal sink (`LogService.debug` is the verbose-only level). A legacy set of `[INFO]`/`[WARN]`/`[ERROR]` prints in the extractor and download service still writes to the platform log; moving them onto the log service is tracked as hygiene work.
- Tests are characterization-first: parser/selection/resume behavior is pinned by fixtures under `test/fixtures/`, so behavior changes show up as deliberate diffs.
- Formatting: don't reformat unrelated code; keep diffs focused.
