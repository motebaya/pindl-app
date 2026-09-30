# LICENSES

PinDL's own code is MIT-licensed. The distributed APKs bundle third-party
components under their own licenses, listed here per the redistribution
hygiene requirement (LEG-1/LEG-2). This file is a compliance summary, not
legal advice.

## PinDL application code

- **License:** MIT (see [LICENSE](LICENSE))
- **What we distribute:** the app's Dart/Kotlin code, compiled into the APK.

## Flutter engine & framework

- **License:** BSD-3-Clause
- **Upstream:** https://github.com/flutter/flutter
- **What we distribute:** the compiled Flutter engine (`libflutter.so`) and
  framework runtime inside every APK. Flutter's bundled-font notices are
  covered by the engine's own license bundle (`flutter --licenses`).

## Fonts — Playpen Sans

- **License:** SIL Open Font License, Version 1.1 — full text in
  [`assets/fonts/OFL.txt`](assets/fonts/OFL.txt)
- **Upstream:** https://github.com/google/fonts/tree/main/ofl/playpensans
  (project authors: https://github.com/TypeTogether/Playpen-Sans)
- **What we distribute:** 5 static TTF weights (Light 300, Regular 400,
  Medium 500, SemiBold 600, Bold 700) as bundled assets. The OFL requires
  this license text to accompany redistribution — provided beside the files
  and here.

## FFmpegKit (HLS → MP4 conversion, `ffmpeg_kit_flutter_new_https`)

- **License:** LGPL-3.0 as stated by the package's metadata
  (community fork: `ffmpeg_kit_flutter_new_https` ^2.1.0)
- **FFmpeg upstream:** https://ffmpeg.org
- **What we distribute:** the FFmpegKit native libraries in the `ffmpeg`
  flavor only (the `lite` flavor contains none).
- **Build note:** the app invokes FFmpeg with stream-copy arguments
  (`-c copy` demux/remux of HLS segments into MP4). No transcoding is
  performed and no GPL components are knowingly enabled; the owner should
  verify the fork's published build flags against its stated license if
  this matters for a distribution channel.

## AndroidX, Kotlin, and other Gradle/Maven dependencies

- **License:** Apache-2.0 (AndroidX libraries, Kotlin standard library and
  runtime components)
- **Upstream:** https://android.googlesource.com/platform/frameworks/support ;
  https://github.com/JetBrains/kotlin
- **What we distribute:** compiled classes/resources merged into the APK.

## Dart packages

All Dart packages are used unmodified from pub.dev under their published
licenses (spot-verified from package metadata: `dio`/`flutter_riverpod`/
`flutter_foreground_task`/`permission_handler` MIT; `hive` Apache-2.0;
`video_player`/`shared_preferences` BSD-3 Flutter Authors; the FFmpegKit
package LGPL-3.0). Each package's LICENSE file is the authoritative text.
