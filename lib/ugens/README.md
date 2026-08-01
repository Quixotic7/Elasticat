# Elasticat custom SuperCollider UGens

Compiled server plugin (`ElasticatUGens.so`) for the warp DSP that's awkward or
expensive in the SC UGen graph: a click-free sub-head crossfade buffer reader
(`ElasticatReader`), plus `ElasticatGrains`, `ElasticatSlicer`, and
`ElasticatWavetable`. Every warp mode has a pure-SuperCollider fallback, so the
engine still sounds correct if the plugin is absent — the plugin just adds the
click-free reads and leaner DSP.

## How it installs (users do nothing)

`ElasticatUGens.so` ships **prebuilt** for the norns (armv7l) in this folder. On
launch, `install.lua` copies it — and the `Classes/*.sc` wrappers + `VERSION` —
into `~/.local/share/SuperCollider/Extensions/elasticat-ugens/`, but only when the
installed `VERSION` differs from the bundled one. It runs at script load, *before*
norns boots scsynth, so a fresh `;install` loads the plugin the same session. After
a `;update` that bumps the plugin, a **SLEEP → wake** loads the new binary.

## Rebuild from source (fallback)

If the prebuilt won't load on your device (an SC ABI mismatch — rare, norns is
uniform), rebuild it on the norns. No toolchain to install: norns ships `g++` and
the SC plugin headers at `/usr/local/include/SuperCollider/`.

```
ssh we@norns.local
~/dust/code/elasticat/lib/ugens/build.sh      # compile -> install to Extensions
```

then SLEEP → wake. `build.sh` writes straight into the Extensions dir.

## Layout

- `src/*.cpp` — the UGens (one `.so`, `ElasticatUGens`, registers all units)
- `Classes/*.sc` — the language-side `UGen` wrappers (installed beside the `.so`)
- `ElasticatUGens.so` — the prebuilt binary that ships (armv7l)
- `VERSION` — bump when `src/` changes so the installer reinstalls
- `build.sh` — on-device compile + install (the fallback above)
- `install.lua` — the first-run/update installer (called from `elasticat.lua`)

## Maintainer: refreshing the prebuilt binary

From the dev machine, with the norns engine UNLOADED (script stopped — the g++
compile is CPU-heavy and can xrun the live audio), run the repo's
`bin/build-ugens.sh`: it rsyncs the source to the norns, runs `build.sh` there, and
copies the fresh `ElasticatUGens.so` back into this folder to commit. Bump
`VERSION` in the same change.
