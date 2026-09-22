#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/assets/bin"/{linux,macos,windows,android}

echo "Fetching yt-dlp desktop binaries (official single-file builds)…"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" -o "$ROOT/assets/bin/linux/yt-dlp"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" -o "$ROOT/assets/bin/macos/yt-dlp"
curl -fL "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -o "$ROOT/assets/bin/windows/yt-dlp.exe"
chmod +x "$ROOT/assets/bin/linux/yt-dlp" "$ROOT/assets/bin/macos/yt-dlp" 2>/dev/null || true
echo "Done. Desktop binaries placed in assets/bin/{linux,macos,windows}/"
echo ""
echo "Android: no official standalone build is published."
echo "Place an arm64-v8a PyInstaller build at assets/bin/android/yt-dlp (and chmod +x)."
echo "See https://github.com/yt-dlp/yt-dlp#installation for build notes."
