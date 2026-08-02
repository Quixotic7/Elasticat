local ParamValues = {}
ParamValues.__index = ParamValues

local TrackSequencer = include("lib/sequencer/track_sequencer")

-- One source of truth for rates (lib/sequencer/track_sequencer.lua).
local PATTERN_RATES = TrackSequencer.RATES

-- Rate labels come from TrackSequencer (shown as fractions, one source).
local rate_label = TrackSequencer.rate_label

-- Region params (loop/range) are the resolver's live-scrub inputs and are
-- p-lockable per STEP only, never per slice (owner: "unlikely I'd want to lock
-- region per slice"). effective_param_locks already drops them from the slice
-- merge; the UI mirrors that, so editing range while holding a SLICE does the
-- normal base edit rather than silently writing a slice lock that never applies.
-- A held STEP still region-locks as before (the signature live-scrub feature).
local SLICE_LOCK_EXCLUDED = {
  loop_start = true, loop_end = true,
  range_start = true, range_end = true
}

local function fmt_round(value)
  return tostring(math.floor((value or 0) + 0.5))
end

local function fmt_1dp(value)
  return string.format("%.1f", value or 0)
end

local function fmt_2dp(value)
  return string.format("%.2f", value or 0)
end

local function fmt_3dp(value)
  return string.format("%.3f", value or 0)
end

local function fmt_0dp(value)
  return string.format("%.0f", value or 0)
end

local function fmt_percent(value)
  return tostring(math.floor(((value or 0) * 100) + 0.5))
end

local function fmt_milli(value)
  return tostring(math.floor(((value or 0) * 1000) + 0.5))
end

local function fmt_2dp_x(value)
  return string.format("%.2fx", value or 0)
end

local function fmt_chop_steps(value)
  local n = value or 0
  if math.abs(n - math.floor(n + 0.5)) < 0.001 then
    return tostring(math.floor(n + 0.5))
  end
  return string.format("%.2f", n)
end

-- Wavetable LFO rate spans 0.001Hz .. 8kHz on an exponential knob, so the readout
-- needs more decimals when tiny (3dp sub-1Hz), fewer as it climbs (owner: fine LFO
-- rates under 1Hz), and a plain integer at audio rates.
local function fmt_lfo_rate(value)
  local n = value or 0
  if n < 1 then return string.format("%.3f", n) end
  if n < 100 then return string.format("%.2f", n) end
  return tostring(math.floor(n + 0.5))
end

-- warp RATE: when the value sits on one of the FN-snap fractions, show the
-- musical ratio ("1/2", "3/4", or "2" for wholes) so a snap is visible; off a
-- ratio, show the raw multiplier ("1.23x"). The clean ratio (no "x") vs the
-- "x"-suffixed float doubles as a "snapped / free" indicator. Fractions ascend,
-- matching source_warp_items' snap list.
local WARP_RATE_FRACTIONS = {
  {1, 16}, {1, 8}, {1, 6}, {1, 4}, {1, 3}, {3, 8}, {1, 2}, {5, 8}, {2, 3},
  {3, 4}, {5, 6}, {7, 8}, {1, 1}, {7, 6}, {5, 4}, {4, 3}, {3, 2}, {5, 3},
  {7, 4}, {11, 6}, {2, 1}, {3, 1}, {4, 1}, {6, 1}, {8, 1}
}
local function fmt_warp_rate(value)
  local v = value or 1
  -- 0.0075 window: a snapped fraction is stored rounded to 0.01, so the error can
  -- be a full 0.005 (7/8 = 0.875 -> 0.88, 5/8 = 0.625 -> 0.63). 0.005 sat exactly
  -- on that boundary and missed them; 0.0075 clears it and stays well under half
  -- the smallest gap between fractions (~0.021), so it never labels the wrong one.
  for _, f in ipairs(WARP_RATE_FRACTIONS) do
    if math.abs(v - (f[1] / f[2])) < 0.0075 then
      return f[2] == 1 and tostring(f[1]) or (f[1] .. "/" .. f[2])
    end
  end
  return string.format("%.2fx", v)
end

-- FX dynamics unit displays (owner: most FX params stay Elektron-style raw 0-127,
-- but the compressor + duck read in dB / ms / ratio where it matters for dialling
-- them in). The value here is the 0-127 knob; these MIRROR the amount->units maps
-- in the SynthDefs (lib/Engine_Elasticat.sc, elasticatFxComp / elasticatFxDuck) --
-- keep the two in sync. LuaJIT is 5.1 (no 2-arg math.log), hence log10().
local function log10(x) return math.log(x) / math.log(10) end
local function fx_linlin(x, imin, imax, omin, omax)
  x = util.clamp(x, imin, imax)
  return omin + (((x - imin) / (imax - imin)) * (omax - omin))
end
local function fx_linexp(x, imin, imax, omin, omax)
  x = util.clamp(x, imin, imax)
  return omin * ((omax / omin) ^ ((x - imin) / (imax - imin)))
end
local function fmt_ms(sec)
  local ms = sec * 1000
  return ms >= 100 and string.format("%.0fms", ms) or string.format("%.1fms", ms)
end
local function fmt_comp_thresh(v) return string.format("%.0fdB", 20 * log10(fx_linlin((v or 0) / 127, 0, 1, 0.02, 1.0))) end
local function fmt_comp_ratio(v) return string.format("%.1f:1", 1 / fx_linexp((v or 0) / 127, 0.001, 1, 1.0, 0.05)) end
local function fmt_comp_attack(v) return fmt_ms(fx_linexp((v or 0) / 127, 0.001, 1, 0.0005, 0.1)) end
local function fmt_comp_release(v) return fmt_ms(fx_linexp((v or 0) / 127, 0.001, 1, 0.02, 0.8)) end
local function fmt_comp_makeup(v) return string.format("+%.1fdB", 20 * log10(fx_linlin((v or 0) / 127, 0, 1, 1.0, 4.0))) end
local function fmt_duck_amount(v)
  local amt = util.clamp((v or 0) / 127, 0, 1)
  return amt >= 0.995 and "MAX" or string.format("%.0fdB", 20 * log10(1 - amt))
end
local function fmt_duck_attack(v) return fmt_ms(fx_linexp((v or 0) / 127, 0, 1, 0.001, 0.05)) end
local function fmt_duck_release(v) return fmt_ms(fx_linexp((v or 0) / 127, 0, 1, 0.05, 1.2)) end
local function fmt_limit_gain(v) return string.format("+%.1fdB", fx_linlin((v or 0) / 127, 0, 1, 0, 18)) end
local function fmt_limit_ceil(v) return string.format("%.1fdB", fx_linlin((v or 0) / 127, 0, 1, -6, 0)) end
local function fmt_limit_release(v) return fmt_ms(fx_linexp((v or 0) / 127, 0, 1, 0.002, 0.1)) end

-- Every simple numeric-display parameter maps its id to a formatter here.
-- Adding a new one is a single line; only params with bespoke display logic
-- (enum remapping, pseudo-items, etc.) need an explicit branch below instead.
local ID_FORMATTERS = {
  sample_slot = fmt_round,
  target_bpm = fmt_round,
  sample_bpm = fmt_round,
  source_bpm = fmt_round,
  sample_steps = fmt_round,
  pattern_steps = fmt_round,
  global_pattern_length = fmt_round,
  slice_count = fmt_round,
  slice_index = fmt_round,
  trig_chance = fmt_round,
  trig_ratchet = fmt_round,
  swing = fmt_round,
  grain_density = fmt_round,
  pitch = fmt_1dp,
  default_length = fmt_2dp,
  default_velocity = fmt_percent,
  loop_start = fmt_0dp,
  loop_end = fmt_0dp,
  range_start = fmt_0dp,
  range_end = fmt_0dp,
  trim_start = fmt_3dp,
  trim_end = fmt_3dp,
  gain = fmt_2dp_x,
  mode_macro = fmt_2dp,
  amp = fmt_2dp,
  pan = fmt_2dp,
  crossfade = fmt_round,
  filter_balance = fmt_round,
  fx_drive = fmt_round,
  fx_mix = fmt_round,
  delay_feedback = fmt_round,
  delay_tone = fmt_round,
  reverb_size = fmt_round,
  reverb_damp = fmt_round,
  lofi_bits = fmt_round,
  lofi_rate = fmt_round,
  -- Send 1/2 + Master insert FX (PRD SS3/SS8) -- same shape as Insert 1 above,
  -- namespaced per slot (delay_time is an options param, not listed here, same
  -- as Insert 1's delay_time).
  send1_level = fmt_round,
  send2_level = fmt_round,
  send1_fx_drive = fmt_round,
  send1_fx_mix = fmt_round,
  send1_delay_feedback = fmt_round,
  send1_delay_tone = fmt_round,
  send1_reverb_size = fmt_round,
  send1_reverb_damp = fmt_round,
  send1_lofi_bits = fmt_round,
  send1_lofi_rate = fmt_round,
  send2_fx_drive = fmt_round,
  send2_fx_mix = fmt_round,
  send2_delay_feedback = fmt_round,
  send2_delay_tone = fmt_round,
  send2_reverb_size = fmt_round,
  send2_reverb_damp = fmt_round,
  send2_lofi_bits = fmt_round,
  send2_lofi_rate = fmt_round,
  master_fx_drive = fmt_round,
  master_fx_mix = fmt_round,
  master_delay_feedback = fmt_round,
  master_delay_tone = fmt_round,
  master_reverb_size = fmt_round,
  master_reverb_damp = fmt_round,
  master_lofi_bits = fmt_round,
  master_lofi_rate = fmt_round,
  slice_rate = fmt_2dp,
  warp_rate = fmt_warp_rate,
  wt_window = fmt_round,
  wt_cycle = fmt_round,
  wt_lfo_rate = fmt_lfo_rate,
  wt_lfo_depth = fmt_round,
  xfade = fmt_milli,
  pv_dispersion = fmt_2dp,
  chop_steps = fmt_chop_steps,
  grain_size = fmt_milli,
  grain_jitter = fmt_milli,
  wsola_window = fmt_milli,
  wsola_search = fmt_milli,
  pv_window = fmt_milli,
  xfade = fmt_milli,
  slice_attack = fmt_milli,
  slice_hold = fmt_milli,
  slice_release = fmt_milli,
  -- FX dynamics: dB / ratio / ms (owner). Everything else in the FX machines
  -- keeps the raw 0-127 (Elektron-style) default -- no entry needed.
  comp_thresh = fmt_comp_thresh,
  comp_ratio = fmt_comp_ratio,
  comp_attack = fmt_comp_attack,
  comp_release = fmt_comp_release,
  comp_makeup = fmt_comp_makeup,
  duck_amount = fmt_duck_amount,
  duck_attack = fmt_duck_attack,
  duck_release = fmt_duck_release,
  limit_gain = fmt_limit_gain,
  limit_ceil = fmt_limit_ceil,
  limit_release = fmt_limit_release
}

function ParamValues.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id,
    show_message = opts.show_message,
    sample_name = opts.sample_name,
    param_value_or = opts.param_value_or,
    get_grid_ui = opts.get_grid_ui,
    get_alt = opts.get_alt,
    -- Razor slice-point editor: Start/End edits delegate here (SNAP mode +
    -- friends coupling live in the coordinator, which owns the razor params).
    razor_edit = opts.razor_edit,
    -- Sample-editor Trim Start/End: FN+knob snap (grid/zoom/zero-x/transient)
    -- delegates to the coordinator, which owns the seconds-domain trim state.
    trim_edit = opts.trim_edit,
    -- FN + PLAY on the razor page selects a chop action (Redistribute/Auto-Chop/
    -- None); the coordinator owns the pending selection and commits on FN release.
    razor_action_select = opts.razor_action_select,
    razor_action_short = opts.razor_action_short,
    get_scene_edit = opts.get_scene_edit,
    get_scene_value = opts.get_scene_value,
    get_select_sample = opts.get_select_sample,
    get_default_trig_length = opts.get_default_trig_length,
    set_default_trig_length = opts.set_default_trig_length,
    get_default_trig_velocity = opts.get_default_trig_velocity,
    set_default_trig_velocity = opts.set_default_trig_velocity,
    set_last_trim_focus = opts.set_last_trim_focus,
    get_sample_duration = opts.get_sample_duration,
    active_step_lock_bases = opts.active_step_lock_bases or {},
    active_step_lock_ids = opts.active_step_lock_ids or {},
    -- Base-value resolver (docs/BASE_VALUE_RESOLVER.md): for a CONTINUOUS base
    -- param, publish/clear a non-destructive step override instead of mutating
    -- the track param. Returns true when it took the param; false (or absent)
    -- means fall back to the destructive params:set path (discrete/option/binary
    -- p-locks, region/range, and track-1 hand-registered params keep it).
    set_base_override = opts.set_base_override,
    value_flash_until = opts.value_flash_until or {},
    value_flash_seconds = opts.value_flash_seconds or 0.85,
    applying_step_locks = false
  }, ParamValues)
end

function ParamValues:option_value(param_id)
  local param = params:lookup_param(self.id(param_id))
  if param == nil or param.options == nil then
    return params:string(self.id(param_id))
  end
  return param.options[param:get()] or params:string(self.id(param_id))
end

function ParamValues:item_locked(param_item)
  if param_item == nil then
    return false
  end
  -- A held A/B scene anchor shows this param's scene lock with the same
  -- visuals as a held step's p-lock (PRD §6.6).
  if self.get_scene_edit ~= nil and self.get_scene_edit() ~= nil
    and self.get_scene_value ~= nil and self.get_scene_value(param_item.id) ~= nil then
    return true
  end
  local grid_ui = self.get_grid_ui()
  if grid_ui == nil or param_item.lockable ~= true then
    return false
  end
  return grid_ui:held_param_lock(param_item.lock_id or param_item.id) ~= nil
end

-- True if ANY step in the pattern p-locks this param (the low-profile corner dot,
-- owner cue). STEP locks only -- scene locks are surfaced by holding the Scene
-- keys, not this marker.
function ParamValues:item_step_locked(param_item)
  if param_item == nil or param_item.blank or param_item.lockable ~= true then
    return false
  end
  local grid_ui = self.get_grid_ui()
  if grid_ui == nil or grid_ui.any_step_locks == nil then
    return false
  end
  return grid_ui:any_step_locks(param_item.lock_id or param_item.id) == true
end

function ParamValues:item_param_id(param_item)
  if param_item == nil or param_item.pseudo ~= nil then
    return nil
  end
  return self.id(param_item.id)
end

function ParamValues:item_long_name(param_item)
  if param_item == nil then
    return ""
  elseif self:showing_slice_count(param_item) then
    return "slice count"
  elseif param_item.pseudo == "pattern_rate" then
    return "pattern rate"
  elseif param_item.pseudo == "step_length" then
    return "trig length"
  elseif param_item.pseudo == "step_velocity" then
    return "velocity"
  elseif param_item.pseudo == "slice_choke" then
    return "choke group"
  elseif param_item.pseudo == "slice_select" then
    return self:showing_slice_count(param_item) and "slice count" or "edit slice"
  elseif param_item.id == "default_length" then
    return "trig length"
  elseif param_item.id == "default_velocity" then
    return "velocity"
  elseif param_item.file then
    return "sample"
  elseif param_item.id == "mode_macro" then
    -- Use the per-engine label (DUTY/MIX/CHAOS/SMEAR) in messages instead of the
    -- generic "mode macro" param name.
    return string.lower(param_item.short or "macro")
  end

  local full_id = self:item_param_id(param_item)
  local param = full_id ~= nil and params:lookup_param(full_id) or nil
  return (param ~= nil and param.name) or param_item.id
end

function ParamValues:item_flash_key(param_item)
  if param_item == nil then
    return nil
  end
  return param_item.lock_id or param_item.id or param_item.pseudo
end

function ParamValues:flash_item_value(param_item)
  local key = self:item_flash_key(param_item)
  if key ~= nil then
    self.value_flash_until[key] = util.time() + self.value_flash_seconds
  end
end

function ParamValues:item_value_flashing(param_item)
  local key = self:item_flash_key(param_item)
  return key ~= nil and (self.value_flash_until[key] or 0) > util.time()
end

-- SLIC (slice_select) is a two-job knob: it selects the edited slice, but FN +
-- turn changes the slice COUNT. While that count edit is fresh AND FN is still
-- held, the cell shows the count (the value being changed) instead of the
-- selected index. Releasing FN reverts instantly.
-- The "SLIC" slice selector on EITHER slice source page: slice_select (pseudo,
-- razor editor) or the real slice_index param (grid slice). FN + its knob edits
-- the slice COUNT on both, so both show the count while that edit is fresh.
local function is_slice_selector(param_item)
  return param_item ~= nil
    and (param_item.pseudo == "slice_select" or param_item.id == "slice_index")
end

function ParamValues:showing_slice_count(param_item)
  return is_slice_selector(param_item)
    and self.get_alt() and (self.slice_count_edit_until or 0) > util.time()
end

function ParamValues:pattern_rate_index()
  local grid_ui = self.get_grid_ui()
  if grid_ui ~= nil and grid_ui.seq ~= nil then
    -- Per-track sequence state (Phase 1): the rate lives on the selected
    -- track's state table (grid_ui.seq), not on the sequencer object.
    return grid_ui.seq.rate_index or TrackSequencer.RATE_UNITY
  end
  return TrackSequencer.RATE_UNITY
end

function ParamValues:item_raw_value(param_item)
  local grid_ui = self.get_grid_ui()
  if param_item == nil then
    return 0
  elseif param_item.blank then
    return 0
  elseif self:showing_slice_count(param_item) then
    -- FN + the SLIC selector (slice_select OR slice_index) shows the slice COUNT
    -- being edited rather than the selected slice, on both slice source pages.
    return math.floor((params:get(self.id("slice_count")) or 1) + 0.5)
  elseif param_item.pseudo == "pattern_rate" then
    return self:pattern_rate_index()
  elseif param_item.pseudo == "step_length" then
    local fallback = self.param_value_or("default_length", self.get_default_trig_length())
    return grid_ui ~= nil and (grid_ui:held_param_lock("length") or fallback) or fallback
  elseif param_item.pseudo == "step_velocity" then
    local fallback = self.param_value_or("default_velocity", self.get_default_trig_velocity())
    return grid_ui ~= nil and (grid_ui:held_param_lock("velocity") or fallback) or fallback
  elseif param_item.pseudo == "slice_choke" then
    -- Per-slice choke group of the held/selected slice (0 = None). Not a param.
    return grid_ui ~= nil and grid_ui.choke_value ~= nil and grid_ui:choke_value() or 0
  elseif param_item.pseudo == "slice_select" then
    -- The Razor editor's selected slice (its Start/End edit target). Not a param.
    -- Under a fresh FN+turn the cell tracks the slice COUNT being edited instead.
    if self:showing_slice_count(param_item) then
      return math.floor((params:get(self.id("slice_count")) or 1) + 0.5)
    end
    return grid_ui ~= nil and grid_ui.get_selected_slice ~= nil and grid_ui:get_selected_slice() or 1
  elseif param_item.file then
    return self.sample_name()
  elseif params:lookup_param(self.id(param_item.id)) ~= nil then
    local lock_id = param_item.lock_id or param_item.id
    -- While a step OR a slice is held, the cell shows that lock's value (the
    -- slice's own identity for a held slice). held_param_lock routes to whichever.
    -- Region params are step-lockable only, so a held slice does not show/edit
    -- them as a slice lock (SLICE_LOCK_EXCLUDED).
    local step_edit = grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() or nil
    local slice_edit = step_edit == nil and grid_ui ~= nil and grid_ui.slice_edit ~= nil
      and not SLICE_LOCK_EXCLUDED[lock_id] and grid_ui:slice_edit() or nil
    if (step_edit ~= nil or slice_edit ~= nil) and param_item.lockable == true then
      local locked = grid_ui:held_param_lock(lock_id)
      if locked ~= nil then
        return locked
      end
    end
    -- Held A/B anchor: show the scene's locked value for this param (the
    -- value an encoder edit would adjust), like a held step's lock.
    if self.get_scene_edit ~= nil and self.get_scene_edit() ~= nil and self.get_scene_value ~= nil then
      local scene_value = self.get_scene_value(param_item.id)
      if scene_value ~= nil then
        return scene_value
      end
    end
    if self.active_step_lock_bases[lock_id] ~= nil then
      return self.active_step_lock_bases[lock_id]
    end
    return params:get(self.id(param_item.id))
  end
  return 0
end

function ParamValues:format_item_value(param_item, value)
  if param_item == nil then
    return ""
  elseif param_item.blank then
    return "---"
  elseif param_item.id == "machine" then
    local param = params:lookup_param(self.id("machine"))
    local options = param ~= nil and param.options or {}
    local machine = options[math.floor((value or self.param_value_or("machine", 1)) + 0.5)] or self:option_value("machine")
    if machine == "loop_trig" then
      return "trig"
    elseif machine == "grid_slice" then
      return "slice"
    elseif machine == "razor_slice" then
      return "razor"
    elseif machine == "slice_poly" then
      return "s.poly"
    elseif machine == "razor_poly" then
      return "r.poly"
    end
    return machine
  elseif param_item.id == "mode" then
    local param = params:lookup_param(self.id("mode"))
    local options = param ~= nil and param.options or {}
    local mode = options[math.floor((value or self.param_value_or("mode", 1)) + 0.5)] or self:option_value("mode")
    if mode == "tempo_varispeed" then
      return "tempo"
    elseif mode == "granular" then
      return "GText"
    elseif mode == "pitch_corrected" then
      return "pc"
    elseif mode == "random_ola" then
      return "ola"
    elseif mode == "gstretch" then
      return "GStrch"
    elseif mode == "gstretch2" then
      return "GStr2"
    end
    return mode
  elseif param_item.pseudo == "pattern_rate" then
    return rate_label(math.floor((value or self:pattern_rate_index()) + 0.5))
  elseif param_item.pseudo == "step_length" then
    return string.format("%.2f", value or self:item_raw_value(param_item))
  elseif param_item.pseudo == "step_velocity" then
    return tostring(math.floor(((value or self:item_raw_value(param_item)) * 100) + 0.5))
  elseif param_item.pseudo == "slice_choke" then
    local group = math.floor((value or self:item_raw_value(param_item)) + 0.5)
    return group <= 0 and "None" or tostring(group)
  elseif param_item.pseudo == "slice_select" then
    return tostring(math.floor((value or self:item_raw_value(param_item)) + 0.5))
  elseif param_item.file then
    return self.sample_name()
  elseif param_item.binary then
    return (value or 0) >= 1 and "on" or "off"
  elseif (param_item.id == "env_hold" or param_item.id == "env_release")
    and (value or self:item_raw_value(param_item)) >= 128 then
    return "INF"
  elseif param_item.id == "trig_release" then
    -- "boomerang" overflows a cell; compact forms for the machine-trig page.
    local names = {"rtrn", "boom", "rset"}
    local raw = math.floor((value or self.param_value_or(param_item.id, 1)) + 0.5)
    return names[raw] or names[1]
  elseif param_item.id == "slice_play_mode" then
    local param = params:lookup_param(self.id(param_item.id))
    local options = param ~= nil and param.options or {}
    local mode = options[math.floor((value or self.param_value_or(param_item.id, 1)) + 0.5)] or self:option_value(param_item.id)
    if mode == "1 shot" then
      return "shot"
    elseif mode == "1 shot hold" then
      return "hold"
    end
    return mode
  elseif param_item.id == "chop_loop_mode" then
    local param = params:lookup_param(self.id(param_item.id))
    local options = param ~= nil and param.options or {}
    local mode = options[math.floor((value or self.param_value_or(param_item.id, 1)) + 0.5)] or self:option_value(param_item.id)
    if mode == "forward stop" then
      return "stop"
    elseif mode == "loop forward" then
      return "loop"
    elseif mode == "ping pong" then
      return "pong"
    end
    return mode
  elseif param_item.options ~= nil then
    local param = params:lookup_param(self.id(param_item.id))
    if param ~= nil and param.options ~= nil then
      return param.options[math.floor((value or params:get(self.id(param_item.id))) + 0.5)] or params:string(self.id(param_item.id))
    end
    return tostring(value or "")
  end

  local formatter = ID_FORMATTERS[param_item.id]
  if formatter == nil then
    -- Send/Master slot params are the insert params namespaced send1_/send2_/
    -- master_; strip the slot prefix so the dB/ms dynamics formatters (comp/duck/
    -- limit) apply on the send + master FX pages too.
    formatter = ID_FORMATTERS[param_item.id:gsub("^send1_", ""):gsub("^send2_", ""):gsub("^master_", "")]
  end
  if formatter ~= nil then
    return formatter(value)
  end

  return tostring(value or "")
end

function ParamValues:item_display_value(param_item)
  if param_item ~= nil and param_item.file then
    return self.sample_name()
  end
  -- PLAY cell shows the chop action being selected (FN + turn) instead of the
  -- play mode, on the razor page.
  if param_item ~= nil and param_item.id == "slice_play_mode"
    and self.razor_action_short ~= nil then
    local ra = self.razor_action_short()
    if ra ~= nil then
      return ra
    end
  end
  local value = self:item_raw_value(param_item)
  return self:format_item_value(param_item, value)
end

function ParamValues:snap_value(param_item, current, delta)
  local snaps = param_item.snaps
  if snaps == nil or #snaps == 0 then
    return current
  end

  -- Escape tolerance: how far past `current` a snap must sit to count as the
  -- "next" one. It must exceed the param's storage quantization, or a snap value
  -- that was stored rounded (e.g. 7/6 = 1.16667 stored as 1.17) strands the
  -- ladder -- snapping DOWN from 1.17 would find 7/6 again and never reach 1.0.
  -- snap_tolerance opts into a wider window; keep it < half the smallest gap
  -- between adjacent snaps so it never skips a value. Default stays hair-thin.
  local tol = param_item.snap_tolerance or 0.0001

  if delta >= 0 then
    for _, value in ipairs(snaps) do
      if value > current + tol then
        return value
      end
    end
    return snaps[#snaps]
  end

  for i = #snaps, 1, -1 do
    if snaps[i] < current - tol then
      return snaps[i]
    end
  end
  return snaps[1]
end

-- Snap to the next multiple of `mult` strictly past `current`, in the direction
-- of `delta`. Used by Range's FN behavior (multiples of 8).
function ParamValues:snap_to_multiple(param_item, current, delta, mult)
  local snapped
  if delta >= 0 then
    snapped = (math.floor(current / mult + 1e-6) + 1) * mult
  else
    snapped = (math.ceil(current / mult - 1e-6) - 1) * mult
  end
  return util.clamp(snapped, param_item.min or 0, param_item.max or (current + snapped))
end

function ParamValues:adjusted_value(param_item, current, delta, snap)
  if param_item.options ~= nil then
    return util.clamp(math.floor(current + (delta >= 0 and 1 or -1)), 1, param_item.options)
  end

  -- FN held (snap == fn_active): default is snap-to-useful-values. Trim scans
  -- drop to a fine step instead (they get a zoomed view for precision), and
  -- Range snaps to fixed multiples.
  if snap then
    if param_item.trim_scan or param_item.fn_fine then
      -- FN uses fine_step instead of snapping (trim scan = finer; chop steps =
      -- coarser 0.25 vs the normal 0.05).
      local step = param_item.fine_step or param_item.step or 1
      return util.clamp(current + (delta * step), param_item.min or current, param_item.max or current)
    elseif param_item.fn_snap_multiple ~= nil then
      return self:snap_to_multiple(param_item, current, delta, param_item.fn_snap_multiple)
    elseif param_item.snaps ~= nil and #param_item.snaps > 0 then
      return self:snap_value(param_item, current, delta)
    end
    local step = param_item.fine_step or param_item.step or 1
    return util.clamp(current + (delta * step), param_item.min or current, param_item.max or current)
  end

  -- FN not held: normal increments. Trim scans one ~1/128-of-sample detent so
  -- scrubbing a long file feels like the 0-128 sample views.
  local step
  if param_item.trim_scan and self.get_sample_duration ~= nil then
    local duration = self.get_sample_duration() or 0
    step = duration > 0 and (duration / 128) or (param_item.step or 1)
  else
    step = param_item.step or 1
    -- Exponential knob granularity: the step GROWS along an exponential curve with
    -- the value -- fine near 0, coarser toward the top, capped -- so one control
    -- covers sub-audio LFO rates AND audio rates on a smooth curve (no hard step
    -- boundaries). exp_step = {min, max, tau}: step = min * e^(|value|/tau), <= max.
    -- (owner: wavetable LFO rate feels like ~0.5 / 1 / 8.)
    local es = param_item.exp_step
    if es ~= nil then
      step = math.min(es.max, es.min * math.exp(math.abs(current) / es.tau))
    end
  end
  return util.clamp(current + (delta * step), param_item.min or current, param_item.max or current)
end

function ParamValues:apply_item_value(param_item, value)
  local grid_ui = self.get_grid_ui()
  if param_item == nil then
    return
  elseif param_item.file then
    local select_sample = self.get_select_sample()
    if select_sample ~= nil then
      select_sample()
    end
  elseif param_item.pseudo == "pattern_rate" then
    if grid_ui ~= nil and grid_ui.seq ~= nil then
      -- Per-track sequence state (Phase 1): write the selected track's rate.
      grid_ui.seq.rate_index = util.clamp(math.floor(value + 0.5), 1, #PATTERN_RATES)
      self.show_message("Pattern Rate " .. rate_label(grid_ui.seq.rate_index))
    end
  elseif param_item.pseudo == "step_length" then
    local next_length = util.clamp(value, param_item.min or 0.25, param_item.max or 16)
    self.set_default_trig_length(next_length)
    if params:lookup_param(self.id("default_length")) ~= nil then
      params:set(self.id("default_length"), next_length, true)
    end
  elseif param_item.pseudo == "step_velocity" then
    local next_velocity = util.clamp(value, param_item.min or 0, param_item.max or 1)
    self.set_default_trig_velocity(next_velocity)
    if params:lookup_param(self.id("default_velocity")) ~= nil then
      params:set(self.id("default_velocity"), next_velocity, true)
    end
  elseif param_item.pseudo == "slice_choke" then
    -- Per-slice choke group: write the held/selected slice(s). Not a param.
    if grid_ui ~= nil and grid_ui.set_choke_value ~= nil then
      grid_ui:set_choke_value(util.clamp(math.floor(value + 0.5), param_item.min or 0, param_item.max or 8))
    end
  elseif param_item.pseudo == "slice_select" then
    -- Move the Razor editor's selected slice. Not a param.
    if grid_ui ~= nil and grid_ui.set_selected_slice ~= nil then
      grid_ui:set_selected_slice(value)
    end
  elseif params:lookup_param(self.id(param_item.id)) ~= nil then
    params:set(self.id(param_item.id), value)
  end
end

function ParamValues:apply_param_lock_value(lock_id, value)
  -- These locks are layered by GridSequencer, not written to their track-base
  -- param: loop_start/loop_end feed the active-region resolve; range_start/
  -- range_end feed the active-range override (map_trim_point). Writing them here
  -- would corrupt the Track values the page shows and make them jump around as
  -- steps trigger. length/velocity are consumed at trigger time, not as params.
  if lock_id == "length" or lock_id == "velocity"
    or lock_id == "loop_start" or lock_id == "loop_end"
    or lock_id == "range_start" or lock_id == "range_end"
    or lock_id == "env_reset" or lock_id == "lfo_reset" or lock_id == "filter_reset"
    or lock_id == "trig_jump" or lock_id == "trig_release" then
    return
  end
  local full_id = self.id(lock_id)
  if params:lookup_param(full_id) ~= nil then
    params:set(full_id, value)
  end
end

function ParamValues:apply_step_param_locks(locks)
  locks = locks or {}
  self.applying_step_locks = true

  local override = self.set_base_override

  for lock_id, _ in pairs(self.active_step_lock_ids) do
    if locks[lock_id] == nil then
      -- Continuous base param: clear its non-destructive override. Only if the
      -- resolver did NOT own it do we restore a snapshotted base (the
      -- destructive path discrete/region p-locks still use). A base is never
      -- snapshotted for an override param, so this branch never runs for one.
      if not (override ~= nil and override(lock_id, nil)) then
        local base = self.active_step_lock_bases[lock_id]
        if base ~= nil then
          self:apply_param_lock_value(lock_id, base)
        end
      end
      self.active_step_lock_ids[lock_id] = nil
      self.active_step_lock_bases[lock_id] = nil
    end
  end

  for lock_id, value in pairs(locks) do
    -- Publish the override first; only fall back to the destructive snapshot +
    -- params:set when the resolver declines (returns false / not wired).
    if override == nil or not override(lock_id, value) then
      if self.active_step_lock_bases[lock_id] == nil and params:lookup_param(self.id(lock_id)) ~= nil then
        self.active_step_lock_bases[lock_id] = params:get(self.id(lock_id))
      end
      self:apply_param_lock_value(lock_id, value)
    end
    self.active_step_lock_ids[lock_id] = true
  end
  self.applying_step_locks = false
end

function ParamValues:delta_item(param_item, delta)
  local grid_ui = self.get_grid_ui()
  if param_item == nil or param_item.blank then
    return
  end

  if param_item.file then
    self:apply_item_value(param_item, 0)
    return
  end

  -- Razor slice-point editor (source page 1): Start/End own their edit path so
  -- the coordinator can apply the SNAP mode (grid/zoom/zero-x/transient/friends)
  -- and the friends neighbour coupling. Never p-lockable, so this precedes the
  -- lock routing entirely.
  if param_item.razor_point ~= nil and self.razor_edit ~= nil then
    self.razor_edit(param_item.razor_slice, param_item.razor_point, delta, self.get_alt())
    -- razor_edit already set the param; mirror the generic path's feedback so the
    -- value still flashes/prints (it stopped showing once these bypassed below).
    self:flash_item_value(param_item)
    if self.show_message ~= nil then
      self.show_message(self:item_long_name(param_item) .. " " .. self:item_display_value(param_item))
    end
    return
  end

  -- FN + PLAY on the razor page selects a chop action instead of the play mode
  -- (razor machines only; the coordinator gates + commits on FN release). Falls
  -- through to a normal play-mode edit on grid slice / when razor_action_select
  -- declines.
  if param_item.id == "slice_play_mode" and self.get_alt()
    and self.razor_action_select ~= nil and self.razor_action_select(delta) then
    self:flash_item_value(param_item)
    return
  end

  -- Sample-editor Trim Start/End: same pattern -- FN+knob applies the trim SNAP
  -- mode (grid/zoom/zero-x/transient) via the coordinator's seconds-domain edit.
  if param_item.trim_point ~= nil and self.trim_edit ~= nil then
    -- Track which edge was last touched so the waveform zooms around it (the
    -- razor path sets this via the generic branch; trim bypasses that).
    if self.set_last_trim_focus ~= nil then
      self.set_last_trim_focus(param_item.id)
    end
    self.trim_edit(param_item.trim_point, delta, self.get_alt())
    self:flash_item_value(param_item)
    if self.show_message ~= nil then
      self.show_message(self:item_long_name(param_item) .. " " .. self:item_display_value(param_item))
    end
    return
  end

  -- SLIC selects the edited slice (slice_select on razor, slice_index on grid
  -- slice); FN + the knob instead changes the slice COUNT (owner). One knob, two
  -- jobs, gated on FN -- on BOTH slice source pages.
  if is_slice_selector(param_item) and self.get_alt() then
    local cid = self.id("slice_count")
    if params:lookup_param(cid) ~= nil then
      local nxt = util.clamp(math.floor((params:get(cid) or 1) + (delta >= 0 and 1 or -1) + 0.5), 1, 32)
      params:set(cid, nxt)
      self:flash_item_value(param_item)
      -- While actively turning under FN, the SLIC cell shows the slice COUNT (the
      -- value being edited) rather than the selected slice index. Each detent
      -- refreshes the window; it reverts to the index shortly after you stop, or
      -- immediately when FN releases (showing_slice_count gates on get_alt).
      self.slice_count_edit_until = util.time() + self.value_flash_seconds
      if self.show_message ~= nil then
        self.show_message("Slice count " .. nxt)
      end
    end
    return
  end

  local lock_id = param_item.lock_id or param_item.id

  -- Slow-option items (e.g. chop LOOP mode) need several detents to advance one
  -- option, so a small nudge doesn't flip them. Accumulate raw delta and only
  -- act once it crosses the threshold.
  if param_item.options ~= nil and param_item.slow_option then
    self.option_accum = self.option_accum or {}
    local acc = (self.option_accum[lock_id] or 0) + delta
    if math.abs(acc) < (param_item.slow_option == true and 3 or param_item.slow_option) then
      self.option_accum[lock_id] = acc
      return
    end
    self.option_accum[lock_id] = 0
    delta = acc
  end

  -- P-lock target: a held STEP, or (none held) a held SLICE -- its own identity
  -- (MPC chop program). held_param_lock / set_held_param_lock route to whichever
  -- is active, so the edit lands on the step or the slice. Region params are
  -- step-lockable only: while holding a slice they fall through to a normal base
  -- edit (SLICE_LOCK_EXCLUDED), never a per-slice lock.
  local step_edit = grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() or nil
  local slice_edit = step_edit == nil and grid_ui ~= nil and grid_ui.slice_edit ~= nil
    and not SLICE_LOCK_EXCLUDED[lock_id] and grid_ui:slice_edit() or nil
  local locking = (step_edit ~= nil or slice_edit ~= nil) and param_item.lockable == true
  local current = locking and (grid_ui:held_param_lock(lock_id) or self:item_raw_value(param_item)) or self:item_raw_value(param_item)
  local next_value = self:adjusted_value(param_item, current, delta, self.get_alt())

  if param_item.id == "trim_start" or param_item.id == "trim_end"
    or param_item.id == "range_start" or param_item.id == "range_end" then
    -- Tracks which trim/range endpoint was last touched so the waveform page
    -- can zoom around it under FN. One tracker serves both pairs; each page
    -- reads only its own ids.
    self.set_last_trim_focus(param_item.id)
  end

  if locking then
    if lock_id == "range_start" and self.param_value_or("range_end_sync", 1) == 1 then
      -- E-SNC: range start/end lock as a rigid pair -- clamped shared delta so
      -- the gap never collapses at 0/128 (matches the live encoder link).
      local base_end = grid_ui:held_param_lock("range_end") or self.param_value_or("range_end", 128)
      local delta = util.clamp(next_value - current, -current, 128 - base_end)
      grid_ui:set_held_param_lock("range_start", current + delta)
      grid_ui:set_held_param_lock("range_end", base_end + delta)
    elseif lock_id == "range_start" then
      -- Independent: the locked start can't reach the locked (or track) end.
      local end_ref = grid_ui:held_param_lock("range_end") or self.param_value_or("range_end", 128)
      grid_ui:set_held_param_lock(lock_id, util.clamp(next_value, 0, math.max(0, end_ref - 1)))
    elseif lock_id == "range_end" then
      local start_ref = grid_ui:held_param_lock("range_start") or self.param_value_or("range_start", 0)
      grid_ui:set_held_param_lock(lock_id, util.clamp(next_value, math.min(128, start_ref + 1), 128))
    elseif lock_id == "loop_start" then
      -- Track start/end get the same mutual clamp as range: the locked start can
      -- never reach the locked (or track) end, so a step P-lock can't put start
      -- past end (owner: "should not be able to move start beyond the end").
      local end_ref = grid_ui:held_param_lock("loop_end") or self.param_value_or("loop_end", 128)
      grid_ui:set_held_param_lock(lock_id, util.clamp(next_value, 0, math.max(0, end_ref - 1)))
    elseif lock_id == "loop_end" then
      local start_ref = grid_ui:held_param_lock("loop_start") or self.param_value_or("loop_start", 0)
      grid_ui:set_held_param_lock(lock_id, util.clamp(next_value, math.min(128, start_ref + 1), 128))
    else
      grid_ui:set_held_param_lock(lock_id, next_value)
    end
    self:flash_item_value(param_item)
    self.show_message(self:item_long_name(param_item) .. " lock " .. self:format_item_value(param_item, next_value))
  else
    -- Track knob: same start<end clamp as the step p-lock above, so turning the
    -- Sample Start knob can never drag it past Sample End (and vice versa).
    if lock_id == "loop_start" then
      next_value = util.clamp(next_value, 0, math.max(0, self.param_value_or("loop_end", 128) - 1))
    elseif lock_id == "loop_end" then
      next_value = util.clamp(next_value, math.min(128, self.param_value_or("loop_start", 0) + 1), 128)
    end
    self:apply_item_value(param_item, next_value)
    self:flash_item_value(param_item)
    self.show_message(self:item_long_name(param_item) .. " " .. self:item_display_value(param_item))
  end
end

return ParamValues
