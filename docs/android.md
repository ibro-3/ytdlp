# Android notes

Android is the primary target: the CPython runtime, `ffmpeg` and `ffprobe` are bundled as assets and extracted on first launch. This document covers rebuilding those assets and the build configuration.

## Bundling binaries

Desktop (`yt-dlp` for Linux/macOS/Windows) is a developer convenience only:

```bash
./tool/fetch_binaries.sh
```

It fetches the official single-file builds into `assets/bin/`, verifies each one actually runs, and prints guidance for Android. Those binaries are **gitignored** and **not registered in `pubspec.yaml`** (see [architecture.md](architecture.md#engine-resolution)); delete them with `rm -rf assets/bin/{linux,macos,windows}`.

**Android has no official standalone binary** — the GitHub Linux build links glibc and won't run on Android's bionic libc. This repo bundles a self-contained CPython + yt-dlp runtime assembled from official Termux packages (CPython 3.14 + yt-dlp 2026.08.19):

```bash
./tool/fetch_android_runtime.sh          # both ABIs
./tool/fetch_android_runtime.sh x86_64   # emulator only
```

This produces `assets/bin/android/<abi>/python.tar.gz` (~16 MB per ABI), already registered in `pubspec.yaml`. At first launch the app extracts it to its private files dir and runs `python3.14 bin/yt-dlp` with `LD_LIBRARY_PATH`/`PYTHONHOME`/`SSL_CERT_FILE` pointed at the tree — no root, no Termux app needed. Settings → **Update yt-dlp** refreshes only the yt-dlp script from the official release; the CPython interpreter, native libs and bundled ffmpeg still ship with the app, so those need an app update.

## ffmpeg and ffprobe

Modern YouTube serves video/audio as separate DASH streams, and merging them needs ffmpeg. The Termux ffmpeg package drags in ~97 packages (~40 MB/ABI), so instead a minimal **static** ffmpeg is cross-compiled with the NDK — just the file protocol, mp4/webm/mkv demuxers and muxers yt-dlp needs for `-c copy` merges (~2 MB/ABI):

```bash
./tool/fetch_ffmpeg_android.sh          # both ABIs (needs ANDROID_NDK / ~/Android/Sdk/ndk)
./tool/fetch_ffmpeg_android.sh x86_64   # emulator only
```

**ffprobe ships alongside ffmpeg and is equally required.** Merging only needs ffmpeg, but every *postprocessing* step — embedding subtitles, embedding a thumbnail cover, converting subtitle formats — goes through yt-dlp's `FFmpegMetadataPP`, which probes the output with ffprobe and aborts with `Postprocessing: ffprobe not found`. yt-dlp resolves the pair from a single `--ffmpeg-location`: given the path to ffmpeg it looks for ffprobe in the same directory, so the two must be extracted together.

The app extracts both on first launch and passes the ffmpeg path to `--ffmpeg-location`. The extraction marker (`ffmpeg-8.1.3-static-v2-ffprobe` in `binary_manager.dart`) must be bumped whenever these binaries change, or existing installs keep a stale ffmpeg-only copy; it also re-extracts when ffprobe is missing.

| ABI (device) | Asset | Status |
| ------------ | ----- | ------ |
| `x86_64` (Studio emulators) | `assets/bin/android/x86_64/…` | ffmpeg merge verified end-to-end on emulator; ffprobe rebuilt and packaged, not yet exercised on-device |
| `arm64-v8a` (physical devices) | `assets/bin/android/arm64-v8a/…` | same recipe, untested here |

If a per-ABI archive is missing, the app shows an actionable error naming the expected path and the ABI it was looking under. An install that lands on such a build cannot self-update — Settings reports that an app update is needed.

On Android the embed toggles in the format sheet and in Settings → Post-processing are gated on *ffprobe* specifically, not ffmpeg, because ffmpeg alone can merge but cannot postprocess. The capability is probed **once per session** and cached, so typing in an unrelated Settings field cannot make the toggles flicker greyed out; while the probe runs they say "checking" rather than claiming ffmpeg is missing. Updating yt-dlp re-runs it.

## Storage

- `INTERNET` permission in `android/app/src/main/AndroidManifest.xml`.
- Downloads go to the app-specific external dir on Android 10+ (no storage permission needed). A folder picked in Settings must be a real, writable filesystem path — the bundled yt-dlp child process writes by path, not via SAF `content://` URIs, so SD-card picks are rejected with an explanation.

## Build configuration

- **`targetSdk = 28` is deliberate.** Android 10+ enforces W^X for apps targeting API 29+: `exec()` on files in app-writable storage is denied (`avc: denied { execute_no_trans }`), which breaks the bundled CPython/yt-dlp runtime extracted into the app support dir. Termux ships targetSdk 28 for the same reason. That trips Google Play's `ExpiredTargetSdkVersion` lint on release builds, so that single check is disabled in `android/app/build.gradle.kts` — every other lint rule still runs. A higher target is reachable with `-P ytdlpTargetSdk=33`, but the runtime will not execute under it without repackaging the engine.
- **`compileSdk` is 37 while `targetSdk` stays 28.** `receive_sharing_intent` 1.9.0 and `flutter_foreground_task` 11.x compile against 37, so the build script pins `compileSdk = 37` instead of following `flutter.compileSdkVersion` (36 in Flutter 3.47). These are independent: `compileSdk` gates which APIs are visible at compile time, `targetSdk` drives runtime behaviour. Verified via `aapt2 dump badging`.
- **`android.builtInKotlin=true`** in `android/gradle.properties` (the Flutter template default is `false`). Both plugins migrated to Flutter's built-in Kotlin and no longer apply the Kotlin Gradle Plugin themselves, which is required under AGP 9+ and removes the "applies Kotlin Gradle Plugin" build warning.
- Distribution: the Play Store forbids YouTube downloading, and the expired target SDK is not accepted — this is intended for sideload/F-Droid/GitHub.

## Signing

Release builds are signed with a real keystore, falling back to the debug key with a warning when `android/key.properties` is absent.

```bash
keytool -genkey -v -keystore ~/ytdlp-release.keystore -alias ytdlp -keyalg RSA -keysize 2048 -validity 10000
cp android/key.properties.example android/key.properties   # then fill in your details
flutter build apk --release --split-per-abi
```

`android/key.properties` is gitignored — never commit it. For CI, inject the keystore and properties file from GitHub secrets at build time.

## Per-ABI splits

Each ABI adds ~16 MB (CPython) + ~2 MB ffmpeg + ~1.7 MB ffprobe. A universal release APK is ~90 MB; `--split-per-abi` produces one APK per ABI at ~25 MB each for `arm64-v8a`, `armeabi-v7a`, `x86_64` and `x86`.

```bash
flutter build apk --release --split-per-abi
```

## Metadata fetch limits

`fetchVideoInfo` runs yt-dlp with a 90s timeout and bounded output capture. The two streams get separate budgets: 16 MB for the JSON payload on stdout (a real single video is ~100 KB) and 64 KB for stderr, whose *tail* is kept for diagnostics. The stdout payload is retained **in full** up to its budget — it is what gets parsed, so it is never window-truncated. When stdout exceeds its budget the process is killed immediately instead of buffering a runaway response, and the app says what happened:

- a **playlist link** — yt-dlp returns the whole collection (tens of MB) and still exits 0, so the app reports that rather than a generic error
- otherwise the site sent a response too large to read, with the actual size

A playlist is normally recognised *before* this point and re-fetched cheaply with `--flat-playlist`, so the oversize path is the rare case. The heuristic (`looksLikePlaylistOutput`) is deliberately narrow — an unrelated failure like "video is private" must stay an error.

A chatty stderr never fails a successful fetch, and output is decoded leniently so one malformed byte cannot blank out the metadata. If a payload still cannot be read, the app shows what the response actually began with, tolerating a short non-JSON preamble the bundled runtime may print.