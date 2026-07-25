# Elasticat — Product Requirements Document

**This is the source of truth for product decisions.** Every agent working on
elasticat reads this first. Technical structure lives in `docs/ARCHITECTURE.md`;
the multi-track scaling design and phase gates live in
`docs/MULTITRACK_ARCHITECTURE.md`; who works on what lives in
`docs/WORKSTREAMS.md`.

## 1. Vision

Elasticat is a **sample loop mangler and performance sequencer** for monome
norns + grid: Elektron-style parameter-lock sequencing married to live,
continuous manipulation of a tempo-warped loop. The end state is a 4-8 track
groovebox with per-track machines, filters, envelopes, insert FX, sends, mod
matrix, and scene morphing — but every stage of that journey must remain a
playable instrument on its own.

**The signature feature** (protect it in every decision): program a sequence,
then *live-scrub* trim/range/region/filter while it plays. Region and range
edits are live and p-lockable; happy accidents are the point. Any new parameter
should default to being live-adjustable and p-lockable unless there's a
specific reason not to be.

**What makes it unique in the norns ecosystem**: nothing on norns combines
Elektron plocks + conditional performance gestures (trig jump/release walls,
ghost trigs, live step trig) + tempo-warped loop machines + a scene-morphable
mixer. The closest neighbors (mlr, cheat codes, gridstep) each do one axis;
elasticat's identity is the *combination*.

## 2. Where we are (July 2026)

Single track, fully playable. Shipped and hardware-verified:

- 4 machines (loop, loop_trig, grid_slice, razor_slice), 6 warp modes
  (tape, tempo_varispeed, chopped, granular, random_ola, pitch_corrected).
- Three-layer region model (Track / Step / Actual) for loop region AND range;
  live loop keys > sequenced step > main loop, each layer releasing to the one
  below via Return/Boomerang/Reset (anchor-based Return keeps a tempo-warped
  loop perfectly in sync through overrides).
- Trig machinery: p-locks, ghost trigs, Trig Jump (wall/street model), Trig
  Release, mono/poly carryover, live step trig, step preview, loop-key
  programming vs performance modes.
- Amp stage: AHR/ADSR envelope (Elektron 0-127 exponential times, INF
  hold/release), pan (0-128 true-center), track volume, portamento.
- Filter stage (first two machines): Classic + Morphing, post-mix per-track,
  with an independent filter envelope (AHR/ADSR) and env depth. Pan/vol
  relocated to the filter output stage.
- File/pool system: 128 slots, per-slot BPM/steps/trim/gain metadata,
  decoupled file editing vs playback slot, sample preview, stereo support.
- UI: 9 categories, dynamic per-machine/per-mode pages, settings layers,
  header/messaging system, launch intro + tempo-synced visualizer.
- **CPU baseline: ~11% average, ~15% spikes** (1 track: transport + 1 reader +
  filter + Lua UI). This number gates all multi-track ambitions.

Known gaps (tracked):

- **No persistence for sequencer state** — superseded by the Projects system
  (§7), which is the MVP blocker.
- `tempo_varispeed` ignores the pitch parameter (never implemented in DSP).
- Live-held notes have no note-off: releasing a live step doesn't gate the amp
  ADSR (next trigger re-gates). Needs an engine `noteOff`.
- loop_trig machine's live-hold path is approximate (silent between gates).

## 3. Signal chain (target architecture)

Per track:

```
[Generator | Neighbor track | Audio input] -> Filter -> Amp -+-> Insert 1 -> Insert 2 -+-> Master
                                                             |                         |
                                                  (send tap: pre-insert)    (send tap: post-insert)
                                                             v                         v
                                                          Send 1/2 ................ Send 1/2
```

- **Send tap point is a per-track setting**: sends read either post-amp
  (pre-insert) or post-insert-2. This is a bus argument, not a graph rebuild.
- **Send buses**: each send runs its own FX and returns into the Master bus.
  (Optional later refinement: a per-send toggle to return *around* the master
  insert rather than through it.)
- **Master**: -> Master insert FX -> hardware output.
- **Hardware fact**: norns has exactly **one stereo output path** — the
  headphone jack mirrors the main DAC. There is no separately addressable
  output; all routing choices are about which busses/inserts a signal passes
  through, not where it physically exits.

Chain input is switchable per track: own generator (default), neighbor track
(Elektron-style: consumes track N-1's post-chain audio, N-1 stops reaching
master on its own), or the norns audio input (live external processing —
this makes elasticat an FX box for hardware, a real differentiator).

**CPU reality check**: the final shape (8 tracks? 2 inserts each? FX only on
sends?) is decided by measurement, not hope. See §10.

## 4. Machines

### 4.1 Sound generators (exist)

The switchable "machine" per track: loop, loop_trig, grid_slice, razor_slice —
plus, in multitrack, `neighbor` and `input`. Warp mode (6 engines) is a
p-lockable sub-choice of the loop machines.

### 4.2 Filter machines

**Rules (apply to every filter machine):**

- The track's filter machine is a **setting** (FILTER settings page), not
  p-lockable. Its *parameters* are p-lockable.
- Every filter machine has a **filter envelope** with mode **AHR (default) or
  ADSR** — the env mode is a setting, not p-lockable. Envelope times follow
  the Elektron 0-127 exponential mapping; env depth is bipolar.
- One filter instance per track, post-mix (after voice summing, before
  pan/vol). Per-voice filters for slice polyphony are **out of scope** unless
  CPU profiling later shows headroom — a CPU multiplier with marginal audible
  benefit.
- Cutoff/Res/Drive are 0-127 amounts. Morph/Balance knobs are 0-128 centered
  params (64 = center). Type is an options param.

**Catalog** (1-2 shipped, rest in priority order):

| # | Machine | Status | P-lockable params | Notes |
|---|---------|--------|-------------------|-------|
| 1 | Classic | shipped | Type (LP/HP/BP/notch), Cutoff, Res, Drive | Elektron-style multimode |
| 2 | Morphing | shipped | Morph, Cutoff, Res, Drive | LP -> notch -> HP sweep |
| 3 | Classic Stereo | shipped | Balance, Type, Cutoff, Res, Drive | Balance 0-128: 64 centered; 128 = R cutoff pushed up / L pushed down; 0 = mirror |
| 4 | Morphing Stereo | shipped | Balance, Morph, Cutoff, Res, Drive | same balance law |
| 5 | Classic Mid/Side | shipped | MS Balance, Type, Cutoff, Res, Drive | decode to M/S, filter each, re-encode; balance biases mid vs side cutoff |
| 6 | Morphing Mid/Side | shipped | MS Balance, Morph, Cutoff, Res, Drive | same |
| 7 | Comb | planned | Freq/Tune, Feedback, Damp, Mix | tuned comb, negative/positive feedback |
| 8 | Ladder | planned | Cutoff, Res, Drive | Moog-style ladder; self-oscillation flavor |
| 9 | Formant | planned | Vowel/Morph, Cutoff (shift), Res, Mix | vowel-morphing bandpass bank |

Stereo/MS variants reuse the mono machine's DSP with two filter instances and a
balance law — implement as parameterized variants of Classic/Morphing, not
copy-pasted SynthDefs.

### 4.3 FX catalog

Same machine pattern as filters: an FX slot hosts a switchable FX machine whose
params are p-lockable (where it makes musical sense); which FX occupies a slot
is a setting. Slots: per-track Insert 1/2, Send 1, Send 2, Master insert.

Priority order (build the infrastructure with 2-3 cheap FX, then expand):

**Tier 1 (MVP-adjacent, cheap, high value)**
- Drive/clip distortion (also validates the insert infrastructure)
- Delay (tempo-synced, feedback, filter in loop)
- Reverb (algorithmic — SC `JPverb`-style or `FreeVerb`-family to start)
- Bit reduction + sample-rate reduction (one "LOFI" machine, two knobs)

**Tier 2**
- Compressor (track insert + a master "glue" variant)
- Chorus / Flanger / Phaser (one modulated-delay core, three machine faces)
- Tape delay (wow/flutter, saturation in the loop)
- Wavefolder

**Tier 3 (experiments — each needs a CPU spike first)**
- Convolution reverb (SC `PartConv`; load IRs from dust. Feasible on norns
  only as a single send instance, if at all — benchmark before promising)
- Warbler (dedicated wow/flutter/dropout tape-character effect)
- Filter-as-FX (the filter machine catalog available in an FX slot — free
  feature once both use the machine pattern)

## 5. Parameter conventions (project law)

These were settled deliberately; don't relitigate:

- **Amounts** (levels, times, depths, drive, cutoff, resonance, volume):
  **0-127**, Elektron style. Envelope times map exponentially to seconds
  via the range setting; value 128 on env Hold/Release is the INF sentinel.
- **Positions/spans** (loop start/end, range start/end): **0-128** fence-post
  space; 128 = 2^7 divides evenly forever (0-127 does not).
- **Bipolar/centered** (pan, morph, balance, env depth): **0-128** with 64 =
  true center (odd step count gives symmetric sides).
- **P-lockable by default.** Machines themselves (generator, filter, FX
  choice) and envelope *modes* are settings. Behavioral flags (trig_jump,
  trig_release, resets) are p-lockable but excluded from continuous
  param-lock application (consumed at trigger time).
- Engine sends: continuous/encoder-driven params go through the coalesced
  12Hz `queue_engine_call`; one-shot events (note_on, region+phase) send
  immediately.

## 6. Patterns & sequencer model

### 6.1 Pattern slots

**16 patterns per project.** A pattern is near-total snapshot: sequences,
step locks, track settings, machine choices (generator/filter/FX machines and
their params), module settings — everything *except* the global scope below.

**Global (project-level, shared by all 16 patterns):**
- The sample pool (128 slots + per-slot metadata) and all File settings.
- Master volume and master settings (clock sync, step preview, live step
  trig, performance mode, etc.).
- **BPM is per-pattern by default**, with a master setting ("global BPM")
  that, when enabled, forces one project-wide tempo regardless of pattern.

### 6.2 Pattern-load grid mode

Dedicated **pattern key at X8,Y5** (above the mini keyboard).

- Press: enter pattern-load mode — the bottom step row becomes the 16 pattern
  slots. Hold: momentary mode, exits on release.
- In the mode: pitch keys inert; Up/Down/Left arrows inert; **NO** exits;
  any top-row category key exits; **Right arrow = rename current pattern**
  (opens the text-entry dialog, §7.3); pressing a pattern slot loads it and
  exits the mode.

### 6.3 Pattern change quantization (Tonverk-style)

A PATTERN setting selects how a newly chosen pattern engages during playback:

- **Sequential** (default): the new pattern starts when the current one
  reaches its end — the **global pattern length** defines that boundary.
- **Direct Jump**: switch immediately; the new pattern picks up at the
  current playback position.
- **Direct Start**: switch immediately; the new pattern restarts from step 1.
- **Temp Jump**: switch immediately; when the temp pattern completes one
  pass, playback automatically returns to the previous pattern.

### 6.4 Track vs global pattern length

Each track has its own pattern length (polymeter); a separate **global
pattern length** defines the pattern cycle — sequential pattern advances (and
Temp Jump returns) happen on the global boundary.

### 6.5 Trig conditions (MVP)

Each step gets **two independent p-lockable fields**; a trig fires only if
both pass:

- **Chance**: 0-100% probability.
- **Condition**: none | A:B cycles (1:2, 2:2, 1:3, 2:3, 3:3, 1:4 ... through
  the standard Elektron set) | Fill | !Fill | Pre | !Pre | NEI | !NEI | 1st.
  - *Pre* = the previous conditional trig on this track passed.
  - *NEI* = the neighbor track's previous conditional passed — meaningless
    until multitrack; the options exist but evaluate as always-true until
    then.
  - *1st* = only on the first pattern pass after entering it.

**Fill key: X16,Y6** (directly above the page key). Hold = momentary fill;
FN+Fill = latch on/off. Fill state drives Fill/!Fill conditions.

Plus (same workstream): **ratchets** (per-step retrig count/rate p-lock) and
**swing** (global amount + per-step micro-offset p-lock).

### 6.6 A/B crossfader morph (in MVP, 1-track)

Two scene snapshots (A/B) capture p-lockable param values; a crossfader
morphs every captured param continuously between them — the Octatrack gesture,
single-track first. Hold a scene anchor + adjust a param to lock it to that
scene; the multitrack version (per-track inclusion, track volumes) follows
the design in `docs/MULTITRACK_ARCHITECTURE.md` Phase 4.

**Open layout question**: the multitrack design placed the scene row on row 5
cols 8-15, but X8,Y5 is now the pattern key. Proposed resolution: scene
anchors + crossfade surface on **row 5 cols 9-16** (A=9, surface 10-15, B=16),
keeping x1/x2 octave, x8 pattern. Confirm before building.

## 7. Projects & persistence

### 7.1 Project files

**Everything serializes to a project file**: all 16 patterns (sequences,
locks, per-pattern settings/machines), pool slot assignments + metadata,
global settings. Operations: **Load**, **Save** (to the loaded project's
path), **Save As New**. Browsing uses the existing fileselect pattern.

**Auto-naming** (a setting) when saving a new project:
- **None** — user types a name (text-entry dialog).
- **Date** — `yymmdd-hhmm`.
- **Namesizer** — generated via the `/dust/code/namesizer` library. Detected
  at runtime (`util.file_exists`); if absent the option hides/falls back to
  Date.

### 7.2 Temp work project + recall

- The active session **auto-saves to a temp project file** — but **only while
  playback is stopped** (never mid-playback; no audio stutters). Cadence:
  debounced after edits while stopped, and on transport stop.
- The loaded project's own file is written **only by explicit Save** — the
  temp copy is the scratch. Mess up the temp state? Re-load the project from
  disk and you're back.
- **Script reload / power cycle loads the temp work project** — leave and
  come back, everything is as you left it. If the temp state is broken,
  "New Project" reinitializes and becomes the new working project.
- **Memorize/Recall (RAM, playback-safe)**: snapshot the whole project state
  to a memory buffer and recall it instantly, usable *during* playback.
  Grid: **FN + Octave Down (X1,Y5) = Recall**, **FN + Octave Up (X2,Y5) =
  Memorize**.

### 7.3 Text-entry dialog (generic)

A modal popup rendering over everything, reusable anywhere text input is
needed (project names, pattern rename, future uses).

- **Norns controls** (user notation K=knob/encoder, B=button): E2 moves the
  cursor/character index, E3 selects the character at the index; K2 =
  backspace, K3 = accept, K1 = cancel. *(Interpretation of the spec — confirm
  feel at build time; norns' stock `textentry` UX is the reference point.)*
- **Grid**: while the dialog is open the grid becomes a **QWERTY keyboard**
  (Synthstrom Deluge style): letter rows + shift/space/backspace/enter.
  Dialog closes → grid returns to its previous mode.

## 8. The 1-track MVP (current focus)

**Definition of done — a person who is not us can:** load samples, sequence
and p-lock all four machines across 16 patterns, mangle live (loop keys, live
step trig, scrub, fill, crossfader), shape with filter + amp envelope, add
basic FX, and have everything survive reloads and power cycles via the
project system. Solid, no pops, no CPU spikes above ~25%.

Checklist (order within the list ≈ suggested build order):

- [x] 4 machines, 6 warp modes, region layers, trig machinery (§2)
- [x] Amp envelope/pan/vol; filter Classic + Morphing with filter env
- [x] **Projects system** (§7): temp work project + autosave-while-stopped,
      load/save/save-as, text-entry dialog (norns + grid QWERTY), auto-name
      modes, memorize/recall. *MVP blocker.*
- [x] **Patterns** (§6.1-6.4): 16 slots, pattern-load grid mode, rename,
      quantized switching (all four modes), per-track + global lengths.
- [x] **Trig conditions + ratchets + swing + Fill key** (§6.5). (Per-step swing micro-offset deferred; global swing shipped.)
- [x] **A/B crossfader morph, 1-track** (§6.6).
- [x] Filter machines 3-6 (stereo + M/S variants of the two shipped filters)
- [x] FX infrastructure: 1 insert slot + 2 sends + master bus, with Tier-1 FX
      (drive, delay, reverb, lofi)
- [x] Engine `noteOff` (live-held note release gates the ADSR properly)
- [x] `tempo_varispeed` pitch implemented (rate-coupled drift on the transport phase)
- [ ] CPU verified ≤ ~25% with filter + 3 FX active
- [x] A `dust`-ready release: docs/README for strangers, sane defaults (README + docs/CONTROLS.md shipped)

Explicitly **not** MVP: multitrack, mod matrix/LFOs, neighbor/input machines,
comb/ladder/formant filters, Tier-2/3 FX, convolution, MIDI mapping,
sampling/resampling (§9).

## 9. Feature backlog (post-MVP)

1. **Resample to slot** — record the master bus into a free pool slot, then
   mangle the mangled. The loop-mangler ouroboros; a killer identity feature.
   Documented ideas: threshold-armed record start; beat-quantized record
   lengths (1/2/4/8 bars) so BPM/steps metadata is auto-correct; auto-slice
   after record; record into the *currently playing* slot for feedback-loop
   madness (dangerous, wonderful).
2. **Live input sampling** — record the audio input into a pool slot (pairs
   with the multitrack `input` chain source); same armed/quantized record
   machinery as resampling.
3. **LFOs / mod matrix** — multitrack Phase 3; `lfo_reset` p-locks already
   reserve the trig-page slot.
4. **Pattern chaining / song mode** — chain the 16 slots into songs.
5. **Dice/randomize page** — randomize locks within user-set ranges, undo.
6. **Grid performance visualizer** — LEDs following phase/envelope.
7. **MIDI mapping** — params + pattern/scene switching from external gear.

## 10. CPU budget & strategy

Baseline: **11% avg / 15% spike** = transport + 1 reader + filter + Lua UI.

Working budget (norns stock; leave ~25% headroom for the OS/softcut):

| Stage | Budget |
|---|---|
| Per track (reader + filter + amp env) | ≤ 7% |
| Per insert FX | ≤ 2% |
| Each send FX (shared) | ≤ 4% |
| Master chain | ≤ 3% |
| Lua/UI/grid | ≤ 5% |

8 tracks x 7% + 4 sends/master ≈ 70% — the theoretical ceiling. Expect the
practical answer to be **4-6 tracks with 1-2 inserts**, or 8 tracks with FX
only on sends. Decided by measurement at each phase gate
(`docs/BENCHMARK_RESULTS.md`), not in advance.

Levers, in order of preference:
1. Active-track-count setting (engine instantiates only what's used).
2. Bypass = free: a neutral filter/FX slot allocates **no synth** (not a
   running synth at unity).
3. One reader synth per track (already true — modes crossfade-swap).
4. Shared send FX instead of per-track inserts.
5. Control-rate everything modulation-side; audio-rate only where audible.
6. No per-voice filters.
7. Lua-side: autosave only while stopped (project law, §7.2); serialization
   must never run in the audio-critical path.

## 11. Phasing

MVP (§8) precedes everything. After MVP ships, the multitrack phases in
`docs/MULTITRACK_ARCHITECTURE.md` apply as written (Phase 1 scaffolding →
Phase 8 performance pass), with these pulled forward into the MVP in 1-track
form: Phase 2 partially (filter/amp exist), Phase 4 partially (A/B crossfader
morph), Phase 7 substantially (projects). Their multitrack phases become
"generalize to per-track" rather than "build from scratch."

Every phase gate = hardware-verified acceptance criteria + regression check +
CPU measurement, per the multitrack doc.

## 12. Doc map

| Doc | What it answers |
|---|---|
| `docs/PRD.md` (this) | What are we building and why; catalogs; conventions; patterns/projects; MVP; budget |
| `docs/ARCHITECTURE.md` | How the code is organized; modularity rules; extension recipes |
| `docs/MULTITRACK_ARCHITECTURE.md` | Multi-track design + phased acceptance criteria |
| `docs/WORKSTREAMS.md` | Which agent/worktree owns what; integration protocol |
| `docs/MODE_CATALOG.md` | Warp mode reference |
| `docs/TEST_PLAN.md` / `docs/BENCHMARK_RESULTS.md` | Verification + CPU measurements |
