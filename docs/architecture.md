# Architecture

## Stack

- **State** — `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services). Long-lived services are `ChangeNotifier`s consumed with `AnimatedBuilder`. Listeners follow `settingsControllerProvider`, not the settings *service*, which yields one always-equal instance and would never notify.
- **Routing** — `go_router` 18 (`StatefulShellRoute.indexedStack`) with an `errorBuilder`.
- **Theme** — one `ColorScheme.fromSeed(seedColor: red)` drives all four families (`core/theme/app_theme.dart`), plus the Material `CardThemeData`/`NavigationBar`/`SearchBar` chrome and, for Linux, `AppTheme.gtk`'s Adwaita greys and metrics. Theme mode (system/light/dark) and the seed colour are the Settings pair; the *style* is not a setting — the OS decides, which is the point.
- **Platform UI** — `core/platform_style.dart` resolves the family from `defaultTargetPlatform` — Android → Material, macOS → Cupertino, Windows → Fluent, Linux → GTK4/Adwaita. `widgets/platform/platform_app.dart` picks the root (`MaterialApp.router` / `CupertinoApp.router` / `FluentApp.router` — `fluent_ui`; GTK is a Material root carrying `AppTheme.gtk`, because there is no GTK theme holder to hang it on), and every screen is built from the wrappers in `widgets/platform/` (`AppScaffold`, `AppButton`, `AppSwitchTile`, `AppSegmented`, `AppListTile`, `AppSection`, `showAppConfirm`, `showAppToast`, …), each of which renders the family the OS asked for. The GTK shapes live in `widgets/platform/platform_gtk.dart`: the 52×24 sliding switch, the pill, the bordered expander, the popover menu and drop-down, and the header bar with its view switcher.
  - **Why no `libadwaita` package:** the pub one (2.0.2, 2023) pins `package_info_plus` below 5 and `flutter_svg` below 3, both of which this app needs much newer versions of, so the family is built in-house from Material widgets plus Adwaita's own metrics and greys. The window is still the **GTK3** embedder Flutter ships for Linux — GTK4 is the look, not the toolkit underneath; the runner's `GtkHeaderBar` keeps the window controls but no longer carries its own title, so the Flutter header bar owns it. The toolkit underneath can be switched — see *Linux toolkit* below.
- **Storage** — `hive` + `path_provider`. Three boxes: `history`, `settings`, `queue`. Each is opened independently at start-up and a failure is reported in the app rather than thrown. Every reader treats a corrupt record as absent rather than crashing.
- **Notifications** — `flutter_local_notifications`, `downloads` channel on Android, `LinuxNotificationDetails`, `DarwinNotificationDetails`. Permission is only requested when the Settings toggle is switched on. Progress is throttled to percent-change + 2s.
- **Background downloads (Android)** — `flutter_foreground_task` runs a `dataSync` foreground service while the queue is non-empty, holding a wake lock. Notification updates are throttled to a changed percentage and at most one every 2s.
- **Share intake (Android)** — `receive_sharing_intent` catches `ACTION_SEND` text/plain intents; a shared URL is extracted with the same `extractUrl` used for the clipboard.

## Download layout

The download root is `getDownloadsDirectory()` on desktop and the external app dir on Android, overridable in Settings. Downloads land in `Video/` or `Audio/` (`services/downloads/download_layout.dart`); playlist entries group one folder deeper, under the sanitized playlist title.

The app moves a finished file from staging itself rather than letting yt-dlp write it to a final path, so it sanitizes that folder name itself (`sanitizeFolderName`) — path separators, control characters and Windows-reserved device names included.

## Engine resolution

`BinaryManager` locates `yt-dlp` in this order:

1. system `PATH` (`which`/`where`, desktop only)
2. bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android)
3. desktop only: auto-download the official single-file build from GitHub releases into the app support dir

The desktop builds in `assets/bin/` are **not** registered in `pubspec.yaml`: `flutter.assets` has no per-platform scoping, so declaring them would package ~56 MB of desktop binaries into every Android APK. `test/models/android_runtime_test.dart` fails if that ever changes.

`ytdlpVersion()` / `updateYtdlp()` power the Settings update: system installs use `yt-dlp -U`; app-managed desktop copies re-download the official build; on Android the yt-dlp script inside the extracted CPython runtime is replaced with the official standalone release, downloaded to a temp file and verified by running `--version` with the runtime's own interpreter first.

Downloads are checked against the SHA-256 in the release's `SHA2-256SUMS` before anything is made executable, a body implausibly small for a yt-dlp build is refused, and redirects are followed by hand against a pinned host allowlist rather than by `HttpClient`'s own handling.

`ffmpeg` is preferred from `PATH`; without it the app requests combined formats only (`b[ext=mp4][acodec!=none]/b[acodec!=none]`).

## Linux toolkit (GTK3 / GTK4)

The Linux shell is written against one toolkit at a time, chosen at configure
time by `FLUTTER_TOOLKIT` (`linux/CMakeLists.txt`):

| | `gtk3` (default) | `gtk4` |
| --- | --- | --- |
| pkg-config | `gtk+-3.0` | `gtk4` |
| embedder | `libflutter_linux_gtk.so` | `libflutter_linux_gtk4.so` |
| window | `gtk_container_add` + explicit realize | `gtk_window_set_child` + present |
| title bar | header bar on GNOME/Wayland, server title bar elsewhere | header bar always |

```bash
flutter build linux --release                  # GTK3
FLUTTER_TOOLKIT=gtk4 flutter build linux       # GTK4
FLUTTER_EMBEDDER=/path/to/libflutter_linux_gtk4.so flutter build linux
```

The environment variable exists because `flutter build` forwards a fixed set of
CMake arguments and no way to add more. A `-DFLUTTER_TOOLKIT=` on a manual
CMake invocation wins over it, and the cached value is reused in between.

Two preflights stop a GTK4 build rather than producing a broken bundle:

- **The embedder.** `unpack_linux` copies one embedder into `linux/flutter/ephemeral/`,
  hard-coded to the GTK3 one, so a GTK4 build stages `libflutter_linux_gtk4.so`
  itself — from `FLUTTER_EMBEDDER` when one is given (a custom engine build, with
  its `flutter_linux/` headers picked up from beside it), otherwise from the
  engine's artifact cache. Stable has no such file, and the configure step says
  so by name rather than failing to link later.
- **The plugins.** Plugins carry their own CMakeLists, and `url_launcher_linux`
  still builds against GTK3. It would be handed a GTK4 `FlView` and call GTK3
  functions on that — and it inherits GTK4's include path through the `flutter`
  interface target, so it cannot even compile. The plugin list is therefore
  scanned and the build stops, with no override: the list is derived from the
  plugin symlinks rather than hard-coded, so the check stops firing by itself
  once those plugins port.

Nothing in Dart depends on the toolkit: the embedder API is identical from
Dart's side, and the plugins that matter on Linux are toolkit-free
(`file_picker_linux` goes through XDG portals). CI's **Configure Linux (GTK4)**
job holds the line on the preflights.

## Project structure

```
lib/
  main.dart, app.dart
  core/{platform_style.dart, providers.dart}
  core/{router,theme,models,utils}/…        # router/app_router.dart, theme/app_theme.dart, 15 models
  services/ytdlp/{binary_manager,ytdlp_service,progress_parser,bounded_capture,json_payload,arg_tokenizer,ejs_installer,redirect_policy,process_kill,asset_downloader}.dart
  services/downloads/{download_manager,download_layout,history_service,queue_store,folder_scanner,network_probe}.dart
  services/{cookies,settings}/…             # cookie jar + domains, settings service, templates, backup
  services/{updates,diagnostics,notifications,foreground,sharing}/…
  widgets/platform/…                        # 7 wrapper files, one widget family each
  widgets/{app_shell,startup_banner,tab_carousel}.dart
  features/{home,queue,library,settings,playlist}/…
assets/bin/
  android/<abi>/{python.tar.gz,ffmpeg,ffprobe}    # required on Android, committed
  linux/yt-dlp, macos/yt-dlp, windows/yt-dlp.exe   # desktop fallbacks, gitignored
tool/{fetch_binaries,fetch_android_runtime,fetch_ffmpeg_android}.sh
```

## Release identity

- **App ID** — `com.github.ytdlp` on every platform: `android/app/build.gradle.kts`, `linux/CMakeLists.txt`, `macos/Runner/Configs/AppInfo.xcconfig` and the `RunnerTests` bundle in `macos/Runner.xcodeproj`.
- **App label** — `YTDL`: `AndroidManifest.xml`, `macos/Runner/Info.plist`, `linux/runner/my_application.cc`, `windows/runner/main.cpp` and the `Runner.rc` version block.
- **Launcher icon** — adaptive icon, red background with a white download arrow.
- The on-disk binary/app name stays `ytdlp` on desktop (`BINARY_NAME`, `PRODUCT_NAME`) to match the `ytdlp.app` product reference in `Runner.xcodeproj`.

## Desktop sandbox (macOS)

macOS builds are sandboxed, so `macos/Runner/*.entitlements` must grant:

- `com.apple.security.network.client` — without it a Release build cannot connect to anything, so every fetch and download fails
- `com.apple.security.files.user-selected.read-write` — the download-folder picker and `cookies.txt` import both touch files outside the app container
- `DebugProfile.entitlements` additionally keeps `cs.allow-jit` and `network.server` for Flutter's debug VM service, and mirrors both entitlements above

CI builds macOS because these entitlements are not verifiable any other way.