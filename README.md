# YTDL — Material 3 Downloader

A Flutter Material 3 app that downloads videos via a **bundled `yt-dlp` binary** + `ffmpeg` (1000+ sites: YouTube, TikTok, Vimeo, etc.). Targets **Android + Desktop (Linux/Windows/macOS)** with a red seed theme, adaptive `NavigationBar`/`NavigationRail`, and Riverpod + go_router.

![M3](https://img.shields.io/badge/Material-3-red) ![Flutter](https://img.shields.io/badge/Flutter-3.47-blue)

## Features

- **Download tab** — M3 `SearchBar` URL input (paste/clear), `yt-dlp -J` metadata fetch, `VideoInfoCard` (thumbnail via `cached_network_image`), format picker (`SegmentedButton` Video/Audio + `ChoiceChip` qualities), `FilledButton` download.
- **Queue tab** — live progress (`LinearProgressIndicator`, %/speed/ETA), cancel/retry/open/share/delete. Backed by `DownloadManager` (ChangeNotifier) streaming yt-dlp `--newline` output.
- **Library tab** — Hive-backed history, file existence check, open (`open_filex`), share (`share_plus`), clear.

## Stack

- **State:** `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services)
- **Routing:** `go_router` 18 (`StatefulShellRoute.indexedStack`)
- **Theme:** `ColorScheme.fromSeed(seedColor: Colors.red)` (M3), `CardThemeData`, `NavigationBar`/`NavigationRail` adaptive at 760dp.
- **Storage:** `hive` + `path_provider` (downloads dir: `getDownloadsDirectory()` desktop, external app dir on Android)
- **Engine:** `BinaryManager` locates `yt-dlp` in this order — system PATH (`which`/`where`, desktop only), bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android), then (desktop only) auto-downloads the official single-file build from GitHub releases into the app support dir. Copies to app support dir + `chmod 755`. Prefers system `ffmpeg` on PATH; without it, requests combined formats only (`b[ext=mp4]/b`).

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
  services/downloads/{download_manager,history_service}.dart
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

**Android has no official standalone binary** — the GitHub Linux build links glibc and won't run on Android's bionic libc. You must cross-build `yt-dlp` (PyInstaller against the NDK) and place it per-ABI, matching what the device reports via `uname -m`:

| ABI (device)                 | Asset path                          |
| ---------------------------- | ----------------------------------- |
| `arm64-v8a` (physical RK/MTK/SD) | `assets/bin/android/arm64-v8a/yt-dlp` |
| `x86_64` (Studio emulators)  | `assets/bin/android/x86_64/yt-dlp`  |
| `armeabi-v7a` (older 32-bit) | `assets/bin/android/armeabi-v7a/yt-dlp` |
| `x86`                        | `assets/bin/android/x86/yt-dlp`     |

Then register the asset(s) in `pubspec.yaml` and rebuild:

```bash
flutter clean && flutter run
```

If a per-ABI asset is missing, `assets/bin/android/yt-dlp` is tried as a fallback; otherwise the app shows an actionable error naming the expected path.

APK per-ABI splits are recommended (binaries ~15 MB).

## Android notes

- `INTERNET` permission added to `android/app/src/main/AndroidManifest.xml`.
- Downloads go to app-specific external dir on Android 10+ (no storage permission needed). No `ffmpeg` in v1 — audio is `M4A` (`ba[ext=m4a]/b`), video is combined-only when `ffmpeg` is absent.
- Distribution: Play Store forbids YouTube downloading — intended for sideload/F-Droid/GitHub.

## Testing the pipeline (desktop)

```bash
yt-dlp -J --no-playlist "https://www.youtube.com/watch?v=jNQXAC9IVRw" | head
ffmpeg -version
flutter run -d linux --verbose
```

## Roadmap

- Phase 3: bundled `ffmpeg` merge, playlist support, subtitles/thumbnails, notifications, share intent (`receive_sharing_intent`).
- Re-enable `dynamic_color` harmonization once `material_ui` ColorScheme alias stabilizes (removed in this build due to flutter/material vs material_ui type collision).
