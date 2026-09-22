#!/usr/bin/env bash
# Assembles a self-contained Termux-based CPython + yt-dlp runtime for
# Android (bionic) and packs it as assets/bin/android/<abi>/python.tar.gz.
#
# Usage: ./tool/fetch_android_runtime.sh [x86_64|arm64-v8a]   (default: both)
#
# Sources (pinned, official upstreams):
#   - Termux packages (packages.termux.dev): python, openssl, libffi, ...
#   - yt-dlp itself comes from Termux's python-yt-dlp package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK_DIR:-/tmp/opencode/ytdl-android}"
OUT="$ROOT/assets/bin/android"
BASE_URL="https://packages.termux.dev/apt/termux-main"

declare -A ARCHMAP=( [x86_64]=x86_64 [arm64-v8a]=aarch64 )
ARCHES=("$@")
if [ ${#ARCHES[@]} -eq 0 ]; then ARCHES=(x86_64 arm64-v8a); fi

have() { command -v "$1" >/dev/null 2>&1; }
have ar     || { echo "need 'ar' (binutils)"; exit 1; }
have tar    || { echo "need 'tar'"; exit 1; }
have python3 || { echo "need 'python3'"; exit 1; }

for ARCH in "${ARCHES[@]}"; do
  TERMUX_ARCH="${ARCHMAP[$ARCH]:-}"
  [ -n "$TERMUX_ARCH" ] || { echo "unknown arch: $ARCH (want x86_64|arm64-v8a)"; exit 1; }
  echo "=== $ARCH (termux $TERMUX_ARCH) ==="
  mkdir -p "$WORK" "$OUT/$ARCH"

  PKGFILE="$WORK/Packages.$TERMUX_ARCH"
  if [ ! -f "$PKGFILE" ]; then
    curl -fL --max-time 120 \
      "$BASE_URL/dists/stable/main/binary-$TERMUX_ARCH/Packages" -o "$PKGFILE"
  fi

  DEBDIR="$WORK/debs-$TERMUX_ARCH"
  mkdir -p "$DEBDIR"
  python3 - "$PKGFILE" "$DEBDIR" "$BASE_URL" <<'EOF'
import re, sys, os, urllib.request
pkgfile, debdir, base = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(pkgfile).read()
pkgs = {}
for p in txt.split('\n\n'):
    m = re.search(r'^Package: (\S+)', p, re.M)
    if m: pkgs[m.group(1)] = p
def field(p, k):
    m = re.search(rf'^{k}: (.*)', p, re.M)
    return m.group(1).strip() if m else ''
skip = {'python-pip'}  # packaging-only dep, not needed at runtime
need, seen = ['python', 'python-yt-dlp'], set()
while need:
    n = need.pop()
    if n in seen or n not in pkgs: continue
    seen.add(n)
    for d in field(pkgs[n], 'Depends').split(','):
        d = re.sub(r'\(.*?\)', '', d).strip()
        if d and d not in skip: need.append(d)
print('closure:', ' '.join(sorted(seen)))
for n in sorted(seen):
    fn = field(pkgs[n], 'Filename')
    dest = os.path.join(debdir, os.path.basename(fn).replace('%3a', ':'))
    if os.path.exists(dest):
        print('have', os.path.basename(dest)); continue
    print('get', os.path.basename(fn))
    urllib.request.urlretrieve(base + '/' + fn, dest)
EOF

  SYSROOT="$WORK/sysroot-$TERMUX_ARCH"
  rm -rf "$SYSROOT"; mkdir -p "$SYSROOT"
  for deb in "$DEBDIR"/*.deb; do
    tmp="$(mktemp -d)"
    ( cd "$tmp" && ar x "$deb" data.tar.xz && tar -xJf data.tar.xz -C "$SYSROOT" )
    rm -rf "$tmp"
  done
  U="$SYSROOT/data/data/com.termux/files/usr"

  # --- trim to a minimal runtime ---
  rm -rf "$U/include" "$U/share/man" "$U/share/doc" \
         "$U/share/bash-completion" "$U/share/fish" "$U/share/zsh" \
         "$U/lib/python3.14/test" "$U/lib/python3.14/tkinter" \
         "$U/lib/python3.14/ensurepip" "$U/lib/python3.14/pydoc_data"
  find "$U" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$U/lib" -name '*.a' -delete 2>/dev/null || true
  # keep only the binaries we execute; drop REPL/tooling helpers
  ls "$U/bin" | grep -vxE 'python3\.14|python3|python|yt-dlp' | while read -r b; do
    rm -f "$U/bin/$b"
  done
  # sanity: interpreter + payload present
  [ -x "$U/bin/python3.14" ] || [ -f "$U/bin/python3.14" ] || { echo "python missing!"; exit 1; }
  [ -f "$U/bin/yt-dlp" ] || { echo "yt-dlp script missing!"; exit 1; }
  [ -d "$U/lib/python3.14/site-packages/yt_dlp" ] || { echo "yt_dlp module missing!"; exit 1; }

  tar -czf "$OUT/$ARCH/python.tar.gz" -C "$SYSROOT" data
  echo "wrote $OUT/$ARCH/python.tar.gz ($(du -h "$OUT/$ARCH/python.tar.gz" | cut -f1))"
done

echo "Done. Register new files in pubspec.yaml flutter.assets, then"
echo "flutter clean && flutter run (Android)."
