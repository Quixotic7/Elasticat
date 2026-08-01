# Base-value resolver (the three-track switch)

Owner's mental model, captured so it never has to be re-explained. This is the
single authority on **what value a p-lockable parameter sends to the engine**,
and on what the two low-profile bars (and the waveform) draw. If code and this
doc disagree, the code is wrong.

## The switch

Think of three train tracks feeding one switch; exactly one is connected at a
time. Per parameter, per track, per tick, the **base value** is:

```
base = step_override   (a firing step p-locked this param)
     ?? crossfader_value (a scene A/B morph is moving this param)
     ?? track_value      (the per-track stored param — what the knob edits)
```

Priority is **step > crossfader > track** (owner-confirmed). A step p-lock is an
explicit per-step value, so it overrides a morph for the duration of that step's
window; the morph resumes the instant the step ends.

**A hand edit reclaims the param from the crossfader.** Crossfader beats track by
default, but if you turn a param's knob while NOT moving the fader, that param
hands control back to the track value until the fader is next moved (owner: "if
I am not changing the crossfader, adjusting the track cutoff should make it the
base value"). Mechanically: a normal edit clears that one param's
`crossfader_override` (`elasticat.knob_takes_over`, from `scene_base_follow`); the
next `scene_store:apply` re-publishes it. So the priority is really step >
(whichever of crossfader / track was touched most recently for that param).

The base is what the script sends to the engine. The engine then adds its own
**envelope + LFO + macro** modulation on top:

```
actual = base + engine mods (env / LFO / macros)
```

`actual` is what actually sounds. The mod part is measured by the engine and
returns on the 15 Hz `/elasticat/mod` + `/elasticat/filterEnv` feeds (see
`route_mod_report` / `route_filter_env_report`); the script never computes it.

## The two bars, and the waveform

Every low-profile param cell draws two bars. They are the switch made visible:

- **Stored bar (2 px)** = `track_value` (source 1), always. Turning the knob
  moves this bar on any page, at any time — even mid-step or mid-morph, so the
  edit is never silently swallowed. You may not *hear* it while a higher track
  is connected, but you always *see* it land on the track value.
- **Actual bar (1 px)** = `base + mods` — the resolved switch output plus the
  engine mod feed. During a firing step it shows the step value; during a morph
  it shows the crossfader value; otherwise it tracks the stored bar (plus mods).

The **waveform** (region view) is the region/range equivalent of the actual bar:
it highlights the **resolved active start/end** — a firing step's region/range
p-lock while that step plays, else the live scrub / track value — never merely
the stored loop points. (Owner requirement, 2026-07-27.)

## Non-destructive is the whole point

The switch must **never mutate `track_value`**. The bug this design retires was
built on mutation: a firing step p-lock wrote its value into the track param and
restored it each tick, so a live knob edit was overwritten by the per-tick
restore ("turning the knob does nothing"). The fix is not "restore more
carefully" — it is: the track param is the durable source 1 and is only ever
written by the user (knob) or a normal recall; steps and the crossfader publish
into **override layers** that the resolver reads. Nothing else may write the
track param.

This is already how **region/range** work today (`active_range_*` tables +
`elasticat.active_range()` resolve step-override-else-track; `map_trim_point` /
`update_engine_loop_points` send the resolved point; the param is untouched).
This design **generalises that pattern to every continuous p-lockable param** and
adds the crossfader as the middle source.

## Scope: continuous params only

The switch is for parameters that have a meaningful continuous "value":
`filter_cutoff`, `filter_res`, `filter_morph`/`filter_type` (as they morph),
`pitch`, `pan`, the four macros, `loop_start`/`loop_end`, `range_start`/
`range_end`, and the rest of the SPEC continuous set.

The **momentary / trigger** p-locks are NOT base values and stay exactly as they
are (consumed at trigger time, never a resolved base): `env_reset`, `lfo_reset`,
`filter_reset`, `trig_jump`, `trig_release`, `length`, `velocity`. These are
already excluded in `ParamValues:apply_param_lock_value`; keep them excluded.

## Where it lives (implementation map)

- **Override tables (facade, `lib/elasticat.lua`).** Generalise the existing
  `active_range_*` idea to `step_override[track][suffix]` and
  `crossfader_override[track][suffix]`. `track_value` is just the SPEC param
  (`params:get(track_pid(track, suffix))`).
- **`elasticat.resolve_base(track, suffix)`** — the switch:
  `step_override ?? crossfader_override ?? track_value`. Single authority; the
  region/range resolve (`active_range`) becomes one caller of it.
- **Resolve-and-send.** A continuous SPEC param's send takes
  `resolve_base(track, suffix)`, not the raw param value. Anything that changes a
  source re-sends through it: the param action (knob), the sequencer
  setting/clearing a step override, the crossfader moving. This mirrors how the
  `range_*` action already re-sends the loop points. Sends stay on the existing
  12 Hz coalescing queue (`tr_queue` / `morph_active`) — the resolver must not
  reintroduce the pattern/morph flood that was just fixed.
- **Step overrides (`lib/ui/param_values.lua` + sequencer).**
  `apply_step_param_locks` stops calling `params:set` on the track param for
  continuous locks; instead it publishes `step_override` and, on clear, drops it
  — then asks the facade to re-send. `active_step_lock_bases` (the destructive
  base snapshot) goes away for these params.
- **Crossfader (`lib/scene_store.lua` + coordinator `set_value`).** The morph's
  `set_value` callback publishes `elasticat.set_crossfader_override(track, suffix,
  value)` (per-track) instead of `params:set`, so the track param stays source 1;
  `SceneStore.bases` already holds `track_value`, so one-sided morphs and
  `update_base` (edit-follows) are unchanged. When a param LEAVES the morph set
  (unlocked from both scenes, or its endpoints become equal),
  `elasticat.reconcile_crossfader(scene_store:morph_target_keys())` drops its
  override and re-sends the track value so the knob regains control -- run after
  every `scene_store:apply`, and after `clear_key` / `capture` (which can shrink
  the set while the fader is idle).

### Resolvability (which params take the switch)

`elasticat.is_resolvable(track, suffix)` = the param is a continuous base value
(`is_base_suffix`) AND its knob edit flows through `entry_action` -- every base
param on tracks 2-8, and the `t1` base params on track 1. Track 1's remaining
hand-registered params (pitch, xfade, chop/grain, slice times) bypass
`entry_action`, so an override there could not win over the knob; both
`set_step_override` and `set_crossfader_override` decline them and the caller
keeps the destructive `params:set`. This is the one gap in "all p-lockable
params", and it closes for free once track 1 is registered through the SPEC like
tracks 2-8.
- **Render.** Stored bar reads `track_value`; actual bar reads
  `resolve_base + mod feed`. The filter curve already reads the live value during
  playback (#41 B); point it and the low-profile actual bar at `resolve_base` so
  every continuous param behaves identically. The waveform reads
  `elasticat.active_range()` (already resolved) for its highlight.

## Invariants

1. Only the user (knob) or an outright recall writes `track_value`. Steps and the
   crossfader never do.
2. `resolve_base` is the ONLY thing that decides the engine base for a continuous
   p-lockable param. No parallel path.
3. The stored bar is `track_value`; the actual bar and waveform are the resolved
   value (+ mods). They diverge on purpose while a higher track is connected.
4. Trigger/momentary p-locks are untouched.
5. Cost: a fader tick or a step edge issues no more sends than the destructive
   path did, and all continuous sends stay on the 12 Hz coalescing queue.
