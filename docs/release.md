# Release checklist

How a YTDL release is cut, verified and published. The release pipeline is
**tag-driven**: nothing but a `v*` tag (or a manual dispatch) triggers it, and
nothing publishes that does not come from this tree.

The single source of toolchain truth is **Flutter 3.50.0 / Dart 3.14** —
`pubspec.yaml` (`environment:`), every workflow, this document and the README
all pin the same thing. If they ever disagree, the tree is wrong, not the docs.

## 1. Pre-flight gate (any machine)

```bash
flutter --version                       # expect 3.50.0 / Dart 3.14.0
flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos           # must print: No issues found!
flutter test --exclude-tags network
```

The same gate runs as the `gate` job of `release.yml`, so a tag that would not
pass here fails there — but checking first costs nothing and saves a CI cycle.

## 2. Version and changelog

1. Set `version:` in `pubspec.yaml` (semver + build number), e.g. `1.0.0-rc.1+1`.
2. Move the `[Unreleased]` entries of `CHANGELOG.md` into a new
   `## [X.Y.Z] — YYYY-MM-DD` section, leave `[Unreleased]` empty, and update the
   compare links at the bottom.
3. The tag is the contract: `release.yml` refuses to build a tag whose version
   does not match `pubspec.yaml` (build suffix `+1` is ignored for the
   comparison).
4. Prerelease tags — anything containing `-`, e.g. `v1.0.0-rc.1` — publish as
   GitHub **pre-releases**. Tags without one publish as **latest**.

## 3. Device verification (before tagging anything user-facing)

Build the exact artifact to be shipped:

```bash
flutter build apk --release --split-per-abi --target-platform=android-arm64,android-x64
```

Install on all of:

- **API 29 emulator** (Android 10, the W^X boundary)
- **API 34 emulator** (Android 14)
- **A physical arm64 device**

and actually download a video on each. Verify, at minimum:

- A download starts, progresses, completes, and the file opens.
- Kill the app mid-download; on relaunch the partial is reported failed and
  Retry continues from the `.part` file rather than re-fetching.
- While downloading, `adb shell dumpsys activity services com.github.ytdlp`
  shows the `dataSync` foreground service holding a wake lock.
- The ongoing-download notification is a monochrome icon, not a blob.
- `adb shell dumpsys package com.github.ytdlp | grep versionName` reports the
  tagged version.

Desktop: build and launch the Linux, Windows and macOS bundles once each
(`flutter build linux|windows|macos --release`), start the app, and download one
video on each. macOS is unsigned — expect Gatekeeper; right-click → Open.
Windows is unsigned — expect SmartScreen; "More info" → "Run anyway".

## 4. Keystore and secrets contract

Release signing requires these repository secrets:

| Secret | Content |
| ------ | ------- |
| `ANDROID_KEYSTORE_B64` | `base64 -w0 ytdlp-release.keystore` |
| `ANDROID_STORE_PASSWORD` | keystore password |
| `ANDROID_KEY_PASSWORD` | key password |
| `ANDROID_KEY_ALIAS` | key alias (e.g. `ytdlp`) |

- `release.yml` decodes the keystore to `android/keystore.jks` — the gradle
  file resolves `storeFile` relative to the repository root — and writes
  `android/key.properties` (gitignored, as is `android/keystore.jks`).
- **Tag builds fail fast if `ANDROID_KEYSTORE_B64` is absent.** Manual
  `workflow_dispatch` builds may fall back to the debug key (CI smoke only),
  but every APK is then verified with `apksigner verify --print-certs` and a
  debug-signed artifact fails the workflow.
- Never commit the keystore or `key.properties`. Generate with:

  ```bash
  keytool -genkey -v -keystore ~/ytdlp-release.keystore -alias ytdlp \
    -keyalg RSA -keysize 2048 -validity 10000
  ```

## 5. Tag → workflow → verification

```bash
git tag -a v1.0.0-rc.1 -m "YTDL v1.0.0-rc.1"
git push origin v1.0.0-rc.1
gh run watch --exit-status   # or: gh run list --workflow release.yml
```

The workflow runs: `gate` → four build jobs (Android APKs, Linux, Windows,
macOS) → `release` (merges checksums, creates the GitHub release).

Verify before announcing anything:

- [ ] The release is marked **pre-release** for a `-` tag and carries the
      auto-generated notes.
- [ ] Assets attached: `app-arm64-v8a-release.apk`, `app-x86_64-release.apk`,
      `linux-release.tar.gz`, `windows-release.zip`, `macos-release.tar.gz`,
      `SHA256SUMS.txt`.
- [ ] Spot-check the checksums against your downloads:
      `sha256sum -c SHA256SUMS.txt`.
- [ ] Spot-check the APK signature on a downloaded artifact:
      `apksigner verify --print-certs app-arm64-v8a-release.apk` — the
      distinguished name must **not** contain `CN=Android Debug`.
- [ ] Install the APK fresh on an API 29 device/emulator, open Settings →
      **App version**: an rc install reports *Up to date*; a 0.1 or 1.0.0-rc.1
      install reports *Update available* pointing at the new rc. (A stable
      build is never offered a prerelease while a stable release exists.)

## 6. Hotfix rule

Never re-tag or force-push an existing release tag. If a published release is
broken:

1. Branch from the tag, fix, and land the fix on `main` via a normal PR.
2. Cut the next tag (`v1.0.0-rc.2` / `v1.0.0+1`) from `main`.
3. Only then verify and publish; delete nothing from the old release. A broken
   artifact that is already in the wild is edited by adding a note, not by
   removing the file silently.

## 7. Rollback

Every fix in this tree is an isolated commit; `git revert` restores any of
them. The Android `targetSdk` default is `28` and needs no rollback (the `33`
experiment failed on-device and is documented in `docs/android.md`). If an rc
regresses the update check, reverting the update-service commit restores the
previous comparison; if it regresses the release pipeline, re-run
`release.yml` from a dispatch to rebuild artifacts without tagging.

## 8. Deferred from this process

Deliberately **not** part of the release line: iOS/Web (dropped — no engine),
Play Store publication (policy-barred for this app), macOS notarization (the
release is unsigned; see README) and full localization. See *Deferred* in the
release plan / issue tracker.
