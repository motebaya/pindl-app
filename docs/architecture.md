# Architecture (contributor overview)

PinDL is a Flutter Android application with a layered structure: UI on top, orchestration below it, and extraction/download/persistence services at the bottom. This page describes the codebase as it exists in 3.1.1.

## Layout

```text
lib/
├── core/               # Pure Dart: no widgets, no platform channels
│   ├── network/        # HTTP host allowlist, retry util, byte-range resume engine
│   ├── validation/     # Download content validation (signatures, size floor)
│   ├── persistence/    # Metadata schema (v2) reading/writing
│   ├── media/          # Media rendition selection
│   ├── utils/          # Filename/folder helpers, URL validation
│   └── …               # config, constants, exceptions, theme
├── data/
│   ├── controllers/    # ExtractionController, DownloadCoordinator, BoardController
│   ├── services/       # Dio-based download service, HLS converter, Hive history,
│   │                   # task-state persistence, notifications, logging
│   ├── parsers/        # Pinterest HTML/JSON parsing
│   ├── pinterest/      # Request construction (resources/registry)
│   └── models/         # Board, BoardSection, PinItem, …
└── presentation/
    ├── pages/          # Home page (host + part files), about page
    ├── providers/      # Riverpod job/extraction/download orchestration
    ├── widgets/        # Boards picker, soft-UI widget kit
    └── utils/          # User-facing error message mapping
```

## Flow

```text
UI (presentation/pages)
  ↓
providers (Riverpod orchestration: session state, hooks, channels)
  ↓
controllers (data/controllers)
  ├── ExtractionController  — input routing, short-URL resolution, feed pagination,
  │                           single-pin extraction, metadata assembly (pure data out)
  ├── BoardController       — board/section/pin listing with capped pagination + dedupe
  └── DownloadCoordinator   — per-item download planning, queue processing,
                              HLS branches, completion-set tracking
  ↓
services (data/services)          core (lib/core)
  ├── DownloadService (dio, 3-wide sliding window)   ├── retry + host allowlist
  ├── HlsService/HlsConverter (ffmpeg variant)       ├── byte-range resume engine
  ├── TaskStatePersistence + Hive history            ├── content validation
  └── NotificationHelper / LogService                └── metadata schema v2
```

The controller layer is deliberately widget-free and platform-channel-free: extraction and download planning return plain data, so the whole layer is fixture-testable without Flutter bindings. The provider layer owns the state machine and the only platform-channel call sites.

## Key invariants

- **Completion set is authoritative.** A session's progress is a set of completed item indices; `last_index_downloaded` is derived as the largest contiguous run. Success/skip = complete; failed/cancelled = incomplete and re-offered. Completion records are media-type relative (image vs video lists are separate).
- **Validate before save.** Downloaded bytes are checked (file signature, minimum size) before entering the Downloads folder; unknown signatures fail closed for images.
- **Resume is fail-safe.** Byte-level resume continues only on an exact 206 match with the recorded validators (ETag/size); any anomaly falls back to a clean full restart.
- **Metadata JSON is the resume truth.** Files carry a `schema` field (currently 2); readers tolerate older files, and future schemas prompt instead of guessing.
- **Feed path stability.** Boards reuse the same download coordinator and queue machinery as feed downloads (per-board folders via an output override); the feed path is unchanged when boards mode is off.

## Platform notes

- Android integration lives under `android/` (Kotlin `MainActivity` + `MediaChannelHandler` for media-store and storage operations). Plugins are registered manually, and a test mirrors that list against the generated plugin file so drift fails CI with the offending plugin named.
- Two build flavors exist: `lite` and `ffmpeg` (HLS conversion), selected by the `ENABLE_FFMPEG` dart-define. `minSdk` is 24.

See [Development](development.md) for commands and CI behavior.
