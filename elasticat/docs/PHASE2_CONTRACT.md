# Phase 2 contract — the track as a class instance

Binding interface between the parallel Phase 2 worktrees. Same role as
`PHASE1_CONTRACT.md`: agree the surface first, then each worktree owns its own
files and never edits another's.

## Goal

Every track is an instance of one `ElasticatTrack` class with **no bespoke
per-track behavior anywhere**. Changing how a track works must be a one-place
change, never 8x. Track 1 is not special.

## Decision: one class, one file

`ElasticatTrack` is a **real SuperCollider class**, but it is defined **inside
`lib/Engine_Elasticat.sc`** rather than its own file.

SuperCollider permits multiple class definitions per `.sc` file, and the
existing marker files (`ElasticatKernel.sc`, `ElasticatTransport.sc`,
`ElasticatModes.sc`) are comment-only stubs that record why this codebase kept
everything in one file: *"the norns crone dynamic engine loader only needs to
discover one Engine_* class file"*, with companion class loading explicitly
**never verified on norns**. A separate class file that fails to load breaks the
whole class library — the script would not start at all.

So: real class instances now, loader risk zero. Extracting `ElasticatTrack` to
its own file is a later, separately-verified step. **Do not create new `.sc`
files.**

## Track ownership

`ElasticatTrack` owns, per instance:

- **State**: every field currently in `trackDefaultState` (machine/sample/loop/
  pitch/amp/pan, amp env, filter + filter env, insert FX, send levels + tap, and
  the full mod section: 2 LFOs, mod env, 4 macro bases + the 4x5 macro depth
  matrix).
- **Nodes/busses**: `group`, `sourceGroup`, `phaseBus`, `fxBus`, `insertBus`,
  `mixBus`, 5 control mod busses, and the `transport`/`mod`/`reader`/`filter`/
  `insert`/`sendTap`/`mix` synths plus its own slice voices.
- **Lifecycle**: `alloc`, `free` (click-free), `spawnFilter`, `spawnInsert`,
  `spawnSendTap`, `spawnMod`, `spawnMode`, `triggerSlice`.

The engine owns only what is genuinely global: the 2 send busses and their FX,
the master bus + master FX, transport tempo, the sample pool, and OSC routing.

## Node graph (per track, identical for all 8)

```
track.group
  track.sourceGroup { mod (kr) -> transport -> reader -> slice voices } -> fxBus
  filter     fxBus     -> insertBus     (ALSO the amp/pan/mod output stage)
  insert FX  insertBus -> mixBus        (NO synth at all when machine = None)
  sendTap    insertBus | mixBus         -> sendBus1 / sendBus2 (global)
  trackMix   insertBus | mixBus         -> masterBus (mute + teardown fade, unity)
```

Group order: `tracksGroup -> sendGroup -> masterGroup`.

Two invariants that are easy to get wrong:

1. **amp/pan live on the FILTER synth, never the mix synth.** `filterModOut`
   applies the AMP and PAN mod destinations there, so a track's own LFO can only
   reach them at the filter. The mix synth stays at unity — applying amp in both
   places squares the gain.
2. **Insert machine None spawns no synth.** `trackPostInsertBus` re-points the
   send tap and mix synth at `insertBus` instead. Whenever the insert appears or
   disappears, both must be re-pointed.

## Engine command surface

**Every per-track command takes the track index as its first argument.** Name is
mechanically derived from the state field:

```
field  filterCutoff   ->  command  \trFilterCutoff   args (track, value)
field  menvDepth      ->  command  \trMenvDepth      args (track, value)
```

Rule: `tr` + UpperCamelCase(field). Lua's `tr_call` in `lib/elasticat.lua`
already derives this exact name and warns once when a command is missing, so the
Lua side can be wired before the engine side lands.

Fields requiring a per-track command (beyond the Phase 1 set, which already
exists): `amp`, `pan`, `filterMachine`, `filterType`, `filterCutoff`,
`filterRes`, `filterDrive`, `filterMorph`, `filterBalance`, `filterEnvMode`,
`filterEnvAttack`, `filterEnvDecay`, `filterEnvSustain`, `filterEnvRelease`,
`filterEnvHold`, `filterEnvDepth`, `envMode`, `envAttack`, `envDecay`,
`envSustain`, `envRelease`, `envHold`, `fxInsertMachine`, `fxDrive`, `fxMix`,
`delayBeats`, `delayFeedback`, `delayTone`, `reverbSize`, `reverbDamp`,
`lofiBits`, `lofiRate`, `sendTap`, `sendLevel1`, `sendLevel2`, `lfo1Dest`,
`lfo1Wave`, `lfo1Beats`, `lfo1Depth`, `lfo1Mode`, `lfo2Dest`, `lfo2Wave`,
`lfo2Beats`, `lfo2Depth`, `lfo2Mode`, `menvDest`, `menvAttack`, `menvDecay`,
`menvSustain`, `menvRelease`, `menvDepth`, `mvelDest`, `mvelDepth` (velocity as a
mod source: the engine latches the last trigger velocity per track and routes
`velocity * mvelDepth` to `mvelDest` through the same mod matrix).

Plus indexed forms: `\trMacroBase (track, macro, value)` and
`\trMacroDepth (track, macro, dest, value)`, and `\trSliceTrigger (track, ...)`
mirroring the existing global `\triggerSlice` args.

**No global aliases.** The old un-prefixed commands (`\filterCutoff`, ...) are
deleted; Lua always passes a track. Anything still calling a global command is a
bug, not a fallback.

Implement the plain value setters through **one** generic dispatch (a spec table
of `field -> (arg:, synth:, lo:, hi:)` driving a single `set` method), not ~50
hand-written methods. Bespoke methods only where the logic is genuinely
non-trivial (machine respawns, seconds conversions).

## OSC reporting

Every per-instance `SendReply` MUST carry the track index as `replyID` — 8
copies of the mod synth and 8 filters now run. Already done for
`/elasticat/modRaw` and `/elasticat/filterEnvRaw`. The script keeps only the
**selected** track's stream for UI purposes.

## Param model (Lua)

`ParamsSpec.SPEC` (`lib/tracks/params_spec.lua`) becomes the single source of
truth. `ParamsSpec.register` already loops all 8 tracks and
`ParamsSpec.track_suffix` already maps **track 1 to the unprefixed id** and
tracks 2-8 to `t<N>_<suffix>`, so track 1 keeps every id it has today and
existing projects keep loading.

Because pages resolve ids through the `ui_id` funnel in `elasticat.lua`, a
suffix added to `SPEC` automatically becomes per-track everywhere in the UI:
pages, p-locks, scene capture. That is the leverage — do not add per-track
branching in the UI.

Stays global: sample pool (`trim_*`, `sample`, `file_slot`), transport/tempo,
master FX, send-bus FX params, project/system settings, and the A/B scene
crossfader (it captures whole scenes across all tracks).

## Worktree file ownership

Each worktree edits ONLY its own files.

| Worktree | Owns |
|---|---|
| `phase2-engine` | `lib/Engine_Elasticat.sc` |
| `phase2-params` | `lib/tracks/params_spec.lua`, `lib/elasticat.lua` |
| `phase2-ui` | `elasticat.lua`, `lib/ui/**`, `lib/pages/**`, `lib/grid_sequencer.lua` |
| integrator | `bin/**`, `docs/**`, merges |

## Verification

- `bin/test-elasticat-sclang` — class library compiles (a failure here means the
  script will not start on norns at all).
- `bin/test-elasticat-lua` — per-track param registration for all 8 tracks; the
  `ui_id` funnel resolves every suffix to a **registered** id per track; no
  cross-track contamination. The `lookup_param` stub **throws** on unknown ids
  like real norns — keep it that way, it is what caught the `menv_hold` bug.
- `bin/test-elasticat-engine-runtime` — boots scsynth, allocates 8 tracks,
  asserts each track's synths/busses exist and that lowering `activeTrackCount`
  frees them.

Local scsynth CPU is not norns CPU. Graph correctness can be proven here; real
headroom needs the device.

---

# Addendum — per-track sequencers

## Requirement (owner, 2026-07-26)

> Each track should have its own sequencer with step locks etc that apply to
> that track. A sequencer cannot P-Lock other tracks parameters. A track's
> sequencer should still run in background when that track is not the active
> one. Architecturally a track should be its own instance of a track class.
> Each track sequencer needs to be perfectly clock synced. I don't want the
> sequencers drifting out of phase. Also, each track can have its own pattern
> length and rate. Then there is also a global pattern length, which is not per
> track — mirror Elektron.

## Why the current design cannot satisfy it

`GridSequencer` is ONE object holding `self.tracks[n]` state plus `self.track`
(the selected track). Only the selected track gets the real step path; every
other track runs `elasticat.track_step` — a Phase 1 stub doing pitch,
loop_start/loop_end locks and a bare `noteOn`, missing range locks, ratchets,
trig_release, region-trigger semantics, slice triggering and step length.

## No drift: derive, never accumulate

This is the load-bearing decision.

Timing today is wall-clock and **accumulated**:
`next_step_time = next_step_time + step_duration(...)`, off `util.time()`, with
each track accumulating separately and separately sampling `current_bpm()`.
That drifts by construction — float error compounds, and a tempo change lands
on each track at a different instant.

Replace it with boundaries **derived** from the one shared musical clock:

```
beats_per_step(t) = 0.25 / rate(t)          -- 0.25 beat = a 16th at rate 1x
elapsed(t)        = clock.get_beats() - clock_origin
step_position(t)  = floor(elapsed(t) / beats_per_step(t))
step_index(t)     = (step_position(t) % pattern_steps(t)) + 1
```

Every track reads the SAME `clock.get_beats()`, so they cannot drift — by
construction, not by correction. A tempo change alters how fast beats advance
and every track follows identically. `clock_origin` already exists in
`lib/elasticat.lua` (`reset_clock_origin`).

A track fires when its `step_position` INCREASES; carry the last fired position
per track. Never advance by "+1 step" off a timer.

**Swing** becomes a phase offset on the boundary, not a duration multiplier:
odd steps test against `n * beats_per_step + swing_offset`. It must not
reintroduce accumulation.

## Rates

`rate` is a musical scale factor, Elektron-style. The existing 8-entry set gains
**0.0625** (1/16x): at 4 steps that makes each step one bar, and the pattern 4
bars — the owner's worked example. Keep the existing values working.

## Lengths — Elektron model

- **Per-track length** (`pattern_steps`, already per-track) and **per-track
  rate**: a track free-runs its own length at its own rate.
- **Global pattern length** stays global (`global_pattern_length`): it is the
  master cycle that pattern switching and pattern-boundary logic use. Per-track
  lengths run inside it and re-align with it, exactly like PER TRACK mode on a
  Digitakt.

## Structural isolation of p-locks

"A sequencer cannot P-Lock other tracks parameters" must be structural, not a
convention. Every param write originating from a step lock resolves through
THAT track's id funnel with an explicit track (`ParamsSpec.track_id(track, …)`),
never the selected-track `ui_id`. A test must assert a step lock on track 3
changes no param on track 1 or 5.

## One step path

Delete `elasticat.track_step`. There is ONE step-trigger routine parameterised
by track, called for the selected and background tracks alike. A trig on track 1
must behave identically whether or not track 1 is selected.

## Display follows the SELECTED track only

Confirmed with the owner: the visual playhead, waveform/region view, meters and
modulated-parameter readouts follow the selected track. Do not render 8
playheads. This addendum is about audio and trigger behaviour, not display.

---

# Addendum — multi-track A/B crossfader scenes

## Defect

`SceneStore` is wired to `id(suffix)` -- the TRACK 1 prefixer -- not the
selected-track funnel (`elasticat.lua`, `SceneStore.new{ get_value/set_value }`).
So capturing a scene while track 2 is selected stores TRACK 1 values.

It is not merely mis-wired: scene values are keyed by BARE SUFFIX (`"pan"`), so
the store cannot represent two tracks at once. It is single-track by
construction.

## Design (owner-confirmed)

- **Scene values are keyed by FULL per-track param id**, so one scene holds
  values for every track.
- **FN + Scene key captures ALL ACTIVE TRACKS** in one press. A scene stays
  "the whole instrument", which is the behaviour the owner values. Confirmed
  over the accumulate-per-track alternative because snapshotting a mix would
  otherwise take 8 gestures, and a scene could silently be missing a track that
  was never visited.
- **Hold Scene + turn an encoder** stays surgical: it locks that one param for
  the SELECTED track, which it does naturally because the encoder edits the
  selected track's param.
- **Moving the crossfader applies GLOBALLY** -- it morphs every track that has
  stored values, not just the selected one.

## Consequences to handle

- `morph_param_suffixes()` returns suffixes; the morph target set must expand to
  (track, suffix) pairs across active tracks. `PATTERN_GLOBAL_SUFFIXES` doubles
  as the morph EXCLUSION list -- keep that, and remember `t<N>_amp` was added to
  it, so track volumes are deliberately NOT morph targets.
- Scene serialization (`project_store.lua` scenes snapshot) changes shape.
  Owner has said backwards compatibility with old project files is not required
  yet, so migrate rather than dual-read, but do not silently corrupt: a scene
  saved in the old bare-suffix shape should load as track 1 values or be
  discarded, not applied to the wrong track.
- Lowering `active_track_count` must not strand stored values for tracks that
  are no longer active; they should simply not be applied while inactive.

## Cost control (owner concern: audio stutter/dropouts)

Measured: **98 morphable params per track**, so 784 per scene at 8 tracks and
1568 held for A+B. 76 of the 98 are `queue = true` (coalesced at 12Hz); 22 are
immediate.

**Capture is NOT the expensive part** -- it is a one-shot read of 784 params,
microseconds in Lua, on a gesture the user made deliberately.

**Apply is.** `scene_store:apply(t)` runs on every crossfader move. Naively that
is 784 `params:set` calls per fader tick, each firing an action; against a ~30Hz
ease that is ~23k param writes/sec plus an OSC burst from the 22 uncoalesced
ones per track. That is the dropout risk, and it is in the one place the user is
actively performing.

Required, in order of value:

1. **Precompute the morph set.** Only params whose two ENDPOINTS actually differ
   can change during a morph; the rest are no-ops on every tick. Compute this
   set once when a scene is captured or a lock/base changes, never per tick.
   This is EXACT -- no behavioural change -- and in practice collapses 784 to
   the handful a scene really varies.

   Preferred over the owner's suggested "only capture params that differ from
   their default": that is a good instinct and a decent heuristic, but the
   endpoint-difference test is strictly better. It is exact, and it also drops
   params where both scenes hold the same NON-default value, which the
   default-comparison misses.

2. **Skip no-op writes.** If the interpolated value equals the param's current
   value, do not set it. Removes most of the remaining cost at the ends of fader
   travel and for slow-moving params.

3. **Only apply to ACTIVE tracks.** Do not morph tracks above
   `active_track_count`.

4. **Keep morph writes on the coalescing path.** The 12Hz `queue_engine_send`
   already collapses a fast sweep to one send per param per tick; make sure the
   morph path benefits, and consider routing the 22 immediate params through it
   for the duration of a morph.

Same class of problem as the pattern-switch burst (~1116 params in one tick).
Any bulk param application in this codebase needs this treatment.

### Send slowly, interpolate in the engine

Owner's framing, and it is the right one: this is client-side interpolation.
Send parameter motion at a low rate and let the engine smooth between updates,
the way a networked game interpolates entity motion rather than sending every
frame.

Most of this already exists and was simply never joined up:

- Lua already coalesces engine sends at **12Hz** (`engine_send_interval = 1/12`
  in `lib/elasticat.lua`) -- the owner's suggested rate, already built. A morph
  should ride this path rather than inventing a second one.
- The engine already smooths with `Lag.kr` in many places (pitch 0.03,
  cutoff 0.01, morph 0.02, track gain 0.03).

**The gap: those two numbers were never matched.** Lag times were tuned for
DISCRETE edits (a knob turn arriving once), not for a 12Hz stream. At 12Hz
updates land ~83ms apart, so a 10ms lag settles in 10ms and then sits still for
73ms -- audibly stepped. Low-rate updates plus short smoothing is worse than
either extreme, because it turns a zipper into a staircase.

Rule: **for a param driven by the morph stream, smoothing time must be at least
the send interval** (~80-100ms at 12Hz). Two ways to get there:

- Lengthen the lag globally on continuous morph targets. ~80ms is imperceptible
  on most, and is in the range analogue gear smooths anyway.
- Or give those synths a slew-time argument the script raises for the duration
  of a morph and drops afterwards, so a deliberate knob turn stays snappy.

Prefer the second where responsiveness matters (cutoff especially); the first is
fine for amp/pan/res. Note `VarLag` is not currently used anywhere in the
engine, and is the natural UGen if slew time needs to change at runtime.

**Only continuous params may morph.** Option/binary params -- filter type,
machine, LFO wave/mode, mod dest, env mode -- cannot be interpolated
meaningfully; a half-morphed enum is nonsense. Exclude them from the morph set
(they snap when a scene is recalled outright). This also shrinks the set, on top
of the endpoint-difference filter above.
