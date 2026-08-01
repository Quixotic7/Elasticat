# Changelog

## FX pages: change the effect on-page (Mode-Parameter layout)

- The four FX slot pages (Insert 1, Send 1, Send 2, Master) now use the same two-row + banner layout as FILTER MIX and WARP. The FX machine selector is the bottom-left banner, so you can switch the effect on the page — select the banner pair, hold FN, turn K2 — without opening the settings menu.
- Each machine's parameters fill the two low-profile rows above the banner. Unlike the warp/filter mode banners, the FX machine can be changed during playback (FN still guards an accidental turn): the engine respawns the effect without stopping the transport.
- The Sends routing page (send levels + tap) is unchanged.

## Filter machines + FILTER MIX page

- The filter is now a selectable **machine**, like the warp engine, chosen from the FILTER settings: **CLASSIC** (LP/HP/BP/notch), **MORPHING** (continuous LP→notch→HP), **LADDER** (Moog-style, self-oscillating), **COMB** (tuned feedback comb), and **FORMANT** (A–E–I–O–U vowel bank). Cutoff, resonance, drive and the filter envelope stay p-lockable across all of them.
- Every machine runs in stereo and supports a per-track **stereo OR mid-side balance**, spreading the two channels' cutoffs from a single bipolar control.
- New **FILTER MIX** page (a third FILTER page) hosts the balance control and the stereo/mid-side mode. It introduces the reusable **"Mode Parameter"** page layout: two rows of low-profile params over an FX-style banner that shows the current mode. The mode is not p-lockable and, like the warp engine, only changes with playback stopped and FN held.
- Each machine keeps CUT on the first parameter cell, RES on the second, and the envelope DEPTH on the fourth, so the core controls never move between machines.

## WARP page adopts the Mode-Parameter layout

- The WARP page now uses the same design as FILTER MIX: the warp-engine selector is the bottom-left banner, and the synced **RATE** multiplier sits at the bottom-right next to it. Selecting the last pair edits the warp mode with K2 (stopped + FN) and RATE with K3 (freely, and p-lockable).
- Each mode's own parameters fill the two rows above; a mode can carry up to eight. Modes with an amplitude envelope always show **Attack then Release** together on the second row, so every envelope reads the same regardless of the mode.

## Elektron-style param page rendering (FILTER/AMP/FX visual overhaul)

- New `lib/ui/page_render.lua` replaces the bare label+value cells on every generic K2/K3-pair param page (master/pattern/trig/source machine+warp/filter/amp/fx/mod) with a Digitakt-inspired layout: a faintly framed 2x4 cell grid, small dim label over a bright value per cell, a 2px position bar under every ranged value (bipolar params like PAN/MRPH/BAL/DPTH/XFD fill from center), a bright outline around the selected K2/K3 pair, label-chip inversion for held p-locks/scene locks, and value-chip inversion as the momentary edit flash. Rendering only -- the interaction model (K2/K3 pair select, E2/E3 edit, E1 page, grid category keys) is unchanged.
- Per-category widgets fill each page's unused cell space: FILTER p1 draws the active machine's response curve (type/morph shape, cutoff position, resonance peak, stereo/MS balance as a dim ghost curve, machine name tag), FILTER p2 draws the filter envelope (AHR/ADSR, height scaled by DEPTH, negative depth hangs downward), AMP draws the amp envelope (AHR/ADSR incl. INF hold/release as flat-to-edge), FX p1 shows the Insert 1 machine name as a large banner (NONE reads BYPASS), FX p2 shows Send 1/2 machine names with live level bars.
- Widget geometry reads through `ParamValues:item_raw_value`, so held step p-locks and scene locks move the curve/envelope live.
- Cell drawing is level-batched into passes (never per-cell `screen.level`, guarding against the historical redraw-metro freeze) and curves are <=23-point polylines; `bin/test-elasticat-lua` gains a render sweep that drives every category/page/machine/env-mode/filter-type through a recording screen stub and asserts the per-frame `screen.level` call count stays bounded.

## Sample metadata writes deferred instead of timer-throttled

- Replaced the timer-based throttle for trim/bpm/steps/gain sidecar writes with a dirty-flag approach: edits just mark the slot dirty and update the screen/engine live, with the actual disk write (sidecar file + pool-state snapshot) deferred until the sample slot changes, the page/category navigates away, or the script exits. Keeps scrubbing an encoder from ever triggering disk I/O per tick.
- Fixed the dead duplicate Source Sample-Editor item list: `page_items_for` now uses `lib/pages/model.lua`'s "SAMPLE" page data directly instead of a separately hand-maintained copy in `elasticat.lua`, removing the divergence risk that nearly caused the `gain` item to go missing from one of the two lists.

## Modularity pass (Phase 0 of the multitrack architecture)

- Extracted `lib/wav_reader.lua` (WAV parsing), `lib/script_state.lua` (dust/data persistence), `lib/pages/model.lua` (the page/category data table), `lib/pages/navigation.lua` (category/page/settings selection state machine), `lib/ui/param_values.lua` (parameter value/format/apply/lock runtime), and `lib/ui/source_page.lua` (Source-category rendering) out of `elasticat.lua`, which drops from 2241 to 885 lines.
- Converted `format_item_value`'s ~140-line id-keyed if/elseif chain into an id → formatter lookup table for the common numeric-display case.
- Deleted confirmed dead code: `draw_three_labels`, `draw_three_values`, `draw_two_pairs`, `draw_step_edit`, `draw_playhead`, `status_message`, `compact_value`, `short_mode`, `short_machine`.
- Updated `docs/ARCHITECTURE.md` to describe the new module boundaries, and added `docs/MULTITRACK_ARCHITECTURE.md` with the full 8-track target design and phased roadmap.
- Pure code motion — no intended behavior change.

## Per-page K2/K3 pair memory

- Each page now remembers its own last-selected K2/K3 parameter pair for the session instead of always resetting to the first pair when switching categories, pages, or returning from settings. Kept as in-memory state, not a norns param, so it isn't saved with the pset.

## Source page waveform and pitch ruler fixes

- Fixed the waveform trace itself overshooting the box at full amplitude by switching each column from a stroked line to a clamped, filled 1px-wide rect.
- Rebuilt the pitch ruler's dot/label placement to round the pitch offset once and lay out every dot and octave label from that single integer anchor with fixed 3px spacing, instead of rounding each dot independently. The old per-dot rounding let neighboring gaps drift between 2 and 3 blank pixels as pitch changed, which read as jitter; spacing is now always exactly 2 blank pixels. This also tightened the ruler from 18px/octave to 15px/octave (18 isn't evenly divisible into 5 dot/label gaps, 15 is).

## Source page header pixel pass

- Root-caused a class of "off by 1px" rendering bugs to `screen.move/line/stroke` on thin 1px marks (separator, waveform border, waveform markers, meter ticks/bars) rendering shifted or truncated in this environment; replaced every one of them with `screen.rect/fill`, which renders exact pixel bounds.
- Header background is a light grey (level 12) panel, 10px tall, with a 1px black separator at x=8 between the centered (0-7) track number and the message/tempo area.
- Page icon is a solid white 7x8px tag at x=120 with a 3-pixel dog-ear notch cut from its top-left corner, showing the header's grey through the cut.
- Header meter is a black 78x2px strip with dB-mapped live levels drawn in grey on top (dim below -12dB, brighter above -12dB), plus a fixed 2px-tall 0dB reference tick at x=71.
- Sample-slot cell redrawn to spec: a full white cell with a black 23x9 window cut into it starting at an inset of (7,1), the slot number centered in that window, and single corner pixels notched at the cell's top-left and bottom-left.
- Centered text in Source page single-line cells (STRT, END, REV, XFAD, etc.) instead of left-aligning it.
- Waveform box sits at exactly (1,23) sized 127x27 with a pixel-exact 1px border.
- Fixed waveform start/end/playhead markers overshooting the box: the vertical tick no longer extends 1px past the bottom edge, and the position-to-pixel mapping no longer places the rightmost position 1px past the right edge.

## Source page header

- Merged the two duplicate header-drawing wrappers into a single `draw_page_header(title, page_number)` used by every page (root pages, settings, and both Source sub-pages), fixing a bug where non-Source pages always showed page "1" and the Source main page showed the encoder-pair index instead of its real page number.
- Fixed the header page icon to render filled white with black text and black corner bevels, matching the sample-slot tab style, instead of an inverted black-filled box.
- Blank parameter cells (FILTER/AMP/FX/MOD placeholders and blank Source trim cells) now render as empty boxes instead of "---".
- Raised the SuperCollider status-report rate and the Lua redraw metro from 15 Hz to 30 Hz so the header meter tracks audio more responsively.

## Parameter pages

- Added a 128-slot sample pool with active slot selection, sample-slot parameter locks, saved pool state, and per-slot BPM/step metadata.
- Added `loadPoolSlot` / `setSampleSlot` engine commands so slot changes can switch resident buffers without loading from disk.
- Reworked Source page 1 into a Tonverk-style sample view with waveform, playhead, start/end markers, and compact value-flashing cells.
- Added Elektron-style parameter pages for MASTER, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, and MOD.
- Added norns page navigation, active encoder-pair selection, settings-layer navigation, useful-value snapping, and page-header value messages.
- Added grid top-row category shortcuts with FN+category settings access.
- Added generic step parameter locks for page parameters, with held-step lock editing and lock clearing.
- Updated the root page renderer to a four-column, two-row layout with corner-only active-pair markers.
- Fixed category shortcuts to change both root and settings categories while the settings layer is active.
- Filtered Source page controls by the active Machine and active warp mode.
- Added persisted default trig length and velocity params, while keeping held-step edits as locks.
- Fixed held-step parameter displays to show locked values in the main parameter cells.
- Fixed active-pair corner markers so one corner is drawn on each controlled parameter instead of each selected cell.
- Added FN+category return from settings to the main parameter pages.
- Routed synced Master BPM edits through norns `clock_tempo` when clock sync is on and the norns clock source is internal.
- Kept playback-applied parameter locks from replacing master values on the main parameter cells.
- Preserved the selected warp mode when changing Machines and moved LoopTrig triggers onto the active warp engine.
- Added slice clock sync and slice rate controls; slice voices now receive the active warp profile.

## Machine sequencing

- Added user-facing Machines: loop, loop_trig, grid_slice, and razor_slice.
- Added pattern length from 1-256 steps, defaulting to 64.
- Reworked grid steps into trig records with optional loop locks, slices, pitch locks, velocity, and note length.
- Added mini keyboard pitch entry and step pitch locking on grid rows 5-7.
- Added triggered SuperCollider slice voices with one-shot, held, looping, continue, reverse, velocity, envelope, and mono/poly behavior.
- Added RazorSlice params for 32 precise start/end pairs; moving a start preserves that slice length.

## Elasticat v2 foundation

- Replaced the prototype all-modes-running SynthDef with one shared transport synth and one active mode synth.
- Renamed modes with accurate terminology while preserving legacy engine command aliases.
- Added immediate crossfaded mode switching.
- Added quarter-note Lua clock observations and bounded soft correction in the engine.
- Derived source BPM from loaded sample duration and declared sample steps.
- Added step/bar timing parameters, source sample BPM, and 0-128 sample start/end points.
- Tightened parameter increments for steps, start/end, pitch, timing, grain, and mode controls.
- Made tape playback independent of internal BPM and smoothed pitch/start/end modulation.
- Added chopped step slicing, chopped loop mode, and pitch-aware chopped playback.
- Updated the performance UI with shift-only metadata and a horizontal playhead.
- Added status payloads for phase, frames, RMS, tempo, correction, switches, realignments, stale observations, and load generation.
- Updated the test script for sample browsing, play/stop, norns BPM control, shifted mode switching, sample steps, and mode-specific controls.
