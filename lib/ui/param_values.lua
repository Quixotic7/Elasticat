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
  slice_release = fmt_milli
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
  elseif param_item.pseudo == "pattern_rate" then
    return "pattern rate"
  elseif param_item.pseudo == "step_length" then
    return "trig length"
  elseif param_item.pseudo == "step_velocity" then
    return "velocity"
  elseif param_item.pseudo == "slice_choke" then
    return "choke group"
  elseif param_item.pseudo == "slice_select" then
    return "edit slice"
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
  elseif param_item.id == "playhead_return" then
    return "ph mode"  -- short so "playhead return <value>" doesn't get cut off
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
      return "grain"
    elseif mode == "pitch_corrected" then
      return "pc"
    elseif mode == "random_ola" then
      return "ola"
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
  if formatter ~= nil then
    return formatter(value)
  end

  return tostring(value or "")
end

function ParamValues:item_display_value(param_item)
  if param_item ~= nil and param_item.file then
    return self.sample_name()
  end
  local value = self:item_raw_value(param_item)
  return self:format_item_value(param_item, value)
end

function ParamValues:snap_value(param_item, current, delta)
  local snaps = param_item.snaps
  if snaps == nil or #snaps == 0 then
    return current
  end

  if delta >= 0 then
    for _, value in ipairs(snaps) do
      if value > current + 0.0001 then
        return value
      end
    end
    return snaps[#snaps]
  end

  for i = #snaps, 1, -1 do
    if snaps[i] < current - 0.0001 then
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
    else
      grid_ui:set_held_param_lock(lock_id, next_value)
    end
    self:flash_item_value(param_item)
    self.show_message(self:item_long_name(param_item) .. " lock " .. self:format_item_value(param_item, next_value))
  else
    self:apply_item_value(param_item, next_value)
    self:flash_item_value(param_item)
    self.show_message(self:item_long_name(param_item) .. " " .. self:item_display_value(param_item))
  end
end

return ParamValues
