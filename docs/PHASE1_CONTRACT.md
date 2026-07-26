# Phase 1 contract — track scaffolding (binding design decisions)

Two workstreams (engine / Lua) build against this file in parallel. If a
decision here proves wrong in practice, STOP and flag it in your report
rather than silently diverging — the other stream is building against it.

## Track model
- `TRACK_COUNT_MAX = 8`. `active_track_count` (1-8, default 1) is a
  project-global param; the engine only allocates chains for tracks
  1..count. Track 1 is the existing chain.
- **Regression invariant (binding):** with `active_track_count = 1`,
  behavior is byte-for-byte the current single-track script. Existing param
  ids, engine commands, project files, and psets keep working unchanged.

## Param ids (Lua)
- Track 1 KEEPS today's unprefixed ids (`elasticat_loop_start`, ...) —
  this is what preserves psets/projects/regression.
- Tracks 2-8 get `elasticat_t<N>_<suffix>` (e.g. `elasticat_t2_loop_start`),
  generated programmatically in `lib/tracks/params_spec.lua` — no
  hand-written duplication. Phase 1 generates ONLY the source/warp/trig
  machine params + per-track play state (the Phase 1 chain has no
  filter/amp-env/insert/mod).
- Helper: `track_id(n, suffix)` -> track 1 = `id(suffix)`, else
  `id("t" .. n .. "_" .. suffix)`. All track-aware code goes through it.

## Engine commands (SC)
- New namespaced commands take a LEADING track index (int, 1-based):
  `\trLoopStart (if)`, `\trLoopEnd (if)`, `\trPitch (if)`, `\trPlay (ii)`,
  `\trSetMachine (ii)`, `\trLoadPoolSlot (iis)`, `\trSampleSlot (ii)`, ...
  — mirror the existing per-track-relevant command set with a `tr` prefix.
- Existing commands stay EXACTLY as-is and act on track 1 (they become
  thin aliases). Nothing currently calling the engine changes behavior.
- Each track chain = its own phase bus + transport phasor + reader synth
  (crossfade-swapped machines, same as today), mixed straight to the
  master bus. NO per-track filter/amp-env/insert/mod in Phase 1; track 1
  keeps its existing full path (through the global filter synth) untouched.
- `\activeTrackCount (i)` allocates/frees chains. Freeing must be
  click-free (fade the chain's mix gain before freeing).

## Sequencer (Lua, grid_sequencer.lua)
- Per-track sequence state: the existing fields (steps, page_loop,
  rate_index, play position, ...) become an array `self.tracks[1..8]`,
  with `self.track` = selected track index (default 1) and accessors so
  the current code paths keep reading/writing "the selected track" — the
  refactor must not fork the step/lock logic per track.
- All 1..count tracks ADVANCE during playback (each its own pattern
  position); only the selected track is EDITED/displayed.
- Pattern slots capture/apply ALL tracks' sequences (pattern snapshot
  gains a per-track array; old single-track snapshots load into track 1).

## Grid
- Row 4, cols 8-15 = track select keys 1-8 (lit = active count, bright =
  selected). Press = select; FN+press = mute toggle (muted track advances
  but outputs silence — engine `\trMute (ii)`). Cols 1-7/16 of row 4 stay
  reserved.

## Projects
- Project/pattern serialization gains a `tracks` array; loaders accept old
  files (no `tracks` key -> everything is track 1). Editor prefs unchanged.

## Out of scope for Phase 1
Per-track filter/amp/insert/mod (Phase 2/3), neighbor routing (Phase 5),
per-track sends (Phase 6), track copy/paste (later; clipboard scopes stay
selected-track).

## Phase 1 integration notes (as shipped)
- Known per-track no-ops for tracks 2-8 (warn-once in Lua, engine commands
  land in Phase 2+): slice voice shaping (`sliceAttack/Release`,
  `setSliceRate/SyncToClock`), loop `xfade`. Slice *triggering* works
  (`triggerSlice` routes per track); shaping stays global.
- `\trChopSteps` added engine-side (steps -> beats /4, mirroring legacy).
- `setReverse` aliases to engine `\trReverse`.
- Engine follow-ups flagged by the workstreams: warp-param re-send after a
  chain realloc; clock hard-realign only snaps track 1's phasor; tracks 2-8
  use drone AHR env defaults (per-track env shapes are Phase 2).
