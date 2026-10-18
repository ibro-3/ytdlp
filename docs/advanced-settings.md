# Advanced settings

Settings → **Advanced** (collapsed by default) exposes the parts of yt-dlp the rest of the UI does not model.

It is a two-page carousel — **Flags** and **File name** — under a visible tab strip. The pages differ by roughly 3× in height and a `PageView` is unbounded vertically, so the height is measured from the pages themselves (each sits in a scroll view whose unbounded child's laid-out size is its real height). One save button below the carousel commits both pages, and the carousel is capped to the window height.

## Extra yt-dlp flags

Applied to every download and overridable per download.

- Text is split with a shell-*word-splitting* scanner (quotes and backslash escapes honoured) but **never passed through a shell**.
- Flags the app sets itself are reported as ignored rather than silently accepted: `-o`/`--output`, `-f`/`--format`, `--no-playlist`/`--yes-playlist`, `--ffmpeg-location`. User flags are inserted *before* the app's own group, since yt-dlp lets the last occurrence of a single-valued option win.
- An unterminated quote is a hard error that disables the Download button.
- `--exec` and `--config-location` are warned about rather than refused: both run arbitrary commands, but blocking them would refuse settings that exist in shipped backups.

## Output template (`-o`)

The file name, with a live preview.

- It must resolve to an extension (via `%(ext)s` or a literal one) — the manager identifies the media file by extension, telling a `.mkv` from a `.srt` sidecar or a `.part` leftover.
- A `%(playlist_title)s/` prefix is stripped from the *staging* template and applied when the finished file is moved.
- A template containing `..` is **refused** as a blocking error: yt-dlp resolves it against the staging directory and would write outside it.
- A template that can only produce the extension is called out in the UI, since every file then shares one name.

File identification goes through `OutputTemplate.identityFragment`: the id when the template has `%(id)s`, the title when it does not, and no filter when only the extension is available.

## Saved argument templates

Named flag sets in the settings box under their own key prefix (capped at 30, keyed by name so saving twice replaces). Editable and removable in Settings; not offered in the per-download format sheet.

## Backup and restore

One JSON file holding the preferences and every saved template.

- Restore is a snapshot, not a merge, so a template deleted before the backup stays deleted.
- A document from a newer app version is refused rather than partially applied, and an unrelated JSON file is rejected before the "replace settings?" prompt appears.
- A restore applies to the **running** app: theme, seed and download defaults change immediately.

## Copy diagnostics

Versions, paths and the relevant settings as plain text.

- Every probe is allowed to fail without losing the rest of the report.
- **Cookies are never included** — only whether one is configured.
- A credential in the extra-arguments or file-name field is **masked rather than truncated** (`--password <redacted>`), keeping the flag name, since those values are short and the report is destined for a public tracker.
- The download folder is collapsed to its last two components.

## yt-dlp capabilities

First-class controls for parallel fragments, rate limit, request delay, proxy, `Referer`, audio extraction + container, remux without re-encoding, embedded metadata/chapters, SponsorBlock removal, livestream-from-start, a download archive, and `--no-part`. Every one is *also* reachable as a raw flag, but these validate their own inputs.

- **Defaults change nothing** — fragment parallelism defaults to 1, yt-dlp's own `-N` default.
- **Fragment parallelism is capped at 4** — on a phone `-N 16` fails the download outright.
- **Postprocessing is dropped without ffmpeg+ffprobe.** Audio extraction, remux, metadata, chapters and SponsorBlock all probe with ffprobe. Without it the flags are omitted rather than passed through to fail after the bytes are downloaded, and the toggles are disabled with the reason shown. A conversion to a container that cannot hold the chosen extras drops that extra and says so.