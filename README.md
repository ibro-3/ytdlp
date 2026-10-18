# YTDL — Platform-Native Downloader

A Flutter app that downloads videos with a **bundled `yt-dlp` binary** and `ffmpeg`, covering 1000+ sites (YouTube, TikTok, Vimeo, …). It targets **Android and desktop (Linux/Windows/macOS)** and follows the host OS's widget family — **Material 3** on Android, **Cupertino** on macOS, **Fluent UI** on Windows, **GTK4/Adwaita** on Linux — with one red seed theme across all four. State is Riverpod, routing is `go_router`.

![M3](https://img.shields.io/badge/Material-3-red) ![Flutter](https://img.shields.io/badge/Flutter-3.47-blue)

## Features

- **Download** — paste, share or scan a URL, fetch metadata with `yt-dlp -J`, then pick format, quality and subtitles in a bottom sheet. Playlists and channels open a picker instead.
- **Queue** — live progress with pause, resume, retry, cancel and reordering; concurrent downloads; the queue survives an app restart and resumes from partial files.
- **Batch** — paste several URLs at once; each resolves and fails on its own.
- **Library** — searchable, sortable history with file-existence checks, open/share/delete and a folder scan to adopt unknown files.
- **Settings** — theme, download folder, quality and subtitle defaults, network options, cookies, extra yt-dlp flags, a file-name template, backups and diagnostics.

## Documentation

| Document | Contents |
| -------- | -------- |
| [docs/features.md](docs/features.md) | What each tab does, queue behaviour, playlists and channels |
| [docs/architecture.md](docs/architecture.md) | Stack, storage, engine resolution, release identity, the Linux GTK3/GTK4 toolkits |
| [docs/android.md](docs/android.md) | Bundled runtime and ffmpeg, builds, signing |
| [docs/advanced-settings.md](docs/advanced-settings.md) | Extra flags, output template, backups, diagnostics |
| [docs/youtube-support.md](docs/youtube-support.md) | The `yt-dlp-ejs` JavaScript runtime and player clients |
| [docs/cookies.md](docs/cookies.md) | `cookies.txt` import, per-site control, `--cookies-from-browser` |

## Getting started

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux   # or android
```

On desktop a system `yt-dlp` and `ffmpeg` on `PATH` are used, so no bundled binary is needed for development; if neither exists the app downloads the official single-file `yt-dlp` build on first run. On Android the CPython runtime, `ffmpeg` and `ffprobe` are bundled as assets — see [docs/android.md](docs/android.md).

## Platform support

| Platform | Status |
| -------- | ------ |
| **Android** | Primary target. Bundled CPython + yt-dlp runtime and static ffmpeg/ffprobe, `dataSync` foreground service, share-sheet intake. **Material 3** UI. |
| **Linux** | Supported. System or bundled `yt-dlp`, GTK notifications. **GTK4/Adwaita** UI: a 42dp header bar with a view switcher in it (`AdwViewSwitcher`-style) instead of a bottom tab bar, Cantarell, Adwaita's neutral greys with the seed kept as the accent, no ink splashes, popover menus and drop-downs, and a 52×24 sliding switch. The window is the GTK3 embedder Flutter ships by default, and the shell also builds against GTK4 — see [docs/architecture.md](docs/architecture.md). |
| **Windows** | Supported. System or bundled `yt-dlp.exe`. **Fluent UI** UI, through [`fluent_ui`](https://pub.dev/packages/fluent_ui): a `NavigationView` pane, Fluent buttons/switches/dialogs, and a `ComboBox` in place of Material's drop-down. The native frame is unchanged; a custom title bar is not used. |
| **macOS** | Supported. Sandboxed — entitlements matter — and **Cupertino** UI, with a `CupertinoTabScaffold` tab bar. See [docs/architecture.md](docs/architecture.md). |
| **iOS** / **Web** | Dropped. `dart:io` is used throughout; no engine was ever implemented for either. |

## Reporting a bug

Paste the output of **Settings → Copy diagnostics** into the issue. It reports versions, paths, settings and whether ffmpeg/ffprobe and the JavaScript runtime were found — never cookies or any credential. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: `dart format`, `flutter analyze --fatal-infos` and `flutter test` are the definition of green, user-visible changes need a README or `docs/` update, and nothing user-supplied may reach a shell — extra yt-dlp flags go through the argument tokenizer as an argument list.

## Licence

GPL-3.0-or-later; see [LICENSE](LICENSE). The bundled binaries carry their own licences: yt-dlp is GPL-3.0-or-later, the static `ffmpeg` build is LGPL-2.1-or-later, and the CPython runtime is assembled from official Termux packages under the PSF licence.
