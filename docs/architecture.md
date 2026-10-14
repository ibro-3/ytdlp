# Architecture

## Stack

- **State** — `flutter_riverpod` 3.x (`NotifierProvider` for Home, `Provider` for services). Long-lived services are `ChangeNotifier`s exposed through a plain `Provider` and consumed with `AnimatedBuilder`. Anything that must follow a settings change listens to `settingsControllerProvider` rather than the settings *service*, which yields one always-equal instance and would never notify.
- **Routing** — `go_router` 18 (`StatefulShellRoute.indexedStack`) with an `errorBuilder`, so a deep link the app has no route for says so in the app rather than in the framework's error page.
- **Theme** — one `ColorScheme.fromSeed(seedColor: red)` drives all three families (`core/theme/app_theme.dart`), plus the Material `CardThemeData`/`NavigationBar`/`SearchBar` chrome. Theme mode and seed colour are Settings; the *style* is not a setting.
- **Platform UI** — `core/platform_style.dart` resolves the family from `defaultTargetPlatform`, `widgets/platform/platform_app.dart` picks the root (`MaterialApp.router` / `CupertinoApp.router` / `FluentApp.router`), and every screen is built from the wrappers in `widgets/platform/` (`AppScaffold`, `AppButton`, `AppSwitchTile`, `AppSegmented`, `AppListTile`, `AppSection`, `showAppConfirm`, `showAppToast`, …). Under all three roots the Material `Theme` and all three `Global*Localizations` are still installed. The Material path is the default on every test, so the suite still covers it; `test/app_style_smoke_test.dart` walks each tab under macOS and Windows overrides.
- **Storage** — `hive` + `path_provider`. Three boxes: `history` (library), `settings`, `queue` (task snapshots for restart recovery). Each is opened independently at start-up and a failure is reported in the app rather than thrown, so one unusable store costs the user that feature instead of the whole app. Every reader treats a corrupt record as absent rather than crashing.
- **Notifications** — `flutter_local_notifications`, `downloads` channel on Android, `LinuxNotificationDetails`, `DarwinNotificationDetails`. Permission is only requested when the Settings toggle is switched on, never at first launch. Progress is throttled to percent-change + 2s; completion/failure alerts honour the toggle. macOS progress updates are shown without an alert, since it has no progress bar.
- **Background downloads (Android)** — `flutter_foreground_task` runs a `dataSync` foreground service for as long as the queue is non-empty. It starts with the first task, shows the active download's title and percentage, and stops once the queue drains. A wake lock is held while it runs, and notification updates are throttled to a changed percentage and at most one every 2s (`ForegroundServiceDidNotStartInTime`).
- **Share intake (Android)** — `receive_sharing_intent` catches `ACTION_SEND` text/plain intents. A shared URL is extracted with the same `extractUrl` used for the clipboard, so "check this out https://…" works.

## Download layout

The download root is `getDownloadsDirectory()` on desktop and the external app dir on Android, overridable in Settings. Downloads land in `Video/` or `Audio/` (`services/downloads/download_layout.dart`); playlist entries group one folder deeper, under the sanitized playlist title.

The app moves a finished file from staging itself rather than letting yt-dlp write it to a final path, so it sanitizes that folder name itself (`sanitizeFolderName`) — path separators, control characters and Windows-reserved device names included.

## Engine resolution

`BinaryManager` locates `yt-dlp` in this order:

1. system `PATH` (`which`/`where`, desktop only)
2. bundled `assets/bin/<platform>/yt-dlp` (per-ABI on Android)
3. desktop only: auto-download the official single-file build from GitHub releases into the app support dir

The desktop builds in `assets/bin/` are **not** registered in `pubspec.yaml`: `flutter.assets` has no per-platform scoping, so declaring them would package ~56 MB of desktop binaries into every Android APK. Desktop falls through to the auto-download instead. `test/models/android_runtime_test.dart` fails if that ever changes.

`ytdlpVersion()` / `updateYtdlp()` power the Settings update:

- system installs use `yt-dlp -U`
- app-managed desktop copies re-download the official build
- on Android the button replaces the yt-dlp script inside the extracted CPython runtime with the official standalone release — downloaded to a temp file and verified by running `--version` with the runtime's own interpreter before it replaces the working script

A download whose body is implausibly small for a yt-dlp build (an error page or a captive portal served with a 200) is refused, the bytes are checked against the SHA-256 GitHub publishes in the same release's `SHA2-256SUMS` before anything is made executable, and redirects are followed by hand against a pinned host allowlist (`github.com` and its release CDNs) rather than by `HttpClient`'s own handling. Copies land in the app support dir with mode `755`.

`ffmpeg` is preferred from `PATH`; without it, the app requests combined formats only (`b[ext=mp4][acodec!=none]/b[acodec!=none]`).

## Project structure

```
lib/
  main.dart, app.dart
  core/theme/{app_theme,app_theme_context}.dart
  core/platform_style.dart
  core/router/app_router.dart
  core/providers.dart
  core/models/{video_info,download_task,download_record,download_options,settings_model,playlist_info,playlist_paging,collection_kind,output_template,command_template,yt_prefs,youtube_prefs,library_filter,cookie_model,cookie_profiles,cookie_browser}.dart
  core/utils/{url_validator,formatters,json_utils}.dart
  services/ytdlp/{binary_manager,ytdlp_service,progress_parser,bounded_capture,json_payload,arg_tokenizer,ejs_installer,redirect_policy,process_kill,asset_downloader}.dart
  services/downloads/{download_manager,download_layout,history_service,queue_store,folder_scanner,network_probe}.dart
  services/cookies/{cookie_jar,cookie_jar_service,cookie_domains,cookie_model}.dart
  services/settings/{settings_service,template_store,backup_service}.dart
  services/updates/app_update_service.dart
  services/diagnostics/diagnostics_service.dart
  services/notifications/notification_service.dart
  services/foreground/foreground_service.dart
  services/sharing/share_intent_service.dart
  widgets/{app_shell,platform}.dart
  widgets/platform/{platform_app,platform_scaffold,platform_content,platform_controls,platform_inputs,platform_feedback,platform_toast}.dart
  widgets/startup_banner.dart
  widgets/tab_carousel.dart
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

## Release identity

- **App ID** — `com.github.ytdlp` on every platform: `android/app/build.gradle.kts`, `linux/CMakeLists.txt` (`APPLICATION_ID`), `macos/Runner/Configs/AppInfo.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`) and the `RunnerTests` bundle in `macos/Runner.xcodeproj`.
- **App label** — `YTDL`: `AndroidManifest.xml` on Android, `CFBundleDisplayName`/`CFBundleName` in `macos/Runner/Info.plist`, the GTK header-bar title in `linux/runner/my_application.cc`, and the window title in `windows/runner/main.cpp` plus the `Runner.rc` version block.
- **Launcher icon** — adaptive icon with red background and a white download arrow.
- The on-disk binary/app name stays `ytdlp` on desktop (`BINARY_NAME`, `PRODUCT_NAME`) to match the `ytdlp.app` product reference in `Runner.xcodeproj`; only the user-facing label is `YTDL`.

## Desktop sandbox (macOS)

macOS builds are sandboxed, so `macos/Runner/*.entitlements` must grant:

- `com.apple.security.network.client` — without it a Release build cannot resolve or connect to anything, so every metadata fetch and download fails
- `com.apple.security.files.user-selected.read-write` — the download-folder picker and `cookies.txt` import both touch files outside the app container
- `DebugProfile.entitlements` additionally keeps `cs.allow-jit` and `network.server` for Flutter's debug VM service, and mirrors both entitlements above so a debug build behaves like a Release one

CI builds macOS because these entitlements are not verifiable any other way.