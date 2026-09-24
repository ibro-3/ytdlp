# YTDL — Material 3 Downloader

A Flutter Material 3 app that downloads videos via a **bundled `yt-dlp` binary** + `ffmpeg` (1000+ sites: YouTube, TikTok, Vimeo, etc.). Targets **Android + Desktop (Linux/Windows/macOS)** with a red seed theme, adaptive `NavigationBar`/`NavigationRail`, and Riverpod + go_router.

![M3](https://img.shields.io/badge/Material-3-red) ![Flutter](https://img.shields.io/badge/Flutter-3.47-blue)

## Features

- **Download tab** — M3 `SearchBar` URL input (paste/clear), a clipboard paste FAB that extracts the link out of whatever you shared, `yt-dlp -J` metadata fetch, `VideoInfoCard` (thumbnail via `cached_network_image`), and a single **Download** button. Tapping it opens a bottom sheet with the format (`SegmentedButton` Video/Audio) + quality (`ChoiceChip`) pickers and its own Download button. The sheet is seeded from the Settings defaults ("Default video quality" / "Audio only by default") on every open.
- **Queue tab** — live progress (`LinearProgressIndicator`, %/speed/ETA), cancel/retry/open/share/delete. Backed by `DownloadManager` (ChangeNotifier) streaming yt-dlp `--newline` output. One download runs at a time on mobile, two in parallel on desktop. Posts Android progress/completion notifications (foreground-only in v1).
  - **Resumable**: a failed or interrupted download keeps its staging directory and yt-dlp's `.part` file, so Retry continues instead of re-fetching. Engine flags add `--continue`, `--retries 10`, `--fragment-retries 10` and a capped `--retry-sleep linear=1:5:2` backoff.
  - **Restart-safe**: the queue is snapshotted to Hive. Work that was running when the process was killed comes back as *failed* ("Interrupted when the app closed — tap Retry to continue") with its partial download intact; staging directories no task refers to are deleted on startup so they can't leak storage.
- **Library tab** — Hive-backed history, file existence check, open (`open_filex`), share (`share_plus`), clear.
- **Settings tab** — theme mode (system/light/dark) + seed color swatches, default video quality / audio-only, **download folder** (default Downloads, or any writable folder picked in Settings; videos → `Video/`, audio → `Audio/`), **cookies.txt import** (see below), yt-dlp version + one-tap update (system `yt-dlp -U`; app-managed copies and the Android runtime refresh from the official release), notification toggle + test.

### Cookies (YouTube and other gated sites)

Some sites — YouTube in particular — refuse anonymous requests, showing "Sign in to confirm you're not a bot" or limiting formats. Settings → **Cookies** imports a Netscape-format `cookies.txt`; it is copied into the app's support directory and handed to yt-dlp via `--cookies`. The app never parses or stores credentials itself, and removing it in Settings deletes the setting (the copy stays on disk until you delete it).

> **Known limitation:** yt-dlp also wants a **PO token** (and increasingly a JS runtime — `yt-dlp-ejs` or Deno) for full YouTube support. This app ships no JS runtime in its bundled CPython runtime and does not run a PO-token provider, so some YouTube formats may be unavailable or fail with a bot check. Cookies fix the *authentication* half; the *PO token* half needs a bundled Deno (~30-40 MB per ABI) or a switch to a pure-JVM yt-dlp. Until then, if YouTube downloads fail while other sites work, that is the cause.

## Stack

- **State:** `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services)
- **Routing:** `go_router` 18 (`StatefulShellRoute.indexedStack`)
- **Theme:** `ColorScheme.fromSeed(seedColor: Colors.red)` (M3), `CardThemeData`, `NavigationBar`/`NavigationRail` adaptive at 760dp.
- **Storage:** `hive` + `path_provider` (download root: `getDownloadsDirectory()` desktop / external app dir on Android, overridable in Settings). Downloads land in `Video/` or `Audio/` subfolders (`services/downloads/download_layout.dart`); playlists will group under one folder per playlist inside the matching area. Three Hive boxes: `history` (library), `settings`, `queue` (task snapshots for restart recovery).
- **Engine:** `BinaryManager` locates `yt-dlp` in this order — system PATH (`which`/`where`, desktop only), bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android), then (desktop only) auto-downloads the official single-file build from GitHub releases into the app support dir. `ytdlpVersion()` / `updateYtdlp()` power Settings updates: system installs via `yt-dlp -U`; app-managed desktop copies re-download the official build; on Android the button replaces the yt-dlp script inside the extracted CPython runtime with the official standalone release — downloaded to a temp file and verified by running `--version` with the runtime's own interpreter before it replaces the working script, so a bad download can never break the engine. There is no URL to configure. Copies to app support dir + `chmod 755`. Prefers system `ffmpeg` on PATH; without it, requests combined formats only (`b[ext=mp4][acodec!=none]/b[acodec!=none]`).
- **Notifications:** `flutter_local_notifications`, `downloads` channel, `POST_NOTIFICATIONS` (Android 13+ runtime grant on toggle). Progress throttled to percent-change + 2s; completion/failure alerts; honoring the Settings toggle. Foreground-only in v1 — background downloads need a Foreground Service (follow-up).

## Project structure

```
lib/
  main.dart, app.dart
  core/theme/app_theme.dart
  core/router/app_router.dart
  core/providers.dart
  core/models/{video_info,download_task,download_record}.dart
  core/utils/{url_validator,formatters}.dart
  services/ytdlp/{binary_manager,ytdlp_service,progress_parser}.dart
  services/downloads/{download_manager,download_layout,history_service}.dart
  widgets/app_shell.dart
  features/home/{home_controller,home_page,widgets/video_info_card}.dart
  features/queue/queue_page.dart
  features/library/library_page.dart
assets/bin/.gitkeep
tool/fetch_binaries.sh
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

Fetches official single-file `yt-dlp` builds for Linux/macOS/Windows into `assets/bin/` and prints guidance for Android.

**Android has no official standalone binary** — the GitHub Linux build links glibc and won't run on Android's bionic libc. This repo bundles a self-contained CPython + yt-dlp runtime assembled from official Termux packages (same versions as Termux ships: currently CPython 3.14 + yt-dlp 2026.08.19):

```bash
./tool/fetch_android_runtime.sh          # both ABIs
./tool/fetch_android_runtime.sh x86_64   # emulator only
```

This produces `assets/bin/android/<abi>/python.tar.gz` (~16 MB per ABI), already registered in `pubspec.yaml`. At first launch the app extracts it to its private files dir and runs `python3.14 bin/yt-dlp` with `LD_LIBRARY_PATH`/`PYTHONHOME`/`SSL_CERT_FILE` pointed at the tree — no root, no Termux app needed. Settings → **Update yt-dlp** refreshes only the yt-dlp script from the official release; the CPython interpreter, native libs and bundled ffmpeg still ship with the app, so those need an app update.

**ffmpeg (video downloads):** modern YouTube serves video/audio as separate DASH streams, and merging them needs ffmpeg. The Termux ffmpeg package drags in ~97 packages (~40 MB/ABI), so instead a minimal **static** ffmpeg is cross-compiled with the NDK — just the file protocol, mp4/webm/mkv demuxers and muxers yt-dlp needs for `-c copy` merges (~2 MB/ABI):

```bash
./tool/fetch_ffmpeg_android.sh          # both ABIs (needs ANDROID_NDK / ~/Android/Sdk/ndk)
./tool/fetch_ffmpeg_android.sh x86_64   # emulator only
```

The app extracts it on first launch and passes `--ffmpeg-location` to yt-dlp, so video downloads merge on-device.

| ABI (device)                     | Asset                              | Status               |
| -------------------------------- | ---------------------------------- | -------------------- |
| `x86_64` (Studio emulators)      | `assets/bin/android/x86_64/…`      | verified end-to-end on emulator (fetch + video download w/ ffmpeg merge) |
| `arm64-v8a` (physical devices)   | `assets/bin/android/arm64-v8a/…`    | same recipe, untested here |

If a per-ABI archive is missing, `assets/bin/android/yt-dlp` (a single-file bionic build committed to the repo) is tried as a fallback; otherwise the app shows an actionable error naming the expected path. An install that ends up on such a build cannot self-update — Settings reports that an app update is needed, since custom build URLs are no longer configurable.

> **Android 14+ SELinux note:** apps targeting recent SDKs (`untrusted_app_34`) are denied `execute` on their own data files (`avc: denied { execute_no_trans }`), which silently breaks any bundled-subprocess design. This project therefore sets `targetSdk = 28` in `android/app/build.gradle.kts` (same approach as Termux) so the bundled runtime can execute. Trade-off: sideload/F-Droid distribution only — the Play Store requires a recent target SDK (and forbids YouTube downloading anyway).

APK per-ABI splits are recommended (each runtime adds ~16 MB + ~2 MB ffmpeg). A universal release APK is ~90 MB; split it per ABI for ~25 MB each:

```bash
flutter build apk --release --split-per-abi
```

## Before publishing anything

The app still carries Flutter's placeholder identity — these are release blockers that need a human decision (changing `applicationId` later breaks upgrades, so pick once):

- `applicationId = "com.example.ytdlp"` in `android/app/build.gradle.kts` → your own reverse-DNS id.
- `android:label="YTDL"` in the manifest, and the launcher icon is still the default Flutter icon.
- Release builds are signed with the **debug key** — create a keystore and wire up `signingConfigs` (keep the keystore out of git; use GitHub secrets for CI).
- Ship with `--split-per-abi` (see above), and add a changelog/version policy if you publish releases.

## Android notes

- `INTERNET` permission added to `android/app/src/main/AndroidManifest.xml`.
- Downloads go to app-specific external dir on Android 10+ (no storage permission needed). A folder picked in Settings must be a real, writable filesystem path — the bundled yt-dlp child process writes by path, not via SAF `content://` URIs (SD-card picks are rejected with an explanation; on-device folders work).
- **Android notes (ffmpeg):** on Android the bundled minimal static `ffmpeg` is used so DASH video/audio streams can merge (`--ffmpeg-location`). When ffmpeg is unavailable (desktop without a system `ffmpeg`), video is combined-only (no DASH merge) and audio is `M4A` (`ba[ext=m4a]/ba`).
- **`targetSdk = 28` is deliberate.** Android 10+ (API 29+) enforces W^X for apps targeting API 29+: `exec()` on files in app-writable storage is denied (`avc: denied { execute_no_trans }`), which breaks the bundled CPython/yt-dlp runtime extracted into the app support dir. Termux ships targetSdk 28 for the same reason. Because that trips Google Play's `ExpiredTargetSdkVersion` lint on release builds, that single check is disabled in `android/app/build.gradle.kts` — every other lint rule still runs. A higher target is still reachable for experiments with `-P ytdlpTargetSdk=33`, but the runtime will not execute under it without repackaging the engine (e.g. shipping it via `jniLibs` into `nativeLibraryDir`) or switching to a pure-JVM yt-dlp.
- Release builds are signed with the **debug key** (placeholder in `android/app/build.gradle.kts`). Create a real keystore before publishing anywhere.
- Distribution: Play Store forbids YouTube downloading — intended for sideload/F-Droid/GitHub.

## Testing

```bash
flutter test                                    # unit + widget tests (fast, no device)
flutter test integration_test/app_test.dart -d <device>   # on-device pipeline test
```

The integration test boots the real app, fetches a video, picks a format and waits for the download to complete — it needs a device/emulator and network. It runs in CI via the opt-in **Device test (Android)** workflow (Actions → *Run workflow*), which boots an emulator; it is deliberately not on every push because it costs ~10 minutes of emulator time.

## Roadmap

Done recently: bottom-sheet format picker (removed the inline format section), clipboard paste button, resumable downloads with retry backoff, queue persistence across restarts, cookies.txt support, one-tap yt-dlp update from a fixed source.

Still open:

- **YouTube PO tokens + a JS runtime** (`yt-dlp-ejs` or Deno) in the bundled runtime — the main remaining blocker for YouTube reliability (see *Cookies* above).
- **Android foreground service** so downloads survive the app being backgrounded (currently foreground-only).
- Playlist downloads (`download_layout.dart` already carries the per-playlist template; the caller always passes `false`).
- Subtitles and thumbnail/metadata embedding.
- Share intent (`receive_sharing_intent`) — share a link straight into the app.
- Release identity: app id, icon, signing key, per-ABI splits.
