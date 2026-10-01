# Usage

_Applies to PinDL 3.1.0._

## What you can paste

| Input | Behavior |
|---|---|
| Pin URL | Downloads that single pin |
| Pin ID | Same as a pin URL |
| `@username` (or plain username) | Bulk download of that profile's pins, paginated |
| `pin.it/…` short link | Resolved automatically; pin links download, profile links fill the input with `@username` for you to submit |

Feed downloads are capped per run. When a cap is hit, a **Fetch more** button appears on the result card to continue from where extraction stopped (it reuses the stored cursor only when the request context still matches — otherwise it re-extracts from the first page).

## Feed and Boards modes

A **Feed | Boards** switch sits above the input:

- **Feed** (default): pins from a single pin or a user profile.
- **Boards**: paste a username, then tap **Find boards** to list that account's boards. See [Boards](boards.md).

## Media type and options

You choose whether to download images, videos, or both, and whether to enable **Continue mode** (resume a previous session). Continue mode always starts unchecked on a fresh launch — it never silently persists.

## Downloads and progress

- Files are saved to `Downloads/PinDL/@<username>/Images` and `…/Videos` (`<pinId>_image.jpg`, `<pinId>_video.mp4`, `<pinId>_thumbnail.jpg`; carousel/multi-image pins get `<pinId>_image_1..n`).
- A session summary (downloaded / skipped / failed) is shown, and a metadata JSON is written alongside for resume support.
- Progress appears in the app; when the app goes to the background, a foreground service keeps work running and a progress notification takes over, with a completion alert at the end. Notifications update at a steady rate, not a flood.
- Cancel from the app; cancelled items count as incomplete and are re-offered by Continue mode.

## Resume behavior

- Interrupted sessions are persisted. On the next launch the app offers to **resume or discard**.
- Continue mode is media-type aware: image and video sessions keep separate completion records, so switching type never corrupts the other list.
- Successfully downloaded items are never re-downloaded; failed or cancelled ones are re-offered.

## Limitations

- **lite flavor:** HLS-only videos (`.m3u8` streams) are skipped up front with the message "HLS video — requires FFmpeg build". Use the ffmpeg variant for those.
- Private boards/pins, logged-in-only content, and quality picking are not supported — the app only handles publicly accessible content.
- Extraction depends on Pinterest's page structure; if it changes, downloads can fail with "Pinterest's page structure changed — try updating the app".

Errors are shown in plain language (for example "This pin was deleted or doesn't exist" or "No downloadable media found") — see [Troubleshooting](troubleshooting.md).
