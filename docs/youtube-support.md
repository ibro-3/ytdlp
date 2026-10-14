# YouTube support

YouTube serves different format lists to different "player clients", and increasingly gates the good ones behind a proof-of-origin token that yt-dlp can only obtain by running JavaScript. Two controls live in Settings → **Advanced → YouTube**.

## JavaScript runtime

Installs `yt-dlp-ejs` into the bundled CPython runtime's `site-packages`.

The install is **verified before it commits, twice over**: the downloaded bytes are compared against the SHA-256 PyPI published for that wheel before anything is unpacked (a manifest carrying no digest is refused), and the staged package is then imported by the bundled interpreter.

- Requests may only reach `pypi.org` and `files.pythonhosted.org` over HTTPS, and are never auto-redirected — `HttpClient` follows redirects on its own, and a redirect of the *manifest* request would hand whoever controlled it the download URL and the expected checksum together.
- What this does **not** detect is a compromised PyPI account publishing a new wheel under the same version.
- The package is unpacked to a staging directory, rejected if it contains a link or a path escaping it, and **imported from staging before the installed copy is touched**, so the engine is never left without its runtime. Anything that does not import is removed and the previous copy restored; the backup is kept until verification has passed. Installs and uninstalls are serialised, since they share one staging directory.
- The section reports the real state (`installed` / `not installed` / `installed but not working`) rather than claiming a capability it cannot check.

The `yt-dlp-ejs` version is **pinned** alongside the bundled yt-dlp version rather than tracking "latest", so an install is reproducible and a bad upstream release cannot break every user's downloads. The wheel's checksum comes from PyPI rather than being hard-coded here.

On desktop installs the runtime is not managed, because a system yt-dlp picks up a system-installed `yt-dlp-ejs` on its own; the section reports that rather than pretending to install something.

## Extra player clients

Passes `--extractor-args youtube:player_client=web,…` for the clients you tick. `web` is always included and is yt-dlp's default, so the flag is only sent when you have actually added one. The app's value is emitted *after* any raw `--extractor-args` in the extra-args field, because yt-dlp lets the last occurrence win.

## What this does not do

- It does not bundle a JS engine (Deno, ~30–40 MB per ABI) inside the APK. An in-process engine would need an NDK build like the CPython runtime.
- It does not bypass account-level bot checks — those still need cookies (see [cookies.md](cookies.md)).

## Known limitation

yt-dlp also wants a **PO token** for full YouTube support. Cookies fix the *authentication* half; the JS runtime addresses the *PO token* half. Until both are in place, if YouTube downloads fail while other sites work, that is the cause.