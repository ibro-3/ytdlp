# Cookies

Some sites — YouTube in particular — refuse anonymous requests, showing "Sign in to confirm you're not a bot" or limiting formats.

Cookie *values* are treated as credentials everywhere — never logged, never in diagnostics, never printed by the parser, and never in the parser's equality or hashing. Diagnostics report switched-off **hosts** (already present in your cookie file, your download URLs and any yt-dlp error) and never a value.

## `cookies.txt` import

Settings → **Cookies** imports a Netscape-format file, copies it into the app's support directory and hands it to yt-dlp via `--cookies`.

- The import **validates structurally**: the file must parse to at least one real cookie, so an HTML error page saved as `cookies.txt` is rejected at the picker.
- The file is written **owner-only** (mode `0600` where the platform has such a mode).

### Per-site control

A browser export carries every site you happen to be logged into. **Choose which sites are sent** lists every host in the jar with its cookie count and lifetime — session-only, dated, or expired — and switches individual hosts off. yt-dlp has no per-site flag, so a switch works by writing a **narrower** jar: the import is kept intact next to the file yt-dlp reads, which makes a switch reversible. Subdomains stay their own row rather than being folded into the parent.

The UI states how many cookies are withheld, and that a withheld site is indistinguishable from an expired one when a download fails. Switching *every* site off is refused outright rather than writing an empty jar.

### Concurrent writes

yt-dlp writes cookies back to the file it is given, so two simultaneous downloads sharing one jar can interleave those writes and truncate it. Unlike `--download-archive`, this is left alone deliberately: the only real fix is a per-task copy, which would discard the refreshed tokens yt-dlp writes back. Worth doing properly, with a merge-back step.

## Browser cookies (desktop)

Settings → **Browser cookies** points yt-dlp at the browser login you already have via `--cookies-from-browser`. yt-dlp decrypts the store itself; the app never handles a cookie value from a browser.

- A **profile folder** picker lists the profiles holding a cookie store, for Chromium and Firefox layouts alike, and yt-dlp is given the profile *by name*, never by path: yt-dlp splits its browser specification on `:`, so a Windows path would parse as a different browser entirely. Blank asks for the browser's default.
- A value that *looks* like a path — one beginning with a separator — is refused and the reason shown. The check runs where the argument is built, not only where it is typed, because a restored backup writes a profile straight into the settings box.

Three things this deliberately does not do quietly:

- **It does not combine sources.** yt-dlp will accept `--cookies` *and* `--cookies-from-browser` and merge them, so a chosen browser sets the imported jar aside and says so, and the per-site page banners that its switches are not in effect until the browser is turned off.
- **It does not hide itself on Android** — the platform exposes no browser cookie store, so the control is disabled with that stated. The `cookies.txt` import is the route there.
- **It does not pretend Safari is cross-platform** — yt-dlp can only read Safari's cookies on macOS; picking it elsewhere shows why.

Diagnostics report the browser and profile *name* — both already visible in your own browser UI — and never the profile folder.