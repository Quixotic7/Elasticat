# Input actions (Unity-style input manager)

All input flows through **named semantic actions** bound in **one place**, so UI
code never checks physical devices, a remap is a single edit, and a new device
is one translator. `lib/input/router.lua` is the layer; `fn_active()` is the one
FN predicate (norns K1 OR grid FN) — never check raw `alt` / `grid_ui.fn_down`.

## Done

**Stage A — norns keys + encoders.** The base surface routes through the router:
physical inputs → named actions in one bindings table (`set_base` in
`elasticat.lua`), modifier-resolved (macro/scene/step/FN), most-specific-first.
`key()`/`enc()` are thin translators. `param_edit` carries the pair **slot** —
the seam Stage C binds MIDI knobs to. Tests: `bin/lua/input_router_base_test.lua`.

**Stage B — the grid.** All grid coordinates live in one shared table,
`lib/input/grid_layout.lua`, read by BOTH the router's modal nav bindings
(yes/no/arrows) AND `GridSequencer:key`'s dispatch. Moving a key is one edit
there. The dispatch *logic* (ordered if/elseif, key-release semantics, context
gates) is unchanged — only coordinates are data. Tests:
`bin/lua/grid_dispatch_test.lua`.

## Stage C — external hardware (NOT built)

Goal: MIDI/OSC controllers, especially **knob banks** (Roto-Control, Midi
Fighter Twister), driving the instrument — including **every param on a page at
once**, not just norns' two encoders.

### 1. Device translators

A translator turns a device's events into the existing action names and calls
the router — zero UI changes. Pattern mirrors `norns_key` / `enc` / `grid_key`:

- **MIDI note controller (grid-like, e.g. Launchpad):** map note → `(x, y)` via
  a device map, call `grid_ui:key(x, y, z)`. Because the grid layout is already
  data (`grid_layout.lua`), the pads line up with one coordinate map.
- **MIDI CC / OSC (buttons):** map CC → an action name, dispatch through the
  router's base layer (add a `router:midi_cc(cc, val)` translator that resolves
  a binding table like `norns_key` does).
- Bindings for these live in device tables alongside the existing ones, so the
  "one place to remap" property holds per device.

### 2. Page-param addressability (the knob-bank feature)

Today `param_edit` targets the selected pair (slot 1/2). For a bank of knobs,
each knob must address a DIFFERENT param on the current page.

- Generalise the target: `param_edit` already carries a slot; extend it to an
  arbitrary **page-param index** (or param id). The base handler resolves the
  target from the current page's item list (`nav:current_group_items()` is the
  2-up view; a page exposes up to 8 low-profile cells — see
  `filter_lowprofile_items` etc.), so `param_edit(target=N, delta)` edits the
  Nth cell.
- A knob controller sends absolute or relative CC → a translator emits
  `param_edit(target=knob_index, value)`. Support **absolute** values too (a
  detented knob sends 0–127): add a `param_set(target, value01)` action that maps
  the knob's range onto the param's controlspec, versus the relative
  `param_edit(target, delta)` norns encoders use.
- Respect the base-value resolver: knob edits are normal edits, so they go
  through `param_values:delta_item` / a new absolute setter, which already routes
  to `set_step_override` / `knob_takes_over` etc. — nothing engine-side changes.
- MIDI feedback (motorised / LED-ring knobs): a page-change or param-change hook
  emits the current resolved values back out so the ring/motor tracks — read
  `elasticat.resolved_value(suffix)` per visible cell.

### 3. Scope notes / gotchas

- **FN and other modifiers** stay semantic — a MIDI controller can map a pad/CC
  to "hold FN" by driving the same modifier state `fn_active()` reads.
- **The router is device-agnostic**; per-device MECHANICS (14-bit CC, NRPN, MIDI
  learn, hot-plug) live in the translators, never in the UI.
- **MIDI learn / user remapping**: since bindings are plain tables, a "learn"
  mode just writes a table entry — persist it with the project.
- Input is the highest-risk subsystem and is not unit-hardware-testable here:
  keep every device translator behind the same behavior-preserving + test-locked
  discipline as Stages A/B.
