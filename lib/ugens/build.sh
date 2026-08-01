#!/usr/bin/env bash
# Compile + install the Elasticat UGens ON the norns (run locally on the device --
# no SSH). This is the first-run installer's build FALLBACK (used only if the
# bundled prebuilt ElasticatUGens.so fails to load on this device, e.g. an SC ABI
# mismatch) and the manual "rebuild from source" path. norns ships g++ and the SC
# plugin headers, so no toolchain install is needed.
#
# After this, RESTART the norns audio (SLEEP -> wake) so scsynth loads the plugin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INC="${SC_INCLUDE:-/usr/local/include/SuperCollider}"
EXT="${ELASTICAT_EXT:-$HOME/.local/share/SuperCollider/Extensions/elasticat-ugens}"

if [[ ! -d "$INC/plugin_interface" ]]; then
  echo "SuperCollider plugin headers not found at $INC" >&2
  echo "(set SC_INCLUDE=/path/to/SuperCollider if they live elsewhere)" >&2
  exit 1
fi

echo "==> compiling ElasticatUGens.so"
mkdir -p "$EXT"
# The .so is the ONLY thing that goes in Extensions. The SC class wrappers
# (Classes/*.sc) are compiled by norns straight from the script dir, so an
# Extensions copy would DUPLICATE them and break the class library compile
# ("supercollider fail"). Remove any legacy duplicate.
rm -rf "$EXT/Classes"
# -O3, strict IEEE floats (NOT -ffast-math -- it was a suspect for grain grit).
g++ -shared -fPIC -std=c++17 -O3 -DNDEBUG \
  -I"$INC" -I"$INC/plugin_interface" -I"$INC/common" -I"$INC/server" \
  -o "$EXT/ElasticatUGens.so" "$HERE"/src/*.cpp

echo "==> installing the version stamp"
cp "$HERE/VERSION" "$EXT/VERSION"

echo "BUILD_INSTALL_OK -> $EXT"
echo "RESTART the norns audio (SLEEP -> wake) to load the plugin."
