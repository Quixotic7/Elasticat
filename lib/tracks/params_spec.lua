-- Track param model (docs/PHASE1_CONTRACT.md, docs/PHASE2_CONTRACT.md):
-- programmatic per-track param generation, plus the track_id helper every
-- track-aware code path goes through.
--
-- Track 1 KEEPS today's unprefixed ids (elasticat_loop_start, ...) -- that is
-- what preserves psets/projects/regression. Tracks 2-8 get
-- elasticat_t<N>_<suffix> ids generated from the one SPEC table below -- no
-- hand-written per-track duplication.
--
-- Phase 2: the whole signal chain (filter, both envelopes, insert FX, sends,
-- output, the mod section and the per-track behaviour settings) lives here too
-- and is registered for ALL 8 TRACKS INCLUDING TRACK 1 -- see the `t1` flag
-- below. lib/elasticat.lua no longer registers any of them by hand.
--
-- This module is deliberately free of norns requires at load time (the test
-- harness loads it under plain LuaJIT): register() receives its dependencies
-- (params, controlspec, formatters, value transforms, engine facade) from
-- lib/elasticat.lua.

local unpack = table.unpack or unpack

local ParamsSpec = {}

ParamsSpec.TRACK_COUNT_MAX = 8

-- Macro mod matrix: each macro holds a signed depth to each of these 5
-- destinations. `key` names the macro's per-dest depth param suffix
-- (macroN_<key>_depth); `param` is the ACTUAL page param the user turns while
-- holding a macro key to dial that destination in; `index` is the engine's
-- destination index (1-5, matching the mod buses). Lives here because the
-- macro SPEC entries below are generated from it; lib/elasticat.lua reads the
-- same table so there is exactly one definition.
ParamsSpec.MACRO_DESTS = {
  {key = "pitch", param = "pitch", index = 1},
  {key = "cutoff", param = "filter_cutoff", index = 2},
  {key = "res", param = "filter_res", index = 3},
  {key = "amp", param = "amp", index = 4},
  {key = "pan", param = "pan", index = 5}
}

-- One entry per per-track param. kind defaults to "control" (entry.spec is the
-- controlspec.new argument list, copied verbatim from track 1's registration in
-- lib/elasticat.lua).
--
--   cmd     the engine command, WITHOUT the track index. tr_call in
--           lib/elasticat.lua maps it to \tr<UpperCamel> and no-ops (warning
--           once) while the engine half is still landing.
--   args    extra leading args between the track and the value, for the
--           indexed commands (trMacroBase(track, macro, value) and
--           trMacroDepth(track, macro, dest, value)).
--   xform   named value transform (deps.xforms) applied before sending --
--           0-127 -> 0..1, 0-128 -> -1..1, env value -> seconds, etc.
--   offset  simple additive transform (options index -> engine 0-based).
--   fmt     named display formatter (deps.formatters), called (param, track).
--   action  named custom action (deps.actions) for the handful of params that
--           do something other than push one value to the engine.
--   queue   route through the 12Hz coalescing send queue (what every knob-ish
--           track-1 param did via queue_engine_call) instead of sending
--           immediately.
--   hidden  params:hide() after registering (macro matrix depths).
--   t1      ParamsSpec registers this for TRACK 1 as well. Entries without it
--           are still hand-registered for track 1 in lib/elasticat.lua and are
--           only generated here for tracks 2-8.
ParamsSpec.SPEC = {
  -- state
  {suffix = "play", name = "play", kind = "binary", default = 0, cmd = "play"},
  {suffix = "mute", name = "mute", kind = "binary", default = 0, cmd = "mute", t1 = true},
  -- source
  {suffix = "sample_slot", name = "sample slot", spec = {0, 128, "lin", 1, 1, "", 1 / 128}, cmd = "setSampleSlot"},
  {suffix = "machine", name = "machine", kind = "option", options = "machines", default = 1},
  {suffix = "pitch", name = "pitch", spec = {-24, 24, "lin", 0.1, 0, "st", 0.1 / 48}, cmd = "setPitch", queue = true},
  -- region_point folds THIS track file-trim window and Range into the engine
  -- point, matching what track 1 hand-registered action does. Without it a
  -- Loop-page encoder edit on a background track sent the RAW 0-128 value, so
  -- the same number addressed a different place depending on the selection.
  {suffix = "loop_start", name = "sample start", spec = {0, 128, "lin", 0.01, 0, "", 1 / 128},
    cmd = "loopStart", xform = "region_point", queue = true},
  {suffix = "loop_end", name = "sample end", spec = {0, 128, "lin", 0.01, 128, "", 1 / 128},
    cmd = "loopEnd", xform = "region_point", queue = true},
  -- Range pushes no value of its own -- it changes the MAPPING, so its action
  -- re-sends this track loop points. Previously these had no action at all,
  -- so editing a background track Range did nothing until its next trig.
  {suffix = "range_start", name = "range start", spec = {0, 128, "lin", 0.01, 0, "", 1 / 128},
    action = "range_remap"},
  {suffix = "range_end", name = "range end", spec = {0, 128, "lin", 0.01, 128, "", 1 / 128},
    action = "range_remap"},
  {suffix = "loop_reverse", name = "loop reverse", kind = "binary", default = 0, cmd = "setReverse"},
  {suffix = "xfade", name = "loop xfade", spec = {0, 0.25, "lin", 0.001, 0.005, "", 0.004}, cmd = "xfade", queue = true},
  -- warp
  {suffix = "mode", name = "warp mode", kind = "option", options = "modes", default = 1, cmd = "setMode", offset = -1},
  {suffix = "chop_steps", name = "chop steps", spec = {0.05, 16, "lin", 0.05, 1, "steps", 0.05 / 15.95}, cmd = "chopSteps"},
  {suffix = "chop_loop_mode", name = "chop loop mode", kind = "option",
    options = {"forward stop", "loop forward", "ping pong"}, default = 1, cmd = "chopLoopMode", offset = -1},
  {suffix = "chop_attack", name = "chop attack", spec = {0.0001, 0.2, "lin", 0.0001, 0.002, "s", 0.0005 / 0.1999}, cmd = "chopAttack", queue = true},
  {suffix = "chop_hold", name = "chop hold", spec = {0, 0.5, "lin", 0.001, 0.04, "s", 0.001 / 0.5}, cmd = "chopHold", queue = true},
  {suffix = "chop_release", name = "chop release", spec = {0.0001, 0.2, "lin", 0.0001, 0.01, "s", 0.0005 / 0.1999}, cmd = "chopRelease", queue = true},
  {suffix = "grain_size", name = "grain size", spec = {0.002, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.498}, cmd = "grainSize", queue = true},
  {suffix = "grain_density", name = "grain density", spec = {1, 64, "lin", 1, 8, "gr/step", 1 / 63}, cmd = "grainDensity", queue = true},
  {suffix = "grain_jitter", name = "grain jitter", spec = {0, 0.25, "lin", 0.001, 0.01, "s", 0.001 / 0.25}, cmd = "grainJitter", queue = true},
  {suffix = "wsola_window", name = "OLA window", spec = {0.005, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.495}, cmd = "wsolaWindow", queue = true},
  {suffix = "wsola_search", name = "OLA wander", spec = {0, 0.1, "lin", 0.001, 0.015, "s", 0.001 / 0.1}, cmd = "wsolaSearch", queue = true},
  {suffix = "pv_window", name = "PC window", spec = {0.005, 2, "lin", 0.001, 0.2, "", 0.001 / 1.995}, cmd = "pvWindow", queue = true},
  {suffix = "pv_dispersion", name = "PC dispersion", spec = {0, 1, "lin", 0.001, 0, "", 0.001}, cmd = "pvDispersion", queue = true},
  -- slice machines (grid_slice; razor split tables stay shared with track 1 in
  -- Phase 1 -- 64 params x 7 tracks is deferred until per-track razor lands)
  {suffix = "slice_count", name = "slice count", spec = {1, 32, "lin", 1, 16, "", 1 / 31}},
  {suffix = "slice_index", name = "slice index", spec = {1, 32, "lin", 1, 1, "", 1 / 31}},
  {suffix = "slice_play_mode", name = "slice play mode", kind = "option",
    options = {"1 shot", "1 shot hold", "loop", "continue"}, default = 1},
  {suffix = "slice_reverse", name = "slice reverse", kind = "binary", default = 0},
  {suffix = "slice_sync", name = "slice clock sync", kind = "binary", default = 1, cmd = "setSliceSyncToClock"},
  {suffix = "slice_rate", name = "slice rate", spec = {0.125, 8, "exp", 0.01, 1, "x", 0.01}, cmd = "setSliceRate", queue = true},
  {suffix = "slice_polyphony", name = "slice polyphony", kind = "option", options = {"poly 8", "mono"}, default = 1},
  {suffix = "slice_hold_to_step", name = "slice hold to step", kind = "binary", default = 1},
  {suffix = "slice_attack", name = "slice attack", spec = {0.0001, 0.2, "lin", 0.0001, 0.002, "", 0.0005 / 0.1999}, cmd = "sliceAttack", queue = true},
  {suffix = "slice_hold", name = "slice hold", spec = {0, 4, "lin", 0.01, 0.25, "", 0.01 / 4}, queue = true},
  {suffix = "slice_release", name = "slice release", spec = {0.0001, 0.5, "lin", 0.0001, 0.02, "", 0.001 / 0.4999}, cmd = "sliceRelease", queue = true},
  -- trig (sequencer-domain: read by grid_sequencer, never sent to the engine)
  {suffix = "pattern_steps", name = "pattern steps", spec = {1, 256, "lin", 1, 16, "", 1 / 255}},
  {suffix = "trig_jump", name = "trig jump", kind = "binary", default = 1},
  {suffix = "trig_release", name = "trig release", kind = "option",
    options = {"return", "boomerang", "reset"}, default = 1},
  {suffix = "trig_chance", name = "trig chance", kind = "number", min = 0, max = 100, default = 100},
  {suffix = "trig_condition", name = "trig condition", kind = "option", options = "trig_conditions", default = 1},
  {suffix = "trig_ratchet", name = "trig ratchet", kind = "number", min = 1, max = 8, default = 1},
  {suffix = "env_reset", name = "env reset", kind = "binary", default = 1},
  {suffix = "lfo_reset", name = "lfo reset", kind = "binary", default = 1},
  {suffix = "filter_reset", name = "filter reset", kind = "binary", default = 1},

  -- ---- Phase 2: the signal chain (every entry below is t1 = true) ---------
  -- filter (machine/type are settings that respawn the engine's filter synth;
  -- cutoff maps exponentially to Hz, res/drive linearly to 0..1, morph and
  -- balance are the project's centered 0-128 bipolar convention).
  {suffix = "filter_machine", name = "filter machine", kind = "option",
    options = "filter_machines", default = 1, cmd = "filterMachine", offset = -1, queue = true, t1 = true},
  {suffix = "filter_type", name = "filter type", kind = "option",
    options = "filter_types", default = 1, cmd = "filterType", offset = -1, queue = true, t1 = true},
  {suffix = "filter_cutoff", name = "filter cutoff", spec = {0, 127, "lin", 1, 127, "", 1 / 127},
    cmd = "filterCutoff", xform = "cutoff_hz", fmt = "filter_cutoff", queue = true, t1 = true},
  {suffix = "filter_res", name = "filter resonance", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "filterRes", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "filter_drive", name = "filter drive", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "filterDrive", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "filter_morph", name = "filter morph", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "filterMorph", xform = "morph", fmt = "filter_morph", queue = true, t1 = true},
  {suffix = "filter_balance", name = "filter balance", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "filterBalance", xform = "bipolar", fmt = "filter_balance", queue = true, t1 = true},

  -- filter envelope (independent mode from the amp env, but shares its
  -- exponential seconds mapping via env_range; REL/HOLD reach 128 = INF).
  {suffix = "filter_env_mode", name = "filter envelope mode", kind = "option",
    options = {"ADSR", "AHR"}, default = 2, cmd = "filterEnvMode", offset = -1, queue = true, t1 = true},
  {suffix = "filter_env_attack", name = "filter env attack", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "filterEnvAttack", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "filter_env_decay", name = "filter env decay", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "filterEnvDecay", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "filter_env_sustain", name = "filter env sustain", spec = {0, 127, "lin", 1, 100, "", 1 / 127},
    cmd = "filterEnvSustain", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "filter_env_release", name = "filter env release", spec = {0, 128, "lin", 1, 0, "", 1 / 128},
    cmd = "filterEnvRelease", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "filter_env_hold", name = "filter env hold", spec = {0, 128, "lin", 1, 128, "", 1 / 128},
    cmd = "filterEnvHold", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "filter_env_depth", name = "filter env depth", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "filterEnvDepth", xform = "bipolar", fmt = "filter_depth", queue = true, t1 = true},

  -- amp envelope. env_release defaults to 128 = INF deliberately: a new
  -- project sustains until note-off rather than cutting the tail immediately.
  -- env_range is Lua-side only (it sets the seconds mapping), so its action
  -- re-sends this track's amp/filter/mod envelope times instead of one value.
  {suffix = "env_mode", name = "envelope mode", kind = "option",
    options = {"ADSR", "AHR"}, default = 2, cmd = "envMode", offset = -1, queue = true, t1 = true},
  {suffix = "env_attack", name = "env attack", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "envAttack", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "env_decay", name = "env decay", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "envDecay", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "env_sustain", name = "env sustain", spec = {0, 127, "lin", 1, 100, "", 1 / 127},
    cmd = "envSustain", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "env_release", name = "env release", spec = {0, 128, "lin", 1, 128, "", 1 / 128},
    cmd = "envRelease", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "env_hold", name = "env hold", spec = {0, 128, "lin", 1, 128, "", 1 / 128},
    cmd = "envHold", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "env_range", name = "envelope range", kind = "option",
    options = {"1s", "4s", "8s", "16s", "32s", "64s", "128s", "256s", "512s", "1024s"},
    default = 3, action = "env_range", t1 = true},

  -- insert FX (machine is a setting that respawns the engine's insert synth;
  -- delay time is a beat-division options param so it stays tempo-synced).
  {suffix = "fx_insert1_machine", name = "fx insert 1 machine", kind = "option",
    options = "fx_machines", default = 1, cmd = "fxInsertMachine", offset = -1, queue = true, t1 = true},
  {suffix = "fx_drive", name = "fx drive", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "fxDrive", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "fx_mix", name = "fx mix", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "fxMix", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "delay_time", name = "delay time", kind = "option",
    options = "delay_times", default = 4, cmd = "delayBeats", xform = "delay_beats", queue = true, t1 = true},
  {suffix = "delay_feedback", name = "delay feedback", spec = {0, 127, "lin", 1, 38, "", 1 / 127},
    cmd = "delayFeedback", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "delay_tone", name = "delay tone", spec = {0, 127, "lin", 1, 127, "", 1 / 127},
    cmd = "delayTone", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "reverb_size", name = "reverb size", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "reverbSize", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "reverb_damp", name = "reverb damp", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "reverbDamp", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "lofi_bits", name = "lofi bits", spec = {0, 127, "lin", 1, 127, "", 1 / 127},
    cmd = "lofiBits", xform = "lofi_bits", fmt = "lofi_bits", queue = true, t1 = true},
  {suffix = "lofi_rate", name = "lofi rate", spec = {0, 127, "lin", 1, 127, "", 1 / 127},
    cmd = "lofiRate", xform = "lofi_rate", fmt = "lofi_rate", queue = true, t1 = true},

  -- sends: the tap point + the two per-track send LEVELS. The send BUS FX
  -- (send1_reverb_size, ...) are shared by every track and stay global in
  -- lib/elasticat.lua.
  {suffix = "send_tap", name = "send tap", kind = "option",
    options = {"pre insert", "post insert"}, default = 1, cmd = "sendTap", offset = -1, queue = true, t1 = true},
  {suffix = "send1_level", name = "send 1 level", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "sendLevel1", xform = "amount", fmt = "env_level", queue = true, t1 = true},
  {suffix = "send2_level", name = "send 2 level", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "sendLevel2", xform = "amount", fmt = "env_level", queue = true, t1 = true},

  -- output. amp folds in the active sample slot's gain (see the "amp" xform);
  -- both land on the track's FILTER synth engine-side, which is where the mod
  -- matrix applies the AMP/PAN destinations.
  {suffix = "amp", name = "amp", spec = {0, 127, "lin", 1, 100, "", 1 / 127},
    cmd = "amp", xform = "amp", fmt = "env_level", queue = true, t1 = true},
  {suffix = "pan", name = "pan", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "pan", xform = "bipolar", fmt = "pan_127", queue = true, t1 = true},

  -- modulation: 2 LFOs + 1 mod envelope, computed engine-side on control buses
  -- by this track's own \elasticatMod synth. SPD is a musical division sent as
  -- beats-per-cycle so LFO rates follow targetBpm across tempo changes.
  {suffix = "lfo1_dest", name = "lfo 1 dest", kind = "option",
    options = "mod_dests", default = 1, cmd = "lfo1Dest", offset = -1, queue = true, t1 = true},
  {suffix = "lfo1_wave", name = "lfo 1 wave", kind = "option",
    options = "mod_waves", default = 1, cmd = "lfo1Wave", offset = -1, queue = true, t1 = true},
  {suffix = "lfo1_speed", name = "lfo 1 speed", kind = "option",
    options = "mod_speeds", default = 4, cmd = "lfo1Beats", xform = "mod_beats", queue = true, t1 = true},
  {suffix = "lfo1_depth", name = "lfo 1 depth", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "lfo1Depth", xform = "bipolar", fmt = "filter_depth", queue = true, t1 = true},
  {suffix = "lfo1_mode", name = "lfo 1 mode", kind = "option",
    options = "mod_lfo_modes", default = 1, cmd = "lfo1Mode", offset = -1, queue = true, t1 = true},
  {suffix = "lfo2_dest", name = "lfo 2 dest", kind = "option",
    options = "mod_dests", default = 1, cmd = "lfo2Dest", offset = -1, queue = true, t1 = true},
  {suffix = "lfo2_wave", name = "lfo 2 wave", kind = "option",
    options = "mod_waves", default = 1, cmd = "lfo2Wave", offset = -1, queue = true, t1 = true},
  {suffix = "lfo2_speed", name = "lfo 2 speed", kind = "option",
    options = "mod_speeds", default = 4, cmd = "lfo2Beats", xform = "mod_beats", queue = true, t1 = true},
  {suffix = "lfo2_depth", name = "lfo 2 depth", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "lfo2Depth", xform = "bipolar", fmt = "filter_depth", queue = true, t1 = true},
  {suffix = "lfo2_mode", name = "lfo 2 mode", kind = "option",
    options = "mod_lfo_modes", default = 1, cmd = "lfo2Mode", offset = -1, queue = true, t1 = true},
  {suffix = "menv_dest", name = "mod env dest", kind = "option",
    options = "mod_dests", default = 1, cmd = "menvDest", offset = -1, queue = true, t1 = true},
  {suffix = "menv_attack", name = "mod env attack", spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "menvAttack", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "menv_decay", name = "mod env decay", spec = {0, 127, "lin", 1, 64, "", 1 / 127},
    cmd = "menvDecay", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "menv_sustain", name = "mod env sustain", spec = {0, 127, "lin", 1, 100, "", 1 / 127},
    cmd = "menvSustain", xform = "amount", queue = true, t1 = true},
  {suffix = "menv_release", name = "mod env release", spec = {0, 127, "lin", 1, 48, "", 1 / 127},
    cmd = "menvRelease", xform = "env_seconds", fmt = "env_time", queue = true, t1 = true},
  {suffix = "menv_depth", name = "mod env depth", spec = {0, 128, "lin", 1, 64, "", 1 / 128},
    cmd = "menvDepth", xform = "bipolar", fmt = "filter_depth", queue = true, t1 = true},

  -- behaviour settings that describe how THIS track plays. portamento and
  -- mode_switch_fade reach the engine; the rest are read live by the
  -- sequencer / UI (no engine action, exactly as before).
  {suffix = "portamento", name = "portamento", kind = "binary", default = 0,
    cmd = "portamento", queue = true, t1 = true},
  {suffix = "mode_switch_fade", name = "mode switch fade",
    spec = {0.001, 0.25, "lin", 0.001, 0.05, "", 0.001 / 0.249},
    cmd = "modeSwitchFade", queue = true, t1 = true},
  {suffix = "playhead_return", name = "playhead return", kind = "option",
    options = {"return", "boomerang", "reset"}, default = 1, t1 = true},
  {suffix = "loop_division", name = "loop key division", spec = {2, 32, "lin", 2, 16, "", 2 / 30},
    fmt = "integer", t1 = true},
  {suffix = "trig_polyphony", name = "trig polyphony", kind = "option",
    options = {"mono", "poly"}, default = 1, t1 = true},
  {suffix = "default_length", name = "default trig length",
    spec = {0.25, 16, "lin", 0.25, 1, "", 0.25 / 15.75}, fmt = "decimal2", t1 = true},
  {suffix = "default_velocity", name = "default velocity", spec = {0, 1, "lin", 0.01, 1, "", 0.01},
    fmt = "percent", t1 = true},
  {suffix = "range_end_sync", name = "range end sync", kind = "binary", default = 0, t1 = true}
}

-- 4 macros, generated from MACRO_DESTS so the matrix shape is stated once.
-- VALUE (0-127 -> 0..1) is the knob the grid macro keys / MACRO page drive,
-- p-lockable per step; each macro then contributes VALUE * depth[d] to
-- destination d. The 20 matrix-depth params are hidden from the PARAMS menu
-- (the grid gesture is their interface) but still serialize with patterns and
-- projects.
for m = 1, 4 do
  ParamsSpec.SPEC[#ParamsSpec.SPEC + 1] = {
    suffix = "macro" .. m .. "_value", name = "macro " .. m .. " value",
    spec = {0, 127, "lin", 1, 0, "", 1 / 127},
    cmd = "macroBase", args = {m}, xform = "macro_base", queue = true, t1 = true
  }
  for _, dest in ipairs(ParamsSpec.MACRO_DESTS) do
    ParamsSpec.SPEC[#ParamsSpec.SPEC + 1] = {
      suffix = "macro" .. m .. "_" .. dest.key .. "_depth",
      name = "macro " .. m .. " " .. dest.key .. " depth",
      spec = {0, 128, "lin", 1, 64, "", 1 / 128},
      cmd = "macroDepth", args = {m, dest.index}, xform = "bipolar",
      fmt = "filter_depth", queue = true, hidden = true, t1 = true
    }
  end
end

-- Membership set: which bare suffixes are per-track. Everything else (sample
-- pool, transport/tempo, master + send-bus FX, project/system settings, the
-- A/B crossfader) passes through track_suffix unchanged -- so a track-aware id
-- funnel is safe to apply uniformly: global params can never pick up a track
-- prefix by accident.
ParamsSpec.PER_TRACK = {}
-- suffix -> entry, so a sync/scan path can push a param through the EXACT
-- transform + engine command its action uses (see elasticat.sync_entries).
ParamsSpec.BY_SUFFIX = {}
for _, entry in ipairs(ParamsSpec.SPEC) do
  ParamsSpec.PER_TRACK[entry.suffix] = true
  ParamsSpec.BY_SUFFIX[entry.suffix] = entry
end

-- Every macro suffix in registration order (macroN_value + its 5 matrix
-- depths), for the mod sync path.
ParamsSpec.MACRO_SUFFIXES = {}
for m = 1, 4 do
  ParamsSpec.MACRO_SUFFIXES[#ParamsSpec.MACRO_SUFFIXES + 1] = "macro" .. m .. "_value"
  for _, dest in ipairs(ParamsSpec.MACRO_DESTS) do
    ParamsSpec.MACRO_SUFFIXES[#ParamsSpec.MACRO_SUFFIXES + 1] = "macro" .. m .. "_" .. dest.key .. "_depth"
  end
end

-- track 1 -> the unprefixed suffix (today's ids); tracks 2-8 -> t<N>_<suffix>.
-- Non-per-track suffixes always pass through unchanged.
function ParamsSpec.track_suffix(track, suffix)
  track = tonumber(track) or 1
  if track <= 1 or not ParamsSpec.PER_TRACK[suffix] then
    return suffix
  end
  return "t" .. math.floor(track) .. "_" .. suffix
end

-- Which track a suffix belongs to: 3 for "t3_filter_cutoff", 1 for a bare
-- per-track suffix (track 1 keeps the unprefixed id), nil for a global one.
-- Lets a scanner that walks registered ids (pattern partition, project
-- globals, scene capture) filter by track without re-deriving the naming.
function ParamsSpec.track_of_suffix(suffix)
  local n = suffix:match("^t(%d+)_")
  if n ~= nil then
    return tonumber(n)
  end
  return ParamsSpec.PER_TRACK[suffix] and 1 or nil
end

-- Contract helper: track_id(n, suffix) -> full param id.
-- track 1 = id(suffix), else id("t" .. n .. "_" .. suffix).
function ParamsSpec.track_id(track, suffix, prefix)
  return (prefix or "elasticat_") .. ParamsSpec.track_suffix(track, suffix)
end

-- The param action for one SPEC entry on one track. Every engine-bound entry
-- ends up calling the SAME per-track command with a leading track index -- the
-- entry table is the only thing that differs, which is what stops tracks from
-- diverging. Exposed for tests.
function ParamsSpec.entry_action(deps, track, entry, pid)
  local custom = entry.action ~= nil and (deps.actions or {})[entry.action] or nil
  if custom ~= nil then
    return function(x) custom(x, track, pid) end
  end

  local cmd = entry.cmd
  if cmd == nil then
    return function(_) end
  end

  -- tr_now / tr_queue take (key, track, cmd, ...) so the queued variant can
  -- coalesce on the param id. deps.tr_call (the Phase 1 shape) is the fallback
  -- for callers -- tests included -- that only wire the immediate path.
  local send = entry.queue and deps.tr_queue or deps.tr_now
  if send == nil then
    local tr_call = deps.tr_call
    if tr_call == nil then
      return function(_) end
    end
    send = function(_, t, c, ...) tr_call(t, c, ...) end
  end

  local xform = entry.xform ~= nil and (deps.xforms or {})[entry.xform] or nil
  local offset = entry.offset
  local args = entry.args

  return function(x)
    local value = x
    if xform ~= nil then
      value = xform(x, track)
    elseif offset ~= nil then
      value = x + offset
    end
    if args == nil then
      send(pid, track, cmd, value)
    elseif #args == 1 then
      send(pid, track, cmd, args[1], value)
    else
      send(pid, track, cmd, args[1], args[2], value)
    end
  end
end

-- Register one SPEC entry for one track. deps: {params, cs, prefix, tr_now,
-- tr_queue, tr_call, xforms, formatters, actions, + the named option lists
-- (machines, modes, trig_conditions, filter_machines, fx_machines, ...)}.
local function register_entry(deps, track, entry)
  local params = deps.params
  local pid = ParamsSpec.track_id(track, entry.suffix, deps.prefix)
  local name = "t" .. track .. " " .. (entry.name or entry.suffix)

  if entry.kind == "binary" then
    params:add_binary(pid, name, "toggle", entry.default or 0)
  elseif entry.kind == "number" then
    params:add_number(pid, name, entry.min, entry.max, entry.default)
  elseif entry.kind == "option" then
    local labels = entry.options
    if type(labels) == "string" then
      labels = deps[labels]
    end
    params:add_option(pid, name, labels, entry.default or 1)
  else
    -- Formatters are per-track closures: the envelope-time formatter needs to
    -- read THIS track's env_range to turn a 0-127 value into seconds.
    local fmt = entry.fmt ~= nil and (deps.formatters or {})[entry.fmt] or nil
    params:add_control(pid, name, deps.cs.new(unpack(entry.spec)),
      fmt ~= nil and function(param) return fmt(param, track) end or nil)
  end

  if entry.hidden and params.hide ~= nil then
    params:hide(pid)
  end

  params:set_action(pid, ParamsSpec.entry_action(deps, track, entry, pid))
end

-- The entries ParamsSpec registers for a given track: everything for tracks
-- 2-8, and the `t1` subset for track 1 (the rest of track 1's params are still
-- hand-registered in lib/elasticat.lua).
function ParamsSpec.entries_for(track)
  if track > 1 then
    return ParamsSpec.SPEC
  end
  local out = {}
  for _, entry in ipairs(ParamsSpec.SPEC) do
    if entry.t1 then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Register active_track_count + the per-track param set for ALL 8 tracks
-- (track 1 gets the `t1` subset -- see entries_for). Called from the END of
-- elasticat.params() so every scanner downstream (pattern partition, factory
-- defaults, project globals) sees these params -- per-track params land in the
-- per-pattern partition automatically; active_track_count / t<N>_play are
-- added to PATTERN_GLOBAL_SUFFIXES by the coordinator (elasticat.lua) so they
-- stay project-global.
function ParamsSpec.register(deps)
  local params = deps.params
  local prefix = deps.prefix or "elasticat_"

  -- active_track_count (1-8, default 1): the engine only allocates chains for
  -- tracks 1..count; the UI gates the row-4 track keys on it. All 8 tracks'
  -- params are registered unconditionally -- the count gates engine/UI only.
  params:add_group(prefix .. "group_tracks", "tracks", 1)
  params:add_number(prefix .. "active_track_count", "active tracks", 1, ParamsSpec.TRACK_COUNT_MAX, 1)
  params:set_action(prefix .. "active_track_count", function(n)
    if deps.engine_call ~= nil then
      deps.engine_call("activeTrackCount", n)
    end
    if deps.on_active_track_count ~= nil then
      deps.on_active_track_count(n)
    end
  end)

  for track = 1, ParamsSpec.TRACK_COUNT_MAX do
    local entries = ParamsSpec.entries_for(track)
    params:add_group(prefix .. "t" .. track .. "_group", "track " .. track, #entries)
    for _, entry in ipairs(entries) do
      register_entry(deps, track, entry)
    end
  end
end

return ParamsSpec
