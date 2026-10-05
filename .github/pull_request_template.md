## What this changes

<!-- One or two sentences. What does the user get that they did not have before? -->

## Why

<!-- The problem, not the solution. Link the issue if there is one. -->

## How it was verified

<!-- Be specific: which platforms, and whether a real download ran end to end.
     CI runs format + analyze --fatal-infos + flutter test, but say what you
     ran yourself. -->

- [ ] `dart format --output=none --set-exit-if-changed .`
- [ ] `flutter analyze --fatal-infos`
- [ ] `flutter test`
- [ ] Real download run end to end (say which platform, audio/video, quality)

## Checklist

- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] `README.md` updated, if this is user-visible (the README documents
      behaviour in detail and is the spec)
- [ ] Tests added or updated for the changed code
- [ ] No user input reaches a shell — extra flags go through the argument
      tokenizer, not a shell string

## Engine contract

Tick if this touches any of these, because that is where a regression is hardest
to notice:

- [ ] Arguments passed to `yt-dlp`
- [ ] The staging directory / finalise-and-move path
- [ ] How the finished media file is identified (extension matching)
- [ ] Nothing in this area — N/A