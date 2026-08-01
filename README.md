# Elasticat

Elasticat is a sample-loop mangler and performance sequencer for monome norns
+ grid. It marries Elektron-style step sequencing and parameter locks with
live, continuous manipulation of a tempo-warped loop — program a sequence,
then scrub the loop's trim/range/region live while it plays. That live-scrub
gesture is the whole point: it stays playable and p-lockable everywhere in
the script.

This is a single-track instrument today (a multi-track version is planned).
Everything below describes the current, shipped behavior.

## Requirements

- A monome norns (or norns shield/fates running the norns OS).
- A monome grid, **128 (8x16) size**. Elasticat's entire surface — the
  step sequencer, transport, loop/slice keys, the mini keyboard, patterns,
  scenes, and settings — is grid-only. The norns keys and encoders can
  browse pages, audition sounds, and edit parameter values, but **playback
  start/stop and every step/loop/slice trigger live on the grid**. Treat the
  grid as required, not optional.
- Some free space in `dust/data/` and `dust/audio/` for projects and samples.

## Install

In maiden's REPL:

```
;install https://github.com/Quixotic7/Elasticat
```

Then pick **elasticat** from the norns SELECT menu. (Or clone/copy this folder to
`dust/code/elasticat/` on the norns and load it manually.)

### Compiled DSP (installs itself)

elasticat's warp engines use a small compiled SuperCollider plugin
(`ElasticatUGens.so`) that ships **prebuilt** for the norns. On launch the script
copies it into your SuperCollider Extensions folder automatically — nothing to do.
It runs fine without the plugin too (every warp mode has a pure-SuperCollider
fallback); the plugin just adds click-free reads and leaner grain/slice/wavetable
DSP.

### Updating

```
;update elasticat
```

If an update ships a newer plugin and the compiled DSP doesn't engage afterward,
**SLEEP → wake** the norns once so SuperCollider reloads it.

### Troubleshooting the DSP

The prebuilt plugin targets the norns platform (32-bit armv7l). In the rare event
it won't load, rebuild it from the bundled source on the norns (no toolchain to
install — norns ships g++ and the SuperCollider headers):

```
ssh we@norns.local
~/dust/code/elasticat/lib/ugens/build.sh
```

then SLEEP → wake. See [`lib/ugens/README.md`](lib/ugens/README.md) for details.

## Quick start

1. Connect your grid before (or after) loading the script — it reconnects
   automatically.
2. Press the **FILE** category key (grid `8,1`) to open its SAMPLE page.
   Press `K3` once to select the pair containing the `FILE` cell, then turn
   `E2` to open the sample browser and load a `.wav`. Filenames like
   `break_bpm136.wav` auto-fill the sample's BPM.
3. Press grid `4,1` (**PLAY**) to start the transport. With no steps
   programmed yet you'll hear the loaded sample looping — that's the main
   loop, always on.
4. Tap a few keys in the bottom **step row** (`y=8`) to toggle trigs on. Each
   trig replays the loop from its start. Congratulations, that's a
   sequence — under a minute, as promised.
5. While it plays, hold one of the **loop keys** in row `y=2` — the loop
   jumps to and plays from that key's position live. Let go and it eases
   back. That's the signature move; try it on different steps, machines, and
   pages.

## Grid reference

Elasticat maps its whole surface at once; what a given zone does can depend
on the active param **category** (row 1) and the active **machine** (loop
vs. slice). The map below shows the default/loop-machine layout.

```
y\x     1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
y1     FN    -  REC PLAY STOP    -  MST FILE  PAT    - TRIG  SRC FILT  AMP   FX  MOD
y2      1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
y3     17   18   19   20   21   22   23   24   25   26   27   28   29   30   31   32
y4      -    -    -    -    -    -    -    -    -    -    -    -    -    -    -    -
y5   OCT- OCT+    -    -    -    -    - PATN SC-A  xf1  xf2  xf3  xf4  xf5  xf6 SC-B
y6      -   C#   D#    -   F#   G#   A#    -    -    -  YES    -   UP    -    - FILL
y7      C    D    E    F    G    A    B  C+1    -    -   NO LEFT DOWN RGHT    - PAGE
y8      1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
```

`-` is unused/reserved — nothing happens if you press it.

### Key/zone table

| Zone | Grid (x,y) | What it does |
|---|---|---|
| FN | `1,1` | Hold as a modifier (like a shift key). Norns `K1` does the same thing. |
| REC | `3,1` | Toggles the recording indicator (arms/disarms; recording itself is a future feature). |
| PLAY | `4,1` | Toggle play/pause without resetting to step 1. |
| STOP | `5,1` | Stop and reset the sequencer to step 1. |
| Category keys | `7,1` `8,1` `9,1` `11,1`-`16,1` | MASTER, FILE, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, MOD. Press to switch category; press the *same* one again to cycle its pages. Hold FN and press one to open its **settings** page. |
| Loop keys 1-16 | row `y=2` | Loop machines: 16 positions across the loop region — hold one to jump the live loop there. Slice machines: triggers slices 1-16. |
| Loop keys 17-32 | row `y=3` | Loop machines: only active when **SOURCE settings > LDIV (loop key division)** is raised above 16 (default 16, so row 3 is normally idle for loop machines). Slice machines: triggers slices 17-32. |
| Octave down/up | `1,5` / `2,5` | Shifts the mini keyboard (rows 6/7) down/up an octave (range -2..+2). With **FN held**, these become **Recall** (`1,5`) and **Memorize** (`2,5`): Memorize snapshots the whole project (patterns, params, pool, scenes) to RAM; Recall restores it instantly, safe during playback. Recall lights up only once something is memorized. |
| PATN | `8,5` | **Pattern-load** overlay. Quick tap latches it open (tap again to close); a longer hold is momentary (closes on release). While open, the step row (`y=8`) shows the 16 pattern slots — press one to load it. The Right arrow (`14,7`) renames the current pattern. Hold FN and press this key instead to open the on-screen pattern-quantize menu. |
| Scene A / Scene B | `9,5` / `16,5` | A/B crossfader scene anchors. Hold one and turn `E2`/`E3` to write that parameter's value into the held scene only (doesn't change what you hear). FN + press captures *every morphable parameter's* current value into that scene at once. |
| Crossfader glide keys | `10,5` – `15,5` | Six positions spanning A (`10,5`) to B (`15,5`). Holding one eases the crossfade toward that position (~0.3s); tap for a nudge, hold to land there. Release freezes wherever it got to. |
| Black keys (mini keyboard) | `2,6` `3,6` `5,6` `6,6` `7,6` | C#, D#, F#, G#, A# of the current octave. |
| YES | `11,6` | Confirm in menus/dialogs (same as norns `K3`). On the FILE page, hold to preview the loaded sample's trim while stopped. |
| Up arrow | `13,6` | Menu/settings navigation (up), or with PAGE held, selects "Page Select" mode. |
| FILL | `16,6` | Hold for momentary Fill (drives Fill/!Fill trig conditions); FN + press latches Fill on/off. |
| White keys (mini keyboard) | `1,7`-`8,7` | C D E F G A B C (one octave + the root of the next). |
| NO | `11,7` | Cancel in menus/dialogs (same as norns `K2`). |
| Left arrow | `12,7` | Menu/settings navigation (left/value down), or with PAGE held, selects "Pattern Rate" mode. |
| Down arrow | `13,7` | Menu/settings navigation (down), or with PAGE held, selects "Page Loop" mode. |
| Right arrow | `14,7` | Menu/settings navigation (right/value up/confirm on action rows); with PAGE held, back to "Page Select" mode. While the pattern-load overlay is open, **renames the current pattern**. |
| PAGE | `16,7` | Hold down to turn the step row into a page-mode overlay: pick which param page plays (Page Select), which pages loop during playback (Page Loop), or the per-page playback rate (Pattern Rate) using the up/left/down arrows above, then tap a step-row key to apply. |
| Step row | row `y=8` | The 16 steps of the current param page. Quick tap = toggle a trig on/off. FN + quick tap = toggle a **ghost** trig (carries state forward without re-triggering). Hold a step, then turn `E2`/`E3` (or press loop/pitch keys) to parameter-lock it. Hold a step + norns `K2`/`K3` clears one lock; hold FN(`K1`) + `K2`/`K3` clears that parameter's locks across the whole pattern. |

## Copy, clear, and paste

Like the Elektron boxes, the REC/PLAY/STOP keys double as **COPY / CLEAR /
PASTE** while a scope is held — each scope keeps its own buffer:

- **Steps** — hold one or more steps + REC copies them (with their p-locks);
  hold a destination step + STOP pastes, preserving the copied steps'
  spacing; hold a step + PLAY clears its p-locks but keeps the trig.
- **Sequencer page** — hold PAGE + REC/PLAY/STOP copies/clears/pastes the
  selected page.
- **Pattern** — FN + REC/PLAY/STOP copies/clears/pastes the whole pattern
  (clear asks for confirmation and wipes trigs only).

## Norns keys and encoders

| Control | Action |
|---|---|
| `K1` (hold) | FN modifier — never a quick-press action (norns reserves a quick K1 tap for its own system menu). |
| `K1` + turn `E1` | Clockwise: open the current category's settings page. Counter-clockwise: leave settings. |
| `K1` + turn `E2`/`E3` | Snap the currently-edited parameter to a useful preset value instead of a smooth adjustment. |
| `E1` | Cycle through parameter pages, rolling from one category into the next at the ends. |
| `E2` / `E3` | Edit the left/right parameter of the current page's selected pair. |
| `K2` / `K3` | Move to the previous/next parameter pair on the page. |
| Hold a step + `E2`/`E3` | Parameter-lock that step's value for the currently-edited parameter. |
| Hold a step + `K2`/`K3` | Clear that step's lock on the corresponding (left/right) parameter. |
| `K1` + `K2`/`K3` | Clear that parameter's locks across every step in the pattern. |
| **In settings** (after opening one with `K1`+`E1`): `K3`/grid YES | Confirm / invoke the selected row's action. |
| `K2`/grid NO | Cancel / close settings. |
| grid up/down arrows or `E2` | Move the selected settings row (crosses pages). |
| grid left/right arrows or `E3` | Adjust the selected row's value (or confirm, on an action row). |

## Core concepts

### Machines and warp modes

The **machine** is the sound generator a track uses, chosen on the SOURCE
settings page:

- **loop** — plays the selected region continuously once the transport
  starts; every trig restarts it. Holding a step and then tapping one loop
  key locks that step's *start and end*; tapping the same key again drops the
  end lock (start-only, end follows the track); holding a step with two or
  more loop keys locks both start and end from their span (a live loop-key
  press with no step held instead drives the *live* region directly — see the
  region model below).
- **loop_trig** — the same engine, but silent except during a triggered
  step; a step's loop-key lock sets exactly the region *that step* plays.
- **grid_slice** — divides the region into up to 32 equal slices. Row `y=2`
  plays slices 1-16, row `y=3` plays 17-32. A step can carry more than one
  slice unless slice polyphony is set to mono.
- **razor_slice** — same slice-trigger engine as grid_slice, but each slice
  gets its own precise start/end pair (moving a slice's start moves its end
  by the same amount, preserving its length).

Loop machines also pick a **warp mode** — how the region is actually read
back:

- **tape** — plays at the sample's native rate, tape-deck style; pitch is
  true varispeed (faster = higher, slower = lower).
- **tempo_varispeed** — forces the region to fit the current step length and
  BPM, so it always lands exactly at the loop boundary. (Known gap: the
  pitch control doesn't do anything in this mode yet.)
- **chopped** — slices the loop into rhythmic chunks (chop steps sets how
  many) with forward-stop, loop-forward, or ping-pong playback per chunk.
- **granular** — reads the region as small overlapping grains; grain size,
  density, and jitter shape the texture, and pitch shifts grains
  independently of loop length.
- **random_ola** — a looser, shuffled overlap-add stretch with wander/random
  placement around the moving playhead.
- **pitch_corrected** — plays the tempo-synced region through a pitch
  shifter, so timing and pitch are corrected separately (has its own
  robotic/formant character, tunable via the PC window/dispersion params).

### The region model: Track, Step, and Actual

Elasticat layers the loop **region** (and the **Range**, a narrower window
inside the file's trim) in three levels:

- **Track** — the region you set directly on the SOURCE (or RANGE) page.
  This is always live-editable, whether or not anything is sequenced.
- **Step** — a step can carry its own region lock (hold the step, then tap
  loop keys) and/or its own Range lock (hold the step, then turn the RANGE
  page's `R-ST`/`R-EN` encoders). While that step is the one currently
  sounding, its lock shadows the Track region for exactly as long as the
  step's note lasts, then falls back.
- **Actual** — what you actually hear right now. Priority order: a **live
  held loop key** always wins (even over a step's lock), then the current
  **Step** lock if one is active, then the **Track** region underneath
  everything.

When an override ends — a step's lock's window elapses, or you let go of a
held loop key — **Trig Release** (per-step lockable, or the TRIG page 3
default) decides what happens next:

- **Return** (default) — the main loop snaps back to exactly where it would
  naturally be if the override had never happened, so a tempo-warped loop
  stays perfectly in sync.
- **Boomerang** — plays the override region backwards on the way out.
- **Reset** — restarts the main loop from its own start.

**Trig Jump** (per-step lockable, TRIG page 3) governs how a *new* trig
engages its region: on (default) it snaps the playhead to the new region's
start every time — tight, quantized retriggering. Off, the playhead keeps
walking through its current absolute position instead, only warping to the
region's start if that position would otherwise fall outside it — looser,
more glide-like transitions between step regions.

### Parameter locks (p-locks)

Almost every parameter is p-lockable (Elektron-style): hold a step in the
step row and turn `E2`/`E3` (or press a loop/pitch/slice key) to lock that
value into the step. A locked step applies its stored value only while it's
triggering; everywhere else the Track-level (unlocked) value keeps playing.
Machine/filter/FX *choice* and envelope *mode* are settings, not p-lockable
— their individual parameters are.

Clearing locks: hold the step and press `K2`/`K3` to clear one parameter's
lock on that step; hold `K1` (FN) and press `K2`/`K3` to clear that
parameter's locks across every step in the pattern.

### Trig conditions, Fill, ratchets, and swing

Every step carries two independent, p-lockable fields (TRIG COND page) that
both have to pass for the step to actually fire:

- **Chance** — 0-100% probability roll.
- **Condition** — none, an Elektron-style A:B cycle (fires on the A-th of
  every B pattern passes, e.g. `1:2`, `2:3`... up to `4:4`), `FILL`/`!FILL`
  (gated by the Fill key below), `PRE`/`!PRE` (did this track's *previous*
  conditional trig pass?), `NEI`/`!NEI` (reserved for a future neighbor
  track — always true today), or `1ST` (only the first pass after entering
  this pattern).

**Fill** (grid `16,6`): hold for momentary Fill, or hold FN and press to
latch it on/off. Drives the FILL/!FILL condition above.

**Ratchets**: the TRIG COND page's RTCH field (1-8, p-lockable) re-triggers
a step that many times, evenly spaced across its own duration — a quick way
to get rolls/flams without extra steps.

**Swing**: TRIG settings has one global SWING amount (50 = straight, up to
75 = heavy swing). It lengthens odd-numbered steps and shortens the
following even one by the same ratio. There is currently no per-step swing
offset — it's a single pattern-wide amount.

### Patterns and quantized switching

A project holds **16 patterns**. A pattern is a near-total snapshot: every
track's sequence, step locks, machine/filter/FX choices and their settings,
and per-pattern BPM. What's *not* per-pattern (it's global, shared by every
pattern) is the sample pool, File settings, master volume, and the other
master settings.

Press the **PATN** key (`8,5`) to open the pattern-load overlay (tap to
latch it open, or hold briefly for a momentary look) — the step row becomes
the 16 pattern slots; press one to load it. The Right arrow (`14,7`, while
the overlay is open) opens the rename dialog for the current pattern.

How a newly-picked pattern actually engages is set on the PATTERN settings
page (**pattern change**):

- **Sequential** (default) — the new pattern starts when the current one
  finishes its global cycle.
- **Direct Jump** — switches immediately, picking up at the current step.
- **Direct Start** — switches immediately, restarting from step 1.
- **Temp Jump** — switches immediately, then automatically returns to the
  previous pattern after one full pass of the new one.

Each track has its own pattern length (`LEN`), while a separate **global
pattern length** (`GLEN`, also on the PATTERN page) sets the boundary that
Sequential switches (and Temp Jump returns) wait for.

### Projects, autosave, and renaming

Everything — all 16 patterns, the sample pool and its metadata, and the
global settings — lives in a **project file** (`.eproj`, stored under
`dust/data/elasticat/projects/`). Manage projects from MASTER settings, page
2 (**PROJECT**): hold FN and press the MASTER category key (`7,1`) to open
MASTER settings, then press `7,1` again *without* FN to cycle to the PROJECT
page (or just scroll down past the last item of settings page 1 — it
auto-advances):

- **LOAD** — browse and open a saved project.
- **SAVE** — write to the currently-loaded project's file.
- **SAVE AS NEW** — write to a new file (named via AUTO-NAME below, or typed
  in if AUTO-NAME is set to None).
- **NEW PROJECT** — reset to a blank project.
- **AUTO-NAME** — None (type a name) or Date (`yymmdd-hhmm`) for Save As
  New / New Project.

You never have to remember to save while you work: whenever the transport
is **stopped**, edits auto-save (debounced a couple of seconds) to a hidden
temp-work project. Reloading the script, or power-cycling norns, resumes
exactly where you left the temp project — no explicit save needed to keep
working. Your actual project **file** on disk is only touched by an
explicit SAVE / SAVE AS NEW, so if you mess up the temp state, reloading the
saved project from disk gets you back to your last real save. Autosave never
fires while the transport is playing, so it can't cause an audio hiccup.

Renaming a pattern (or typing a project name) opens a modal text-entry
dialog. On the norns front panel: `E2` scrolls a character picker, `E3`
commits the highlighted character (append-only — there's no independent
cursor), `K2` backspaces, `K3` accepts, `K1` cancels. On the grid, it
becomes a QWERTY keyboard while open: letter rows on `y=2` (QWERTYUIOP),
`y=3` (ASDFGHJKL), `y=4` (ZXCVBNM), and a control row on `y=5` — space
(`1,5`-`8,5`), shift (`10,5`-`11,5`, hold for uppercase), backspace
(`13,5`-`14,5`), and OK (`16,5`).

### A/B crossfader scenes

The MASTER page's `XFD` value (also grid row `y=5`, columns 9-16 — see the
grid reference above) is an Octatrack-style A/B scene crossfader. Capture
the current sound into scene A or B with FN + the scene anchor key, or lock
individual parameters into a scene by holding its anchor and turning `E2`/
`E3` — that edit writes only into the held scene, the live sound doesn't
move until the fader does. Move the fader (or hold one of the six glide
keys) to morph continuously between A and B; a parameter untouched in both
scenes is left alone by the fader.

### Filter machines

Each track has one post-mix filter (after voice summing, before pan/volume)
with its own AHR or ADSR envelope (independent of the amp envelope). Choose
the machine on FILTER settings:

- **Classic** — Elektron-style multimode: TYPE sweeps LP/HP/BP/notch, plus
  Cutoff/Res/Drive.
- **Morphing** — one MORPH knob sweeps low-pass → notch → high-pass, plus
  Cutoff/Res/Drive.
- **Classic Stereo** / **Morphing Stereo** — two independent filter instances
  (one per channel), with a BAL param (centered 0-128, 64 = both channels
  identical) spreading their cutoffs: full right pushes the R channel's
  cutoff up and L's down, full left mirrors that.
- **Classic Mid/Side** / **Morphing Mid/Side** — decodes to mid/side,
  filters each independently, re-encodes to L/R; the MSBL param spreads
  cutoff between Mid and Side the same way BAL does for Stereo.

All six machines share the same TYPE/MORPH, Cutoff, Res, and Drive controls
as their mono counterpart.

Filter envelope DEPTH modulates cutoff (bipolar, 64 = no modulation).

### FX insert

The FX section has four slots: **Insert 1** (in the track's chain, after the
filter), **Send 1** and **Send 2** (parallel buses fed by a send tap you can
place before or after Insert 1 — send levels live on FX page 2 as SEND1/SEND2
and are p-lockable, so you can throw individual steps at a reverb or delay),
and a **Master** insert on the final output (it colors everything, send
returns included). Every slot picks from the same machine list, chosen in FX
settings, and each slot's knobs get their own FX page — Insert 1 on page 1,
Send 1/2 on pages 3/4, Master on page 5 — showing whatever the active machine
offers (all p-lockable):

- **None** — passthrough (default; costs nothing).
- **Drive** — tanh-style clip/saturation.
- **Delay** — tempo-synced, with feedback and a tone (filter-in-loop)
  control.
- **Reverb** — algorithmic (FreeVerb-family), Size/Damp/Mix.
- **Lofi** — bit-depth and sample-rate reduction.

## Troubleshooting

**No sound:**
- Is a sample actually loaded? FILE page > SAMPLE, check the `FILE` cell.
- Is the transport running? Grid `4,1` (PLAY) — the grid is the only way to
  start/stop playback; norns `K` keys don't do it.
- Filter cutoff wide open? Filter defaults to fully open, but if you've been
  turning knobs, check FILTER page CUT hasn't been dragged down.
- Master/track volume (`VOL` on the MASTER or AMP page) at zero?
- Crossfader (`XFD`) parked on a scene that has volume/amp locked low?
- FX insert MIX turned all the way one way when you didn't mean it to be?
- Is the amp envelope's HOLD stuck at a very short value with a slow ATK, so
  the note has already died by the time you're listening? (Default AHR is
  attack 0 / hold INF / release 0 — an instant-on drone — so this usually
  isn't the culprit out of the box, but it's the first thing to check after
  experimenting with envelopes.)

**CPU tips:**
- Elasticat's baseline is roughly 11% average / 15% at spikes for one track
  with the filter and Lua UI running — that's normal.
- An FX insert set to **None** costs nothing; only switch one on when you
  want it.
- Heavier warp modes (granular, random_ola, pitch_corrected) cost more than
  tape/tempo_varispeed — if you hear glitching or see norns' CPU meter
  climbing, try a lighter warp mode first.
- The Lua-side redraw/grid-refresh loop is throttled already; if things feel
  sluggish it's more likely an engine-side (SuperCollider) load issue than
  a UI one.

**Known limitations (not bugs, just not built yet):**
- `tempo_varispeed`'s pitch control doesn't change anything yet.
- Releasing a live-held step (Live Step Trig) doesn't gate the amp envelope
  off — the note keeps ringing until the next trigger re-gates it.
- `loop_trig`'s live-hold behavior is approximate: it can go silent between
  gates instead of holding cleanly.
- There's no Insert 2 slot yet (Insert 1, two sends, and the master insert
  are in).

## Credits / license

Elasticat is developed as part of the NornsTimestretch project. No license
file is included yet — add one here before distributing outside your own
use.
