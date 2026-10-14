# Features

What each tab does. Design rationale lives in the code; this document is the behavioural spec.

## Download tab

- M3 `SearchBar` URL input with paste and clear, plus a clipboard FAB that extracts a link out of whatever you shared.
- **Share-sheet intake** (Android): a URL shared from another app lands here, auto-filled and fetched. The cold-start payload is buffered and consumed with `reset()`, so sharing into a closed app is not lost and a restart does not replay it.
- `yt-dlp -J` metadata fetch, a `VideoInfoCard` (thumbnail via `cached_network_image`) and a single **Download** button.
- A link that resolves to a **playlist** shows a playlist summary instead of a video card; a channel link offers **Download everything**.

### Format sheet

The Download button opens a bottom sheet:

- **Format** — `SegmentedButton` for Video/Audio, `ChoiceChip` for quality.
- **Audio quality** is offered as named tiers (Best/High/Medium/Low) resolved against the source's actual bitrates. Tiers that would deliver the same file are hidden, and each row shows the real container and kbps.
- **Subtitles** — sidecar `.srt`/`.vtt` and/or embed, with per-language chips (auto-generated captions marked "(auto)") and an "All available" option. Embed is gated on ffmpeg. Options are seeded from the Settings defaults on every open.
- **Cover art is derived, not toggled**: an audio download embeds the thumbnail, a video download does not. The sheet states the outcome, including when it is dropped for want of ffmpeg/ffprobe or a container that cannot hold an image.

There is deliberately **no** per-download argument or file-name override here — both live in Settings and apply to every download (see [advanced-settings.md](advanced-settings.md)).

## Queue tab

Backed by `DownloadManager` (a `ChangeNotifier`) that streams yt-dlp `--newline` output.

- Live progress (`LinearProgressIndicator`, %/speed/ETA) with **icon-only** per-task actions: pause + cancel while running, resume + cancel while held, retry + dismiss once failed or canceled, open/share/delete once finished. The app bar pauses the whole queue as well.
- Waiting tasks show a static "Waiting to start" label rather than an indeterminate bar.
- **Queue-wide pause/resume**, **per-task hold**, cancel all with a confirmation, clear finished, and per-task move-earlier/later reordering of anything still waiting. Reordering changes only the queue position, never the creation time.

### Holds

A hold is per task, and `dart:io` cannot suspend a child process:

- Holding a **waiting** download removes it from the scheduler while the rest of the queue carries on.
- Holding a **running** one stops the process, keeps the staging directory and `.part` file, and releases back to waiting. Releasing restarts yt-dlp, which continues from the partial because `--continue` is on by default and the same staging directory is reused.
- A held task shows the percentage it stopped at. The two kinds of pause are labelled separately in the app bar.
- A hold is **not** resumed by an app restart: the task comes back as *failed* with its partial intact, the same as interrupted work.

### Engine and file handling

- **Resumable** — a failed or interrupted download keeps its staging directory and `.part` file, so Retry continues instead of re-fetching. Engine flags add `--continue`, `--retries` and `--fragment-retries` (both configurable in Settings, 0–20) and a capped `--retry-sleep linear=1:5:2` backoff.
- **Restart-safe** — the queue is snapshotted to Hive, including each task's subtitle options. Work that was running when the process was killed comes back as *failed* ("Interrupted when the app closed — tap Retry to continue"). Staging directories no task refers to are deleted on startup. Snapshots are written on a **throttle** (at most one every few seconds) *and* immediately on every user-visible state — enqueue, cancel, hold, retry, completion, removal.
- **Finished files are never silently overwritten.** The final name is reserved before the move, because `rename` deletes an existing destination. A move that crosses a filesystem boundary (SD card, removable volume) falls back to copy-then-delete.
- **Staging directories are only deleted if they really are staging.** The path comes from the queue snapshot, so it is checked against the staging root before any destructive path acts on it.
- **`--download-archive` is serialised.** yt-dlp loads and rewrites the whole ledger, so only one archive-using download runs at a time.
- **Cancelling stops the process.** The signal escalates to `SIGKILL` if the child has not gone, and the run waits for it.
- **Child pipes are drained to completion** rather than cancelled when the exit status arrives; exit status and pipe output travel on separate channels.
- **Sidecars are kept**: subtitles land next to the media file in the library folder (`.mkv` + `.en.srt`). yt-dlp warnings (e.g. "webm doesn't support embedding a thumbnail, mkv will be used") are surfaced on the task instead of failing it.

Progress and completion notifications are posted on Android, Linux and macOS, and a `dataSync` foreground service stays alive on Android while work is in flight.

## Batch links

Pasting or sharing text with several URLs opens a batch page instead of silently taking only the first.

- Each link resolves independently: one unavailable video shows its own error and a retry button while the rest still queue.
- Playlists in the batch are surfaced with a link to their own picker rather than auto-downloaded.
- One quality choice applies to the whole batch, since a batch has no per-video format list.
- Every row can be removed on its own, and retrying one link does not disturb the links still being resolved.

## Playlists and channels

- A collection link is recognised from the first `-J` request and re-fetched with `--flat-playlist`, which lists entries without pulling stream data for each.
- An `@handle`, `/channel/…`, `/c/…` or `/user/…` link is identified as a **channel** and gets its own card and a **Download everything** shortcut; a curated playlist stays **Choose videos**. The distinction comes from the pasted link, because yt-dlp reports a channel's uploads tab as a `/playlist?list=UU…` URL.
- The picker lists every entry with thumbnail and duration, offers a text filter, select-all/clear, and per-batch quality and subtitle options seeded from Settings, with the batch's cover-art behaviour stated rather than offered.
- Each selected entry becomes **its own queue task**, so every video keeps its own progress, retry and cancel, and one unavailable entry cannot fail the rest.
- Entries land in a folder named after the collection inside `Video/` or `Audio/`, and the history record remembers which one a file came from.
- Undownloadable entries (private, members-only, premium) are dropped during parsing rather than shown as items that would always fail.

### Paged listings

- A collection with more entries than fit in one response is fetched 200 at a time (`--playlist-end`, plus `--playlist-start` when resuming) and the picker offers **Load more**.
- Whenever the listing is not the whole collection it says so (`Showing the first 200 of 5,000`), and says `200 videos so far` rather than inventing a total when the site reports none.
- A slice boundary can repeat an entry; the picker drops the repeat instead of queuing it twice.
- **Load more** goes away once a page comes back empty or short.
- Leaving the tab and coming back keeps both the selection and the pages already fetched.

## Library tab

- Hive-backed history with search, sort (newest/oldest/largest/title), an all/video/audio filter, and optional grouping by playlist with each section's count and total size.
- File existence check, open (`open_filex`), share (`share_plus`), clear. A row whose file is gone is **listed and labelled** rather than hidden — the record is the user's history.
- The check is re-taken when the app returns to the foreground and when a scanned file is adopted.
- A **folder scan** (folder icon in the app bar) finds media in the download folder the library has no record of and offers to adopt it, so "Clear history" stays a real reset. A scan that fails says so, with a retry, rather than looking identical to one that found nothing.
- The list is built lazily, so only the rows on screen are materialised — thumbnails included.

## Settings tab

- Theme mode (system/light/dark) and seed color swatches.
- Default video quality, default audio quality (Best/High/Medium/Low) and audio-only.
- Default subtitle options (sidecar vs embed, auto captions).
- **Download folder** — default Downloads, or any writable folder picked in Settings; videos go to `Video/` and audio to `Audio/`.
- **Queue** — simultaneous downloads, remembered queue size.
- **Network** — proxy, referer, rate limit, parallel fragments, request delay, retry counts, and an **unmetered-connections-only** rule that holds new downloads for Wi-Fi/Ethernet without interrupting a running one.
- **cookies.txt** import — see [cookies.md](cookies.md).
- yt-dlp version with one-tap update, notification toggle and test, app version check against the latest GitHub release, **Back up settings** / **Restore from a backup** and **Copy diagnostics**.

See [advanced-settings.md](advanced-settings.md) for Settings → **Advanced**.