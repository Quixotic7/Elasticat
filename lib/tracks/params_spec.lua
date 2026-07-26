-- Phase 1 track scaffolding (docs/PHASE1_CONTRACT.md): programmatic per-track
-- param generation for tracks 2-8, plus the track_id helper every track-aware
-- code path goes through.
--
-- Track 1 KEEPS today's unprefixed ids (elasticat_loop_start, ...) -- that is
-- what preserves psets/projects/regression. Tracks 2-8 get
-- elasticat_t<N>_<suffix> ids generated from the one SPEC table below -- no
-- hand-written per-track duplication. Phase 1 scope only: the source/warp/trig
-- machine params + per-track play/mute state (the Phase 1 chain has no
-- filter/amp-env/insert/mod, so none of those are generated here).
--
-- This module is deliberately free of norns requires at load time (the test
-- harness loads it under plain LuaJIT): register() receives its dependencies
-- (params, controlspec, engine facade) from lib/elasticat.lua.

local unpack = table.unpack or unpack

local ParamsSpec = {}

ParamsSpec.TRACK_COUNT_MAX = 8

-- One entry per per-track param. kind defaults to "control" (entry.spec is the
-- controlspec.new argument list, copied verbatim from track 1's registration in
-- lib/elasticat.lua). `cmd` names the EXISTING track-1 engine command; the
-- engine half exposes it tr-prefixed with a leading track index (see
-- tr_call in lib/elasticat.lua for the name mapping + graceful no-op when the
-- engine half hasn't landed). Entries without `cmd` are Lua-side sequencer/
-- resolver params (no engine action), same as their track-1 counterparts.
ParamsSpec.SPEC = {
  -- state
  {suffix = "play", name = "play", kind = "binary", default = 0, cmd = "play"},
  {suffix = "mute", name = "mute", kind = "binary", default = 0, cmd = "mute"},
  -- source
  {suffix = "sample_slot", name = "sample slot", spec = {0, 128, "lin", 1, 1, "", 1 / 128}, cmd = "setSampleSlot"},
  {suffix = "machine", name = "machine", kind = "option", options = "machines", default = 1},
  {suffix = "pitch", name = "pitch", spec = {-24, 24, "lin", 0.1, 0, "st", 0.1 / 48}, cmd = "setPitch"},
  {suffix = "loop_start", name = "sample start", spec = {0, 128, "lin", 0.01, 0, "", 1 / 128}, cmd = "loopStart"},
  {suffix = "loop_end", name = "sample end", spec = {0, 128, "lin", 0.01, 128, "", 1 / 128}, cmd = "loopEnd"},
  -- Range is a Lua resolver layer on track 1 (map_trim_point); the per-track
  -- params exist for parity/p-locks but stay engine-inert in Phase 1.
  {suffix = "range_start", name = "range start", spec = {0, 128, "lin", 0.01, 0, "", 1 / 128}},
  {suffix = "range_end", name = "range end", spec = {0, 128, "lin", 0.01, 128, "", 1 / 128}},
  {suffix = "loop_reverse", name = "loop reverse", kind = "binary", default = 0, cmd = "setReverse"},
  {suffix = "xfade", name = "loop xfade", spec = {0, 0.25, "lin", 0.001, 0.005, "", 0.004}, cmd = "xfade"},
  -- warp
  {suffix = "mode", name = "warp mode", kind = "option", options = "modes", default = 1, cmd = "setMode", offset = -1},
  {suffix = "chop_steps", name = "chop steps", spec = {0.05, 16, "lin", 0.05, 1, "steps", 0.05 / 15.95}, cmd = "chopSteps"},
  {suffix = "chop_loop_mode", name = "chop loop mode", kind = "option",
    options = {"forward stop", "loop forward", "ping pong"}, default = 1, cmd = "chopLoopMode", offset = -1},
  {suffix = "chop_attack", name = "chop attack", spec = {0.0001, 0.2, "lin", 0.0001, 0.002, "s", 0.0005 / 0.1999}, cmd = "chopAttack"},
  {suffix = "chop_hold", name = "chop hold", spec = {0, 0.5, "lin", 0.001, 0.04, "s", 0.001 / 0.5}, cmd = "chopHold"},
  {suffix = "chop_release", name = "chop release", spec = {0.0001, 0.2, "lin", 0.0001, 0.01, "s", 0.0005 / 0.1999}, cmd = "chopRelease"},
  {suffix = "grain_size", name = "grain size", spec = {0.002, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.498}, cmd = "grainSize"},
  {suffix = "grain_density", name = "grain density", spec = {1, 64, "lin", 1, 8, "gr/step", 1 / 63}, cmd = "grainDensity"},
  {suffix = "grain_jitter", name = "grain jitter", spec = {0, 0.25, "lin", 0.001, 0.01, "s", 0.001 / 0.25}, cmd = "grainJitter"},
  {suffix = "wsola_window", name = "OLA window", spec = {0.005, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.495}, cmd = "wsolaWindow"},
  {suffix = "wsola_search", name = "OLA wander", spec = {0, 0.1, "lin", 0.001, 0.015, "s", 0.001 / 0.1}, cmd = "wsolaSearch"},
  {suffix = "pv_window", name = "PC window", spec = {0.005, 2, "lin", 0.001, 0.2, "", 0.001 / 1.995}, cmd = "pvWindow"},
  {suffix = "pv_dispersion", name = "PC dispersion", spec = {0, 1, "lin", 0.001, 0, "", 0.001}, cmd = "pvDispersion"},
  -- slice machines (grid_slice; razor split tables stay shared with track 1 in
  -- Phase 1 -- 64 params x 7 tracks is deferred until per-track razor lands)
  {suffix = "slice_count", name = "slice count", spec = {1, 32, "lin", 1, 16, "", 1 / 31}},
  {suffix = "slice_index", name = "slice index", spec = {1, 32, "lin", 1, 1, "", 1 / 31}},
  {suffix = "slice_play_mode", name = "slice play mode", kind = "option",
    options = {"1 shot", "1 shot hold", "loop", "continue"}, default = 1},
  {suffix = "slice_reverse", name = "slice reverse", kind = "binary", default = 0},
  {suffix = "slice_sync", name = "slice clock sync", kind = "binary", default = 1, cmd = "setSliceSyncToClock"},
  {suffix = "slice_rate", name = "slice rate", spec = {0.125, 8, "exp", 0.01, 1, "x", 0.01}, cmd = "setSliceRate"},
  {suffix = "slice_polyphony", name = "slice polyphony", kind = "option", options = {"poly 8", "mono"}, default = 1},
  {suffix = "slice_hold_to_step", name = "slice hold to step", kind = "binary", default = 1},
  {suffix = "slice_attack", name = "slice attack", spec = {0.0001, 0.2, "lin", 0.0001, 0.002, "", 0.0005 / 0.1999}, cmd = "sliceAttack"},
  {suffix = "slice_hold", name = "slice hold", spec = {0, 4, "lin", 0.01, 0.25, "", 0.01 / 4}},
  {suffix = "slice_release", name = "slice release", spec = {0.0001, 0.5, "lin", 0.0001, 0.02, "", 0.001 / 0.4999}, cmd = "sliceRelease"},
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
  {suffix = "filter_reset", name = "filter reset", kind = "binary", default = 1}
}

-- Membership set: which bare suffixes are per-track. Everything else (master,
-- pattern-system, filter/amp/fx/mod, editor prefs, ...) passes through
-- track_suffix unchanged -- so a track-aware id funnel is safe to apply
-- uniformly: global params can never pick up a track prefix by accident.
ParamsSpec.PER_TRACK = {}
for _, entry in ipairs(ParamsSpec.SPEC) do
  ParamsSpec.PER_TRACK[entry.suffix] = true
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

-- Contract helper: track_id(n, suffix) -> full param id.
-- track 1 = id(suffix), else id("t" .. n .. "_" .. suffix).
function ParamsSpec.track_id(track, suffix, prefix)
  return (prefix or "elasticat_") .. ParamsSpec.track_suffix(track, suffix)
end

-- Register one SPEC entry for one track. deps: {params, cs, prefix, tr_call,
-- machines, modes, trig_conditions}.
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
    params:add_control(pid, name, deps.cs.new(unpack(entry.spec)))
  end

  if entry.cmd ~= nil and deps.tr_call ~= nil then
    local cmd = entry.cmd
    local offset = entry.offset
    local tr_call = deps.tr_call
    params:set_action(pid, function(x)
      tr_call(track, cmd, offset ~= nil and (x + offset) or x)
    end)
  else
    params:set_action(pid, function(_) end)
  end
end

-- Register active_track_count + track 1's mute + the full per-track param set
-- for tracks 2-8. Called from the END of elasticat.params() so every scanner
-- downstream (pattern partition, factory defaults, project globals) sees these
-- params -- per-track params land in the per-pattern partition automatically;
-- active_track_count / t<N>_play are added to PATTERN_GLOBAL_SUFFIXES by the
-- coordinator (elasticat.lua) so they stay project-global.
function ParamsSpec.register(deps)
  local params = deps.params
  local prefix = deps.prefix or "elasticat_"

  -- active_track_count (1-8, default 1): the engine only allocates chains for
  -- tracks 1..count; the UI gates the row-4 track keys on it. All 8 tracks'
  -- params are registered unconditionally -- the count gates engine/UI only.
  params:add_group(prefix .. "group_tracks", "tracks", 2)
  params:add_number(prefix .. "active_track_count", "active tracks", 1, ParamsSpec.TRACK_COUNT_MAX, 1)
  params:set_action(prefix .. "active_track_count", function(n)
    if deps.engine_call ~= nil then
      deps.engine_call("activeTrackCount", n)
    end
    if deps.on_active_track_count ~= nil then
      deps.on_active_track_count(n)
    end
  end)

  -- Track 1 keeps its full existing unprefixed param set; the only thing it
  -- gains is a mute (engine \trMute works on every track, track 1 included).
  for _, entry in ipairs(ParamsSpec.SPEC) do
    if entry.suffix == "mute" then
      register_entry(deps, 1, entry)
    end
  end

  for track = 2, ParamsSpec.TRACK_COUNT_MAX do
    params:add_group(prefix .. "t" .. track .. "_group", "track " .. track, #ParamsSpec.SPEC)
    for _, entry in ipairs(ParamsSpec.SPEC) do
      register_entry(deps, track, entry)
    end
  end
end

return ParamsSpec
