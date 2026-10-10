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
- **Per-link removal in the batch queue** — the only action was "clear the
  list", so one bad link in a pasted batch cost the user every good one
  alongside it.
- **Start-up failures are reported instead of being fatal** — anything thrown
  before the first frame (a store that will not open, notifications that will
  not initialise) killed the app with a blank screen and nothing to explain
  it. Each step is now attempted on its own and any failure is described in
  the app, which stays usable.
- **A failed folder scan says so** — an unreadable download folder and an
  empty one looked identical, with no way to tell that anything went wrong.

### Changed

- **CI** now builds release APKs split per ABI, plus Linux, Windows and
  macOS bundles, and uploads a coverage report. The Android release
  workflow signs with a keystore from secrets when provided.
- **macOS is built on every pull request**, not only for releases. Its
  sandbox entitlements are not verifiable any other way, which is how a
  release shipped with no network at all.
- **The desktop yt-dlp binaries are no longer committed.** They were ~56 MB
  that the app never packaged and does not need — `BinaryManager` prefers a
  system install and otherwise downloads the official build — so they are
  gitignored and `tool/fetch_binaries.sh` verifies that what it fetches
  actually runs. The Android runtime and ffmpeg remain committed, because
  those are packaged into the APK.
- **The one networked test is tagged** and excluded from CI, keeping the
  documented promise that the suite needs no network.
- **iOS and web scaffolds removed** — there was no engine for either, so
  they were present-but-broken rather than supported.

### Security

- **Cookie jars are written owner-only.** Both files are session credentials
  and were created world-readable on desktop.
- **An output template can no longer climb out of the download folder.** `..`
  in a template made yt-dlp write the finished file anywhere on the
  filesystem — somewhere the app neither reported nor cleaned up.
- **A path is refused where a browser profile name belongs.** yt-dlp reads a
  profile argument beginning with a separator as an absolute path, so a
  hand-edited settings box could aim the cookie read anywhere. The check that
  was meant to catch this always returned "fine", leaving the explanatory UI
  unreachable.
- **That check now runs where the argument is built, not where it is typed.**
  The profile reaches yt-dlp by routes the picker never sees — a restored
  backup writes it straight into the settings box, and it is read back as a
  bare string — so validating it in the UI guarded nothing. The settings screen
  had been telling users "yt-dlp was not pointed at it" while the app pointed
  yt-dlp at it anyway, which is worse than saying nothing. `cookieBrowserSpec`
  now drops a path-shaped profile and falls back to the browser's own default
  profile, and the module's claim that it "deliberately refuses nothing" is
  gone from the docs with it.
- **Credentials are masked in the diagnostics report, not merely truncated.**
  `--password`, `--username` and `--add-header 'Authorization: …'` hold a
  credential, and a truncation cap does nothing about one — almost every
  password and bearer token is shorter than any cap worth having. The helper's
  own comment promised masking and performed only shortening, so those values
  went verbatim into a report that is copied to the clipboard and written to
  the system temp directory on its way to a public tracker. The flag name is
  kept, because "a password is configured" is exactly what a failing login
  needs a report to say. The download folder is collapsed to its last two
  components rather than truncated, for the same reason: `/home/ich/Videos` is
  short enough to survive any length cap and still names the account.
- **Dismissing a task no longer deletes an arbitrary directory.** The staging
  path comes back from the queue snapshot; the resume path already refused one
  outside the staging root but the destructive paths did not.
- **The JavaScript-runtime installer keeps its backup until it has verified
  the install**, so a rejected package restores the previous one instead of
  throwing a filesystem error and leaving nothing. Concurrent installs are
  serialised rather than racing over one staging directory.

### Fixed

- **Library rows kept claiming a deleted file was present.** The existence
  probe recorded every path it had ever checked and never cleared the set, so
  the first answer stood for the life of the process. A file removed from
  outside the app — a file manager, another app, a computer over MTP — kept
  showing as there, and tapping Open on it then failed. The answer is now
  re-taken when the app returns to the foreground and when a scanned file is
  adopted, and the probe runs in one pass for the whole view.
- **Opening the library rebuilt the whole list once per row.** The probe
  spawned a `File.exists` and a `setState` for every row from inside `build`,
  so the first frame of a large library caused that many full list rebuilds.
  Answers are now collected and applied in a single `setState`, and the list is
  a `ListView.builder`, so only the rows on screen are built — with their
  thumbnails, which the previous shape fetched for every row at once.
- **Queue state was not persisted while a download ran** — the snapshot write
  was debounced, and the debounce restarted on every yt-dlp output line.
  Progress arrives many times a second, so the timer never fired for the whole
  duration of a download and the queue snapshot that exists to survive the app
  being killed was never written. Writes are now throttled rather than
  debounced, and every visible transition — enqueue, cancel, hold, retry,
  completion, removal — is written straight away.
- **Reordering dated finished downloads to 1970** — moving a waiting task
  re-stamped its creation time to a microsecond after the epoch, and that value
  is what reaches the library. Queue position now lives in its own field, so a
  reordered download keeps its real date. Reordering also stopped sinking the
  waiting tasks below the finished ones.
- **Two downloads resolving to one filename could destroy each other** — the
  final name was chosen by checking for a collision and then renaming, with
  nothing held across the gap. Concurrent downloads finishing together both saw
  the name as free, and `rename` deletes an existing destination, so one
  finished file was silently overwritten and both tasks reported the same path.
  A move that crosses a filesystem boundary — an SD card, a removable volume —
  also failed outright and discarded a complete download; it now falls back to
  copy-then-delete.
- **yt-dlp responses were intermittently read truncated** — the stdout and
  stderr subscriptions were cancelled the moment the exit status arrived,
  discarding bytes the pipes had not yet delivered. Anything past the pipe
  buffer was lost, which showed up as an intermittent "response the app could
  not read" and, for a large playlist, an intermittent failure to recognise the
  output as a playlist.
- **Cancelling left the download process unreaped** — the run loop returned
  without waiting for the child, then dropped the only handle on it. yt-dlp
  handles SIGTERM by finishing the fragment it is on, and its `ffmpeg`
  children never see the signal at all, so a cancelled or held download could
  keep writing into a staging directory the UI had already deleted. Cancellation
  now escalates to SIGKILL and the child is waited for; a hold that could never
  complete — which left the task `downloading` and stalled the whole queue — is
  no longer possible.
- **Retrying a batch item stranded the rest of the batch** — retrying one
  failed link invalidated the resolve-all run, so every item after it stayed
  `loading` with no fetch in flight: a spinner nothing would ever resolve.
- **The post-processing switches flickered while typing** — the ffmpeg/ffprobe
  capability check ran as a future created inside a builder, so every keystroke
  anywhere in Settings restarted it and dropped the answer back to
  "unavailable". It is resolved once per session, and says "checking" rather
  than claiming ffmpeg is missing before it has looked.
- **Restoring a settings backup did not change the running app** — the restore
  rewrote the stored settings but nothing re-read them, so the theme and
  download defaults stayed as they were until the next launch, right after the
  UI said "Settings restored".
- **A changed concurrency limit needed a restart** — the download manager
  listened to the settings *service*, which always yields the same instance, so
  the listener never fired. It now follows the settings state.
- **A corrupt history record could stop the app from starting** — one
  unreadable entry in the box threw while the library loaded. The other readers
  already skipped such an entry; this one now does too.
- **A dismissed library row could throw** — the "does this file still exist?"
  check handled its own after-dispose case by returning nothing from a
  `Future<bool>` error handler, which is itself a type error.
- **An unknown sort or group option could crash the library tab** — the value
  was looked up by name and threw on a miss. Names that disagree can only come
  from a persisted setting written by a different build.
- **The remembered-queue-size dropdown could assert** — a restored or
  hand-edited value between the offered steps matched no item. It now snaps to
  the nearest offered one instead.
- **`--sleep-requests` was not clamped when edited** — a large number typed
  into Settings reached the command line until the app restarted and read it
  back clamped.
- **A library sort/filter menu value could throw**, as above; and the queue
  overflow menu opened empty when there was nothing to clear or cancel.
- **The scheduler could raise `ConcurrentModificationError`** — it iterated the
  live task list while notifying listeners, so a listener that dismissed a card
  mid-pump mutated the list being iterated.
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