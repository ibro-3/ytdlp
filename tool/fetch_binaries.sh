#!/usr/bin/env bash
# Fetches official yt-dlp desktop binaries into assets/bin/.
#
# Android: there is NO official standalone Android build (the GitHub Linux
# binary links glibc and will not run on Android/bionic). Cross-build
# yt-dlp against the NDK in CI and drop it in per-ABI folders, e.g.:
#   assets/bin/android/arm64-v8a/yt-dlp   (physical devices)
#   assets/bin/android/x86_64/yt-dlp      (Android Studio emulators)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/assets/bin"/{linux,macos,windows,android}

if [ -f "$ROOT/assets/bin/linux/yt-dlp" ] &&
   [ -f "$ROOT/assets/bin/macos/yt-dlp" ] &&
   [ -f "$ROOT/assets/bin/windows/yt-dlp.exe" ]; then
  echo "Desktop binaries already present. Delete them to re-fetch."
  exit 0
fi

echo "Fetching yt-dlp desktop binaries (official single-file builds)…"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$ROOT/assets/bin/linux/yt-dlp"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$ROOT/assets/bin/macos/yt-dlp"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -o "$ROOT/assets/bin/windows/yt-dlp.exe"
chmod +x "$ROOT/assets/bin/linux/yt-dlp" "$ROOT/assets/bin/macos/yt-dlp" 2>/dev/null || true
echo "Done. Desktop binaries placed in assets/bin/{linux,macos,windows}/"
echo "Add them to pubspec.yaml flutter.assets if you want them bundled."
echo ""
cat <<'EOF'
Android:
  Place a yt-dlp build for your ABI at:
    assets/bin/android/arm64-v8a/yt-dlp   (physical devices)
    assets/bin/android/x86_64/yt-dlp      (Android Studio emulators)
  then run: flutter clean && flutter run
  See README "Android notes" for distribution caveats.
EOF