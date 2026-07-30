#!/usr/bin/env bash
# Build + install the RubberBand SuperCollider UGen ON the norns (armv7l).
#
# RubberBand (breakfastquay/rubberband, GPL v2+) is a studio-grade time-stretch /
# pitch-shift library. The audionerd/RubberBandUGens wrapper exposes `RubberBand.ar`
# -- a real-time BUFFER PLAYER with INDEPENDENT `rate` (time) + `pitchShift` (pitch),
# which is exactly what elasticat's clean-stretch mode wants.
#
# The library ships a SINGLE compilation unit (rubberband/single/RubberBandSingle.cpp,
# built-in FFT + resampler, no threading) -- so it builds with plain g++, no meson and
# no external deps. TWO armv7 gotchas, both handled below:
#   * needs -latomic (std::atomic on 32-bit ARM -> libatomic.so.1)
#   * that's it -- built-in FFT means no fftw/Accelerate/libsamplerate.
#
# LICENSE: RubberBand is GPL v2+. Fine to build on your own norns for personal use;
# distributing elasticat WITH this .so makes that build GPL (or needs a commercial
# RubberBand licence). It is a SEPARATE plugin -- elasticat itself stays unaffected
# unless a track actually selects the RubberBand warp mode.
#
# Usage:  ugens/build-rubberband.sh [--restart]
# The rubberband source is NOT vendored in this repo (1.9M) -- it is cloned fresh here
# and left in the scratchpad; only this script is tracked.

set -euo pipefail
NORNS="${NORNS_HOST:-we@norns.local}"
REPO="https://github.com/audionerd/RubberBandUGens.git"
WORK="${TMPDIR:-/tmp}/RubberBandUGens"

echo "== clone (recursive: pulls the rubberband submodule) =="
rm -rf "$WORK"
git clone --recursive --depth 1 "$REPO" "$WORK"

echo "== transfer to norns (excl .git) =="
rsync -a --exclude '.git' "$WORK/" "$NORNS:~/rubberband-ugens/"

echo "== compile on-device (single-file build + -latomic; ~70s) =="
ssh "$NORNS" 'bash -s' <<'REMOTE'
set -euo pipefail
INC=/usr/local/include/SuperCollider
cd ~/rubberband-ugens
g++ -shared -fPIC -std=c++14 -fvisibility=hidden -O2 -DNDEBUG \
  -I"$INC/plugin_interface" -I"$INC/common" -I rubberband \
  plugins/RubberBand/RubberBand.cpp rubberband/single/RubberBandSingle.cpp \
  -o RubberBand.so -latomic
EXT=~/.local/share/SuperCollider/Extensions/rubberband
mkdir -p "$EXT/Classes"
cp RubberBand.so "$EXT/"
cp plugins/RubberBand/RubberBand.sc plugins/RubberBand/RubberBandLoop.sc "$EXT/Classes/"
# sanity: the .so must record libatomic as NEEDED or it won't dlopen
readelf -d "$EXT/RubberBand.so" | grep -q libatomic && echo "BUILD_INSTALL_OK (libatomic linked)" || { echo "MISSING libatomic"; exit 1; }
REMOTE

if [ "${1:-}" = "--restart" ]; then
  echo "== restart audio (loads the plugin) =="
  ssh "$NORNS" 'sudo systemctl restart norns-sclang'
fi
echo "Done. RubberBand.ar available after the next audio (sclang) restart."
