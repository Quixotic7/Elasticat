# Phase 2 — open tasks (handoff)

> **STATUS (updated 2026-07-27).** This batch is essentially DONE. #46, #42, #44,
> #43, #45 and #41 **parts A+B** are all committed, deployed, and merged to
> `main` (the sections below are kept for history). A full **slice overhaul**
> also landed (per-warp voices, mono default + steal, natural sequenced pitch,
> WARP selector, real step preview; poly is capped at `maxSliceVoices=16`).
> **Still open:** #41 **part C** (DEFERRED — needs an owner call on base-vs-p-lock
> layering; do not build blind) and the lower-priority items (#33, #34, razor
> split-point morph, SVF machines). The "sequencer never advances" report was a
> STUCK norns internal clock (full power-OFF fixes it), NOT a code bug — don't
> chase it. The original snapshot below was taken at `cfef441`; `main` is now
> well ahead.

Snapshot for a fresh session. Suggested order below is cheapest/most-isolated
first. Read `docs/PHASE2_CONTRACT.md` first — it is binding.

## Recurring hazards (all have caused real bugs this project)

- A Lua `local` is only in scope for code **below** its declaration; a function
  reading a local declared later silently reads a **nil global**. Has bitten
  `engine_track`, `engine_call`, `update_engine_loop_points`.
- `params:lookup_param(id)` **throws** on an unknown id — never returns nil.
  Guard with the pcall'd `elasticat.param_exists`.
- `id(suffix)` = **track-1** prefixer. `ui_id(suffix)` = **selected-track**
  funnel. `elasticat.track_pid(track, suffix)` = **explicit track**. Using
  `id()` where a per-track value is meant is the single most common bug class
  here — several tasks below are exactly this.
- New helpers hang on the `elasticat` module table, never new file-scope locals
  (main chunk at LuaJIT's 200-local ceiling, `init()` at the 60-upvalue ceiling).
- `screen.level()` must stay pass-batched (set once per level-pass, never per
  cell/pixel) or the redraw metro freezes. Render tests assert bounded counts.
- In `bin/test-elasticat-*`, Lua runs inside single-quoted `-e` shell strings;
  an apostrophe in a comment silently breaks the quoting. Prefer separate
  `bin/lua/*.lua` files (established pattern).

## Engine vs script

`lib/Engine_Elasticat.sc` is a **SuperCollider class** — it recompiles only on a
**full norns restart**, not a script reload. Tasks touching it (#44 sends, #45
machine change) need a full restart to test on device. Pure-Lua changes need
only a reload.

## Deploy protocol (every change)

1. Run all four suites: `bin/test-elasticat-lua`, `bin/test-elasticat-sclang`,
   `bin/test-elasticat-engine-runtime`, `bin/test-elasticat-contract`
   (prefix `env -u CMDS` if `CMDS` is set in the shell).
2. `git diff --check`, then commit. Message ends with
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
3. `rsync -a --delete --exclude='.git' --exclude='.DS_Store' --exclude='._*' dust/code/elasticat/ /Volumes/dust/code/elasticat/`
4. Clear any `.smbdelete*` tombstone, then
   `diff -rq -x '.DS_Store' -x '._*' -x '.smbdelete*'` between the two trees —
   must print nothing.
5. **`git -C <main-checkout> merge --ff-only HEAD`** to advance `main`, NOT
   `git update-ref`. update-ref moves the branch label while the main checkout
   has `main` checked out, desyncing its working tree (this produced a spurious
   "+4,379 −8,330 uncommitted changes" widget that, if committed, would revert
   the whole session). ff-only merge updates the working tree too.

## Testing discipline (the owner values this)

Write a **failing test that reproduces the bug** before fixing it, then
**mutation-test** the fix (revert it, confirm the test fails). Speculative fixes
that addressed a real defect but not the reported symptom have burned this
project more than once — do not claim a symptom fixed unless you reproduced it.
Promote scratch tests into `bin/lua/` and wire them into `bin/test-elasticat-lua`.

## Worktree/subagent split

File-ownership discipline kept every merge clean this project. Disjoint owners:
`lib/Engine_Elasticat.sc` (engine), `lib/tracks/params_spec.lua` +
`lib/elasticat.lua` (facade/params), `elasticat.lua` (coordinator) + `lib/ui/**`
+ `lib/pages/**` + `lib/grid_sequencer.lua` (UI). **#42, #43, #46 all touch the
coordinator (`elasticat.lua`) and/or `lib/scene_store.lua`** — run those
sequentially or with tight boundaries, not three parallel agents on one file.

---

## #46 — Low-profile UI: 1px-min value bars + 3px selection corners

Files: `lib/ui/low_profile.lua` (+ the pages that use it: FILTER p1/p2, AMP,
MOD ENV). Self-contained, no cross-file contention — good first task.

1. **Clamp value bars to 1px minimum.** A param morphed to 0 renders a 0px bar,
   indistinguishable from empty. Clamp both the 2px VALUE bar and the 1px ACTUAL
   bar widths to >= 1px so a zeroed param reads as "present, at zero".
2. **Selection corners.** Low-profile pages lost the corner markers showing the
   selected K2/K3 pair — confusing when p-locked params render inverted, since
   inversion masks selection. Add tiny ~3px corners, **top-left and
   bottom-right only** (owner's words). Top-left may shift 1px LEFT into the
   black border to avoid overdrawing label text. Keep `screen.level`
   pass-batched — corners in the existing selected-pass, no per-cell level calls.

## #42 — Crossfader: morph muted tracks; FN+glide = slow morph

Files: `elasticat.lua` (coordinator), possibly `lib/scene_store.lua`.

1. **BUG — muted tracks do not receive morphs.** Fade B→A, unmute a track, it
   still holds scene B params. Mute is an OUTPUT gate, not a freeze. Prime
   suspect: the `is_active` callback wired into SceneStore from `elasticat.lua`.
   `is_active` must gate ONLY on `track <= active_track_count`, never on mute.
   Test: capture A/B with a track muted, morph, unmute, assert its params are at
   the morphed values.
2. **FEATURE — FN + glide key = slow morph.** DECIDED: **momentary** — the fade
   advances only WHILE FN + the glide key (xf1-xf6 / SC-A / SC-B, row 5) is
   held, and **pauses** where it is on release (does not snap or auto-continue).
   Full A→B travel **~5 seconds** at the slow rate; put the rate in one named
   local for easy retuning. Non-FN glide keys keep their current faster rate.
   Lives in the coordinator's crossfade key handling (the block that eases the
   `crossfade` MASTER param). Keep writes on the existing param path so 12Hz
   coalescing + morph-set filtering stay in effect.

## #43 — P-lock clearing: B2 clears wrong param; held-Scene + B2 clears scene lock

Files: `elasticat.lua`, `lib/scene_store.lua`, key-handler + `param_values` /
`page_items_for`.

1. **BUG — hold step + B2 clears the WRONG param.** AMP page, PAN/VOL pair
   selected, hold a step with a PAN p-lock, press B2 → it clears Env Release, not
   PAN. The clear path indexes the selected K2/K3 pair into an item list that
   does not match the page's actual layout (AMP is an envelope-layout page: 4 top
   cells + SND1/SND2/PAN/VOL bottom, not the generic 2x4 grid). Make the clear
   resolve the selected pair from the SAME items list the page renders. Check
   FILTER p2 and MOD ENV for the same off-by-layout bug.
2. **FEATURE — held Scene + B2/B3 clears the selected param's scene lock.**
   DECIDED: clears the param from **BOTH** scene A and scene B, on the
   **selected/active track only** — never other tracks' locks, never other
   scenes' entries for other tracks. Result: the key is absent from both scenes,
   so `morph_targets` drops it and it is fully unmorphed (stays at its live/base
   value across the fade — the owner's "same value in both scenes without editing
   each" goal). Needs `SceneStore:clear_key(scene, key)` (or clear-both helper):
   set `scenes[1][key]` and `scenes[2][key]` nil, `invalidate()`. The B2 press
   must resolve the selected param via the SAME items-list fix as (1). Test: pan
   differs A vs B, hold Scene + B2 with PAN selected → pan gone from both scenes,
   no other track touched.

## #44 — Range End Sync per-track; send bus None must be silent

Files: `lib/elasticat.lua` (facade) + `lib/Engine_Elasticat.sc`. Engine change →
full restart to test.

1. **Range End Sync works on track 1 only.** `range_end_sync` is a per-track
   param now, but the linkage (when on, moving range_start drags range_end to
   keep the window width) is implemented only in track 1's hand-registered
   actions. Tracks 2-8 go through the SPEC `range_remap` action, which re-maps
   loop points but has no sync linkage. Move the linkage into the shared path:
   the `range_remap` action (`elasticat.param_actions`) reads that track's
   `range_end_sync` and applies linkage before re-mapping, for ALL tracks
   including 1; collapse track 1's bespoke path onto it (one code path per the
   contract).
2. **Send bus with machine None passes audio (owner hears doubling).**
   `fxInsertNames[0]` = `\elasticatFxNone`, a dry PASSTHROUGH — correct for the
   per-track INSERT (chain must stay connected) but WRONG for send1Synth/
   send2Synth, where it writes the sent signal straight back into masterBus,
   duplicating it. Fix: a send with machine None spawns **no return synth**
   (same pattern as the per-track insert's None → no synth). The send bus simply
   goes unread, which is fine — nothing downstream depends on it. Verify with the
   runtime harness: send level up + machine None → masterBus RMS unchanged.

## #45 — Sample-load warp metadata stale; machine change kills playback

Files: `lib/elasticat.lua` (facade), `lib/Engine_Elasticat.sc`. Engine-adjacent;
verify with the runtime harness. Machine-change half likely needs full restart.

1. **Fresh sample warps wrong until steps nudged.** Load a 136bpm break →
   auto-detects bpm 136 / 40 steps; TAPE mode plays fine but other warp modes
   warp wrong until the owner nudges num-steps (40→39→40), after which tempo
   matches tape at master 136. So detected values reach the PARAMS but not the
   ENGINE on load — the nudge fires the param action that pushes
   `sampleSteps`/`sourceBpm`. `sync_track_slot_metadata` (added in the P2-10
   work) drives this from `sync_tracks` and pool edits, but the LOAD-COMPLETE
   path (pool load installed → slot bound to track) evidently does not call it,
   or calls it before detection writes the params. Trace `load_pool_slot` /
   on-installed flow in `lib/elasticat.lua` and push steps+bpm to every track
   playing that slot AFTER detection lands.
2. **Changing warp mode on a playing track with no trigs silences it** until
   stop/start. The machine/mode respawn (`spawnTrackMode` crossfade) seeds the
   new reader stopped, or loses the play state for tracks whose play came from
   the global transport (`elasticat.play` gates tracks 2..n on `machine==1`, and
   a machine CHANGE never re-evaluates that gate). Fix: on machine/mode change,
   re-push the track's effective play state (same rule `elasticat.play` uses) to
   the fresh synth. Test (runtime harness): start transport, change machine on a
   track with no steps, assert its reader has `playing=1`.

## #41 — Filter render lost filter-env + p-lock motion (do last — most tracing)

Files: `elasticat.lua`, `lib/ui/page_render.lua`, `lib/Engine_Elasticat.sc`.
THREE parts. **A and B are DONE (commit 52f38d6); C is deferred.**

- **A — DONE.** The engine appends the reporting track as a TRAILING OSC value;
  the coordinator read the leading arg as the track and shifted every mod field
  by one, so the feed never reached the render. Arg-order interpretation now
  lives on the facade (`route_mod_report` / `route_filter_env_report`),
  unit-tested (`bin/lua/mod_report_route_test.lua`).
- **B — DONE.** `draw_filter_bars` now reads the LIVE param during playback (what
  a firing step lock set) instead of the masked base `item_value` returns, so a
  firing `filter_cutoff`/`res` lock sweeps the bars; STOPPED still previews the
  held step. Test: `bin/lua/filter_render_plock_test.lua`.
- **C — DEFERRED (owner input).** See part C below; unchanged.

A. **Render no longer shows FILTER ENVELOPE modulation** (LFO still shows). The
   engine's `filterEnvRaw` SendReply carries `trackIndex` as replyID (Phase 2)
   and the UI keeps only the selected track's stream, zeroing on track switch.
   Check the responder in `Engine_Elasticat.sc` forwards the track index and
   `elasticat.lua`'s handler matches the shape — a tagged/untagged mismatch (or a
   track>1 selected while the engine sends untagged) reads as permanently zero.
   Check the filter respawn path (slew arg added in `ea51ee9`) did not drop the
   SendReply or change its replyID. Verify with the 15Hz OSC sniffer on port
   10111 (idiom used earlier in the project).
B. **Render should show cutoff/res updated via STEP P-LOCKS.** It reads
   base/actual via `elasticat.param_display_values` + `mod_offsets`; a step lock
   changes the param via `active_step_lock_bases` and may only show when
   `playing` AND from the mod feed. Trace where `draw_filter_bars` gets its
   actual cutoff/res, make a firing `filter_cutoff` step lock move the bars.
C. **While cutoff step-locks are FIRING, turning the cutoff knob does nothing**
   (clunky). This is the region-scrub-steplock-freeze masking: the step-lock
   layer overwrites the base param each tick, so a live encoder edit is stomped
   by the per-tick base restore. Owner wants base-cutoff edits to still take
   effect — the p-lock overrides only for its own step's window; between/around
   locked steps the newly-edited base applies and is audible, and the knob must
   not fight the restore. The fix is that a live base edit updates the masked
   base rather than being discarded. Same masking drives region/range scrubbing,
   so this likely wants to generalise rather than special-case cutoff. Confirm
   the layering with the owner if the mechanism is ambiguous — do not over-build.

---

## Also open, lower priority (not part of this batch)

- **#33** — UI follow-ups: per-track meters stay dark until the engine emits
  `/elasticat/track/level`; MIX-page VOL column reads master volume until
  resolved per-track; `machine_is_continuous()` gates the global transport on
  TRACK 1's machine and needs a real decision about transport across mixed
  machine types.
- **#34** — Pattern switch sets ~1116 params in one tick (Lua/OSC cost, NOT DSP —
  will not show on the CPU meter; presents as a stutter on pattern change). Fix:
  filter the per-pattern scan to `1..active_track_count` via
  `ParamsSpec.track_of_suffix`. Care: an inactive track activated later must
  still get its stored pattern values.

## Owner decisions still pending

- **Razor slice split points** (64 `razor_NN_start/end`) are currently morph
  targets. Gliding slice boundaries mid-fade is probably wrong; 8% of the target
  set. Owner to decide whether to exclude.
- **SVF filter machines.** Filter is ~40% of per-track CPU (~25 points across 8
  tracks); owner measured 8 tracks at 72-74% on hardware (fits base 11% +
  7.75%/track; FX chain of 2 sends + 1 insert costs only ~6%). A state-variable
  filter yields LP/HP/BP/notch from ONE filter core, so it needs no `Select.ar`
  over 3 biquads and keeps `filterType` a live, click-free, p-lockable param (no
  respawn). It will NOT sound identical to RLPF/RHPF/BPF, so ADD SVF machines
  alongside the existing ones rather than replacing — additive, a contract change
  (grows the machine index space params/UI enumerate; `filter_machine` is
  serialized, so append). Would put 8 bare tracks near 51%.

## CPU reference (owner hardware)

`base 11% + 7.75% per track`. Measured: 4 tracks 42%, 8 tracks 72-74% (incl. a
send delay + send reverb + one lofi insert). Full detail in
`docs/BENCHMARK_RESULTS.md`.
