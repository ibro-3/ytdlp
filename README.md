# YTDL — Material 3 Downloader

A Flutter Material 3 app that downloads videos via a **bundled `yt-dlp` binary** + `ffmpeg` (1000+ sites: YouTube, TikTok, Vimeo, etc.). Targets **Android + Desktop (Linux/Windows/macOS)** with a red seed theme, adaptive `NavigationBar`/`NavigationRail`, and Riverpod + go_router.

![M3](https://img.shields.io/badge/Material-3-red) ![Flutter](https://img.shields.io/badge/Flutter-3.47-blue)

## Features

- **Download tab** — M3 `SearchBar` URL input (paste/clear), a clipboard paste FAB that extracts the link out of whatever you shared, **share-sheet intake** (a URL shared from another app lands here, auto-filled and fetched), `yt-dlp -J` metadata fetch, `VideoInfoCard` (thumbnail via `cached_network_image`), and a single **Download** button. A link that resolves to a **playlist** shows a playlist summary instead, and **Choose videos** opens a picker (see below; a channel link gets **Download everything** instead). Tapping it opens a bottom sheet with the format (`SegmentedButton` Video/Audio) + quality (`ChoiceChip`) pickers and its own Download button. Audio quality is offered as named tiers (Best/High/Medium/Low) resolved against the source's actual bitrates — tiers that would deliver the same file are hidden and every row shows the real container + kbps. The sheet also carries **subtitles** (sidecar `.srt`/`.vtt` and/or embed; per-language chips with auto-generated captions marked "(auto)", plus "All available"), with embed gated on ffmpeg. There is no thumbnail toggle: cover art is **derived** — an audio download embeds it, a video download does not — because a video file gains nothing from an embedded cover while an audio file looks broken in a music player without one. The sheet states the outcome, including when it is dropped for want of ffmpeg/ffprobe or a container that cannot hold an image. Subtitle options are seeded from the Settings defaults on every open. There is deliberately **no** per-download argument or file-name override in the sheet: both live in Settings and apply to every download (see *Advanced settings*).
- **Queue tab** — live progress (`LinearProgressIndicator`, %/speed/ETA), with **icon-only** per-task actions: pause + cancel while running, resume + cancel while held, retry + dismiss once failed or canceled, open/share/delete once finished. A swipe is not the only way to hold one download; the app bar still pauses the whole queue. Backed by `DownloadManager` (ChangeNotifier) streaming yt-dlp `--newline` output. Posts progress/completion notifications (Android, Linux, macOS) and keeps a `dataSync` foreground service alive on Android while work is in flight. **Queue controls**: a queue-wide pause/resume (a running download is never killed by it), **per-task hold** on any card, cancel all with a confirmation, clear finished, and per-task move-earlier/later reordering of anything still waiting. Reordering changes only the queue position, never the creation time — which is what the library records as the download's date. Waiting tasks show a static "Waiting to start" label rather than an indeterminate bar, so a dozen queued items do not read as a dozen active downloads.
  - **A hold is per task.** `dart:io` exposes no way to suspend a child process, so holding a *waiting* download simply removes it from the scheduler while the rest of the queue carries on; holding a *running* one stops the process, keeps the staging directory and `.part` file, and releases back to waiting. Releasing restarts yt-dlp, which continues from the partial because `--continue` is on by default and the same staging directory is reused. A held task shows the percentage it stopped at, and the two kinds of pause are labelled separately in the app bar so it is clear which is in force.
  - **A hold is not resumed by a restart.** Like the queue-wide pause it was a decision about that session, so a held task comes back as *failed* with its partial intact, the same as interrupted work.
  - **Resumable**: a failed or interrupted download keeps its staging directory and yt-dlp's `.part` file, so Retry continues instead of re-fetching. Engine flags add `--continue`, `--retries` and `--fragment-retries` (both configurable in Settings, 0–20) and a capped `--retry-sleep linear=1:5:2` backoff.
  - **Restart-safe**: the queue is snapshotted to Hive, including the subtitle options of each task. Work that was running when the process was killed comes back as *failed* ("Interrupted when the app closed — tap Retry to continue") with its partial download intact; staging directories no task refers to are deleted on startup so they can't leak storage. Snapshots are written on a **throttle** (at most one every few seconds) *and* immediately on every state the user can see — enqueue, cancel, hold, retry, completion, removal — because a progress-driven write that only fires when output pauses would never run during an active download at all.
  - **A finished file is never silently overwritten.** The final name is claimed under a reservation before the move, because `rename` deletes an existing destination: two downloads finishing at the same instant with the same name used to race, and the loser had its file destroyed while both tasks reported the same path. A move that crosses a filesystem boundary (SD card, removable volume) falls back to copy-then-delete rather than discarding a complete download.
  - **A staging directory is only ever deleted if it really is one.** The path comes back from the queue snapshot, so it is checked against the staging root before any destructive path acts on it.
  - **"Skip what I already have" is not a race.** yt-dlp loads and rewrites the whole `--download-archive` ledger, so only one archive-using download runs at a time; the rest queue normally.
  - **Cancelling actually stops the process.** The signal escalates to `SIGKILL` if the child has not gone, and the run waits for it — otherwise a `yt-dlp` that finishes its current fragment on SIGTERM (or an `ffmpeg` that never saw the signal at all) outlives the task and keeps writing into a staging directory the UI has already reclaimed.
  - **A failure is not reported as "could not read the response".** The child's pipes are drained to completion rather than cancelled the moment the exit status arrives; exit status and pipe output travel on separate channels, so anything past the pipe buffer used to be dropped — intermittently unreadable metadata, and a large playlist whose tail went missing.
  - **Sidecars kept**: subtitles land next to the media file in the library folder (`.mkv` + `.en.srt`), never stranded in staging. yt-dlp warnings (e.g. "webm doesn't support embedding a thumbnail, mkv will be used") are surfaced on the task instead of failing it.
- **Batch links** — pasting or sharing text with several URLs opens a batch page instead of silently taking only the first. Each link resolves independently, so one unavailable video shows its own error and a retry button while the rest still queue; playlists in the batch are surfaced with a link to their own picker rather than auto-downloaded. One quality choice applies to the whole batch, since a batch has no per-video format list. Every row can be **removed on its own**, so a single bad link does not cost every good one alongside it. Retrying one link does not disturb the links still being resolved.
- **Playlist and channel downloads** — a collection link is recognised from the first `-J` request and re-fetched with `--flat-playlist`, which lists entries without pulling stream data for each (keeping even a large collection inside the metadata budget). A `@handle`, `/channel/…`, `/c/…` or `/user/…` link is identified as a **channel** and gets its own card and a **Download everything** shortcut; a curated playlist stays **Choose videos**. The distinction comes from the link the user pasted, because yt-dlp reports a channel's uploads tab as a `/playlist?list=UU…` URL. The picker lists every entry with a thumbnail and duration, a text filter, select-all/clear, and per-batch quality + subtitle options seeded from Settings, with the batch's cover-art behaviour stated rather than offered as a choice. Each selected entry becomes **its own queue task**, so every video keeps its own progress, retry and cancel, and one unavailable entry cannot fail the rest. Entries land in a folder named after the collection inside `Video/` or `Audio/`, and the history record remembers which one a file came from. Undownloadable entries (private, members-only, premium) are dropped during parsing rather than shown as items that would always fail.
- **Paged listings** — a collection with more entries than fit in one response is fetched 200 at a time (`--playlist-end`, plus `--playlist-start` when resuming) and the picker offers **Load more**. Whenever the listing is not the whole collection it says so (`Showing the first 200 of 5,000`), and says `200 videos so far` rather than inventing a total when the site reports none. A slice boundary can repeat an entry, and the picker drops the repeat instead of listing — and queuing — it twice. The **Load more** offer goes away once a page comes back empty or short, so it cannot ask for the same missing page repeatedly. Leaving the tab and coming back keeps both the selection and the pages already fetched.
- **Library tab** — Hive-backed history with search, sort (newest/oldest/largest/title), an all/video/audio filter, and optional grouping by playlist with each section's count and total size. File existence check, open (`open_filex`), share (`share_plus`), clear. A row whose file is gone is **listed and labelled** rather than hidden: the record is the user's history, and the file being absent is the thing worth surfacing. The check is re-taken when the app comes back to the foreground and when a scanned file is adopted, so a file deleted from outside the app stops reading as present without a restart. A **folder scan** (folder icon in the app bar) finds media in the download folder that the library has no record of — copied in from a computer, written by another app, or left behind when history was cleared — and offers to adopt it. Adoption is explicit so "Clear history" stays a real reset. A scan that fails says so, with a retry, rather than looking identical to one that found nothing. The list is built lazily, so only the rows on screen are materialised — thumbnails included.
- **Settings tab** — theme mode (system/light/dark) + seed color swatches, default video quality, default audio quality (Best/High/Medium/Low) + audio-only, default subtitle options (sidecar vs embed, auto captions), **download folder** (default Downloads, or any writable folder picked in Settings; videos → `Video/`, audio → `Audio/`), **queue** (simultaneous downloads, remembered queue size), **network** (proxy, referer, rate limit, parallel fragments, request delay, retry counts, and an **unmetered-connections-only** rule that holds new downloads for Wi-Fi/Ethernet without interrupting a running one), **cookies.txt import** (see below), yt-dlp version + one-tap update (system `yt-dlp -U`; app-managed copies and the Android runtime refresh from the official release), notification toggle + test, **app version** check against the latest GitHub release, plus **Back up settings** / **Restore from a backup** and **Copy diagnostics**.

### Advanced settings (extra yt-dlp flags, file naming)

Settings → **Advanced** (collapsed by default) exposes the parts of yt-dlp the UI does not model. It is a two-page carousel — **Flags** and **File name** — under a visible tab strip, because a swipe with no strip is undiscoverable and the strip is also what makes it clear the template moved rather than disappeared. A `PageView` is unbounded vertically and the two pages differ by roughly 3×, so the height is **measured from the pages themselves** rather than hard-coded: each page sits in a scroll view whose child is unbounded, so the child's laid-out size is its real height and the carousel takes the tallest. One save button sits below the carousel and commits both pages. Each page scrolls itself rather than dragging the whole settings list, and the carousel is capped to the window height so a short window cannot push that button far below the fold.

- **Extra yt-dlp flags** — applied to every download, overridable per download. Text is split with a shell-*word-splitting* scanner (quotes and backslash escapes honoured) but **never passed through a shell**, so nothing in the field can chain a command. The flags the app sets itself are detected and reported as ignored rather than silently accepted: `-o`/`--output`, `-f`/`--format`, `--no-playlist`/`--yes-playlist` and `--ffmpeg-location`. That is enforced by *ordering* — user flags are inserted before the app's own group, because yt-dlp lets the last occurrence of a single-valued option win, so a user `-o` placed after ours would redirect the staging path and break the finalise/move step. An unterminated quote is a hard error that disables the Download button instead of being passed on half-closed.
- **Output template** (`-o`) — the file name, with a live preview. Must resolve to an extension (via `%(ext)s` or a literal one) because the manager decides which file is the media file by extension, telling a `.mkv` from a `.srt` sidecar or a `.part` leftover. A `%(playlist_title)s/` prefix is stripped from the *staging* template and applied by the app when the finished file is moved, so a playlist grouping still lands correctly. A template containing `..` is **refused**, as a blocking error: yt-dlp resolves it against the staging directory, so it would write the finished file somewhere outside it — a place the app neither reports as the result nor cleans up.
- **Saved argument templates** — named flag sets, stored in the settings box under their own key prefix (capped at 30, keyed by name so saving twice replaces). Editable and removable in Settings; not offered in the per-download format sheet, which deliberately carries no argument override at all.
- **Back up / restore settings** — one JSON file holding the preferences and every saved template. Restore is a snapshot, not a merge, so a template deleted before the backup stays deleted; a document from a newer app version is refused rather than partially applied, and an unrelated JSON file is rejected before the "replace settings?" prompt appears. A restore applies to the **running** app: theme, seed and download defaults change immediately rather than at the next launch.
- **Copy diagnostics** — versions, paths and the relevant settings as plain text, ready to paste into a bug report. Every probe is allowed to fail without losing the rest of the report, and **cookies are never included** — only whether one is configured, since a path can contain a username. A credential in the extra-arguments or file-name field is **masked rather than truncated**: `--password x` is reported as `--password <redacted>`, because those values are usually far shorter than any length cap would cut at and the report is destined for a public tracker. The flag name is kept, since "a password is configured" is exactly what a failing login needs the report to say. The download folder is collapsed to its last two components for the same reason — `/home/you/Videos` is short enough to survive a length cap and still names the account.
- **yt-dlp capabilities** — first-class controls for the flags most worth having a real UI for: parallel fragments, rate limit, request delay, proxy, `Referer`, audio extraction + container, remux without re-encoding, embedded metadata/chapters, SponsorBlock removal, livestream-from-start, a download archive, and `--no-part`. Every one of them is *also* reachable as a raw flag, but a typed value cannot be right on its own — a fragment count high enough to fail a download, a container that silently drops the cover art you asked to embed — so the controls validate their own inputs.

  Three behaviours worth knowing:

  - **Defaults change nothing.** Fragment parallelism defaults to 1, which is yt-dlp's own `-N` default, so an untouched app produces a byte-identical command line to before these controls existed.
  - **Fragment parallelism is capped at 4.** The throughput gain above that is small and the memory cost is not; on a phone, `-N 16` fails the download outright.
  - **Postprocessing is dropped without ffmpeg+ffprobe.** Audio extraction, remux, metadata, chapters and SponsorBlock all run through yt-dlp's postprocessor, which probes with ffprobe. Without it the flags are omitted rather than passed through to fail *after* the bytes are downloaded, and the toggles are disabled in the UI with the reason shown. A conversion to a container that cannot hold the chosen extras (cover art in WAV, say) drops that extra and says so in the sheet.

The previous hard-coded `" [<id>]"` filename check in `DownloadManager._findFinalFile` generalised to `OutputTemplate.identityFragment`: it uses the id when the template has `%(id)s`, the title when it does not, and no filter at all when the template can only produce the extension. Without that, every template lacking `%(id)s` would have reported "output file not found". A template that is extension-only is called out in the UI, since every file then shares one name and a second download is renamed `"(1)"`.

### YouTube support

YouTube serves different format lists to different "player clients", and increasingly gates the good ones behind a proof-of-origin token that yt-dlp can only obtain by running JavaScript. Two controls live in Settings → **Advanced → YouTube**:

- **JavaScript runtime** — installs `yt-dlp-ejs` into the bundled CPython runtime's `site-packages`. The install is **verified before it commits, twice over**. First the downloaded bytes are compared against the SHA-256 PyPI published for that wheel, before anything is unpacked — a wheel that hashes correctly and still will not load is a real failure mode, and until now that was the *only* check, which any well-built wheel of any provenance passes. A manifest that carries no digest is refused rather than installed unverified. Second, the staged package is imported by the bundled interpreter, which is the check that catches a wheel the runtime genuinely cannot load. Requests may only reach `pypi.org` and `files.pythonhosted.org` over HTTPS, and are never auto-redirected: `HttpClient` follows redirects on its own, and a redirect of the *manifest* request would hand whoever controlled it the download URL and the expected checksum together. What this does **not** detect is a compromised PyPI account publishing a new wheel under the same version — the checksum catches a file that differs from what PyPI published, not a publication PyPI should not have made. The package is unpacked to a staging directory, rejected if it contains a link or a path escaping that directory, and then **imported from staging before the installed copy is touched**, so the engine is never left without its JavaScript runtime — the previous ordering renamed the old copy aside first, and any download starting in that window failed with an ImportError. Anything that does not import is removed and the previous copy restored; the backup is kept until verification has passed, so a rollback has something to restore. Installs and uninstalls are serialised, since they share one staging directory. The section reports the real state (`installed` / `not installed` / `installed but not working`) rather than claiming a capability it cannot check.
- **Extra player clients** — passes `--extractor-args youtube:player_client=web,…` for the clients you tick. `web` is always included and is yt-dlp's default, so the flag is only sent when you have actually added one. The app's value is emitted *after* any raw `--extractor-args` in the extra-args field, because yt-dlp lets the last occurrence win.

The `yt-dlp-ejs` version is **pinned** alongside the bundled yt-dlp version rather than tracking "latest", so an install is reproducible and a bad upstream release cannot break every user's YouTube downloads. The wheel's checksum comes from PyPI rather than being hard-coded here, which is a weaker anchor than the version pin: it proves the bytes match what PyPI published for that version, and is checked against the manifest over an HTTPS connection to a pinned host.

What this does **not** do: it does not bundle a JS engine (Deno, ~30-40 MB per ABI) inside the APK, and it does not bypass account-level bot checks — those still need cookies. On desktop installs the runtime is not managed, because a system yt-dlp picks up a system-installed `yt-dlp-ejs` on its own; the section reports that rather than pretending to install something.

### Cookies (YouTube and other gated sites)

Some sites — YouTube in particular — refuse anonymous requests, showing "Sign in to confirm you're not a bot" or limiting formats. Settings → **Cookies** imports a Netscape-format `cookies.txt`; it is copied into the app's support directory and handed to yt-dlp via `--cookies`.

The import **validates structurally**: the file must parse to at least one real cookie, so an HTML error page saved as `cookies.txt` is rejected at the picker rather than failing every download later with a yt-dlp parse error.

Both files are written **owner-only** (mode `0600` where the platform has such a mode). They are session credentials, and the default file mode would let any other process that can read the app's support directory read the login.

**Per-site control.** A browser export carries every site you happen to be logged into, not just the one yt-dlp needs. The **Choose which sites are sent** button lists every host in the jar with its cookie count and lifetime — session-only, dated, or already expired — and lets you switch each off individually. yt-dlp has no per-site flag, so a switch works by writing a **narrower** jar: the import is kept intact next to the file yt-dlp reads, which is what makes a switch reversible without going back to your browser. Subdomains stay their own row rather than being folded into the parent, so a switch always tells the truth about exactly which host it governs.

Two consequences are stated in the UI rather than left to be discovered: how many cookies are currently being withheld, and — because a withheld site is indistinguishable from an expired one when a download fails — what switching a site off actually does. Switching *every* site off is refused outright instead of writing an empty jar, which would otherwise break every download with a 403 you cannot trace back to a switch.

### Browser cookies (desktop)

Importing a `cookies.txt` means exporting one by hand, and re-exporting it whenever the login expires. On desktop, **Settings → Browser cookies** points yt-dlp at the browser login you already have via `--cookies-from-browser`, so there is no jar to export, copy or refresh. yt-dlp decrypts the store itself; the app never handles a cookie value from a browser either.

A **profile folder** picker lists the profiles inside the folder you choose — the ones holding a cookie store, for Chromium and Firefox layouts alike — and yt-dlp is given the profile *by name*. Never by path: yt-dlp splits its browser specification on `:`, so a Windows path would parse as a different browser entirely, with no way to escape it. Leaving the profile alone asks yt-dlp for the browser's own default, which is right for most people.

A value that *looks* like a path — one beginning with a separator — is refused and the reason shown. yt-dlp reads such a profile argument as an absolute path, so without the check a hand-edited settings box could aim the cookie read at any directory on the device. That check runs where the argument is built, not only where it is typed: a restored backup writes a profile straight into the settings box and it is read back as a bare string, so a check performed by the picker alone would guard nothing. A refused profile falls back to the browser's own default, which is what leaving it blank means anyway.

There are three things this deliberately does not do quietly:

- **It does not combine sources.** yt-dlp will happily accept `--cookies` *and* `--cookies-from-browser` and merge them, at which point a site you switched off would go out from the browser's copy anyway — a switch that looks like it works and does nothing. The app passes at most one, so a chosen browser sets the imported jar aside and says so, and the per-site page carries a banner saying its switches are not in effect until the browser is turned off.
- **It does not hide itself on Android.** Android sandboxes app storage per app and gives an app no access to any browser's cookie store, so the control is disabled with that stated rather than omitted. The `cookies.txt` import is the route there.
- **It does not pretend Safari is cross-platform.** yt-dlp can only read Safari's cookies on macOS; picking it elsewhere shows why.

Diagnostics report the browser and profile *name* — both already visible in your own browser UI — and never the profile folder, for the same reason the jar path is never printed: a path can carry your username.

Cookie *values* are treated as credentials everywhere — never logged, never in diagnostics, never printed by the parser, and never in the parser's equality or hashing. The diagnostics report names the switched-off **hosts** (already present in your cookie file, your download URLs and any yt-dlp error) and never a value.

> **Known limitation:** yt-dlp also wants a **PO token** (and increasingly a JS runtime) for full YouTube support. Settings → **Advanced → YouTube** can install the `yt-dlp-ejs` component into the bundled CPython runtime and pick which player clients yt-dlp should try; see *YouTube support* below. Cookies fix the *authentication* half; the JS runtime addresses the *PO token* half. Until both are in place, if YouTube downloads fail while other sites work, that is the cause.

## Stack

- **State:** `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services). Long-lived services are `ChangeNotifier`s exposed through a plain `Provider` and consumed with `AnimatedBuilder`. Anything that must follow a settings change listens to `settingsControllerProvider` rather than the settings *service*: a provider yielding one always-equal instance never notifies, so a listener on it would never fire.
- **Routing:** `go_router` 18 (`StatefulShellRoute.indexedStack`), with an `errorBuilder` so a deep link the app has no route for says so in the app rather than in the framework's own error page.
- **Theme:** `ColorScheme.fromSeed(seedColor: Colors.red)` (M3), `CardThemeData`, `NavigationBar`/`NavigationRail` adaptive at 760dp.
- **Storage:** `hive` + `path_provider` (download root: `getDownloadsDirectory()` desktop / external app dir on Android, overridable in Settings). Downloads land in `Video/` or `Audio/` subfolders (`services/downloads/download_layout.dart`); playlist entries group one folder deeper, under the sanitized playlist title. Since the app moves a finished file from staging itself rather than letting yt-dlp write it to a final path, it sanitizes that folder name itself (`sanitizeFolderName`) — path separators, control characters and Windows-reserved device names included, because yt-dlp's own template sanitization never runs for a folder the app creates. Three Hive boxes: `history` (library), `settings`, `queue` (task snapshots for restart recovery). Each is opened independently at start-up and a failure is reported in the app rather than thrown, so one unusable store costs the user that feature instead of the whole app. Every reader treats a corrupt record as absent rather than crashing: the whole library load used to fail on a single bad entry.
- **Engine:** `BinaryManager` locates `yt-dlp` in this order — system PATH (`which`/`where`, desktop only), bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android), then (desktop only) auto-downloads the official single-file build from GitHub releases into the app support dir. The desktop builds in `assets/bin/` are **not** registered in `pubspec.yaml` on purpose: `flutter.assets` has no per-platform scoping, so declaring them would package ~56 MB of desktop binaries into every Android APK too, tripling the 19 MB/ABI payload. Desktop falls through to the auto-download instead. `ytdlpVersion()` / `updateYtdlp()` power Settings updates: system installs via `yt-dlp -U`; app-managed desktop copies re-download the official build; on Android the button replaces the yt-dlp script inside the extracted CPython runtime with the official standalone release — downloaded to a temp file and verified by running `--version` with the runtime's own interpreter before it replaces the working script, so a bad download can never break the engine. There is no URL to configure. Copies to app support dir + `chmod 755`. A download whose body is implausibly small for a yt-dlp build (an error page or a captive portal served with a 200) is refused rather than made executable, and a failed download reports *why* — a 503 no longer reaches the user as "yt-dlp was not found". Prefers system `ffmpeg` on PATH; without it, requests combined formats only (`b[ext=mp4][acodec!=none]/b[acodec!=none]`).
- **Notifications:** `flutter_local_notifications`, `downloads` channel on Android, `LinuxNotificationDetails` on Linux, `DarwinNotificationDetails` on macOS. Permission is only requested when the Settings toggle is switched on (Android 13+ runtime grant, macOS `requestPermissions`), never at first launch. Progress throttled to percent-change + 2s; completion/failure alerts; honoring the Settings toggle. macOS progress updates are shown without an alert/banner, since it has no progress bar and a fast download would otherwise fire a banner per update.
- **Background downloads (Android):** `flutter_foreground_task` runs a `dataSync` foreground service for as long as the queue is non-empty, so downloads survive the app being backgrounded. It starts with the first task, shows the active download's title + percentage, and stops once the queue drains. A wake lock is held while it runs. Notification updates are throttled to a changed percentage and at most one every 2s — every update is a platform round trip, and the plugin answers redundant start contracts with `ForegroundServiceDidNotStartInTime`.
- **Share intake (Android):** `receive_sharing_intent` catches `ACTION_SEND` text/plain intents, so YTDL appears in other apps' share sheets. A shared URL is extracted with the same `extractUrl` used for the clipboard (so "check this out https://…" works), auto-fills the Download tab and fetches immediately. The cold-start payload is buffered so sharing into a closed app is not lost, and consumed with `reset()` so a restart does not replay it.

## Project structure

```
lib/
  main.dart, app.dart
  core/theme/app_theme.dart
  core/router/app_router.dart
  core/providers.dart
  core/models/{video_info,download_task,download_record,download_options,settings_model,playlist_info,playlist_paging,collection_kind,output_template,command_template,yt_prefs,youtube_prefs,library_filter,cookie_model,cookie_profiles,cookie_browser}.dart
  core/utils/{url_validator,formatters,json_utils}.dart
  services/ytdlp/{binary_manager,ytdlp_service,progress_parser,bounded_capture,json_payload,arg_tokenizer,ejs_installer}.dart
  services/downloads/{download_manager,download_layout,history_service,queue_store,folder_scanner,network_probe}.dart
  services/cookies/{cookie_jar,cookie_jar_service,cookie_domains,cookie_model}.dart
  services/settings/{settings_service,template_store,backup_service}.dart
  services/updates/app_update_service.dart
  services/diagnostics/diagnostics_service.dart
  services/notifications/notification_service.dart
  services/foreground/foreground_service.dart
  services/sharing/share_intent_service.dart
  widgets/{app_shell,tab_carousel}.dart
  features/home/{home_controller,home_page,widgets/video_info_card,widgets/format_picker_sheet}.dart
  features/queue/{queue_page,batch_queue_page,batch_queue_controller}.dart
  features/library/library_page.dart
  features/settings/{settings_page,cookie_domains_page}.dart
  features/playlist/playlist_page.dart
assets/bin/
  android/<abi>/{python.tar.gz,ffmpeg,ffprobe}    # required on Android, committed
  linux/yt-dlp, macos/yt-dlp, windows/yt-dlp.exe   # desktop fallbacks, gitignored
tool/{fetch_binaries,fetch_android_runtime,fetch_ffmpeg_android}.sh
```

## Getting started

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux   # or android
```

System `yt-dlp` + `ffmpeg` are used if on PATH (checked with `which`/`where`). No bundled binary needed on desktop for dev — and if neither a system install nor a bundled asset exists, the app auto-downloads the official single-file `yt-dlp` build on first run (desktop only).

### Bundling binaries

```bash
./tool/fetch_binaries.sh
```

Fetches official single-file `yt-dlp` builds for Linux/macOS/Windows into `assets/bin/`, verifies each one actually runs, and prints guidance for Android. They are a developer convenience only:

- **gitignored** — a fresh clone does not have them and does not need them;
- **not registered in `pubspec.yaml`** — see the Engine bullet in *Stack* for why bundling them would bloat every Android APK. `test/models/android_runtime_test.dart` fails if that ever changes.

Delete them with `rm -rf assets/bin/{linux,macos,windows}`.

**Android has no official standalone binary** — the GitHub Linux build links glibc and won't run on Android's bionic libc. This repo bundles a self-contained CPython + yt-dlp runtime assembled from official Termux packages (same versions as Termux ships: currently CPython 3.14 + yt-dlp 2026.08.19):

```bash
./tool/fetch_android_runtime.sh          # both ABIs
./tool/fetch_android_runtime.sh x86_64   # emulator only
```

This produces `assets/bin/android/<abi>/python.tar.gz` (~16 MB per ABI), already registered in `pubspec.yaml`. At first launch the app extracts it to its private files dir and runs `python3.14 bin/yt-dlp` with `LD_LIBRARY_PATH`/`PYTHONHOME`/`SSL_CERT_FILE` pointed at the tree — no root, no Termux app needed. Settings → **Update yt-dlp** refreshes only the yt-dlp script from the official release; the CPython interpreter, native libs and bundled ffmpeg still ship with the app, so those need an app update.

**ffmpeg + ffprobe (video downloads and postprocessing):** modern YouTube serves video/audio as separate DASH streams, and merging them needs ffmpeg. The Termux ffmpeg package drags in ~97 packages (~40 MB/ABI), so instead a minimal **static** ffmpeg is cross-compiled with the NDK — just the file protocol, mp4/webm/mkv demuxers and muxers yt-dlp needs for `-c copy` merges (~2 MB/ABI):

```bash
./tool/fetch_ffmpeg_android.sh          # both ABIs (needs ANDROID_NDK / ~/Android/Sdk/ndk)
./tool/fetch_ffmpeg_android.sh x86_64   # emulator only
```

**ffprobe ships alongside ffmpeg and is equally required.** Merging only needs ffmpeg, but every *postprocessing* step — embedding subtitles, embedding a thumbnail cover, converting subtitle formats — goes through yt-dlp's `FFmpegMetadataPP`, which probes the output with ffprobe and aborts with `Postprocessing: ffprobe not found. Please install or provide the path using --ffmpeg-location`. yt-dlp resolves the pair from a single `--ffmpeg-location`: given the path to ffmpeg it looks for ffprobe in the same directory, so the two must be extracted together.

The app extracts both on first launch and passes the ffmpeg path to `--ffmpeg-location`, so video downloads merge and embed on-device. The extraction marker (`ffmpeg-8.1.3-static-v2-ffprobe` in `binary_manager.dart`) must be bumped whenever these binaries change, or existing installs keep a stale ffmpeg-only copy; it also re-extracts when ffprobe is missing.

| ABI (device)                     | Asset                              | Status               |
| -------------------------------- | ---------------------------------- | -------------------- |
| `x86_64` (Studio emulators)      | `assets/bin/android/x86_64/…`      | ffmpeg merge verified end-to-end on emulator; ffprobe rebuilt and packaged, not yet exercised on-device |
| `arm64-v8a` (physical devices)   | `assets/bin/android/arm64-v8a/…`    | same recipe, untested here |

If a per-ABI archive is missing, the app shows an actionable error naming the expected path and the ABI it was looking under. An install that ends up on such a build cannot self-update — Settings reports that an app update is needed, since custom build URLs are no longer configurable.

> **Android 14+ SELinux note:** apps targeting recent SDKs (`untrusted_app_34`) are denied `execute` on their own data files (`avc: denied { execute_no_trans }`), which silently breaks any bundled-subprocess design. This project therefore sets `targetSdk = 28` in `android/app/build.gradle.kts` (same approach as Termux) so the bundled runtime can execute. Trade-off: sideload/F-Droid distribution only — the Play Store requires a recent target SDK (and forbids YouTube downloading anyway).

APK per-ABI splits are recommended (each runtime adds ~16 MB + ~2 MB ffmpeg + ~1.7 MB ffprobe). A universal release APK is ~90 MB; split it per ABI for ~25 MB each:

```bash
flutter build apk --release --split-per-abi
```

## Release identity

- **App ID:** `com.github.ytdlp` on every platform — `android/app/build.gradle.kts`, `linux/CMakeLists.txt` (`APPLICATION_ID`), `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`) and the `RunnerTests` bundle in `macos/Runner.xcodeproj`
- **App label:** `YTDL` — `AndroidManifest.xml` on Android, `CFBundleDisplayName`/`CFBundleName` in `macos/Runner/Info.plist`, the GTK header-bar title in `linux/runner/my_application.cc`, and the window title in `windows/runner/main.cpp` plus the `Runner.rc` version block
- **Launcher icon:** adaptive icon with red background + white download arrow
- The on-disk binary/app name stays `ytdlp` on desktop (`BINARY_NAME`, `PRODUCT_NAME`) to match the `ytdlp.app` product reference in `Runner.xcodeproj`; only the user-facing label is `YTDL`

### Desktop sandbox (macOS)

macOS builds are sandboxed, so `macos/Runner/*.entitlements` must grant:

- `com.apple.security.network.client` — without it a Release build cannot resolve or connect to anything, so every metadata fetch and download fails
- `com.apple.security.files.user-selected.read-write` — the download-folder picker and `cookies.txt` import both touch files outside the app container
- `DebugProfile.entitlements` additionally keeps `cs.allow-jit` and `network.server` for Flutter's debug VM service, and mirrors both entitlements above so a debug build behaves like a Release one

## Platform support

| Platform | Status |
| -------- | ------ |
| **Android** | Primary target. Bundled CPython + yt-dlp runtime and static ffmpeg/ffprobe, `dataSync` foreground service, share-sheet intake. |
| **Linux** | Supported. System or bundled `yt-dlp`, GTK notifications. |
| **Windows** | Supported. System or bundled `yt-dlp.exe`. |
| **macOS** | Supported. Sandboxed — see *Desktop sandbox* above. Notifications are available. |
| **iOS** | **Dropped.** The two dead-end scaffolds were removed from the repo; there is no iOS engine and none is planned. |
| **Web** | **Dropped.** `dart:io` is used throughout and no web engine was ever implemented; the scaffold is removed. |

### Signing

Release builds are signed with a real keystore (not the debug key). To set up:

1. Generate a keystore:
   ```bash
   keytool -genkey -v -keystore ~/ytdlp-release.keystore -alias ytdlp -keyalg RSA -keysize 2048 -validity 10000
   ```

2. Copy the example properties file and fill in your details:
   ```bash
   cp android/key.properties.example android/key.properties
   # Edit android/key.properties with your keystore path and passwords
   ```

3. Build a signed release APK:
   ```bash
   flutter build apk --release --split-per-abi
   ```

The `android/key.properties` file is gitignored — never commit it. For CI, use GitHub secrets to inject the keystore and properties file at build time.

### Per-ABI splits

Each ABI adds ~16 MB (CPython runtime) + ~2 MB (ffmpeg). Build split APKs for smaller downloads:

```bash
flutter build apk --release --split-per-abi
```

This produces separate APKs for `arm64-v8a`, `armeabi-v7a`, `x86_64`, and `x86`.

## Android notes

- `INTERNET` permission added to `android/app/src/main/AndroidManifest.xml`.
- Downloads go to app-specific external dir on Android 10+ (no storage permission needed). A folder picked in Settings must be a real, writable filesystem path — the bundled yt-dlp child process writes by path, not via SAF `content://` URIs (SD-card picks are rejected with an explanation; on-device folders work).
- **Android notes (ffmpeg/ffprobe):** on Android the bundled minimal static `ffmpeg` is used so DASH video/audio streams can merge, and the bundled `ffprobe` is what yt-dlp's postprocessing probes with (`--ffmpeg-location`). The embed toggles in the format sheet and in Settings → Post-processing are gated on *ffprobe* specifically, not ffmpeg, because ffmpeg alone can merge but cannot postprocess — otherwise the download would fail with "ffprobe not found". The capability is probed **once per session** and cached, so typing in an unrelated Settings field cannot make the toggles flicker greyed out; while the probe runs the toggles say "checking" rather than claiming ffmpeg is missing. Updating yt-dlp re-runs it. When ffmpeg is unavailable (desktop without a system `ffmpeg`), video is combined-only (no DASH merge) and audio is `M4A` (`ba[ext=m4a]/ba`).
- **`targetSdk = 28` is deliberate.** Android 10+ (API 29+) enforces W^X for apps targeting API 29+: `exec()` on files in app-writable storage is denied (`avc: denied { execute_no_trans }`), which breaks the bundled CPython/yt-dlp runtime extracted into the app support dir. Termux ships targetSdk 28 for the same reason. Because that trips Google Play's `ExpiredTargetSdkVersion` lint on release builds, that single check is disabled in `android/app/build.gradle.kts` — every other lint rule still runs. A higher target is still reachable for experiments with `-P ytdlpTargetSdk=33`, but the runtime will not execute under it without repackaging the engine (e.g. shipping it via `jniLibs` into `nativeLibraryDir`) or switching to a pure-JVM yt-dlp.
- Release builds are signed with the keystore described in **Release identity** above, falling back to the debug key with a warning when `android/key.properties` is absent.
- **`compileSdk` is 37 while `targetSdk` stays 28.** `receive_sharing_intent` 1.9.0 and `flutter_foreground_task` 11.x compile against 37, so `android/app/build.gradle.kts` pins `compileSdk = 37` instead of following `flutter.compileSdkVersion` (36 in Flutter 3.47). These are independent: `compileSdk` only gates which APIs are visible at compile time, while `targetSdk` drives runtime behaviour — so the W^X requirement that keeps the bundled CPython runtime executable is unaffected. Verified via `aapt2 dump badging`: `compileSdkVersion='37'`, `targetSdkVersion='28'`.
- **`android.builtInKotlin=true`** in `android/gradle.properties` (the Flutter template default is `false`). Both plugins migrated to Flutter's built-in Kotlin (`flutter_foreground_task` 11.0.0, `receive_sharing_intent` 1.9.0) and no longer apply the Kotlin Gradle Plugin themselves, which is required under AGP 9+ and removes the "applies Kotlin Gradle Plugin" build warning. Keeping it `false` still builds, but Flutter will hard-fail on a future version. Because the plugins are now built-in, the earlier `kotlin.jvm.target.validation.mode=warning` workaround is no longer needed and has been removed.
- Distribution: Play Store forbids YouTube downloading — intended for sideload/F-Droid/GitHub.

### Metadata fetch limits
`fetchVideoInfo` runs yt-dlp with a 90s timeout and bounded output capture. The two streams get separate budgets: 16 MB for the JSON payload on stdout (a real single video is ~100 KB), 64 KB for stderr, whose *tail* is kept for diagnostics. The stdout payload is retained **in full** up to its budget — it is what gets parsed, so it is never window-truncated. When stdout exceeds its budget the process is killed immediately instead of buffering a runaway response, and the app says what happened:

- a **playlist link** — yt-dlp returns the whole collection (tens of MB) and still exits 0, so the app reports "that link is a playlist, this app downloads one video at a time" rather than a generic error;
- otherwise the site sent a response too large to read, with the actual size.

A playlist is normally recognised *before* this point, from the first request's exit code or its `_type`, and re-fetched cheaply with `--flat-playlist`. The oversize path is therefore the rare case of a collection too big even as a flat listing. The heuristic is deliberately narrow — an unrelated failure like "video is private" must stay an error rather than being retried as a playlist (see `looksLikePlaylistOutput`).

A chatty stderr never fails a successful fetch, and output is decoded leniently so one malformed byte from a site cannot blank out the metadata. If a payload still cannot be read, the app shows what the response actually began with (and tolerates a short non-JSON preamble the bundled runtime may print to stdout) instead of a bare "invalid JSON".

## Testing

```bash
flutter test                                    # unit + widget tests (fast, no device)
flutter test integration_test/app_test.dart -d <device>   # on-device pipeline test
```

The suite needs no network: the one test that reaches the real GitHub API is tagged `network` and CI excludes it.

```bash
flutter test --tags network                       # opt in, deliberately
```

CI additionally enforces `dart format --set-exit-if-changed` and `flutter analyze --fatal-infos` before the tests, and builds Android, Linux, Windows **and macOS** — macOS is there because its sandbox entitlements are not verifiable any other way, which is how a release shipped with no network at all. Coverage is uploaded as an artifact rather than gated; see the comment in `.github/workflows/dart.yml` for why.

The integration test boots the real app, fetches a video, picks a format and waits for the download to complete — it needs a device/emulator and network. It runs in CI via the opt-in **Device test (Android)** workflow (Actions → *Run workflow*), which boots an emulator; it is deliberately not on every push because it costs ~10 minutes of emulator time.

### Test layout

`test/` mirrors `lib/`: `models/`, `core/`, `services/`, `features/`. `test/support/` holds the hand-written fakes — a Hive `Box` implementation and the pump helpers — so no mocking package is needed. `test/fixtures/` holds real input files.

The binaries in `assets/bin/android/` are exercised by `test/models/android_runtime_test.dart`, which unpacks the real archive and checks the ELF header per ABI. It needs those files present, which a fresh clone has; the desktop binaries are gitignored and not needed by any test.

## Reporting a bug

Paste the output of **Settings → Copy diagnostics** into the issue. It contains versions, paths and the relevant settings, and **never** includes cookies or any credential — only whether a cookie file is configured, since a path can contain a username. That one paste usually answers version and configuration questions outright.

Worth including, because the app reports these states rather than guessing at them:

- whether `ffmpeg` and `ffprobe` were both found (they are separate checks, and postprocessing needs `ffprobe` specifically — `ffmpeg` alone can merge but cannot embed)
- whether the `yt-dlp-ejs` JavaScript runtime reports `installed`, `not installed`, or `installed but not working`
- whether a cookies file is configured
- the exact error text, which is deliberately specific rather than a generic failure message

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: `dart format`, `flutter analyze --fatal-infos` and `flutter test` are the definition of green, user-visible changes need a README update (this document *is* the spec), and nothing user-supplied may reach a shell — extra yt-dlp flags go through the argument tokenizer as an argument list.

## Licence

GPL-3.0-or-later; see [LICENSE](LICENSE). The bundled binaries carry their own licences, which apply to those binaries rather than to this source code — yt-dlp is GPL-3.0-or-later, the static `ffmpeg` build is LGPL-2.1-or-later, and the CPython runtime is assembled from official Termux packages under the PSF licence.

## Roadmap

Done recently: bottom-sheet format picker (removed the inline format section), clipboard paste button, resumable downloads with retry backoff, queue persistence across restarts, cookies.txt support, one-tap yt-dlp update from a fixed source, release identity (app id, adaptive icon, keystore signing), Android foreground service for background downloads, share-sheet intake, macOS sandbox entitlements (`network.client` was missing entirely, so Release builds had no network at all), macOS notifications, an `ffprobe` detection fix that hid the embed-subtitles/thumbnail toggles on every Android launch after the first, **playlist downloads** with a per-entry picker, per-video tasks and sanitized per-playlist folders, **advanced settings** (extra yt-dlp flags with managed-flag protection, a live-previewed output template, and saved named argument templates), and **YouTube support** (a verified `yt-dlp-ejs` installer and player-client selection), **yt-dlp capability controls** (fragment parallelism, rate limits, proxy, audio extraction, remux, embedded metadata/chapters, SponsorBlock, download archive), **queue controls** (configurable concurrency, per-task hold alongside the queue-wide pause, cancel-all, clear-finished, reordering, and a remembered queue size that fixes large playlists being truncated on restart), **derived cover art** (audio embeds the thumbnail, video does not, and the thumbnail toggles are gone rather than defaulted), a **searchable, sortable, groupable library with a folder scan**, **batch URL queueing**, **settings backup / diagnostics export**, an **app update check** against the latest GitHub release, **configurable retry counts**, an **unmetered-connections-only** download rule, **channel and handle support** with paged listings, and a **Netscape cookie-jar parser**.

Still open:

- **A shared `--cookies` jar is still written concurrently.** yt-dlp writes cookies back to the file it is given, so two simultaneous downloads sharing one jar can interleave those writes and truncate it. Unlike `--download-archive` (which is serialised for exactly this reason) this was left alone deliberately: the only real fix is a per-task copy of the jar, which would silently discard the refreshed tokens yt-dlp writes back, and losing a session refresh is worse than a rare truncation. Worth doing properly, with a merge-back step.
- **`--exec` and `--config-location` in the extra-arguments field are warned about, not refused.** Both make yt-dlp run arbitrary commands, and a warning can be scrolled past. Making them blocking would refuse settings that exist in shipped backups, so this is a product call rather than a bug — but it is a deliberate gap, not an oversight.
- **Channel and handle URLs** — now handled: a `@handle`, `/channel/…`, `/c/…` or `/user/…` link is recognised as a channel, gets its own card, and offers **Download everything**. Large channels are listed a page at a time with **Load more** in the picker, and the picker always says how much of the channel it is showing. Still missing: pulling the whole channel without opening the picker, and reverse / section / date ordering.
- **Bundling a JS engine (Deno) in the APK.** The `yt-dlp-ejs` installer removes most of the PO-token gap, but a real in-process engine is ~30-40 MB per ABI and would need an NDK build like the CPython runtime.
- **Cookie management** — shipped: the Netscape jar parser and importer, per-domain listing with lifetime, per-site enable/disable, and desktop `--cookies-from-browser` with a profile picker. A browser-profile *extractor* for Android is still impossible — the platform exposes no browser-profile access at all.
- iOS and web were removed from the repo and are no longer on the roadmap: `dart:io` is used throughout, Android is the only platform with a subprocess engine, and iOS could not run a bundled CPython/yt-dlp process under App Store rules anyway. The two dead ends are now just absent, rather than present-but-broken.
