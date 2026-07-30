# Elasticat custom SuperCollider UGens

Compiled server plugins (`.so`) for the hot DSP that's awkward or expensive in the
SC UGen graph — first target: a click-free **sub-head crossfade buffer reader**
(the softcut-style jump/loop crossfade), exposed as a new warp mode alongside the
SC-graph `tape_xf` for A/B.

`ElasticatPassthru` (`out = in * gain`) is the toolchain-validation UGen and stays
as the smoke test.

## Why on-device build (no cross-toolchain)

The norns is **armv7l** (32-bit ARM, Raspbian). It already has everything needed:

- `g++` 10.2.1, `cmake`, `make`, `git`
- the SuperCollider **3.13 plugin headers**, installed at
  `/usr/local/include/SuperCollider/` (`plugin_interface/SC_PlugIn.hpp` etc.)
- prior art: `mi-UGens`, `PortedPlugins` already built in the Extensions dir

So we compile **on the norns** over SSH — no cross-compiler, no SC-source clone, no
internet. The `.so` must live in SuperCollider's Extensions dir (NOT under `~/dust`,
so the samba deploy can't reach it — SSH is required).

## One-time access setup

Passwordless SSH to the norns (an authorized key), because the samba share only
exposes `~/dust`, not `~/.ssh` or the Extensions dir:

```
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""      # if you have no key
ssh-copy-id we@norns.local                             # password: sleep
```

Verify: `ssh -o BatchMode=yes we@norns.local uname -m` → `armv7l`.

## Build + deploy

```
./ugens/build-ugens.sh            # copy src -> compile on-device -> install to Extensions
./ugens/build-ugens.sh --restart  # ...and restart the norns audio to load it
```

A UGen change is like an engine `.sc` change: **scsynth must restart** to load the
new `.so` and sclang to see the class. `--restart` bounces the audio services;
otherwise SLEEP → wake the norns.

## Layout

- `src/*.cpp` — the UGens (one `.so`, `ElasticatUGens`, registers all units)
- `Classes/*.sc` — the language-side `UGen` wrappers (installed beside the `.so`)
- `build-ugens.sh` — the build/install script (override host with `NORNS_HOST=`)

## Verify a build loaded

```
ssh we@norns.local 'echo "(\ElasticatPassthru.asClass.notNil.postln; 0.exit)" > /tmp/t.scd; sclang /tmp/t.scd 2>&1 | tail -3'
```
`true` = the class compiled and the UGen is registered.
