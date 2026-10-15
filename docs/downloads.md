# Downloads

_Applies to PinDL 3.1.1._

## How downloads work

Each media item is fetched, **validated before saving** (file signature and size are checked), and only then moved into your public `Downloads` folder via Android's media store. A corrupted or unexpected response is rejected as a failed item — it never lands in your gallery looking like a successful download.

## Output organization

```text
Downloads/PinDL/
├── @<username>/
│   ├── Images/<pinId>_image.jpg        (multi-image pins: <pinId>_image_1..n)
│   ├── Videos/<pinId>_video.mp4
│   ├── <pinId>_thumbnail.jpg
│   └── <userId>.json                   (session metadata for resume)
├── @<username>/Boards/<board-slug>-<id>/
│   ├── Images/…  └── Videos/…          (board downloads; see Boards)
└── metadata/<id>.json                  (single-pin metadata)
```

Filenames are deterministic per pin, so re-downloading the same pin replaces the same file instead of creating duplicates.

## Concurrency, retries, and failures

- Up to **3 downloads** run in parallel; the rest queue.
- Network hiccups are retried automatically: up to **3 attempts** per request with short, jittered backoffs between them. Rate-limit responses (HTTP 429) wait longer. Cancelling always wins immediately.
- Failed items are marked failed in the session summary and re-offered by Continue mode — they never count as downloaded.

## Interrupted and partial downloads

- If the app or device is interrupted mid-download, the **partial file is preserved** (never deleted on cancel or network error).
- Large downloads support **byte-range resume**: the next attempt continues from where the transfer stopped instead of starting over, verified against the media CDN. If the server's answer is inconsistent (changed file, mismatched ranges), the download restarts cleanly from zero rather than producing a corrupt file — a restart is the fallback, never a corrupt save.
- Interruptions across app restarts are covered by the resume prompt and Continue mode (see [Usage](usage.md)).

## Video / HLS handling (ffmpeg variant)

- Direct MP4 renditions are downloaded directly; the app picks the best available quality for pins offering multiple renditions, and finds the video wherever the pin page exposes it (several response records, the record's own `videos` list, or the pin data embedded in the page).
- HLS streams (`.m3u8`) are parsed (master playlist → best video+audio variant) and remuxed into a single `.mp4` using stream copy. Output is validated (duration/structure) before it counts as downloaded, and conversions can be cancelled — a cancelled conversion is re-offered, not marked failed.
- Temporary conversion files older than 24 hours are swept on the next conversion; the current session's temp file is removed on finish or cancel.
- **lite variant:** HLS-only items are skipped with an explicit reason instead of failing mid-download.

## Background behavior

While the app is backgrounded, a foreground service keeps extraction and downloads alive, progress continues under a notification with a progress bar, and a completion alert plays at the end. Android 13+ may ask for notification permission; downloads work regardless, only the alerts are affected.
