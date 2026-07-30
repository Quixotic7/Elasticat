#!/usr/bin/env bash
# Build + install the Elasticat custom SC UGens ON the norns.
#
# The norns (armv7l) already has g++/cmake AND the SC 3.13 plugin headers at
# /usr/local/include/SuperCollider, so we compile on-device -- no cross-toolchain,
# no SC-source clone, no internet. This script copies the source over SSH, compiles
# it, and installs the .so + Classes into SuperCollider's Extensions dir.
#
# After running this you MUST restart the norns audio (same as an engine .sc
# change) for scsynth to load the new plugin and sclang to see the new class:
#   ssh we@norns.local 'sudo systemctl restart norns-jack norns-crone norns-sclang'
# or just SLEEP -> wake the norns. `--restart` does it for you.
#
# Prereqs: passwordless SSH to $NORNS (an authorized key). See README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORNS="${NORNS_HOST:-we@norns.local}"
REMOTE_SRC="elasticat-ugens"                                   # ~/elasticat-ugens on the norns
EXT="~/.local/share/SuperCollider/Extensions/elasticat-ugens"  # install target

echo "==> copying source to $NORNS:~/$REMOTE_SRC/"
ssh "$NORNS" "mkdir -p ~/$REMOTE_SRC/src ~/$REMOTE_SRC/Classes"
rsync -az --delete "$ROOT/src/"     "$NORNS:~/$REMOTE_SRC/src/"
rsync -az --delete "$ROOT/Classes/" "$NORNS:~/$REMOTE_SRC/Classes/"

echo "==> compiling + installing on-device"
ssh "$NORNS" 'bash -s' <<'REMOTE'
set -euo pipefail
INC=/usr/local/include/SuperCollider
SRC=~/elasticat-ugens
# -O3 (NOT -ffast-math): -ffast-math relaxes IEEE globally and was a suspect for
# pervasive grain grittiness -- reverted. -O3 keeps strict float semantics but still
# optimizes the arithmetic-heavy grain loop.
g++ -shared -fPIC -std=c++17 -O3 -DNDEBUG \
  -I"$INC" -I"$INC/plugin_interface" -I"$INC/common" -I"$INC/server" \
  -o "$SRC/ElasticatUGens.so" "$SRC"/src/*.cpp
EXT=~/.local/share/SuperCollider/Extensions/elasticat-ugens
mkdir -p "$EXT/Classes"
cp "$SRC/ElasticatUGens.so" "$EXT/"
cp "$SRC"/Classes/*.sc "$EXT/Classes/"
echo "BUILD_INSTALL_OK"
file "$EXT/ElasticatUGens.so"
nm -D "$EXT/ElasticatUGens.so" | grep -E "api_version|server_type|^.* T load" | head
REMOTE

if [[ "${1:-}" == "--restart" ]]; then
  echo "==> restarting norns audio (scsynth reload)"
  ssh "$NORNS" "sudo systemctl restart norns-jack.service norns-crone.service norns-sclang.service" || \
    echo "restart failed -- SLEEP->wake the norns manually to load the plugin"
else
  echo "==> done. RESTART norns audio to load: re-run with --restart, or SLEEP->wake."
fi
