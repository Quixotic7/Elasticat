-- One sequencer per track (docs/PHASE2_CONTRACT.md, per-track sequencers).
--
-- Every track owns an instance of THIS class. There is exactly ONE
-- step-trigger routine -- enter_step -- and it is parameterised by the track
-- index the instance carries, so a trig behaves identically whether or not its
-- track is selected. GridSequencer is a coordinator over 8 of these plus grid
-- input routing; it owns no per-track sequence logic.
--
-- ---- Timing: derived, never accumulated ------------------------------------
-- Step boundaries are DERIVED from the one shared musical clock, never summed
-- off a timer:
--
--   beats_per_step(t) = 0.25 / rate(t)      -- 0.25 beat = a 16th at rate 1x
--   elapsed(t)        = clock.get_beats() - clock_origin
--   step_position(t)  = floor(elapsed / beats_per_step(t))
--   step_index(t)     = (step_position(t) % pattern_steps(t)) + 1
--
-- Every track reads the SAME elapsed beat count, so tracks cannot drift out of
-- phase -- by construction, not by correction. A track fires when its
-- step_position INCREASES (the instance carries the last-fired position); the
-- metro only SAMPLES the clock, so metro jitter costs at most a few
-- milliseconds of latency and never accumulates. A tempo change lands on every
-- track identically because it changes how fast `elapsed` grows, not any
-- track's private bookkeeping.
--
-- Swing is a PHASE OFFSET on the boundary test, not a duration multiplier:
-- odd (0-based) positions compare against pair_start + 2*bps*ratio. See
-- position_at / boundary_beats, which are exact inverses of each other.
--
-- ---- P-lock isolation is structural ----------------------------------------
-- Every param write that originates from a step lock leaves through a ctx sink
-- whose FIRST argument is this instance's track index. There is no code path
-- from a step lock to the selected-track `ui_id` funnel -- the sinks do not
-- accept a track-less call.

local TrackSequencer = {}
TrackSequencer.__index = TrackSequencer

local Step = include("lib/sequencer/step")
local TrigConditions = include("lib/sequencer/trig_conditions")  -- PRD §6.5

-- Pattern rates, the SINGLE source of truth (grid_sequencer.lua and
-- lib/ui/param_values.lua both read these -- they each used to carry their own
-- copy plus their own label function, which is how the two drift apart).
--
-- Stored as exact {numerator, denominator} fractions rather than decimals.
-- Two reasons, both load-bearing:
--   * The triplet family (1/6, 1/3, 2/3, 5/6, 7/6, 5/3, 11/6) repeats in binary
--     float. Deriving beats-per-step as 0.25 * den / num keeps a triplet track
--     landing exactly on the bar instead of creeping by a sample per cycle.
--   * The label is the fraction, not a decimal reverse-engineered back into one
--     ("11/6" cannot be recovered cleanly from 1.8333...).
--
-- Sorted ascending, so 1x sits at RATE_UNITY (13). rate_index IS serialized
-- into saved patterns; the owner has accepted that this re-indexes existing
-- projects, so this is a deliberate break, not an oversight.
TrackSequencer.RATE_FRACTIONS = {
  {1, 16}, {1, 8}, {1, 6}, {1, 4}, {1, 3}, {3, 8}, {1, 2}, {5, 8}, {2, 3},
  {3, 4}, {5, 6}, {7, 8}, {1, 1}, {7, 6}, {5, 4}, {4, 3}, {3, 2}, {5, 3},
  {7, 4}, {11, 6}, {2, 1}
}
TrackSequencer.RATE_UNITY = 13    -- index of 1x; the default

TrackSequencer.RATES = {}
for i, f in ipairs(TrackSequencer.RATE_FRACTIONS) do
  TrackSequencer.RATES[i] = f[1] / f[2]
end

-- "1/16", "3/8", "1", "2" -- shown to the user as a fraction, per the owner.
function TrackSequencer.rate_label(index)
  local f = TrackSequencer.RATE_FRACTIONS[index]
  if f == nil then
    return "1"
  end
  if f[2] == 1 then
    return tostring(f[1])
  end
  return f[1] .. "/" .. f[2]
end

-- Exact beats per step: 0.25 beat (a 16th) divided by the rate, done as
-- rational arithmetic so triplets stay exact.
function TrackSequencer.rate_beats_per_step(index, base)
  local f = TrackSequencer.RATE_FRACTIONS[index] or {1, 1}
  return (base or 0.25) * f[2] / f[1]
end

-- One step at rate 1x, in beats. Also the MASTER grid the global pattern cycle
-- runs on (Elektron PER TRACK model: per-track lengths/rates run inside a
-- global length that is itself unscaled).
TrackSequencer.BEATS_PER_STEP_1X = 0.25

-- Boundary comparisons are done on floats; a boundary computed as n*bps and
-- then divided back by bps can land an ulp short. One nanobeat of slop makes
-- the two exact inverses without measurably shifting any real boundary
-- (1e-9 beat = 0.5 nanoseconds at 120 BPM).
local BEAT_EPSILON = 1e-9

-- Most steps a single tick may fire before we stop replaying history and just
-- resync the position (a long stall, or the clock jumping forward).
local MAX_CATCHUP = 8

local MACHINE_LOOP = 1
local MACHINE_LOOP_TRIG = 2
local MACHINE_GRID_SLICE = 3
local MACHINE_RAZOR_SLICE = 4
local MACHINE_SLICE_POLY = 5
local MACHINE_RAZOR_POLY = 6

-- Trig chance/condition/ratchet are p-lockable per step, but they steer the
-- SEQUENCER, not the engine. They live in a step's param_locks (so the grid
-- p-lock UI works for free) yet must never be pushed to the engine or carried
-- forward as note-length holds -- they are read directly per step instead.
local SEQUENCER_DOMAIN_LOCKS = {
  trig_chance = true,
  trig_condition = true,
  trig_ratchet = true
}

-- Region/range locks are RESOLVER inputs, never applied params. The three-layer
-- model (Track / Step-p-lock / Actual): the Track start/end/range params belong
-- to the user and stay live-editable at all times; a step's region lock rides
-- param_lock_holds into region_layers/apply_active_range and shadows the Track
-- values only in the Actual layer while its window is active.
local REGION_LOCKS = {
  loop_start = true,
  loop_end = true,
  range_start = true,
  range_end = true
}

-- All four slice machines: Grid/Razor (mono) and their Poly variants (>= 3).
local function is_slice_machine(machine)
  return machine >= MACHINE_GRID_SLICE and machine <= MACHINE_RAZOR_POLY
end
TrackSequencer.is_slice_machine = is_slice_machine

local function table_count(t)
  local count = 0
  for _, value in pairs(t or {}) do
    if value then
      count = count + 1
    end
  end
  return count
end

local function any_keys(t)
  for _, held in pairs(t or {}) do
    if held then
      return true
    end
  end
  return false
end

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

function TrackSequencer.index_to_page_step(index)
  local page = math.floor((index - 1) / 16) + 1
  local step = ((index - 1) % 16) + 1
  return page, step
end

-- ctx is the shared environment GridSequencer builds once. EVERY sink below
-- takes the track index as its first argument -- that is what makes p-lock and
-- engine isolation structural rather than conventional.
function TrackSequencer.new(index, ctx)
  local self = setmetatable({}, TrackSequencer)
  self.index = index
  self.ctx = ctx or {}

  -- Pattern-owned state (serialized). Field NAMES are load-bearing: the
  -- coordinator and lib/ui/param_values.lua read `grid_ui.seq.rate_index`, and
  -- the rest of grid_sequencer.lua reads `self.seq.steps` / `.play_index`.
  self.steps = {}
  self.page_loop = {[1] = true}
  self.rate_index = TrackSequencer.RATE_UNITY

  -- Transport-owned state (never serialized).
  self.play_index = 1
  self.play_page = 1
  self.play_step = 1
  self.pattern_pass = 1
  self.last_cond_result = nil
  -- Last FIRED 0-based clock step position. nil = not primed (stopped).
  self.position = nil

  -- Live override state, PER TRACK -- this is what lets a background track have
  -- the full region-lock / trig-release behaviour instead of a bare noteOn.
  self.param_lock_holds = {}
  -- Per-SLICE p-locks (MPC chop program): each slice carries its own param values
  -- (its identity) that apply whenever it plays -- live or on a step -- UNDER the
  -- step's own p-locks (step wins). slice_locks[slice] = {param_id -> value}.
  -- Serialized with the pattern.
  self.slice_locks = {}
  -- Per-SLICE choke group (MPC mute group): slice_choke[slice] = group (1..N);
  -- 0/nil = None. A voice in group G cuts other live voices in the same group on
  -- this track (poly only). Resolved per voice and passed to the engine; kept out
  -- of slice_locks because it is steal metadata, not an engine param that morphs.
  self.slice_choke_map = {}
  self.seq_anchor = nil
  self.seq_release_mode = nil
  self.current_region_start = nil
  self.current_region_end = nil
  self.current_range_start = nil
  self.current_range_end = nil
  self.ratchet_token = 0
  return self
end

-- ---- ctx plumbing ----------------------------------------------------------

function TrackSequencer:call(name, ...)
  local fn = self.ctx[name]
  if fn == nil then
    return nil
  end
  return fn(self.index, ...)
end

-- THIS track's value for a per-track param suffix. Never the selected track's.
function TrackSequencer:param(suffix, fallback)
  if self.ctx.param == nil then
    return fallback
  end
  local value = self.ctx.param(self.index, suffix)
  if value == nil then
    return fallback
  end
  return value
end

function TrackSequencer:param_number(suffix, fallback, lo, hi)
  local raw = tonumber(self:param(suffix, fallback))
  if raw == nil then
    raw = fallback
  end
  if lo ~= nil then
    raw = math.max(lo, math.min(hi, raw))
  end
  return raw
end

function TrackSequencer:param_int(suffix, fallback, lo, hi)
  local raw = tonumber(self:param(suffix, fallback)) or fallback
  raw = math.floor(raw + 0.5)
  if lo ~= nil then
    raw = util.clamp(raw, lo, hi)
  end
  return raw
end

-- Project-wide (non per-track) settings: swing, live-performance mode, ...
function TrackSequencer:global(name, fallback)
  if self.ctx.global == nil then
    return fallback
  end
  local value = self.ctx.global(name)
  if value == nil then
    return fallback
  end
  return value
end

function TrackSequencer:selected()
  return self.ctx.selected_track ~= nil and self.ctx.selected_track() == self.index
end

-- Live loop-key holds and the Live Step Trig hold are physical gestures on the
-- one grid: they belong to the SELECTED track only. Background tracks see an
-- empty hold set, which is exactly right -- their sequenced behaviour is
-- otherwise identical.
function TrackSequencer:loop_holds()
  if self.ctx.loop_holds == nil then
    return {}
  end
  return self.ctx.loop_holds(self.index) or {}
end

function TrackSequencer:live_step_hold()
  return self.ctx.live_step_hold ~= nil and self.ctx.live_step_hold(self.index) == true
end

function TrackSequencer:playing()
  return self.ctx.playing ~= nil and self.ctx.playing() == true
end

-- ---- Per-track settings ----------------------------------------------------

function TrackSequencer:machine()
  return self:param_int("machine", 1, 1, 6)
end

function TrackSequencer:pattern_steps()
  return self:param_int("pattern_steps", 16, 1, 256)
end

function TrackSequencer:slice_count()
  return self:param_int("slice_count", 16, 1, 32)
end

function TrackSequencer:slice_index()
  return self:param_int("slice_index", 1, 1, self:slice_count())
end

function TrackSequencer:trig_polyphony()
  return self:param_int("trig_polyphony", 1, 1, 2)
end

function TrackSequencer:default_velocity()
  return self:param_number("default_velocity", 1)
end

function TrackSequencer:default_length()
  return self:param_number("default_length", 1)
end

function TrackSequencer:base_pitch()
  return self:param_number("pitch", 0)
end

function TrackSequencer:base_region()
  local start_point = self:param_number("loop_start", 0)
  local end_point = self:param_number("loop_end", 128)
  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  return start_point, end_point
end

function TrackSequencer:rate()
  return TrackSequencer.RATES[self.rate_index] or 1
end

-- ---- Clock-derived timing --------------------------------------------------

function TrackSequencer:beats_per_step()
  -- Rational, not 0.25/rate: the triplet rates repeat in binary float, and
  -- dividing by the rounded decimal makes a triplet track creep off the bar.
  -- 0.25 * den / num is exact for every entry in RATE_FRACTIONS.
  local idx = self.rate_index
  if TrackSequencer.RATE_FRACTIONS[idx] == nil then
    idx = TrackSequencer.RATE_UNITY
  end
  return TrackSequencer.rate_beats_per_step(idx, TrackSequencer.BEATS_PER_STEP_1X)
end

-- Swing as a RATIO (0.5 = straight, 0.75 = maximum). Global, like the param.
function TrackSequencer:swing_ratio()
  local raw = tonumber(self:global("swing", 50)) or 50
  return util.clamp(raw, 50, 75) / 100
end

-- 0-based clock step position at `elapsed` beats since the shared origin.
-- Pure function of the shared clock -- no state, no accumulation. Swing shifts
-- the ODD boundary inside each pair; the pair boundary itself never moves, so
-- swing can never make a track slip a beat relative to another.
function TrackSequencer:position_at(elapsed)
  local bps = self:beats_per_step()
  if bps <= 0 then
    return 0
  end
  local u = (elapsed / bps) + BEAT_EPSILON  -- elapsed, measured in straight steps
  local swing = self:swing_ratio()
  if swing <= 0.5 then
    return math.floor(u)
  end
  local pair = math.floor(u / 2)
  local frac = u - (pair * 2)
  return (pair * 2) + ((frac >= (swing * 2)) and 1 or 0)
end

-- Beat offset of the boundary that STARTS 0-based position n. Exact inverse of
-- position_at: position_at(boundary_beats(n)) == n for every n.
function TrackSequencer:boundary_beats(n)
  local bps = self:beats_per_step()
  local swing = self:swing_ratio()
  if swing <= 0.5 then
    return n * bps
  end
  local pair = math.floor(n / 2)
  local odd = n - (pair * 2)
  return (pair * 2 * bps) + ((odd == 1) and (2 * bps * swing) or 0)
end

-- Wall-clock seconds one step occupies at the current tempo. A DURATION (note
-- lengths, ratchet spacing, lock-expiry windows) -- never a step boundary.
function TrackSequencer:step_seconds()
  local bpm = math.max(1, tonumber(self:global("tempo", 120)) or 120)
  return self:beats_per_step() * 60 / bpm
end

function TrackSequencer:note_seconds(record)
  if is_slice_machine(self:machine()) and self:param_int("slice_hold_to_step", 1, 0, 1) == 0 then
    return self:param_number("slice_hold", 0)
  end
  return math.max(0.01, ((record ~= nil and record.length) or self:default_length()) * self:step_seconds())
end

-- ---- Advancement -----------------------------------------------------------

-- Anchor this track at `position` (0-based) WITHOUT firing it. Used by
-- start/stop/pattern-apply, which fire step 1 themselves via enter_step(true).
function TrackSequencer:anchor(position)
  self.position = position
  local steps = self:pattern_steps()
  local index = (position % steps) + 1
  self.play_index = index
  self.play_page, self.play_step = TrackSequencer.index_to_page_step(index)
  self.pattern_pass = math.floor(position / steps) + 1
end

function TrackSequencer:unanchor()
  self.position = nil
end

-- The one advancement routine. `elapsed` is the SHARED beat count -- every
-- track is handed the identical value in the same tick, which is what makes
-- drift impossible.
function TrackSequencer:advance_to(elapsed)
  local target = self:position_at(elapsed)
  if self.position == nil then
    -- Not primed: a track that active_track_count just switched on mid-run.
    -- Join at the DERIVED position so it drops in already in phase with the
    -- others, rather than starting a private count from step 1.
    self:anchor(target)
    return 0
  end
  local fired = 0
  while target > self.position and fired < MAX_CATCHUP do
    self:enter_position(self.position + 1)
    fired = fired + 1
  end
  if target > self.position then
    -- Fell further behind than a tick can musically make up (a stall, or the
    -- clock jumping). Re-anchor on the DERIVED position rather than replaying
    -- history: the alternative -- keeping the stale position -- is exactly the
    -- accumulating error this design exists to prevent.
    self:anchor(target)
  end
  return fired
end

-- Move to a specific 0-based position and fire it. Everything about "where am
-- I in the pattern" is derived from the position, so a pattern-length change
-- or a tempo change can never leave the index and the clock disagreeing.
function TrackSequencer:enter_position(position)
  self.position = position
  local steps = self:pattern_steps()
  self.play_index = (position % steps) + 1
  self.play_page, self.play_step = TrackSequencer.index_to_page_step(self.play_index)
  -- pattern_pass drives the A:B and 1st trig conditions (PRD §6.5). Derived,
  -- so it stays correct across catch-up, pause/resume and tempo changes.
  self.pattern_pass = math.floor(position / steps) + 1
  self:enter_step(false)
end

-- ---- Step records ----------------------------------------------------------

function TrackSequencer:step_record(index, create)
  if self.steps[index] == nil and create then
    self.steps[index] = Step.new()
  end
  return self.steps[index]
end

function TrackSequencer:pattern_has_trigs()
  for _, record in pairs(self.steps) do
    if record ~= nil and record.trig == true then
      return true
    end
  end
  return false
end

function TrackSequencer:has_content()
  return next(self.steps) ~= nil
end

function TrackSequencer:progress()
  local steps = self:pattern_steps()
  if steps < 1 then
    return nil
  end
  local index = math.floor((tonumber(self.play_index) or 1) + 0.5)
  return util.clamp((index - 1) / steps, 0, 1)
end

-- ---- Serialization ---------------------------------------------------------

function TrackSequencer:serialize()
  local steps = {}
  for index, record in pairs(self.steps) do
    if Step.has_content(record) then
      steps[index] = deep_copy(record)
    end
  end
  local page_loop = {}
  for page, on in pairs(self.page_loop) do
    if on then
      page_loop[page] = true
    end
  end
  local slice_locks = {}
  for slice, s in pairs(self.slice_locks) do
    if next(s) ~= nil then
      slice_locks[slice] = deep_copy(s)
    end
  end
  local slice_choke = {}
  for slice, group in pairs(self.slice_choke_map) do
    if group and group > 0 then
      slice_choke[slice] = group
    end
  end
  return {steps = steps, rate_index = self.rate_index, page_loop = page_loop,
    slice_locks = slice_locks, slice_choke = slice_choke}
end

-- Restore pattern-owned state. Transport state (position, pass counters) is
-- deliberately untouched -- the caller decides whether to re-anchor.
function TrackSequencer:deserialize(snapshot)
  snapshot = snapshot or {}
  self.steps = {}
  for index, record in pairs(snapshot.steps or {}) do
    self.steps[index] = deep_copy(record)
  end
  self.rate_index = snapshot.rate_index or TrackSequencer.RATE_UNITY
  self.slice_locks = {}
  for slice, s in pairs(snapshot.slice_locks or {}) do
    self.slice_locks[slice] = deep_copy(s)
  end
  self.slice_choke_map = {}
  for slice, group in pairs(snapshot.slice_choke or {}) do
    if group and group > 0 then
      self.slice_choke_map[slice] = group
    end
  end
  self.page_loop = {}
  for page, on in pairs(snapshot.page_loop or {}) do
    if on then
      self.page_loop[page] = true
    end
  end
  if next(self.page_loop) == nil then
    self.page_loop[1] = true
  end
end

-- ---- Step-level field resolution -------------------------------------------

-- Effective value of a sequencer-domain field for a step: its own p-lock if
-- present, else THIS track's param.
function TrackSequencer:step_field(record, lock_id, suffix, fallback)
  if record ~= nil and record.param_locks ~= nil and record.param_locks[lock_id] ~= nil then
    return record.param_locks[lock_id]
  end
  return self:param(suffix, fallback)
end

function TrackSequencer:effective_ratchet(record)
  local raw = self:step_field(record, "trig_ratchet", "trig_ratchet", 1)
  return util.clamp(math.floor((tonumber(raw) or 1) + 0.5), 1, 8)
end

-- A reset flag is active for a step when the step p-locks it on, or (no lock)
-- THIS track's default is on.
function TrackSequencer:reset_active(record, reset_id)
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil and locks[reset_id] ~= nil then
    return locks[reset_id] == 1
  end
  return self:param_int(reset_id, 1, 0, 1) == 1
end

function TrackSequencer:trig_jump_active(record)
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil and locks.trig_jump ~= nil then
    return locks.trig_jump == 1
  end
  return self:param_int("trig_jump", 1, 0, 1) == 1
end

-- 1=Return (default), 2=Boomerang, 3=Reset.
function TrackSequencer:step_release_mode(record)
  local locks = record ~= nil and record.param_locks or nil
  local raw = locks ~= nil and locks.trig_release or nil
  if raw == nil then
    raw = self:param("trig_release", 1)
  end
  raw = math.floor((tonumber(raw) or 1) + 0.5)
  if raw == 2 then return "boomerang" end
  if raw == 3 then return "reset" end
  return "return"
end

-- Ghost triggers are derived (not a stored flag): a trig that resets nothing.
function TrackSequencer:is_ghost(record)
  if record == nil or record.trig ~= true then
    return false
  end
  local locks = record.param_locks or {}
  if locks.loop_start ~= nil then
    return false
  end
  return not (self:reset_active(record, "env_reset")
    or self:reset_active(record, "lfo_reset")
    or self:reset_active(record, "filter_reset"))
end

-- ---- Trig conditions (PRD §6.5) --------------------------------------------

function TrackSequencer:condition_definition(record)
  local raw = self:step_field(record, "trig_condition", "trig_condition", 1)
  local idx = util.clamp(math.floor((tonumber(raw) or 1) + 0.5), 1, #TrigConditions)
  return TrigConditions[idx]
end

-- Whether a step's CONDITION passes this pass (independent of the chance roll).
-- Pure read -- no side effects -- so it is safe to call for UI/preview too.
-- Fill is a shared live gesture; pattern_pass/last_cond_result are per track.
function TrackSequencer:condition_result(record)
  local def = self:condition_definition(record)
  local kind = def ~= nil and def.kind or "none"
  if kind == "none" then
    return true
  elseif kind == "ab" then
    return ((self.pattern_pass - 1) % def.b) + 1 == def.a
  elseif kind == "fill" then
    return self:global("fill_active", false) == true
  elseif kind == "nfill" then
    return self:global("fill_active", false) ~= true
  elseif kind == "pre" then
    return self.last_cond_result == true
  elseif kind == "npre" then
    return self.last_cond_result ~= true
  elseif kind == "nei" or kind == "nnei" then
    -- Neighbor-track conditions: no neighbor routing exists until Phase 5.
    return true
  elseif kind == "first" then
    return self.pattern_pass == 1
  end
  return true
end

-- Both independent p-lockable fields must pass: the condition AND the chance
-- roll. Records the outcome for a following PRE/!PRE trig, but only for steps
-- that themselves carry a condition.
function TrackSequencer:evaluate_trig(record)
  local def = self:condition_definition(record)
  local kind = def ~= nil and def.kind or "none"
  local fired = self:condition_result(record)
  if fired then
    local chance = util.clamp(self:step_field(record, "trig_chance", "trig_chance", 100), 0, 100)
    if chance < 100 then
      fired = (math.random() * 100) < chance
    end
  end
  if kind ~= "none" then
    self.last_cond_result = fired
  end
  return fired
end

-- ---- Param-lock holds (per track) ------------------------------------------

function TrackSequencer:clear_param_lock_holds()
  self.param_lock_holds = {}
end

function TrackSequencer:expire_param_lock_holds(now)
  local changed = false
  now = now or util.time()
  for lock_id, hold in pairs(self.param_lock_holds) do
    if hold.expires_at ~= nil and now >= hold.expires_at then
      self.param_lock_holds[lock_id] = nil
      changed = true
    end
  end
  return changed
end

-- ---- Per-slice p-locks (MPC chop program) ----------------------------------

function TrackSequencer:slice_lock(slice, param_id)
  local s = self.slice_locks[slice]
  return s and s[param_id] or nil
end

function TrackSequencer:set_slice_lock(slice, param_id, value)
  local s = self.slice_locks[slice]
  if s == nil then
    s = {}
    self.slice_locks[slice] = s
  end
  s[param_id] = value
end

-- Clear one param (or, param_id nil, the whole slice). Returns true if anything
-- was removed.
function TrackSequencer:clear_slice_lock(slice, param_id)
  local s = self.slice_locks[slice]
  if s == nil then
    return false
  end
  if param_id == nil then
    self.slice_locks[slice] = nil
    return true
  end
  if s[param_id] == nil then
    return false
  end
  s[param_id] = nil
  if next(s) == nil then
    self.slice_locks[slice] = nil
  end
  return true
end

function TrackSequencer:slice_lock_set(slice)
  return self.slice_locks[slice]
end

-- Per-slice choke group (0 = None). Getter returns 0 for an unset slice so the
-- trigger path can pass it straight through.
function TrackSequencer:slice_choke(slice)
  return self.slice_choke_map[slice] or 0
end

function TrackSequencer:set_slice_choke(slice, group)
  group = math.floor((tonumber(group) or 0) + 0.5)
  if group <= 0 then
    self.slice_choke_map[slice] = nil
  else
    self.slice_choke_map[slice] = group
  end
end

-- The first slice a step actually fires -- its locks form the per-step base.
function TrackSequencer:primary_slice(record)
  if record ~= nil and record.slices ~= nil then
    for slice, on in pairs(record.slices) do
      if on then
        return slice
      end
    end
  end
  return nil
end

function TrackSequencer:effective_param_locks(record)
  local now = util.time()
  self:expire_param_lock_holds(now)

  local locks = {}
  local has_locks = false
  -- Per-slice p-locks are the BASE layer (the slice's identity); the held layer
  -- and the step's own p-locks below override them. Only a step firing an
  -- explicit slice, and only if that slice has locks -- so loop steps and the
  -- default-slice case are untouched. This covers the TRACK-level params
  -- (filter, env, reverse, ...); pitch/velocity are resolved PER VOICE in
  -- trigger_step_slices, so they are excluded here -- pushing them as track
  -- params would churn against apply_step_pitch and the per-voice value.
  if next(self.slice_locks) ~= nil then
    local slice = self:primary_slice(record)
    local sl = slice ~= nil and self.slice_locks[slice] or nil
    if sl ~= nil then
      for lock_id, value in pairs(sl) do
        if not REGION_LOCKS[lock_id] and not SEQUENCER_DOMAIN_LOCKS[lock_id]
          and lock_id ~= "pitch" and lock_id ~= "velocity" then
          locks[lock_id] = value
          has_locks = true
        end
      end
    end
  end
  for lock_id, hold in pairs(self.param_lock_holds) do
    if not REGION_LOCKS[lock_id] then
      locks[lock_id] = hold.value
      has_locks = true
    end
  end

  if record ~= nil and record.param_locks ~= nil then
    local length_seconds = self:note_seconds(record)
    for lock_id, value in pairs(record.param_locks) do
      if not SEQUENCER_DOMAIN_LOCKS[lock_id] then
        if not REGION_LOCKS[lock_id] then
          locks[lock_id] = value
          has_locks = true
        end
        if lock_id ~= "length" and lock_id ~= "velocity" then
          self.param_lock_holds[lock_id] = {value = value, expires_at = now + length_seconds}
        end
      end
    end
  end

  return has_locks and locks or nil
end

-- The ONE exit for a step lock -> a param. Always carries this instance's
-- track index, so a step on track 3 can only ever write track 3's params.
function TrackSequencer:push_param_locks(locks)
  self:call("apply_step_param_locks", locks)
end

function TrackSequencer:apply_step_pitch(record)
  local pitch = record ~= nil and record.pitch or nil
  if pitch == nil and record ~= nil and record.param_locks ~= nil then
    pitch = record.param_locks.pitch
  end
  if pitch == nil and self.param_lock_holds.pitch ~= nil then
    pitch = self.param_lock_holds.pitch.value
  end
  self:call("set_pitch", pitch or self:base_pitch())
end

-- ---- Region resolution (per track) -----------------------------------------

function TrackSequencer:region_is_current(start_point, end_point)
  return self.current_region_start ~= nil
    and math.abs(self.current_region_start - start_point) < 0.0001
    and math.abs(self.current_region_end - end_point) < 0.0001
end

function TrackSequencer:mark_region_current(start_point, end_point)
  self.current_region_start = start_point
  self.current_region_end = end_point
end

function TrackSequencer:set_region(start_point, end_point)
  if self:region_is_current(start_point, end_point) then
    return
  end
  self:call("set_loop_region", start_point, end_point)
  self:mark_region_current(start_point, end_point)
end

function TrackSequencer:set_region_with_phase(start_point, end_point, phase)
  self:call("set_loop_region", start_point, end_point, phase)
  self:mark_region_current(start_point, end_point)
end

function TrackSequencer:phase_for_position(start_point, end_point, position)
  local range = math.max(0.01, end_point - start_point)
  return ((position - start_point) / range) % 1
end

function TrackSequencer:position_at_region(start_point, end_point, at_time)
  if self.ctx.position_at_region ~= nil then
    return self.ctx.position_at_region(self.index, start_point, end_point, at_time)
  end
  local phase = 0
  if self.ctx.phase ~= nil then
    phase = self.ctx.phase(self.index) or 0
  end
  return start_point + ((end_point - start_point) * phase)
end

-- Resolve a single step record's region against the track base. Start and end
-- are independent. (Used for stopped preview; live playback goes through
-- resolve_active_region so the layering can take effect.)
function TrackSequencer:locked_region(record)
  local start_point, end_point = self:base_region()
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil then
    if locks.loop_start ~= nil then
      start_point = locks.loop_start
    end
    if locks.loop_end ~= nil then
      end_point = locks.loop_end
    end
  end
  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  return start_point, end_point
end

-- The three region layers that can drive playback:
--   track  -- always present (base_region), the bottom fallback
--   keys   -- live loop-key holds (selected track only)
--   seq    -- the currently-triggering step's region lock, with its expiry
function TrackSequencer:region_layers()
  local track_start, track_end = self:base_region()

  self:expire_param_lock_holds(util.time())
  local seq = {}
  if self.param_lock_holds.loop_start ~= nil then
    seq.start_point = self.param_lock_holds.loop_start.value
  end
  if self.param_lock_holds.loop_end ~= nil then
    seq.end_point = self.param_lock_holds.loop_end.value
  end

  local keys = {}
  if self.ctx.loop_key_region ~= nil then
    local key_start, key_end = self.ctx.loop_key_region(self.index)
    if key_start ~= nil then
      keys.start_point = key_start
      keys.end_point = key_end
    end
  end

  return track_start, track_end, seq, keys
end

function TrackSequencer:resolve_active_region()
  local track_start, track_end, seq, keys = self:region_layers()
  -- Held loop keys are a live gesture and always beat the sequenced layer.
  local order = {keys, seq}

  local start_point, end_point = track_start, track_end
  local start_set, end_set = false, false
  for _, layer in ipairs(order) do
    if not start_set and layer.start_point ~= nil then
      start_point = layer.start_point
      start_set = true
    end
    if not end_set and layer.end_point ~= nil then
      end_point = layer.end_point
      end_set = true
    end
  end

  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  return start_point, end_point
end

-- Step Range -> Active Range override, layered exactly like the loop region.
function TrackSequencer:push_active_range(range_start, range_end)
  if range_start ~= self.current_range_start or range_end ~= self.current_range_end then
    self:call("set_active_range", range_start, range_end)
    self.current_range_start = range_start
    self.current_range_end = range_end
    self.current_region_start = nil
  end
end

function TrackSequencer:apply_active_range()
  self:expire_param_lock_holds(util.time())
  local range_start = self.param_lock_holds.range_start and self.param_lock_holds.range_start.value or nil
  local range_end = self.param_lock_holds.range_end and self.param_lock_holds.range_end.value or nil
  self:push_active_range(range_start, range_end)
end

-- A Track-layer region/range param was edited while running: re-resolve and
-- re-push through the layered resolver.
function TrackSequencer:refresh_track_region()
  self.current_region_start = nil
  self:apply_active_range()
  local start_point, end_point = self:resolve_active_region()
  self:set_region(start_point, end_point)
end

function TrackSequencer:current_absolute_position()
  local cur_start = self.current_region_start
  local cur_end = self.current_region_end
  if cur_start == nil then
    return nil
  end
  return self:position_at_region(cur_start, cur_end, util.time())
end

function TrackSequencer:set_region_preserve_position(new_start, new_end)
  local pos = self:current_absolute_position()
  if pos == nil then
    self:set_region(new_start, new_end)
    return
  end
  local phase = self:phase_for_position(new_start, new_end, pos)
  self:set_region_with_phase(new_start, new_end, phase)
end

-- Trig Jump OFF: the walls moved. Returns true when the region actually
-- changed (the main loop was interrupted).
function TrackSequencer:set_region_within_or_warp(new_start, new_end)
  if self:region_is_current(new_start, new_end) then
    return false
  end
  local pos = self:current_absolute_position()
  local lo, hi = math.min(new_start, new_end), math.max(new_start, new_end)
  if pos ~= nil and pos >= lo and pos <= hi then
    self:set_region_preserve_position(new_start, new_end)
  else
    self:set_region_with_phase(new_start, new_end, 0)
  end
  return true
end

-- ---- Playhead anchors / release modes --------------------------------------

function TrackSequencer:make_anchor()
  return {
    start_point = self.current_region_start,
    end_point = self.current_region_end,
    pos = self:current_absolute_position(),
    time = util.time()
  }
end

function TrackSequencer:natural_phase_from(anchor)
  if anchor == nil or anchor.pos == nil or anchor.start_point == nil
    or self.ctx.loop_rate == nil then
    return nil
  end
  local width = math.max(0.01, anchor.end_point - anchor.start_point)
  local anchor_phase = ((anchor.pos - anchor.start_point) / width) % 1
  local rate = self.ctx.loop_rate(self.index, anchor.start_point, anchor.end_point) or 0
  local dir = 1
  if self.ctx.playhead_direction ~= nil then
    dir = self.ctx.playhead_direction(self.index) or 1
  end
  local elapsed = util.time() - (anchor.time or util.time())
  return (anchor_phase + (dir * elapsed * rate)) % 1
end

function TrackSequencer:apply_release_mode(mode, start_point, end_point, anchor)
  if mode == "reset" then
    self:set_region_with_phase(start_point, end_point, 0)
  elseif mode == "return" then
    local phase = self:natural_phase_from(anchor)
    if phase ~= nil then
      self:set_region_with_phase(start_point, end_point, phase)
    else
      self:set_region_with_phase(start_point, end_point, 0)  -- fallback: reset
    end
  else
    self:set_region_preserve_position(start_point, end_point)
  end
end

-- ---- Triggering ------------------------------------------------------------

function TrackSequencer:slice_range(slice)
  if self.ctx.slice_range ~= nil then
    return self.ctx.slice_range(self.index, slice)
  end
  local count = self:slice_count()
  local width = 128 / count
  return (slice - 1) * width, slice * width
end

function TrackSequencer:trigger_region(record)
  local start_point, end_point = self:locked_region(record)
  self:set_region_with_phase(start_point, end_point, 0)
  self:call("trigger_region", start_point, end_point, {
    velocity = record.velocity or self:default_velocity(),
    length_seconds = self:note_seconds(record),
    pitch = record.pitch or self:base_pitch()
  })
end

function TrackSequencer:trigger_step_slices(record)
  local first_start = nil
  local first_end = nil
  local slices = record.slices or {}
  if record.trig and table_count(slices) == 0 then
    slices = {[self:slice_index()] = true}
  end
  -- Gate length by play mode (owner): One-Shot (1) passes 0 -> the engine plays
  -- the whole slice range regardless of step length (its read sweep-end gates
  -- it). Hold/Loop/Continue (2/3/4) pass the STEP note length so a longer step
  -- gates a longer note; the envelope hold can shorten it further (AHR).
  local play_mode = self:param_int("slice_play_mode", 1, 1, 6)
  local slice_length = (play_mode == 1) and 0 or self:note_seconds(record)
  local fired = nil
  for slice = 1, self:slice_count() do
    if slices[slice] then
      fired = fired or {}
      fired[slice] = true
      local start_point, end_point = self:slice_range(slice)
      first_start = first_start or start_point
      first_end = first_end or end_point
      self:call("trigger_slice", slice, start_point, end_point, {
        -- PER-VOICE resolve (each slice its own): the step's p-lock overrides the
        -- SLICE's p-lock (its identity), which overrides the track base. Track-
        -- level slice params (filter/env/reverse) come through effective_param_
        -- locks, which already merged this slice's locks under the step's.
        velocity = record.velocity or self:slice_lock(slice, "velocity") or self:default_velocity(),
        -- Natural pitch, like the live Loop/Slice keys (which pass 0). The read
        -- rate is set by clock-sync/RATE, not the note length, so passing a length
        -- here no longer pitches the slice -- it only gates it (see slice_length).
        length_seconds = slice_length,
        pitch = record.pitch or self:slice_lock(slice, "pitch") or self:base_pitch(),
        -- Per-slice choke group (MPC mute group); 0 = None. Engine cuts other
        -- live voices in the same group on this track (poly only).
        choke = self:slice_choke(slice)
      })
    end
  end
  if first_start ~= nil then
    self:mark_region_current(first_start, first_end)
  end
  -- The step's slices, for the source-page waveform highlight (which slice is
  -- playing). Only updated when a step actually fires slices, so between trigs
  -- the last one stays lit; the grid reads it only while playing.
  if fired ~= nil then
    self.active_slices = fired
  end
end

-- Ratchets: the extra sub-step hits after the first (PRD §6.5). A token
-- cancels stale runs when the next step (or a stop) supersedes them.
function TrackSequencer:schedule_ratchets(record, count)
  if clock == nil or clock.run == nil then
    return
  end
  local machine = self:machine()
  local interval = self:step_seconds() / count
  self.ratchet_token = (self.ratchet_token or 0) + 1
  local token = self.ratchet_token
  clock.run(function()
    for _ = 2, count do
      clock.sleep(interval)
      if not self:playing() or self.ratchet_token ~= token then
        return
      end
      self:retrigger_ratchet(record, machine)
    end
  end)
end

function TrackSequencer:retrigger_ratchet(record, machine)
  self:call("mod_trig",
    self:reset_active(record, "lfo_reset"),
    self:reset_active(record, "env_reset"))
  if machine == MACHINE_LOOP or machine == MACHINE_LOOP_TRIG then
    if not self:is_ghost(record) then
      self:call("note_on", self:note_seconds(record))
    end
    if machine == MACHINE_LOOP_TRIG then
      self:trigger_region(record)
    else
      local start_point, end_point = self:resolve_active_region()
      self:set_region_with_phase(start_point, end_point, 0)
    end
  elseif is_slice_machine(machine) then
    self:trigger_step_slices(record)
  end
end

-- ---- THE step routine ------------------------------------------------------
-- One routine, parameterised by the instance's track. The selected track and
-- every background track run exactly this code; nothing here reads "the
-- selected track" -- every read is self:param(...) and every write leaves
-- through self:call(...), both of which carry self.index.
function TrackSequencer:enter_step(reset_sequence)
  local record = self:step_record(self.play_index, false)
  local machine = self:machine()

  if reset_sequence then
    self:clear_param_lock_holds()
    self.seq_anchor = nil
    -- A fresh start is pass 1 with no prior conditional result (PRD §6.5).
    self.pattern_pass = 1
    self.last_cond_result = nil
  end

  -- Live Step Trig: a live-held step owns playback -- sequenced steps advance
  -- silently until the hold releases.
  if self:live_step_hold() and not reset_sequence then
    return
  end

  -- Trig conditions: an active step only FIRES if its chance roll and its
  -- condition both pass. A step that doesn't fire behaves exactly like an
  -- empty step.
  local active = record ~= nil and (
    (is_slice_machine(machine) and table_count(record.slices) > 0)
    or record.trig == true)
  local fires = active and self:evaluate_trig(record)
  local lock_record = fires and record or nil

  -- Monophonic: a fresh non-ghost trigger ends the previous note -- clear the
  -- carried holds so unlocked params revert to base before this step's locks
  -- apply. Ghost triggers, and Poly mode, carry the previous state forward.
  if not reset_sequence and fires
    and self:trig_polyphony() == 1 and not self:is_ghost(record) then
    self:clear_param_lock_holds()
  end
  self:push_param_locks(self:effective_param_locks(lock_record))
  self:apply_step_pitch(lock_record)
  -- Push the Step Range before any region set, so the region maps through the
  -- correct (Actual) range in the same tick.
  self:apply_active_range()

  -- Retrigger the amp envelope on each non-ghost note.
  if (machine == MACHINE_LOOP or machine == MACHINE_LOOP_TRIG)
    and fires and not self:is_ghost(record) then
    self:call("note_on", self:note_seconds(record))
  end

  -- Retrigger the modulation sources (2 LFOs + mod env) on every firing step
  -- where the corresponding reset resolves ON.
  if fires then
    self:call("mod_trig",
      self:reset_active(record, "lfo_reset"),
      self:reset_active(record, "env_reset"))
  end

  if machine == MACHINE_LOOP then
    local record_locks_region = fires and record.param_locks ~= nil
      and (record.param_locks.loop_start ~= nil or record.param_locks.loop_end ~= nil)
    if reset_sequence then
      local start_point, end_point = self:resolve_active_region()
      self:set_region_with_phase(start_point, end_point, 0)
    elseif record_locks_region then
      -- A step that locks start/end repositions the playhead. Trig Jump on =
      -- warp to the region start; off = only reposition if the playhead is now
      -- outside the new region (the wall/street model).
      local start_point, end_point = self:resolve_active_region()
      local pending_anchor = self.seq_anchor == nil and self:make_anchor() or nil
      local interrupted
      if self:trig_jump_active(record) then
        self:set_region_with_phase(start_point, end_point, 0)
        interrupted = true
      else
        interrupted = self:set_region_within_or_warp(start_point, end_point)
      end
      if interrupted then
        if self.seq_anchor == nil then
          self.seq_anchor = pending_anchor
        end
        self.seq_release_mode = self:step_release_mode(record)
      end
    else
      local start_point, end_point = self:resolve_active_region()
      local region_hold = self.param_lock_holds.loop_start ~= nil
        or self.param_lock_holds.loop_end ~= nil
      if self.seq_anchor ~= nil and not region_hold and not any_keys(self:loop_holds()) then
        -- The armed region override is gone -- release per the expiring step's
        -- Trig Release mode instead of a plain set_region.
        self:apply_release_mode(self.seq_release_mode or "return", start_point, end_point, self.seq_anchor)
        self.seq_anchor = nil
      else
        self:set_region(start_point, end_point)
      end
    end
  elseif machine == MACHINE_LOOP_TRIG then
    if fires then
      self:trigger_region(record)
    else
      local start_point, end_point = self:base_region()
      self:set_region(start_point, end_point)
    end
  elseif is_slice_machine(machine) then
    if fires then
      self:trigger_step_slices(record)
    else
      -- Clear the source-page highlight when this step fires no slice, so it does
      -- not stick on the last slice that played (owner). Empty/failed steps read
      -- as "nothing sounding".
      self.active_slices = nil
    end
  end

  -- Ratchets: schedule the extra sub-step hits after the first (PRD §6.5).
  if fires then
    local ratchet = self:effective_ratchet(record)
    if ratchet > 1 then
      self:schedule_ratchets(record, ratchet)
    end
  end
end

-- Per-tick housekeeping: expire this track's note-length lock windows and
-- revert its region/range when one elapses. Runs for EVERY track -- a
-- background track's region locks have to expire on their own exactly like the
-- selected track's.
function TrackSequencer:tick(now)
  local had_region_hold = self.param_lock_holds.loop_start ~= nil
    or self.param_lock_holds.loop_end ~= nil
  if not self:expire_param_lock_holds(now) then
    return
  end
  self:push_param_locks(self:effective_param_locks(nil))
  self:apply_active_range()
  if self:machine() ~= MACHINE_LOOP then
    return
  end
  local region_hold = self.param_lock_holds.loop_start ~= nil
    or self.param_lock_holds.loop_end ~= nil
  local start_point, end_point = self:resolve_active_region()
  if had_region_hold and not region_hold and self.seq_anchor ~= nil
    and not self:live_step_hold() and not any_keys(self:loop_holds()) then
    self:apply_release_mode(self.seq_release_mode or "return", start_point, end_point, self.seq_anchor)
    self.seq_anchor = nil
  else
    self:set_region(start_point, end_point)
    if not region_hold and not self:live_step_hold() and self.seq_anchor ~= nil then
      self.seq_anchor = nil
    end
  end
end

-- Stop: drop every live override so nothing leaks into the next start.
function TrackSequencer:reset_transport()
  self.position = nil
  self.play_index = 1
  self.play_page, self.play_step = TrackSequencer.index_to_page_step(1)
  self.pattern_pass = 1
  self.last_cond_result = nil
  self.seq_anchor = nil
  self.seq_release_mode = nil
  self.ratchet_token = (self.ratchet_token or 0) + 1
end

return TrackSequencer
