# This document provides video demonstrations of PinDL's core features with detailed explanations.

## 1. Download a Single Image

https://github.com/user-attachments/assets/f4e34aaa-9d34-4212-9d83-cf4e973ddd4e

### Steps Demonstrated:

1. **Enter Pin URL** - Paste a Pinterest pin URL (e.g., `https://pin.it/xxxxx` or `https://pinterest.com/pin/xxxxx`)
2. **Input Validation** - The app detects the input type and shows "PIN" label above the field
3. **Select Media Type** - Check "Image" checkbox (enabled by default)
4. **Submit** - Tap "Submit" to fetch pin information
5. **Preview** - If "Show preview" is enabled, the image thumbnail appears
6. **Download** - Tap "Download" to save the image

### Options Explained:

| Option            | Description                                     |
| ----------------- | ----------------------------------------------- |
| **Save metadata** | Saves pin info as JSON file alongside the image |
| **Overwrite**     | Replaces existing files with same name          |
| **Verbose logs**  | Shows detailed logs in the console panel        |
| **Show preview**  | Displays image/video preview before downloading |

### Output:

- Image saved to: `Downloads/PinDL/{pin_id}.jpg`
- Metadata (if enabled): `Downloads/PinDL/{pin_id}.json`

---

## 2. Download a Single Video and Thumbnail

https://github.com/user-attachments/assets/0c1b51e6-1427-4b77-b230-957cef3f2df2

### Steps Demonstrated:

1. **Enter Video Pin URL** - Paste a Pinterest video pin URL
2. **Select Both Media Types** - Check both "Image" and "Video" checkboxes
3. **Submit** - Tap "Submit" to fetch video information
4. **Video Preview** - The video autoplays (muted) in the preview panel
5. **Download** - Tap "Download" to save both thumbnail and video

### Media Type Checkboxes (Single Pin Mode):

| Selection       | Result                                                                                    |
| --------------- | ----------------------------------------------------------------------------------------- |
| Image only      | Downloads the pin image (or thumbnail for video pins)                                     |
| Video only      | Downloads the video file only                                                             |
| Both checked    | Downloads both thumbnail image AND video file                                             |
| Neither checked | **Not allowed** - Warning shown: "You must select either video or image, or select both." |

### Preview Panel Features:

- **THUMBNAIL badge** - Indicates image preview is the video's thumbnail
- **VIDEO/PLAYING badge** - Shows video playback status
- **Muted indicator** - Video plays without sound (bottom-right corner)

### Output:

- Thumbnail: `Downloads/PinDL/{pin_id}.jpg`
- Video: `Downloads/PinDL/{pin_id}.mp4`
- Metadata (if enabled): `Downloads/PinDL/{pin_id}.json`

---

## 3. Download All User Media

https://github.com/user-attachments/assets/f5010fdc-3ac7-4b48-8ee4-63d468b8fd3c

### Steps Demonstrated:

1. **Enter Username** - Type `@username` (with or without @ prefix)
2. **Input Validation** - The app detects username and shows "USER" label
3. **Select Media Type** - Choose "Image" OR "Video" (radio buttons - single select)
4. **Submit** - Tap "Submit" to fetch user profile and media list
5. **Profile Preview** - User avatar and info displayed
6. **Statistics** - Shows total items available for download
7. **Download All** - Tap "Download" to batch download all media

### User Mode vs Pin Mode:

| Feature         | Username Mode                 | Single Pin Mode           |
| --------------- | ----------------------------- | ------------------------- |
| Media selection | Radio buttons (single choice) | Checkboxes (multi-select) |
| Options         | Image OR Video                | Image AND/OR Video        |
| Continue option | Available                     | Not available             |
| Output folder   | `Downloads/PinDL/@username/`  | `Downloads/PinDL/`        |

### Download Statistics Panel:

| Stat           | Color  | Description                                 |
| -------------- | ------ | ------------------------------------------- |
| **Downloaded** | Green  | Successfully saved files                    |
| **Skipped**    | Yellow | Files already exist (when overwrite is OFF) |
| **Failed**     | Red    | Download errors (network issues, etc.)      |

### Output Structure:

```
Downloads/PinDL/
  @username/
    images/
      {pin_id_1}.jpg
      {pin_id_2}.jpg
      ...
    videos/
      {pin_id_1}.mp4
      {pin_id_2}.mp4
      ...
    @username_metadata.json  (if Save metadata enabled)
```

---

## 4. History extraction user/URL

<img width="360" height="800" alt="extraction_history" src="https://github.com/user-attachments/assets/eb82c9ee-935b-46a1-a7f0-1c02fd67bdc4" />

- Every extraction action, whether on a username or URL, will be saved in the history tab.
- Hold down on an item to copy it to the clipboard.

## 5. Download History

<img width="360" height="800" alt="download_history" src="https://github.com/user-attachments/assets/841a4980-69f5-450a-8b58-d5e832023cca" />

- Every media URL that has entered the download queue will be entered into the download history, whether its status is failed/skipped/successful.
- Hold down on an item to copy it to the clipboard.

## 6. Interrupt and Continue Downloading

https://github.com/user-attachments/assets/b53d0c96-c6c9-46fb-bdcb-a8201d41c49a

### Part A: Interrupting a Download

1. **Start Download** - Begin downloading user media
2. **Stop Button Appears** - Red stop icon next to download button
3. **Tap Stop** - Confirmation dialog: "This will interrupt all downloads..."
4. **Confirm** - Download stops, statistics preserved
5. **Metadata Saved** - Progress automatically saved to metadata file

### Part B: Continuing an Interrupted Download

1. **Enter Same Username** - Type the username from interrupted session
2. **Enable Continue Mode** - Check "Continue" checkbox
3. **Metadata Loaded** - App loads previous session data
4. **Total Progress Shown** - Displays accumulated totals: "X downloaded, Y skipped, Z failed"
5. **Interrupted Warning** - Yellow badge: "Previous session was interrupted"
6. **Remaining Count** - Shows only remaining items to download (based on media type)
7. **Continue Download** - Button changes to "Continue Download"
8. **Resume** - Downloads resume directly from `last_index_downloaded` (no re-checking)

### Continue Mode States:

| State             | Header                         | Button                             | Action                     |
| ----------------- | ------------------------------ | ---------------------------------- | -------------------------- |
| Ready to continue | "Ready to Continue" (blue)     | "Continue Download"                | Resumes from last position |
| All downloaded    | "No items to continue" (red X) | "All downloaded" (green, disabled) | Nothing to do              |
| No metadata found | Warning snackbar shown         | Continue checkbox auto-unchecked   | Run fresh download first   |

### How Continue Mode Works:

1. **Metadata Required** - "Save metadata" must have been enabled in previous session
2. **Tracks Progress** - Each downloaded/skipped/failed item is recorded and accumulated across sessions
3. **Per-Media-Type** - Remaining items calculated per media type (image vs video); switching types shows full count for the new type
4. **Skips Directly** - Download queue starts from `last_index_downloaded + 1`, no re-checking from index 0
5. **Accumulated Stats** - `success_downloaded` accumulates across sessions (e.g., session 1: 100, session 2: +200 = 300 total)
6. **Overwrite Bypass** - If "Overwrite" is enabled, the download button re-enables even for fully downloaded types

---

## 7. Extraction Progress Notification

<!-- TODO: Replace with actual screenshot/video -->
<img width="540" height="651" alt="extract_progress" src="https://github.com/user-attachments/assets/e8bbc84f-322c-4a05-8010-74246cd82462" />

When the app is running in the background during username extraction, a notification appears showing real-time progress:

### Notification Details:

| Property       | Value                                               |
| -------------- | --------------------------------------------------- |
| **Channel**    | Download Progress (silent, no sound)                |
| **Style**      | Ongoing with indeterminate/determinate progress bar |
| **Title**      | `Extracting: @username`                             |
| **Body**       | `collecting items: 245, pages: 5/50`                |
| **Status bar** | Download arrow icon (monochrome)                    |
| **Importance** | LOW (no sound, no heads-up popup)                   |

### Behavior:

- Notification appears only when app is in the background
- Progress bar updates as pages are extracted
- Notification is automatically cleared when app returns to foreground
- If extraction completes while backgrounded, switches to completion notification

---

## 8. Download Progress Notification

<img width="540" height="635" alt="download_progress" src="https://github.com/user-attachments/assets/c2acc094-b85b-451d-89cf-cf3fa86c86cb" />

During media downloads in the background, a progress notification shows byte-level download progress:

### Notification Details:

| Property       | Value                                          |
| -------------- | ---------------------------------------------- |
| **Channel**    | Download Progress (silent, no sound)           |
| **Style**      | Ongoing with determinate progress bar (0-100%) |
| **Title**      | `Downloading (3/47): {pin_id}.jpg`             |
| **Body**       | `success: 2, skipped: 0, failed: 0`            |
| **Status bar** | Download arrow icon (monochrome)               |
| **Importance** | LOW (no sound, no heads-up popup)              |

### Behavior:

- Progress bar reflects byte-level download progress for the current file
- Title updates with each new file in the queue
- Body shows running totals of downloaded/skipped/failed items
- Foreground service keeps the app alive during long downloads
- Notification is automatically cleared when app returns to foreground

---

## 9. Completion Notification

 <img width="540" height="370" alt="notification_comlete" src="https://github.com/user-attachments/assets/46564def-2fb5-4ac1-8143-0fdbbef3b99b" />

When extraction or download completes while the app is in the background, a heads-up notification appears:

### Notification Details:

| Property       | Value                                        |
| -------------- | -------------------------------------------- |
| **Channel**    | Task Completed (with sound)                  |
| **Style**      | Heads-up popup, auto-cancel on tap           |
| **Title**      | `Extraction Complete` or `Download Complete` |
| **Body**       | `Extraction completed in 3m 12s` or similar  |
| **Sound**      | Default system notification sound            |
| **Importance** | HIGH (heads-up popup, sound, vibration)      |

### Behavior:

- Only shown when the app is in the background
- Plays the default system notification sound
- Vibrates the device
- Auto-cancels when the user taps it
- Automatically cleared when the user opens the app
- Duration is calculated from when the task started to when it finished

---

## Console Panel

The console panel at the bottom shows real-time logs:

| Log Type | Color  | Example                                                |
| -------- | ------ | ------------------------------------------------------ |
| Info     | Blue   | `[INFO] Fetching user profile...`                      |
| Success  | Green  | `[SUCCESS] Downloaded: image_123.jpg`                  |
| Warning  | Yellow | `[WARN] File exists, skipping...`                      |
| Error    | Red    | `[ERROR] Network timeout`                              |
| Debug    | Gray   | `[DEBUG] Response: 200 OK` (only with Verbose enabled) |

**Verbose Mode**: When enabled, shows additional debug information including API responses and detailed progress.

---

## Button States Reference

### Submit Button

| State         | Label              | Icon      | Enabled |
| ------------- | ------------------ | --------- | ------- |
| Ready         | "Submit"           | Search    | Yes     |
| Loading       | "Loading info..."  | Spinner   | No      |
| Continue mode | "Using saved data" | Checkmark | No      |

### Download Button

| State          | Label               | Icon      | Color | Enabled |
| -------------- | ------------------- | --------- | ----- | ------- |
| Ready          | "Download"          | Download  | Blue  | Yes     |
| Continue ready | "Continue Download" | Play      | Blue  | Yes     |
| Downloading    | "Download"          | Spinner   | Blue  | No      |
| All downloaded | "All downloaded"    | Checkmark | Green | No      |

### Stop Button

- **Appears**: Only during active extraction or download
- **Icon**: Red stop icon
- **Action**: Shows confirmation dialog before stopping

---

## Storage Permissions

On first launch, PinDL requests storage permissions:

- **Android 10+**: Uses MediaStore API (no permission dialog needed)
- **Android 9 and below**: Requests WRITE_EXTERNAL_STORAGE permission

All downloads are saved to the public Downloads folder, accessible via any file manager.
