# YTDL — Material 3 Downloader

A Flutter Material 3 app that downloads videos via a **bundled `yt-dlp` binary** + `ffmpeg` (1000+ sites: YouTube, TikTok, Vimeo, etc.). Targets **Android + Desktop (Linux/Windows/macOS)** with a red seed theme, adaptive `NavigationBar`/`NavigationRail`, and Riverpod + go_router.

![M3](https://img.shields.io/badge/Material-3-red) ![Flutter](https://img.shields.io/badge/Flutter-3.47-blue)

## Features

- **Download tab** — M3 `SearchBar` URL input (paste/clear), a clipboard paste FAB that extracts the link out of whatever you shared, **share-sheet intake** (a URL shared from another app lands here, auto-filled and fetched), `yt-dlp -J` metadata fetch, `VideoInfoCard` (thumbnail via `cached_network_image`), and a single **Download** button. A link that resolves to a **playlist** shows a playlist summary instead, and **Choose videos** opens a picker (see below). Tapping it opens a bottom sheet with the format (`SegmentedButton` Video/Audio) + quality (`ChoiceChip`) pickers and its own Download button. Audio quality is offered as named tiers (Best/High/Medium/Low) resolved against the source's actual bitrates — tiers that would deliver the same file are hidden and every row shows the real container + kbps. The sheet also carries **subtitles** (sidecar `.srt`/`.vtt` and/or embed; per-language chips with auto-generated captions marked "(auto)", plus "All available") and **thumbnail** (embed as cover art and/or `.jpg` sidecar) options, with embed gated on ffmpeg. Everything is seeded from the Settings defaults on every open. An **Advanced** section adds per-download extra yt-dlp flags and an output template, both pre-filled from Settings and both overridable for one download only (see *Advanced settings*).
- **Queue tab** — live progress (`LinearProgressIndicator`, %/speed/ETA), cancel/retry/open/share/delete. Backed by `DownloadManager` (ChangeNotifier) streaming yt-dlp `--newline` output. Posts progress/completion notifications (Android, Linux, macOS) and keeps a `dataSync` foreground service alive on Android while work is in flight. **Queue controls**: pause/resume (a running download is never killed by a pause), cancel all with a confirmation, clear finished, and per-task move-earlier/later reordering of anything still waiting. Waiting tasks show a static "Waiting to start" label rather than an indeterminate bar, so a dozen queued items do not read as a dozen active downloads.
  - **Resumable**: a failed or interrupted download keeps its staging directory and yt-dlp's `.part` file, so Retry continues instead of re-fetching. Engine flags add `--continue`, `--retries 10`, `--fragment-retries 10` and a capped `--retry-sleep linear=1:5:2` backoff.
  - **Restart-safe**: the queue is snapshotted to Hive, including the subtitle/thumbnail options of each task. Work that was running when the process was killed comes back as *failed* ("Interrupted when the app closed — tap Retry to continue") with its partial download intact; staging directories no task refers to are deleted on startup so they can't leak storage.
  - **Sidecars kept**: subtitles and thumbnails land next to the media file in the library folder (`.mkv` + `.en.srt` + `.jpg`), never stranded in staging. yt-dlp warnings (e.g. "webm doesn't support embedding a thumbnail, mkv will be used") are surfaced on the task instead of failing it.
- **Batch links** — pasting or sharing text with several URLs opens a batch page instead of silently taking only the first. Each link resolves independently, so one unavailable video shows its own error and a retry button while the rest still queue; playlists in the batch are surfaced with a link to their own picker rather than auto-downloaded. One quality choice applies to the whole batch, since a batch has no per-video format list.
- **Playlist downloads** — a playlist link is recognised from the first `-J` request and re-fetched with `--flat-playlist`, which lists entries without pulling stream data for each (keeping even a large collection inside the metadata budget). The picker lists every entry with a thumbnail and duration, a text filter, select-all/clear, and per-batch quality + subtitle/thumbnail options seeded from Settings. Each selected entry becomes **its own queue task**, so every video keeps its own progress, retry and cancel, and one unavailable entry cannot fail the rest. Entries land in a folder named after the playlist inside `Video/` or `Audio/`, and the history record remembers which playlist a file came from. Undownloadable entries (private, members-only, premium) are dropped during parsing rather than shown as items that would always fail.
- **Library tab** — Hive-backed history with search, sort (newest/oldest/largest/title), an all/video/audio filter, and optional grouping by playlist with each section's count and total size. File existence check, open (`open_filex`), share (`share_plus`), clear. A **folder scan** (folder icon in the app bar) finds media in the download folder that the library has no record of — copied in from a computer, written by another app, or left behind when history was cleared — and offers to adopt it. Adoption is explicit so "Clear history" stays a real reset.
- **Settings tab** — theme mode (system/light/dark) + seed color swatches, default video quality, default audio quality (Best/High/Medium/Low) + audio-only, default subtitle/thumbnail options (sidecar vs embed, auto captions), **download folder** (default Downloads, or any writable folder picked in Settings; videos → `Video/`, audio → `Audio/`), **queue** (simultaneous downloads, remembered queue size), **cookies.txt import** (see below), yt-dlp version + one-tap update (system `yt-dlp -U`; app-managed copies and the Android runtime refresh from the official release), notification toggle + test, plus **Back up settings** / **Restore from a backup** and **Copy diagnostics**.

### Advanced settings (extra yt-dlp flags, file naming)

Settings → **Advanced** (collapsed by default) and the per-download Advanced section of the format sheet expose the parts of yt-dlp the UI does not model:

- **Extra yt-dlp flags** — applied to every download, overridable per download. Text is split with a shell-*word-splitting* scanner (quotes and backslash escapes honoured) but **never passed through a shell**, so nothing in the field can chain a command. The flags the app sets itself are detected and reported as ignored rather than silently accepted: `-o`/`--output`, `-f`/`--format`, `--no-playlist`/`--yes-playlist` and `--ffmpeg-location`. That is enforced by *ordering* — user flags are inserted before the app's own group, because yt-dlp lets the last occurrence of a single-valued option win, so a user `-o` placed after ours would redirect the staging path and break the finalise/move step. An unterminated quote is a hard error that disables the Download button instead of being passed on half-closed.
- **Output template** (`-o`) — the file name, with a live preview. Must resolve to an extension (via `%(ext)s` or a literal one) because the manager decides which file is the media file by extension, telling a `.mkv` from a `.srt` sidecar or a `.part` leftover. A `%(playlist_title)s/` prefix is stripped from the *staging* template and applied by the app when the finished file is moved, so a playlist grouping still lands correctly.
- **Saved argument templates** — named flag sets, stored in the settings box under their own key prefix (capped at 30, keyed by name so saving twice replaces). Offered as chips in the format sheet and as removable chips in Settings.
- **Back up / restore settings** — one JSON file holding the preferences and every saved template. Restore is a snapshot, not a merge, so a template deleted before the backup stays deleted; a document from a newer app version is refused rather than partially applied, and an unrelated JSON file is rejected before the "replace settings?" prompt appears.
- **Copy diagnostics** — versions, paths and the relevant settings as plain text, ready to paste into a bug report. Every probe is allowed to fail without losing the rest of the report, and **cookies are never included** — only whether one is configured, since a path can contain a username.
- **yt-dlp capabilities** — first-class controls for the flags most worth having a real UI for: parallel fragments, rate limit, request delay, proxy, `Referer`, audio extraction + container, remux without re-encoding, embedded metadata/chapters, SponsorBlock removal, livestream-from-start, a download archive, and `--no-part`. Every one of them is *also* reachable as a raw flag, but a typed value cannot be right on its own — a fragment count high enough to fail a download, a container that silently drops the cover art you asked to embed — so the controls validate their own inputs.

  Three behaviours worth knowing:

  - **Defaults change nothing.** Fragment parallelism defaults to 1, which is yt-dlp's own `-N` default, so an untouched app produces a byte-identical command line to before these controls existed.
  - **Fragment parallelism is capped at 4.** The throughput gain above that is small and the memory cost is not; on a phone, `-N 16` fails the download outright.
  - **Postprocessing is dropped without ffmpeg+ffprobe.** Audio extraction, remux, metadata, chapters and SponsorBlock all run through yt-dlp's postprocessor, which probes with ffprobe. Without it the flags are omitted rather than passed through to fail *after* the bytes are downloaded, and the toggles are disabled in the UI with the reason shown. A conversion to a container that cannot hold the chosen extras (cover art in WAV, say) drops that extra and says so in the sheet.

The previous hard-coded `" [<id>]"` filename check in `DownloadManager._findFinalFile` generalised to `OutputTemplate.identityFragment`: it uses the id when the template has `%(id)s`, the title when it does not, and no filter at all when the template can only produce the extension. Without that, every template lacking `%(id)s` would have reported "output file not found". A template that is extension-only is called out in the UI, since every file then shares one name and a second download is renamed `"(1)"`.

### YouTube support

YouTube serves different format lists to different "player clients", and increasingly gates the good ones behind a proof-of-origin token that yt-dlp can only obtain by running JavaScript. Two controls live in Settings → **Advanced → YouTube**:

- **JavaScript runtime** — installs `yt-dlp-ejs` into the bundled CPython runtime's `site-packages`. The install is **verified before it commits**: the package is unpacked to a staging directory, rejected if it contains a link or a path escaping that directory, swapped in beside the existing copy, and then *imported by the bundled interpreter*. Anything that does not import is removed again, so a bad download cannot leave the engine in a state where every YouTube fetch fails. The section reports the real state (`installed` / `not installed` / `installed but not working`) rather than claiming a capability it cannot check.
- **Extra player clients** — passes `--extractor-args youtube:player_client=web,…` for the clients you tick. `web` is always included and is yt-dlp's default, so the flag is only sent when you have actually added one. The app's value is emitted *after* any raw `--extractor-args` in the extra-args field, because yt-dlp lets the last occurrence win.

The `yt-dlp-ejs` version is **pinned** alongside the bundled yt-dlp version rather than tracking "latest", so an install is reproducible and a bad upstream release cannot break every user's YouTube downloads.

What this does **not** do: it does not bundle a JS engine (Deno, ~30-40 MB per ABI) inside the APK, and it does not bypass account-level bot checks — those still need cookies. On desktop installs the runtime is not managed, because a system yt-dlp picks up a system-installed `yt-dlp-ejs` on its own; the section reports that rather than pretending to install something.

### Cookies (YouTube and other gated sites)

Some sites — YouTube in particular — refuse anonymous requests, showing "Sign in to confirm you're not a bot" or limiting formats. Settings → **Cookies** imports a Netscape-format `cookies.txt`; it is copied into the app's support directory and handed to yt-dlp via `--cookies`. The app never parses or stores credentials itself, and removing it in Settings deletes the setting (the copy stays on disk until you delete it).

> **Known limitation:** yt-dlp also wants a **PO token** (and increasingly a JS runtime) for full YouTube support. Settings → **Advanced → YouTube** can install the `yt-dlp-ejs` component into the bundled CPython runtime and pick which player clients yt-dlp should try; see *YouTube support* below. Cookies fix the *authentication* half; the JS runtime addresses the *PO token* half. Until both are in place, if YouTube downloads fail while other sites work, that is the cause.

## Stack

- **State:** `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services)
- **Routing:** `go_router` 18 (`StatefulShellRoute.indexedStack`)
- **Theme:** `ColorScheme.fromSeed(seedColor: Colors.red)` (M3), `CardThemeData`, `NavigationBar`/`NavigationRail` adaptive at 760dp.
- **Storage:** `hive` + `path_provider` (download root: `getDownloadsDirectory()` desktop / external app dir on Android, overridable in Settings). Downloads land in `Video/` or `Audio/` subfolders (`services/downloads/download_layout.dart`); playlist entries group one folder deeper, under the sanitized playlist title. Since the app moves a finished file from staging itself rather than letting yt-dlp write it to a final path, it sanitizes that folder name itself (`sanitizeFolderName`) — path separators, control characters and Windows-reserved device names included, because yt-dlp's own template sanitization never runs for a folder the app creates. Three Hive boxes: `history` (library), `settings`, `queue` (task snapshots for restart recovery).
- **Engine:** `BinaryManager` locates `yt-dlp` in this order — system PATH (`which`/`where`, desktop only), bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android), then (desktop only) auto-downloads the official single-file build from GitHub releases into the app support dir. The desktop builds in `assets/bin/` are **not** registered in `pubspec.yaml` on purpose: `flutter.assets` has no per-platform scoping, so declaring them would package ~56 MB of desktop binaries into every Android APK too, tripling the 19 MB/ABI payload. Desktop falls through to the auto-download instead. `ytdlpVersion()` / `updateYtdlp()` power Settings updates: system installs via `yt-dlp -U`; app-managed desktop copies re-download the official build; on Android the button replaces the yt-dlp script inside the extracted CPython runtime with the official standalone release — downloaded to a temp file and verified by running `--version` with the runtime's own interpreter before it replaces the working script, so a bad download can never break the engine. There is no URL to configure. Copies to app support dir + `chmod 755`. Prefers system `ffmpeg` on PATH; without it, requests combined formats only (`b[ext=mp4][acodec!=none]/b[acodec!=none]`).
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
  core/models/{video_info,download_task,download_record,download_options,settings_model,playlist_info,output_template,command_template,yt_prefs,youtube_prefs,library_filter}.dart
  core/utils/{url_validator,formatters,json_utils}.dart
  services/ytdlp/{binary_manager,ytdlp_service,progress_parser,bounded_capture,json_payload,arg_tokenizer,ejs_installer}.dart
  services/downloads/{download_manager,download_layout,history_service,queue_store,folder_scanner}.dart
  services/settings/{settings_service,template_store,backup_service}.dart
  services/diagnostics/diagnostics_service.dart
  services/notifications/notification_service.dart
  services/foreground/foreground_service.dart
  services/sharing/share_intent_service.dart
  widgets/app_shell.dart
  features/home/{home_controller,home_page,widgets/video_info_card,widgets/format_picker_sheet}.dart
  features/queue/{queue_page,batch_queue_page,batch_queue_controller}.dart
  features/library/library_page.dart
  features/settings/settings_page.dart
  features/playlist/playlist_page.dart
assets/bin/
  linux/yt-dlp, macos/yt-dlp, windows/yt-dlp.exe   # optional desktop fallbacks
  android/<abi>/{python.tar.gz,ffmpeg,ffprobe}    # required on Android
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

Fetches official single-file `yt-dlp` builds for Linux/macOS/Windows into `assets/bin/` and prints guidance for Android. **They are not registered in `pubspec.yaml`** — see the Engine bullet in *Stack* for why bundling them would bloat every Android APK. They are useful as a dev convenience (a binary on disk to point at) and as a manual fallback; the app itself uses a system `yt-dlp` or auto-downloads one.

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

If a per-ABI archive is missing, `assets/bin/android/yt-dlp` (a single-file bionic build committed to the repo) is tried as a fallback; otherwise the app shows an actionable error naming the expected path. An install that ends up on such a build cannot self-update — Settings reports that an app update is needed, since custom build URLs are no longer configurable.

> **Android 14+ SELinux note:** apps targeting recent SDKs (`untrusted_app_34`) are denied `execute` on their own data files (`avc: denied { execute_no_trans }`), which silently breaks any bundled-subprocess design. This project therefore sets `targetSdk = 28` in `android/app/build.gradle.kts` (same approach as Termux) so the bundled runtime can execute. Trade-off: sideload/F-Droid distribution only — the Play Store requires a recent target SDK (and forbids YouTube downloading anyway).

APK per-ABI splits are recommended (each runtime adds ~16 MB + ~2 MB ffmpeg + ~1.7 MB ffprobe). A universal release APK is ~90 MB; split it per ABI for ~25 MB each:

```bash
flutter build apk --release --split-per-abi
```

## Release identity

- **App ID:** `com.github.ytdlp` on every platform — `android/app/build.gradle.kts`, `linux/CMakeLists.txt` (`APPLICATION_ID`), `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`) and the `RunnerTests` bundle in `macos/Runner.xcodeproj`
- **App label:** `YTDL` — `AndroidManifest.xml` on Android, `CFBundleDisplayName`/`CFBundleName` in `macos/Runner/Info.plist`, the GTK header-bar title in `linux/runner/my_application.cc`, the window title in `windows/runner/main.cpp` and the `Runner.rc` version block, and `web/index.html` + `web/manifest.json`
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
| **iOS** | **Not supported.** `BinaryManager` has no iOS engine branch and `share_intent_service` no-ops off Android, so there is no way to run `yt-dlp`. |
| **Web** | **Not supported.** `dart:io` is used throughout and there is no web engine implementation. |

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
- **Android notes (ffmpeg/ffprobe):** on Android the bundled minimal static `ffmpeg` is used so DASH video/audio streams can merge, and the bundled `ffprobe` is what yt-dlp's postprocessing probes with (`--ffmpeg-location`). The embed toggles in the format sheet are gated on *ffprobe* specifically, not ffmpeg, because ffmpeg alone can merge but cannot postprocess — otherwise the download would fail with "ffprobe not found". When ffmpeg is unavailable (desktop without a system `ffmpeg`), video is combined-only (no DASH merge) and audio is `M4A` (`ba[ext=m4a]/ba`).
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

The integration test boots the real app, fetches a video, picks a format and waits for the download to complete — it needs a device/emulator and network. It runs in CI via the opt-in **Device test (Android)** workflow (Actions → *Run workflow*), which boots an emulator; it is deliberately not on every push because it costs ~10 minutes of emulator time.

## Roadmap

Done recently: bottom-sheet format picker (removed the inline format section), clipboard paste button, resumable downloads with retry backoff, queue persistence across restarts, cookies.txt support, one-tap yt-dlp update from a fixed source, release identity (app id, adaptive icon, keystore signing), Android foreground service for background downloads, share-sheet intake, macOS sandbox entitlements (`network.client` was missing entirely, so Release builds had no network at all), macOS notifications, an `ffprobe` detection fix that hid the embed-subtitles/thumbnail toggles on every Android launch after the first, **playlist downloads** with a per-entry picker, per-video tasks and sanitized per-playlist folders, **advanced settings** (extra yt-dlp flags with managed-flag protection, a live-previewed output template, and saved named argument templates), and **YouTube support** (a verified `yt-dlp-ejs` installer and player-client selection), **yt-dlp capability controls** (fragment parallelism, rate limits, proxy, audio extraction, remux, embedded metadata/chapters, SponsorBlock, download archive), **queue controls** (configurable concurrency, pause/resume, cancel-all, clear-finished, reordering, and a remembered queue size that fixes large playlists being truncated on restart), a **searchable, sortable, groupable library with a folder scan**, **batch URL queueing**, and **settings backup / diagnostics export**.

Still open:

- **Channel and handle URLs** — these already arrive as flat playlists and work through the same picker, but there is no "download everything from this channel" shortcut, and no pagination for very large collections.
- **Bundling a JS engine (Deno) in the APK.** The `yt-dlp-ejs` installer removes most of the PO-token gap, but a real in-process engine is ~30-40 MB per ABI and would need an NDK build like the CPython runtime.
- **A cookie manager** — per-domain listing, expiry, per-site enable and `--cookies-from-browser`. Currently the app only imports a `cookies.txt` file; the Advanced field can set the flag by hand, but a real manager needs a Netscape jar parser plus a browser-profile extractor, and Android has no browser-profile access at all.
- iOS and web are currently dead ends — either implement an engine or drop them from the supported matrix.
- Changelog / version policy if releases are published.
