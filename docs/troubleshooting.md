# Troubleshooting

_Applies to PinDL 3.1.1._

## Install problems

**"App not installed" / install blocked**
You are installing outside the Play Store. Allow _install unknown apps_ for the browser or file manager you downloaded the APK with, then retry. Check that you picked an APK matching your device (arm64-v8a for most modern phones, armeabi-v7a for older 32-bit devices, universal if unsure) — see [Getting Started](getting-started.md).

**Updating the app**
Install the new APK over the old one (same flavor). The signing key is consistent across releases, so updates install in place without uninstalling.

## Permissions

**Downloads don't start / nothing appears in Downloads**
The app needs **All files access** to write into the public `Downloads` folder. Grant it when the app asks (the permission gate appears on first submit), or via Android _Settings → Apps → PinDL → Permissions_. If it still fails after granting, restart the app once.

**No progress/completion notifications on Android 13+**
The app asks for notification permission; if denied or revoked, downloads still work — only the alerts are missing. Re-enable via _Settings → Apps → PinDL → Notifications_.

## Input and extraction

**"Invalid input — check the URL or username"**
The input is not a recognizable pin URL, pin ID, or username. Usernames look like `@name`; pin URLs contain the pin path. `pin.it` short links are resolved automatically.

**"This pin was deleted or doesn't exist"**
The pin is gone or private. Nothing to download.

**"No downloadable media found"**
The pin exists but contains no downloadable image/video (for example, text-only or link-only pins).

**"Pinterest's page structure changed — try updating the app"**
The site's layout shifted underneath the app. Check the [releases page](https://github.com/motebaya/pindl-app/releases) for a newer build.

**Extraction stops at a cap**
Large profiles are paginated with a per-run cap. Use the **Fetch more** button on the result card to continue.

## Downloads and media

**An item shows as failed**
Failed items are retried automatically (3 attempts) before being marked failed. Cancelled and failed items are re-offered by **Continue mode** on the next run of the same session — completed items are never re-downloaded.

**"HLS video — requires FFmpeg build"** (lite flavor)
That video is only offered as an HLS stream, which the lite variant cannot convert. Either skip it or install the **ffmpeg** variant APK.

**HLS conversion fails or output is missing** (ffmpeg flavor)
Conversion output is validated before being saved, so a broken conversion never produces a corrupt MP4 — the item is marked failed and can be retried. Temporary conversion files older than 24 hours are cleaned up automatically.

**A download restarted from zero**
Byte-range resume only continues when the server confirms the exact same file; if anything mismatches, the download restarts cleanly by design rather than saving a corrupt file. Very old or changed files are the usual cause.

**Wrong or unexpected file for a pin**
Since 3.1.1 the app prefers the best available rendition, so a pin can yield a different (better) file than older releases produced.

## Reporting a problem

**I need more detail than the console shows**
Turn on **Verbose logs** in the options and repeat the action. The console then includes request/response
detail and an extraction decision trace — which pages were tried, how many payloads each returned, and
which image/video rendition was chosen — alongside the normal progress lines. The console header's
copy-all button copies every line to the clipboard so you can paste it into a bug report.

## Boards

**A board doesn't appear in "Find boards"**
Only **public** boards are discoverable. Private/secret boards never show up.

**Board download stops partway**
Each board is processed as its own job; completed boards are skipped and incomplete ones re-run the next time. Check per-board progress in the session summary.

## Development builds

**`flutter analyze` / tests disagree with expectations**
Run `flutter pub get` first — stale generated files are the usual cause. Tests are fully offline and deterministic; they never need a device or network.

**Release build says signing config missing**
Release signing expects `android/key.properties` (local build) or CI secrets. The repository ships a placeholder template only — contributors should build debug APKs: `flutter build apk --debug`. See [Development](development.md).
