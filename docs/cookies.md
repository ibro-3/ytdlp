# Cookies

Some sites — YouTube in particular — refuse anonymous requests, showing "Sign in to confirm you're not a bot" or limiting formats. Two routes exist: a `cookies.txt` jar, and on desktop the browser login you already have.

Cookie *values* are treated as credentials everywhere — never logged, never in diagnostics, never printed by the parser, and never in the parser's equality or hashing. Diagnostics report switched-off **hosts** (already present in your cookie file, your download URLs and any yt-dlp error) and never a value.

## `cookies.txt` import

Settings → **Cookies** imports a Netscape-format file. It is copied into the app's support directory and handed to yt-dlp via `--cookies`.

- The import **validates structurally**: the file must parse to at least one real cookie, so an HTML error page saved as `cookies.txt` is rejected at the picker rather than failing every download later.
- The file is written **owner-only** (mode `0600` where the platform has such a mode).

### Per-site control

A browser export carries every site you happen to be logged into, not just the one yt-dlp needs. **Choose which sites are sent** lists every host in the jar with its cookie count and lifetime — session-only, dated, or already expired — and lets you switch each off individually.

yt-dlp has no per-site flag, so a switch works by writing a **narrower** jar: the import is kept intact next to the file yt-dlp reads, which is what makes a switch reversible without going back to the browser. Subdomains stay their own row rather than being folded into the parent, so a switch always tells the truth about exactly which host it governs.

Two consequences are stated in the UI rather than left to be discovered: how many cookies are currently being withheld, and — because a withheld site is indistinguishable from an expired one when a download fails — what switching a site off actually does. Switching *every* site off is refused outright instead of writing an empty jar, which would otherwise break every download with an untraceable 403.

### Concurrent writes

yt-dlp writes cookies back to the file it is given, so two simultaneous downloads sharing one jar can interleave those writes and truncate it. Unlike `--download-archive`, this is left alone deliberately: the only real fix is a per-task copy of the jar, which would silently discard the refreshed tokens yt-dlp writes back, and losing a session refresh is worse than a rare truncation. Worth doing properly, with a merge-back step.

## Browser cookies (desktop)

Settings → **Browser cookies** points yt-dlp at the browser login you already have via `--cookies-from-browser`, so there is no jar to export, copy or refresh. yt-dlp decrypts the store itself; the app never handles a cookie value from a browser.

- A **profile folder** picker lists the profiles inside the folder you choose — the ones holding a cookie store, for Chromium and Firefox layouts alike — and yt-dlp is given the profile *by name*, never by path: yt-dlp splits its browser specification on `:`, so a Windows path would parse as a different browser entirely. Leaving the profile alone asks yt-dlp for the browser's own default.
- A value that *looks* like a path — one beginning with a separator — is refused and the reason shown, since yt-dlp reads such an argument as an absolute path. That check runs where the argument is built, not only where it is typed, because a restored backup writes a profile straight into the settings box. A refused profile falls back to the browser's own default.

Three things this deliberately does not do quietly:

- **It does not combine sources.** yt-dlp will accept `--cookies` *and* `--cookies-from-browser` and merge them, at which point a site you switched off would go out from the browser's copy anyway. The app passes at most one, so a chosen browser sets the imported jar aside and says so, and the per-site page carries a banner saying its switches are not in effect until the browser is turned off.
- **It does not hide itself on Android.** Android sandboxes app storage per app and gives an app no access to any browser's cookie store, so the control is disabled with that stated rather than omitted. The `cookies.txt` import is the route there.
- **It does not pretend Safari is cross-platform.** yt-dlp can only read Safari's cookies on macOS; picking it elsewhere shows why.

Diagnostics report the browser and profile *name* — both already visible in your own browser UI — and never the profile folder.