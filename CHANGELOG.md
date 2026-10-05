# Changelog

All notable changes to YTDL are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project uses [semantic versioning](https://semver.org/spec/v2.0.0.html).
The version is defined once, in `pubspec.yaml`, and the headings below match it.

## [Unreleased]

### Added

- **App update check** — Settings now reports whether a newer YTDL
  release is on GitHub, with a link to it. A check that cannot reach
  the server, or a build whose own version is unknown, says so rather
  than claiming to be current.
- **Retry controls** — `--retries` and `--fragment-retries` are
  first-class Settings controls (clamped to 0–20) instead of hard-coded
  constants. A raw `--retries` in the extra-arguments field still wins,
  because yt-dlp lets the last occurrence of a flag take effect.
- **Unmetered-connections-only** — new downloads wait for Wi-Fi or
  Ethernet when enabled. The rule applies to *starting* work, so a
  download already running is never interrupted when the network
  changes; a held queue starts as soon as the connection allows.
- **Cookie-jar parser** — `lib/services/cookies/` reads and writes the
  Netscape format that browsers and yt-dlp share, so a jar can be
  inspected, filtered and re-saved without going through yt-dlp. Cookie
  values are treated as credentials throughout: nothing in the parser
  prints one, and none appear in equality, hashing or diagnostics.
- **Per-site cookie management** — a **Choose which sites are sent** page
  lists every host in the imported jar with its cookie count and lifetime,
  and lets each be switched off individually. yt-dlp has no per-site flag,
  so a switch works by writing a narrower jar: the import is kept intact
  alongside the generated file yt-dlp reads, which makes a switch
  reversible without a fresh browser export. Because an omitted site is
  indistinguishable from an expired one when a download fails, the page
  states the omission and how many cookies are withheld, and refuses to
  write an empty jar rather than breaking every download quietly. The
  diagnostics report gains the switched-off host *names* — never values.
- **Browser cookies (desktop)** — yt-dlp can now read the login you
  already have in a browser via `--cookies-from-browser`, so a
  `cookies.txt` no longer has to be exported by hand and re-exported
  whenever the login expires. A profile-folder picker lists the profiles
  inside the folder you choose and passes the profile to yt-dlp **by
  name** — never by path, because yt-dlp splits its browser
  specification on `:` and a Windows path would parse as a different
  browser with no way to escape it. Two sources are never combined:
  yt-dlp would merge a `--cookies` jar with a browser store and a site
  switched off in the per-site page would then go out from the browser
  anyway, so the app passes at most one and says which. Withholding
  nothing is still stated — the per-site page and the diagnostics report
  both say when stored switches are not in effect. The control is
  disabled on Android with the reason given, rather than omitted, because
  the platform grants apps no access to any browser's cookie store.
- **Channel and handle links** — a `@handle`, `/channel/…`, `/c/…` or
  `/user/…` link is now recognised as a channel rather than a generic
  playlist, and gets its own card, title and **Download everything**
  shortcut. Detection reads the link the user pasted, not the payload:
  yt-dlp reports a channel's uploads tab as a `/playlist?list=UU…` URL, so
  trusting the payload would call every channel a playlist.
- **Paged channel listings** — a collection too large for one response is
  listed 200 entries at a time, with **Load more** in the picker. The
  picker says how much is actually shown (`Showing the first 200 of 5,000`)
  whenever it is not showing everything, and invents no total when the
  site reports none. This replaces the previous behaviour, where a channel
  with more entries than the metadata byte budget could hold simply failed
  to list. Selection and the pages already fetched survive a tab switch.
  The **Load more** offer is withdrawn once a page comes back empty or
  short, so it cannot re-request a page the site has no entries for.

### Changed

- **CI** now builds release APKs split per ABI, plus Linux, Windows and
  macOS bundles, and uploads a coverage report. The Android release
  workflow signs with a keystore from secrets when provided.
- **iOS and web scaffolds removed** — there was no engine for either, so
  they were present-but-broken rather than supported.

### Fixed

- **Library search** — the search field never filtered the library: the
  query was built but not passed to the view. It now filters live.
- **Cookie file validation** — the picker accepted anything with a
  `# Netscape HTTP Cookie File` header, so an HTML error page saved as
  `cookies.txt` was accepted and then failed every download with a yt-dlp
  parse error. A file must now parse to at least one real cookie.

## [1.0.0] — 2026-09-30

First tagged release. Everything below landed on `main` between 2026-09-22 and
2026-09-30.

### Added

- **Android engine** — a self-contained CPython 3.14 + yt-dlp runtime assembled
  from official Termux packages, plus a minimal static `ffmpeg`/`ffprobe`
  cross-compiled with the NDK for DASH merges and postprocessing.
- **Resumable downloads** — a failed or interrupted download keeps its staging
  directory and `.part` file, so Retry continues instead of re-fetching. Engine
  flags add `--continue`, `--retries 10`, `--fragment-retries 10` and a capped
  `--retry-sleep linear=1:5:2` backoff.
- **Queue persistence** — the queue is snapshotted to Hive (including each
  task's subtitle options). Work interrupted by a killed process returns as
  *failed* with its partial intact, and orphaned staging directories are cleaned
  up on startup.
- **Cookies** — `cookies.txt` import, copied into the app support directory and
  passed via `--cookies`. Credentials are never parsed or logged.
- **One-tap yt-dlp update** — system installs via `yt-dlp -U`; app-managed copies
  and the Android runtime refresh from the official release, verified by running
  `--version` before the working script is replaced.
- **Foreground service (Android)** — a `dataSync` foreground service keeps
  downloads alive when the app is backgrounded, with a wake lock and throttled
  notification updates.
- **Share-sheet intake (Android)** — `ACTION_SEND` text intents are captured, so
  a URL shared from another app lands on the Download tab. Cold-start payloads
  are buffered and consumed with `reset()`.
- **Playlist downloads** — playlist links are recognised and re-fetched with
  `--flat-playlist`; a picker lists every entry with thumbnail, duration, a text
  filter, select-all/clear and per-batch quality + subtitle options. Each
  selected entry becomes its own queue task and lands in a folder named after
  the playlist.
- **Advanced settings** — extra yt-dlp flags (shell-word-split but never passed
  through a shell, with the app's own flags detected and reported as ignored),
  a live-previewed output template that must resolve to an extension, and saved
  named argument templates.
- **YouTube support** — a verified `yt-dlp-ejs` installer (staged, validated
  against symlink/traversal, swapped in, then imported by the bundled
  interpreter, and removed again if it does not import) plus player-client
  selection.
- **yt-dlp capability controls** — fragment parallelism (capped at 4), rate
  limit, request delay, proxy, `Referer`, audio extraction + container, remux,
  embedded metadata/chapters, SponsorBlock, livestream-from-start, download
  archive and `--no-part`. Postprocessing is dropped without ffmpeg + ffprobe
  rather than passed through to fail after the bytes are downloaded.
- **Queue controls** — configurable concurrency, per-task hold alongside the
  queue-wide pause, cancel-all, clear-finished, move-earlier/later reordering,
  and a remembered queue size.
- **Library** — Hive-backed history with search, sort (newest/oldest/largest/
  title), an all/video/audio filter, and optional grouping by playlist. A folder
  scan finds media with no history record and offers to adopt it explicitly.
- **Batch URL queueing** — text with several URLs opens a batch page where each
  link resolves independently, so one unavailable video does not fail the rest.
- **Settings backup / restore** and **Copy diagnostics** (versions, paths and
  settings as plain text; cookies are never included, only whether one is
  configured).
- **Release identity** — app id `com.github.ytdlp`, label `YTDL`, an adaptive
  launcher icon, and real-keystore signing for releases.
- **macOS sandbox entitlements** — `network.client` and
  `files.user-selected.read-write`, mirrored into `DebugProfile.entitlements`.

### Changed

- **Cover art is derived, not a toggle** — an audio download embeds the
  thumbnail, a video download does not, and the thumbnail switches were removed
  rather than defaulted. A video file gains nothing from embedded cover art; an
  audio file looks broken in a music player without one.
- **Format and quality selection moved into a bottom sheet**, replacing the
  inline section on the Download tab. Audio quality is offered as named tiers
  resolved against the source's actual bitrates, with tiers that would deliver
  the same file hidden and every row showing the real container + kbps.
- **Metadata fetches are bounded and honest** — a 90s timeout with a 16 MB
  stdout budget and 64 KB stderr budget; oversize stdout kills the process and
  says what happened, rather than truncating a payload that then fails to
  parse. A chatty stderr never fails a successful fetch.
- **`OutputTemplate.identityFragment`** generalises the previous hard-coded
  `" [<id>]"` filename check, so templates without `%(id)s` are identified by
  title instead of reporting "output file not found".

### Fixed

- **macOS Release builds had no network at all** — `network.client` was missing
  from the entitlements, so every fetch and download failed in a Release build.
- **macOS notifications were inert** — no `DarwinInitializationSettings` was
  registered.
- **`ffprobe` detection hid the embed toggles** on every Android launch after
  the first, because the extraction marker only checked for `ffmpeg`.
- **`targetSdk = 28` and `compileSdk = 37`** — kept at 28 so the bundled CPython
  runtime stays executable under W^X (same approach as Termux), while `compileSdk`
  tracks what `receive_sharing_intent` and `flutter_foreground_task` need. This
  makes Android sideload/F-Droid only; the Play Store both requires a recent
  target SDK and forbids YouTube downloading.
- Async library I/O, permission-aware settings, and a stale-fetch guard on the
  Download tab.

[Unreleased]: https://github.com/ibro-3/ytdlp/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ibro-3/ytdlp/releases/tag/v1.0.0