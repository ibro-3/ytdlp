#!/usr/bin/env bash
# Cross-compiles a minimal static ffmpeg + ffprobe for Android (bionic) with
# the NDK, for the bundled yt-dlp runtime. Ships as
# assets/bin/android/<abi>/{ffmpeg,ffprobe}.
#
# Both are required. ffmpeg merges split video+audio (DASH) streams, but any
# *postprocessing* (embedding subtitles or a thumbnail cover, converting
# subtitle formats) goes through yt-dlp's FFmpegMetadataPP, which probes the
# output with ffprobe and fails hard with
#   "Postprocessing: ffprobe not found. Please install or provide the path
#    using --ffmpeg-location"
# yt-dlp resolves the pair from a single --ffmpeg-location: given the path to
# ffmpeg it looks for ffprobe next to it, so the two must ship together in the
# same directory.
#
# Why not the Termux ffmpeg package? Its libav*.so link the entire codec
# universe (~97 packages, ~+40 MB/ABI). yt-dlp only merges with `-c copy`,
# which needs no encoders/decoders/filters — just the file protocol, the
# mp4/m4a/webm demuxers and matching muxers. ffprobe only reads container
# metadata, which the same demuxers cover. A static build with only those is a
# few MB per ABI.
#
# Usage: ./tool/fetch_ffmpeg_android.sh [x86_64|arm64-v8a]   (default: both)
#
# Env: FFMPEG_VERSION (default 8.1.3), ANDROID_NDK (default newest in ~/Android/Sdk/ndk)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Scratch directory for the cross-compile. `${TMPDIR:-/tmp}` rather than a
# hard-coded path, so this runs the same on any machine.
WORK="${WORK_DIR:-${TMPDIR:-/tmp}/ytdl-android}"
OUT="$ROOT/assets/bin/android"
VER="${FFMPEG_VERSION:-8.1.3}"
NDK="${ANDROID_NDK:-}"
if [ -z "$NDK" ]; then
  NDK="$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "no NDK found (set ANDROID_NDK)"; exit 1; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYSROOT="$TC/../sysroot"
[ -x "$TC/x86_64-linux-android21-clang" ] || { echo "missing NDK clang wrappers in $TC"; exit 1; }

declare -A ARCHMAP=( [x86_64]=x86_64 [arm64-v8a]=aarch64 )
ARCHES=("$@")
if [ ${#ARCHES[@]} -eq 0 ]; then ARCHES=(x86_64 arm64-v8a); fi

# Shared pristine source tree (copied per arch to keep configure state clean).
SRC="$WORK/ffmpeg-$VER"
if [ ! -f "$SRC/configure" ]; then
  TARBALL="$WORK/ffmpeg-$VER.tar.xz"
  if [ ! -f "$TARBALL" ]; then
    echo "fetching ffmpeg $VER source..."
    curl -fL --max-time 600 -o "$TARBALL" \
      "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  fi
  tar -xJf "$TARBALL" -C "$WORK"
fi

for ARCH in "${ARCHES[@]}"; do
  TARCH="${ARCHMAP[$ARCH]:-}"
  [ -n "$TARCH" ] || { echo "unknown arch: $ARCH (want x86_64|arm64-v8a)"; exit 1; }
  echo "=== $ARCH (ndk $TARCH) ==="
  BUILDDIR="$WORK/ffmpeg-build-$TARCH"
  rm -rf "$BUILDDIR" "$SRC.$TARCH"
  cp -r "$SRC" "$SRC.$TARCH"
  (
    cd "$SRC.$TARCH"
    ./configure \
      --prefix="$BUILDDIR" \
      --cc="$TC/${TARCH}-linux-android21-clang" \
      --enable-cross-compile \
      --target-os=android \
      --arch="$TARCH" \
      --sysroot="$SYSROOT" \
      --strip="$TC/llvm-strip" \
      --disable-autodetect \
      --disable-doc --disable-debug --disable-network --disable-symver \
      --disable-x86asm \
      --disable-avdevice \
      --disable-ffplay \
      --disable-everything \
      --enable-ffmpeg --enable-ffprobe \
      --enable-small \
      --enable-protocol=file,pipe \
      --enable-demuxer=mov,matroska \
      --enable-muxer=mp4,mov,matroska,webm \
      --enable-parser=aac,h264,hevc,vp9,opus \
      --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,opus_metadata
    make -j"$(nproc)"
  ) || { echo "build failed for $ARCH (see ffbuild/config.log)"; exit 1; }
  # Both binaries are required: yt-dlp derives ffprobe's path from ffmpeg's.
  for PROG in ffmpeg ffprobe; do
    BIN="$SRC.$TARCH/$PROG"
    [ -x "$BIN" ] || { echo "no $PROG binary produced"; exit 1; }
    cp "$BIN" "$OUT/$ARCH/$PROG"
    chmod 755 "$OUT/$ARCH/$PROG"
    echo "wrote $OUT/$ARCH/$PROG ($(du -h "$OUT/$ARCH/$PROG" | cut -f1))"
  done
done

echo "Done. Register new files in pubspec.yaml flutter.assets:"
echo "  - assets/bin/android/x86_64/ffmpeg"
echo "  - assets/bin/android/x86_64/ffprobe"
echo "  - assets/bin/android/arm64-v8a/ffmpeg"
echo "  - assets/bin/android/arm64-v8a/ffprobe"