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

have() { command -v "$1" >/dev/null 2>&1; }

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

# The sha256 of each binary is checked against the SHA2-256SUMS asset of the
# very same release. The `--version` exec test below still catches "saved an
# HTML error page", but it cannot catch a *good* binary in disguise — nothing a
# truncated download, a MITM proxy or a substituted mirror produces, and which
# runs (the exec test passes) until first contact with an untrusted server.
# The checksum index costs one more small request from the same origin as the
# binary, so a mismatch means the two disagreed with each other at that
# instant — re-running resolves it or fails loudly the same way again.
have sha256sum || have shasum || { echo "need sha256sum or shasum for verification"; exit 1; }
sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
SUMS="$(mktemp)"
trap 'rm -f "$SUMS"' EXIT
curl -fL --max-time 120 \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS" \
  -o "$SUMS"
verify_sha256() { # <file> <asset name in the SUMS index>
  local bb expected actual
  expected="$(awk -v name="$2" '$2 == name { print $1; exit }' "$SUMS")"
  if [ -z "$expected" ]; then
    echo "error: $2 is missing from SHA2-256SUMS" >&2
    exit 1
  fi
  actual="$(sha256_of "$1")"
  if [ "$actual" != "$expected" ]; then
    echo "error: $2 content hash mismatch" >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi
  echo "  sha256 ok: $2"
}
verify_sha256 "$ROOT/assets/bin/linux/yt-dlp" 'yt-dlp'
verify_sha256 "$ROOT/assets/bin/macos/yt-dlp" 'yt-dlp_macos'
verify_sha256 "$ROOT/assets/bin/windows/yt-dlp.exe" 'yt-dlp.exe'

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