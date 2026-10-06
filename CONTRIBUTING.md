# Contributing to YTDL

Thanks for taking the time. This file covers what the project expects from a
change and how to build and test it.

## Before you start

This is a Flutter app that drives a **bundled `yt-dlp` binary**, so a change can
be correct Dart and still be wrong for the engine underneath it. Two habits are
worth internalising:

- **Report what happened, not what was intended.** The codebase is deliberate
  about this: a failed fetch names the site response rather than saying
  "invalid JSON", an audio quality tier that would deliver the same file is
  hidden rather than shown, and a postprocessing step that needs ffprobe is
  disabled in the UI *with the reason shown* instead of being passed through to
  fail after the bytes are downloaded. Please keep that bar.
- **Never pass user input through a shell.** Extra yt-dlp flags are split with a
  shell-word-splitting scanner but handed to the process as an argument list.
  Anything that reintroduces a shell invocation is a security regression.

## Getting set up

```bash
flutter pub get
flutter analyze
flutter test
```

On desktop a system `yt-dlp` and `ffmpeg` on `PATH` are used, so no bundled
binary is needed for development. On Android the runtime and ffmpeg/ffprobe are
bundled — see *Bundling binaries* in the README if you need to rebuild them.

## Running the checks

CI runs exactly these, so they are the definition of "green":

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze --fatal-infos
flutter test
```

`--fatal-infos` means an analyzer *info* fails the build, not just warnings and
errors. Fix the lint rather than suppressing it; if a suppression is genuinely
right, say why in the code.

## Tests

- **Unit and widget tests** (`test/`) — must run fast and need no device **and no
  network**. If you touch a service, add or update its test. Services that talk
  to a platform plugin are written with an injectable seam (see `ProcessRunner`
  in `binary_manager.dart` and `EjsInstaller`) so they can be faked — follow
  that pattern rather than reaching for a global.

  A test that genuinely needs the internet must carry `tags: ['network']`, which
  is what keeps CI's `flutter test --exclude-tags network` hermetic. Run those
  deliberately with `flutter test --tags network`; a flake there is a bug in the
  test, not an excuse to un-tag it.
- **Integration test** (`integration_test/`) — boots the real app and needs a
  device or emulator plus network. It is deliberately *not* on every CI push
  because an emulator run costs about ten minutes; run it locally with
  `flutter test integration_test/app_test.dart -d <device>` or trigger the
  **Device test (Android)** workflow from the Actions tab.
- English UI strings are matched by some integration tests. If you change a
  string the test asserts on, update the test with it.

## Pull requests

- One logical change per PR. A refactor and a behaviour change in the same PR is
  hard to review.
- Say what you tested and how — which platforms, and whether a real download was
  run end to end.
- If you change anything user-visible, update the README. It documents behaviour
  in detail and **is** the spec; a feature that is not described there is not
  finished.
- Add a `CHANGELOG.md` entry under `[Unreleased]`. Match the existing wording:
  what the user now gets, and why it is honest rather than merely convenient.
- If the change touches the engine contract — arguments passed to yt-dlp, the
  staging/finalise path, file identification — say so explicitly, because that
  is where a silent regression would be hardest to notice.

## Reporting a bug

Please include the output of **Settings → Copy diagnostics**. It contains
versions, paths and the relevant settings, and it never includes cookies or any
credential. That one paste usually saves a round trip.

## Licence

By contributing you agree that your contribution is licensed under the
GNU General Public License v3 or later, the same terms as the project. See
`LICENSE` — note that the bundled yt-dlp and ffmpeg binaries carry their own
licences, which apply to them rather than to this source code.