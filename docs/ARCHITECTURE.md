# Elasticat Architecture

Elasticat is now large enough that feature work should happen through small modules, not by adding more conditionals to `elasticat.lua`.
This document describes the current module boundaries and the rules for future changes.

**Product decisions live in `docs/PRD.md`** (vision, machine/FX catalogs, parameter conventions, MVP scope, CPU budget) — read it first. For the 8-track instrument design (filters, sends, mod matrix, scenes, neighbor routing, projects) and its phased rollout, see `docs/MULTITRACK_ARCHITECTURE.md`; the shipped multitrack behavior contract is `docs/PHASE2_CONTRACT.md`. Other binding design docs: `docs/BASE_VALUE_RESOLVER.md` (how step locks / crossfader morphs / track bases resolve into ONE engine value, non-destructively), `docs/INPUT_ACTIONS.md` (the semantic input-action layer), `docs/MODE_CATALOG.md` (every selectable machine: track/warp/filter/FX). Parallel-agent ownership and integration rules are in `docs/WORKSTREAMS.md`. This document only covers code organization.

**Hard platform limits** that shape this file's rules: `elasticat.lua`'s main
chunk sits AT LuaJIT's 200-local ceiling and `init()` at the 60-upvalue
ceiling — new file-scope state must hang off an existing table (see the
`status` table and `elasticat.cpu_report` for the idiom), never a new local.
The norns screen freezes if `screen.level()` is called per-pixel — level-batch
all drawing (see `lib/ui/page_render.lua`'s performance law).

## References

- `groovecats` keeps domain behavior in object-like modules such as `GrooveCat`, with the top-level script coordinating pages, grid state, and engine calls.
- `gridstep` shows a page-oriented style: top-level state selects a page, and each page or grid mode owns its rendering and interaction rules.
- Elasticat combines those patterns: machine, warp, page, and value-model behavior live in focused modules, while the top-level script only coordinates transport, page dispatch, and norns callbacks.

## Current Boundaries

- `elasticat.lua`
  - norns script entry point.
  - Owns short-lived session state (`playing`, `alt`, `browsing`, step-lock editing bases, message/flash state) and the norns callbacks: `init`, `key`, `enc`, `redraw`, `cleanup`.
  - Wires `GridSequencer`, `Navigation`, `ParamValues`, and `SourcePage` together via dependency injection, the same way it always has for `GridSequencer`.
  - `page_items_for` and the `source_*_items` resolvers stay here: they need `MachineRegistry`/`WarpRegistry`/`params` together, which is genuine coordinator wiring, not page-navigation or value-model logic.
  - Should stay a coordinator, not a feature dumping ground.
- `lib/elasticat.lua`
  - Lua facade for `Engine_Elasticat`.
  - Owns norns params, sample pool metadata, trim sidecars, and throttled
    engine sends (the 12Hz coalescing queue every `queue = true` param rides).
  - Owns the **base-value resolver** (`docs/BASE_VALUE_RESOLVER.md`): step
    lock > crossfader morph > track base, resolved into the one value the
    engine hears, without ever overwriting the stored track value.
  - Owns the per-track OSC feed routing: the engine forwards meter/phase/mod/
    filter-env streams for the **viewTrack** only (plus all-track meters when
    the mixer view is up); `elasticat.osc_report` in `elasticat.lua` decides
    which track a reading belongs to and is unit-tested without `init()`.
- `lib/tracks/params_spec.lua`
  - THE per-track parameter contract: one spec row per param (id, range,
    xform, engine command, queue/lock flags), registered for all 8 tracks.
  - Track 1 keeps its historical unprefixed ids; a shrinking `t1` subset is
    still hand-registered in `lib/elasticat.lua` (known debt — the dual path
    is the recurring source of "works on track N, broken on track M" bugs).
- `lib/sequencer/track_sequencer.lua`
  - Per-track sequencer runtime: every track gets the identical region
    layering, release modes, trig conditions, and slice triggering the
    selected track gets. `grid_sequencer.lua` owns the grid *surface* and
    forwards to the selected track's instance.
- `lib/grid_sequencer.lua`
  - Grid controller and sequencer runtime.
  - Owns grid key handling, step advancement, loop/slice trigger dispatch.
  - Also owns the playhead-override machinery: the three-layer region model
    (live loop keys > sequenced step > main loop), release-mode anchors
    (`make_anchor`/`natural_phase_from`/`apply_release_mode` for
    Return/Boomerang/Reset), Trig Jump's wall/street repositioning, loop-key
    programming-vs-performance dispatch, stopped step preview, and Live Step
    Trig holds. The grid-level simulation harness for this machinery lives in
    the session scratchpad (`playhead_return_test.lua` pattern) — extend it
    when touching these paths; several shipped bugs were only caught there.
  - Also owns: trig condition/chance evaluation and ratchet scheduling (reads
    `lib/sequencer/trig_conditions.lua`, PRD §6.5), the Fill key, the pattern-
    load grid overlay (`key_pattern`/`key_pattern_mode`, PRD §6.2), and the
    A/B scene crossfader's grid surface — anchors + glide-key easing
    (`key_scene`/`start_scene_glide`, PRD §6.6; the scene *data* itself lives
    in `lib/scene_store.lua`, this module only drives the crossfade value from
    grid input).
- `lib/wav_reader.lua`
  - Pure WAV file parsing and waveform bucket extraction.
  - No script state; takes a path, returns data or nil.
- `lib/script_state.lua`
  - `dust/data` persistence: browser folder and sample-pool-snapshot save/load.
  - Built as a `.new()` instance (like `GridSequencer`); includes `lib/elasticat` directly for pool state access.
  - Sequencer/pattern state is now persisted — see `lib/sequencer/pattern_store.lua`
    and `lib/project_store.lua` below, which extend this module's
    `tab.save`-to-`_path.data` pattern for the Projects system (PRD §7)
    instead of duplicating it.
- `lib/sequencer/pattern_store.lua`
  - The 16-pattern-slot store (PRD §6.1): per-slot snapshot capture/apply via
    coordinator-injected callbacks, Tonverk-style change quantization
    (Sequential/Direct Jump/Direct Start/Temp Jump, PRD §6.3), and slot naming.
  - Decoupled from params/engine, same idiom as `GridSequencer`; its
    `serialize()`/`deserialize()` is the stable format `lib/project_store.lua`
    builds on.
- `lib/sequencer/trig_conditions.lua`
  - The ordered table of trig-condition definitions (`none`, A:B cycles,
    Fill/!Fill, Pre/!Pre, Nei/!Nei, 1st — PRD §6.5). Table order IS the
    `trig_condition` option index; shared by the param definition (labels)
    and `grid_sequencer.lua`'s evaluator (kind/a/b) so they can't drift apart.
  - Pure data, no functions.
- `lib/scene_store.lua`
  - A/B crossfader scene data (PRD §6.6): two scene snapshots, per-param
    bases for one-sided morphs, and `apply(t)` to morph+push every captured
    param at crossfade position `t`. Decoupled from params/engine via
    coordinator-injected `morph_ids`/`get_value`/`set_value` callbacks.
  - The grid-side anchor/glide-key input lives in `grid_sequencer.lua`
    (above); this module only owns the scene data and the morph math.
- `lib/project_store.lua`
  - The whole-project file format (PRD §7): assembles a `PatternStore`
    snapshot + coordinator-supplied global-param-scope and sample-pool
    captures into one table, and handles the `tab.save`/`tab.load` file I/O
    for explicit Save/Save As New/Load, the auto-naming schemes (Date now,
    Namesizer detected-at-runtime), and the temp-work-project save/load pair
    (PRD §7.2) that the coordinator uses for the "stopped-only" autosave and
    the script-reload/power-cycle resume.
  - Pure data assembler + file-I/O layer; never touches `pattern_store.lua`
    internals directly, only its public `serialize()`/`deserialize()`.
- `lib/input/router.lua`
  - Universal semantic-action input router (confirm/cancel/up/down/left/right/
    select_delta/value_delta/page_delta) translating norns keys, grid nav
    keys (YES/NO/arrows), and encoders into one action vocabulary that modal
    UI layers (settings, pop-ups, the pattern-quantize menu) consume via a
    pushed/popped focus-handler stack — see the file header for the full
    binding table. New controllers (e.g. MIDI) plug in as one more
    translator; no UI code changes.
- `lib/pages/model.lua`
  - The `page_model` table: declarative category/page/item definitions for MASTER, PATTERN, TRIG, SOURCE, FILTER, AMP, FX, MOD.
  - Pure data, no functions beyond the shared `item()` descriptor helper.
- `lib/pages/navigation.lua`
  - Category/page/K2-K3-pair/settings selection state machine, built as a `.new()` instance.
  - Owns the selection *indices*; does not resolve what items a page shows (that needs `MachineRegistry`/`WarpRegistry`/`params`, so it's a `page_items_for` callback injected from `elasticat.lua`).
- `lib/ui/param_values.lua`
  - The parameter-item value runtime: raw value, display formatting, snap/delta adjustment, apply-to-params, step-lock apply/read.
  - Built via constructor injection (`get_grid_ui`, `get_alt`, step-lock tables, etc.), the same idiom `GridSequencer.new()` already used for its callbacks.
  - `format_item_value` is an id → formatter lookup table for the common numeric-display case; only params needing bespoke display logic (enum remapping, pseudo-items) get an explicit branch.
- `lib/ui/page_render.lua`
  - Elektron-style renderer for the generic K2/K3-pair param pages (everything `draw_root_page` doesn't route to `source_page.lua`): the 2x4 label/value/position-bar cell grid, the selected-pair outline, lock/edit-flash chip inversion, and the per-category widgets (FILTER response curve, FILTER/AMP envelope sketches, FX insert/sends identity).
  - Pure rendering, `.new(opts)` + injected accessors (`param_values`, `param_value_or`, registry name lists); no engine calls, no param writes. Cell drawing is level-batched into passes (never per-cell/per-pixel `screen.level`) and curves are short polylines — see the file header's performance law.
- `lib/ui/source_page.lua`
  - Source-category rendering: the pitch ruler, sample-slot tab, waveform box + start/end/playhead markers, and the main/sample-edit cell renderers.
  - Pure rendering, like `param_renderer.lua`: receives `param_values` and `nav` as objects and coordinator-only helpers (`draw_page_header`, `active_waveform`, `active_region`, `display_phase`, `visual_param_value`) as callbacks, so it never touches engine/param state directly.
- `lib/ui/text_entry.lua`
  - Generic modal text-entry dialog (PRD §7.3): project names, pattern
    rename, reusable anywhere a string needs typing. Norns front panel is an
    append-only character-picker model (`E2` scrolls, `E3` commits, `K2`
    backspace, `K3` accept, `K1` cancel) — a deliberate, documented departure
    from the PRD's literal "E2 moves the cursor" wording, since the given
    control set has no independent caret-move input; see the file header for
    the reasoning. Grid becomes a Deluge-style QWERTY keyboard while open.
  - Pure logic/rendering, `.new(opts)` + injected-callback idiom; owns no
    grid device (the coordinator wraps `grid_ui.g.key` to route grid input
    to it while open) and does not touch sequencer/engine state.
- `lib/Engine_Elasticat.sc`
  - SuperCollider engine implementation — deliberately ONE file (the crone
    loader only discovers one `Engine_*` class file; a broken companion file
    would take the whole class library down).
  - `ElasticatTrack` class: one instance per track, identical node graph for
    all 8 (transport → mod → reader → filter [carries amp/pan] → insert →
    send tap → mix). `activeTrackCount` allocates/frees whole chains.
  - Slice voice pool: per-track cap 8, global cap 24, oldest-first steal,
    choke groups, bounded envelopes.
  - **Idle pause** (CPU headroom): a stopped, silent, un-viewed track's whole
    group is paused (`group.run(false)`); silence is measured post-everything
    from the track-mix output, waking is command-driven (play/trig/view).
    The same 2s tick reports avg/peak CPU to the script (`/elasticat/cpu`).
  - Compiled UGens (`ElasticatReader`, `ElasticatGrains`) are built ON the
    norns (armv7l) — see `ugens/` at the repo root and `lib/ugens/install.lua`.
  - Positional-lockstep registries: `modeSynthNames`/`filterSynthNames`/
    `fxInsertNames` must match the Lua registries index-for-index;
    `bin/test-elasticat-contract` enforces it.

## Already Well-Factored (unchanged by this pass)

- `lib/ui/header.lua`, `lib/ui/param_renderer.lua`, `lib/ui/param_item.lua`, `lib/ui/param_bank.lua`
  - Shared header, parameter item descriptors, banks, and rendering helpers.
  - No engine calls and no sequencer mutation.
- `lib/machines/*`
  - One module per machine.
  - Owns source-page item layout, machine-specific page overrides, and machine-specific lifecycle hooks.
- `lib/warp_modes/*`
  - One module per warp mode.
  - Owns warp parameter layout and warp-specific behavior.
- `lib/filter_modes/*`
  - One module per filter machine: CLASSIC, MORPHING, LADDER, COMB, FORMANT
    (see `docs/MODE_CATALOG.md`), all stereo with a stereo/mid-side balance.
    Mirrors the warp-mode registry pattern.
  - The active filter machine is a *setting* (not p-lockable); its params are
    p-lockable. Registry index must stay aligned with the engine's
    `filterSynthNames` list.
- `lib/fx_modes/*`
  - One module per FX machine — 19 today (see `docs/MODE_CATALOG.md` for the
    full table, param rows, the always-wet set, and the MIX-as-trailing
    rule), mirroring the filter-mode registry pattern exactly. Index 1
    (engine 0) is always the dry-passthrough None machine, so switching
    machines never leaves the insert chain silent (a send-return None instead
    spawns NO synth — a passthrough would double the sent signal).
  - Shared by all four slots: Insert 1 (unprefixed ids), Send 1 / Send 2 /
    Master (prefixed `send1_`/`send2_`/`master_`; the send/master rows are
    GENERATED from the same spec, see `register_send_fx_params` and the
    engine's `sendFxExtraSpec`).
  - The active machine (per slot) is a *setting*, not p-lockable, but CAN be
    swapped during playback (unlike warp/filter machines).
  - Adding a machine touches ~8 places in lockstep — module + registry name +
    option count, engine SynthDef + `fxInsertNames` + per-track and send
    spec rows, `params_spec` SPEC row, sync entries, test counts. Follow an
    existing machine (e.g. `cassette`) end-to-end; the contract test catches
    a missed site.
- `lib/sequencer/*`
  - `step.lua`: step data objects and sequencer model helpers. Grid
    controller asks step objects about content instead of inspecting raw
    tables everywhere.
  - `pattern_store.lua` and `trig_conditions.lua` are documented above under
    Current Boundaries (both are actively growing with the Patterns/Trig-
    conditions work, unlike `step.lua`, which is why they're listed there
    instead of here).

## Modularity Rules

1. Do not add new machine-specific `if machine == ...` branches to `elasticat.lua`.
   Add or update a module in `lib/machines/` instead.
2. Do not add new warp-mode-specific branches to `elasticat.lua`.
   Add or update a module in `lib/warp_modes/` instead.
3. Screen parameter cells should be rendered through `lib/ui/page_render.lua` (generic pages) or `lib/ui/source_page.lua` (Source-category pages; it still uses `lib/ui/param_renderer.lua`'s helpers).
   Do not copy text-fit, cell, or selection-highlight logic into feature code.
4. Page headers must be rendered through `lib/ui/header.lua`, via `elasticat.lua`'s single `draw_page_header` wrapper.
   Do not add page-specific header implementations; pass page title, message, tempo, meter, and page number into the shared header.
5. Parameter layouts should be lists of item descriptors from `lib/ui/param_item.lua`, defined in `lib/pages/model.lua`.
   Use `blank()` for intentional empty cells so the 4x2 layout remains explicit.
6. Step records should be created through `lib/sequencer/step.lua`.
   This keeps trig, slice, pitch, length, velocity, and param-lock behavior coherent.
7. New parameter-formatting rules go in `lib/ui/param_values.lua`'s `ID_FORMATTERS` table (or an explicit branch in `format_item_value` if the param needs bespoke logic), not inline in `elasticat.lua`.
8. New category/page selection behavior goes in `lib/pages/navigation.lua`, not as new loose file-locals in `elasticat.lua`.
9. `elasticat.lua` should be allowed to coordinate state, but feature logic belongs to modules.
10. Every refactor or feature change must pass:
    - `bin/test-elasticat-lua` (syntax + module registry + render sweeps +
      the per-module unit tests it drives)
    - `bin/test-elasticat-sclang` (engine compile)
    - `bin/test-elasticat-engine-runtime` (boots a real scsynth: alloc,
      8-track scaling, slice voice caps/choke, idle pause. On a Mac the
      compiled `ElasticatReader`/`ElasticatGrains` UGens are absent — their
      "not installed" errors are expected noise, the assertions still bind)
    - `bin/test-elasticat-contract` (Lua↔engine registry/command lockstep;
      occasionally SIGSEGVs on exit — rerun, don't debug)
    - `luajit bin/lua/fx_page_test.lua` and `luajit bin/lua/phase2_params_test.lua`
      when touching FX pages or per-track params
    - `git diff --check`
11. Engine `.sc` changes only take effect after a script reload on the norns;
    deploys follow `deploy-elasticat.sh` (rsync + verify IDENTICAL), and
    `main` is only fast-forwarded after a VERIFIED deploy (main mirrors the
    device).

## Extension Flow

To add a machine:

1. Create `lib/machines/<machine>.lua`.
2. Return a table with `id`, `name`, `is_slice`, `source_items()`, and optional page override functions.
3. Register it in `lib/machines/registry.lua`.
4. Add the engine-facing parameter and command behavior in `lib/elasticat.lua` or `Engine_Elasticat.sc` only if required.

To add a warp mode:

1. Create `lib/warp_modes/<mode>.lua`.
2. Return a table with `id`, `name`, and `source_items()`.
3. Register it in `lib/warp_modes/registry.lua`.
4. Keep DSP implementation in SuperCollider and parameter definitions in `lib/elasticat.lua`.

To add a filter machine:

1. Create `lib/filter_modes/<machine>.lua` returning `id`, `name`, and
   `source_items()` (its p-lockable param row; reuse existing `filter_*` param
   ids where the machine shares them — e.g. cutoff/res/drive — and add new ids
   only for genuinely new controls like morph/balance).
2. Register it in `lib/filter_modes/registry.lua` (module + display name).
3. Add the matching SynthDef to `Engine_Elasticat.sc` and append its name to
   `filterSynthNames` at the same index.
4. New param ids go in `lib/elasticat.lua` (ids table + `add_control` +
   engine command), following the PRD §5 range conventions.
5. Stereo/mid-side variants parameterize the mono DSP (two filter instances +
   a balance law); do not copy-paste SynthDefs.

To add a parameter page:

1. Define item descriptors in `lib/pages/model.lua` (or the owning machine/warp module for Source sub-pages).
2. Render them through the existing page renderer (`page_render.lua` or `source_page.lua`).
3. Avoid direct screen drawing unless the page is a custom visual page, such as waveform editing.

To add a new parameter's display formatting:

1. If it's a simple numeric display, add one entry to `ID_FORMATTERS` in `lib/ui/param_values.lua`, reusing an existing `fmt_*` helper if one already matches the shape you need.
2. If it needs bespoke logic (enum remapping, a pseudo-item), add an explicit branch in `format_item_value` before the table lookup.
