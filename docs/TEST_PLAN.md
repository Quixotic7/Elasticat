# Elasticat v2 Test Plan

## Smoke Test

1. Restart norns after copying the engine.
2. Load `code/elasticat/elasticat.lua`.
3. Load a stereo loop.
4. Confirm `/elasticat/load/installed` reports the expected frame count.
5. Press `K3`.
6. Confirm `/elasticat/status` reports `playing=1`, positive frames, moving phase, and nonzero RMS.

## Switching Test

1. Start playback.
2. Turn `E1` through all six modes.
3. Confirm each switch logs `/elasticat/mode`.
4. Confirm phase does not reset during switching.
5. Confirm no stuck double playback after the fade.

## Clock Test

1. Enable `clock sync`.
2. Start playback.
3. Change norns tempo.
4. Confirm `/elasticat/status` updates target BPM and correction without periodic hard resets.

## Stress Targets

- 20 sample loads
- 50 loop-beat changes
- 200 mode switches
- 30-minute sync run
