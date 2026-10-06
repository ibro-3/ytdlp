#!/usr/bin/env bash
# Fetches official yt-dlp desktop binaries into assets/bin/{linux,macos,windows}/.
#
# These are a developer convenience only, and are not tracked in git: the app
# resolves a system install first and otherwise downloads the official build into
# its support directory at run time, so a fresh clone works without them. They
# are deliberately NOT registered in pubspec.yaml's `flutter.assets` — that has no
# per-platform scoping, so declaring them would pack ~56 MB into every Android
# APK. `test/models/android_runtime_test.dart` fails if that ever changes.
#
# Desktop only: the official GitHub Linux binary links glibc and will not run
# on Android/bionic, so Android uses a bundled CPython runtime instead:
#   tool/fetch_android_runtime.sh   (terminux-style runtime + yt-dlp per ABI)
#   tool/fetch_ffmpeg_android.sh    (minimal static ffmpeg for DASH merges)
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

# Verify each one actually runs before it is trusted. A truncated download or an
# HTML error page saved under the name `yt-dlp` would otherwise sit there looking
# like a working binary until a download mysteriously failed.
for platform in linux macos windows; do
  bin="$ROOT/assets/bin/$platform/yt-dlp"
  [ "$platform" = windows ] && bin="$bin.exe"
  if ! out="$(cd "$ROOT" && "$bin" --version 2>&1)"; then
    echo "error: $platform binary did not run:" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "  $platform: $out"
done

echo ""
echo "Done. Desktop binaries placed in assets/bin/{linux,macos,windows}/"
echo "They are gitignored and NOT bundled into builds — see the note at the top"
echo "of this script. Remove them again with:"
echo "  rm -rf assets/bin/{linux,macos,windows}"
echo ""
cat <<'EOF'
Android:
  The Android runtime is separate and IS committed, because it is packaged into
  the APK:
    tool/fetch_android_runtime.sh   produces assets/bin/android/<abi>/python.tar.gz
    tool/fetch_ffmpeg_android.sh    produces assets/bin/android/<abi>/ffmpeg + ffprobe
  See README "Android notes" for distribution caveats.
EOF