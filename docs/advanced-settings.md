# Advanced settings

Settings → **Advanced** (collapsed by default) exposes the parts of yt-dlp the rest of the UI does not model.

It is a two-page carousel — **Flags** and **File name** — under a visible tab strip. A `PageView` is unbounded vertically and the two pages differ by roughly 3× in height, so the height is **measured from the pages themselves**: each page sits in a scroll view whose child is unbounded, so the child's laid-out size is its real height and the carousel takes the tallest. One save button sits below the carousel and commits both pages. Each page scrolls itself rather than dragging the whole settings list, and the carousel is capped to the window height so a short window cannot push that button far below the fold.

## Extra yt-dlp flags

Applied to every download and overridable per download.

- Text is split with a shell-*word-splitting* scanner (quotes and backslash escapes honoured) but **never passed through a shell**, so nothing in the field can chain a command.
- The flags the app sets itself are detected and reported as ignored rather than silently accepted: `-o`/`--output`, `-f`/`--format`, `--no-playlist`/`--yes-playlist` and `--ffmpeg-location`. This is enforced by *ordering* — user flags are inserted before the app's own group, because yt-dlp lets the last occurrence of a single-valued option win.
- An unterminated quote is a hard error that disables the Download button instead of being passed on half-closed.
- `--exec` and `--config-location` are warned about rather than refused: both make yt-dlp run arbitrary commands, but blocking them would refuse settings that exist in shipped backups.

## Output template (`-o`)

The file name, with a live preview.

- It must resolve to an extension (via `%(ext)s` or a literal one), because the manager decides which file is the media file by extension — a `.mkv` from a `.srt` sidecar or a `.part` leftover.
- A `%(playlist_title)s/` prefix is stripped from the *staging* template and applied when the finished file is moved, so playlist grouping still lands correctly.
- A template containing `..` is **refused** as a blocking error: yt-dlp resolves it against the staging directory, so it would write the finished file somewhere outside it.
- A template that can only produce the extension is called out in the UI, since every file then shares one name and a second download is renamed `"(1)"`.

File identification goes through `OutputTemplate.identityFragment`: it uses the id when the template has `%(id)s`, the title when it does not, and no filter at all when the template can only produce the extension.

## Saved argument templates

Named flag sets, stored in the settings box under their own key prefix (capped at 30, keyed by name so saving twice replaces). Editable and removable in Settings; not offered in the per-download format sheet, which carries no argument override at all.

## Backup and restore

One JSON file holding the preferences and every saved template.

- Restore is a snapshot, not a merge, so a template deleted before the backup stays deleted.
- A document from a newer app version is refused rather than partially applied, and an unrelated JSON file is rejected before the "replace settings?" prompt appears.
- A restore applies to the **running** app: theme, seed and download defaults change immediately.

## Copy diagnostics

Versions, paths and the relevant settings as plain text, ready to paste into a bug report.

- Every probe is allowed to fail without losing the rest of the report.
- **Cookies are never included** — only whether one is configured, since a path can contain a username.
- A credential in the extra-arguments or file-name field is **masked rather than truncated**: `--password x` is reported as `--password <redacted>`, because those values are usually shorter than any length cap would cut at. The flag name is kept.
- The download folder is collapsed to its last two components, for the same reason.

## yt-dlp capabilities

First-class controls for the flags most worth having a real UI for: parallel fragments, rate limit, request delay, proxy, `Referer`, audio extraction + container, remux without re-encoding, embedded metadata/chapters, SponsorBlock removal, livestream-from-start, a download archive, and `--no-part`. Every one is *also* reachable as a raw flag, but the controls validate their own inputs.

Three behaviours worth knowing:

- **Defaults change nothing.** Fragment parallelism defaults to 1, which is yt-dlp's own `-N` default.
- **Fragment parallelism is capped at 4.** The throughput gain above that is small and the memory cost is not; on a phone `-N 16` fails the download outright.
- **Postprocessing is dropped without ffmpeg+ffprobe.** Audio extraction, remux, metadata, chapters and SponsorBlock all run through yt-dlp's postprocessor, which probes with ffprobe. Without it the flags are omitted rather than passed through to fail after the bytes are downloaded, and the toggles are disabled in the UI with the reason shown. A conversion to a container that cannot hold the chosen extras (cover art in WAV, say) drops that extra and says so in the sheet.