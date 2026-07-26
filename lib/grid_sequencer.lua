local GridSequencer = {}
GridSequencer.__index = GridSequencer

local Step = include("lib/sequencer/step")
local TrigConditions = include("lib/sequencer/trig_conditions")  -- PRD §6.5
local INTRO_CAT_HEX = include("lib/intro_cat_frames")  -- 55 frames of 16x8 grid levels

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
-- values only in the Actual layer while its window is active. These ids are
-- therefore excluded from the effective_param_locks table handed to
-- apply_step_param_locks -- otherwise they'd be stashed in the
-- active_step_lock_bases bookkeeping, freezing the Track params' display and
-- eating encoder edits during playback (every loop-machine trig locks
-- loop_start, so the Track region was un-editable whenever trigs played).
local REGION_LOCKS = {
  loop_start = true,
  loop_end = true,
  range_start = true,
  range_end = true
}
local INTRO_CAT_FPS = 10  -- must match the screen logo fps so the two stay in sync

-- Decode the hex frame table into numeric levels once (INTRO_CAT[frame][row][col]).
local INTRO_CAT = {}
for f = 1, #INTRO_CAT_HEX do
  local rows = {}
  for row = 1, 8 do
    local cols = {}
    local hex = INTRO_CAT_HEX[f][row]
    for x = 1, 16 do
      cols[x] = tonumber(string.sub(hex, x, x), 16) or 0
    end
    rows[row] = cols
  end
  INTRO_CAT[f] = rows
end

local PAGE_MODES = {"select", "loop", "rate"}
local PAGE_MODE_LABELS = {
  select = "Page Select",
  loop = "Page Loop",
  rate = "Pattern Rate"
}
local RATES = {0.125, 0.25, 0.5, 1, 2, 4, 8, 16}
local STEP_HOLD_SECONDS = 0.25
-- Pattern-load key (8,5) tap-vs-hold threshold: a press+release shorter than
-- this with no slot picked latches the overlay open; anything longer (or a
-- slot pick) is the old momentary-hold behaviour. Mirrors STEP_HOLD_SECONDS'
-- role for the step row.
local PATTERN_TAP_SECONDS = 0.25
local MACHINE_LOOP = 1
local MACHINE_LOOP_TRIG = 2
local MACHINE_GRID_SLICE = 3
local MACHINE_RAZOR_SLICE = 4
local WHITE_KEYS = {[1] = 0, [2] = 2, [3] = 4, [4] = 5, [5] = 7, [6] = 9, [7] = 11, [8] = 12}
local BLACK_KEYS = {[2] = 1, [3] = 3, [5] = 6, [6] = 8, [7] = 10}
local CATEGORY_KEYS = {
  [7] = "master",
  [8] = "file",
  [9] = "pattern",
  [11] = "trig",
  [12] = "source",
  [13] = "filter",
  [14] = "amp",
  [15] = "fx",
  [16] = "mod"
}

local function any_keys(t)
  for _, held in pairs(t) do
    if held then
      return true
    end
  end
  return false
end

local function sorted_held_keys(t)
  local keys = {}
  for x, held in pairs(t) do
    if held then
      table.insert(keys, x)
    end
  end
  table.sort(keys)
  return keys
end

local function table_count(t)
  local count = 0
  for _, value in pairs(t or {}) do
    if value then
      count = count + 1
    end
  end
  return count
end

-- Recursive value copy for pattern snapshots: a captured pattern must not alias
-- the live steps (later edits would mutate the stored snapshot, and vice versa).
-- Only plain data tables (steps, param_locks, slices) pass through here.
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

local function rate_label(rate)
  if rate < 1 then
    return string.format("%.3gx", rate)
  end
  return string.format("%gx", rate)
end

local function format_region(start_point, end_point)
  if end_point == nil then
    return string.format("st %03.0f", start_point)
  end
  return string.format("st %03.0f end %03.0f", start_point, end_point)
end

local function is_slice_machine(machine)
  return machine == MACHINE_GRID_SLICE or machine == MACHINE_RAZOR_SLICE
end

-- ---- Phase 1 track scaffolding (docs/PHASE1_CONTRACT.md) -------------------
-- Per-track sequence state: the fields that used to live directly on self
-- (steps, page_loop, rate_index, play position, condition-pass bookkeeping,
-- step timing) become one table per track in self.tracks[1..8]. self.track is
-- the selected track and self.seq is a direct reference to its state table --
-- every existing code path reads/writes "the selected track" through self.seq,
-- so the step/lock logic is not forked per track. During playback ALL tracks
-- up to active_track_count advance, each with its own pattern position/rate
-- (see tick_background_tracks); only the selected track is edited/displayed.
local TRACK_COUNT_MAX = 8

local function blank_track_state()
  return {
    steps = {},
    page_loop = {[1] = true},
    rate_index = 4,
    play_index = 1,
    play_page = 1,
    play_step = 1,
    -- Trig conditions / Fill (PRD §6.5), per track: pattern_pass counts THIS
    -- track's sequence loops; last_cond_result feeds its PRE/!PRE chain.
    pattern_pass = 1,
    last_cond_result = nil,
    -- Step timing, per track (each track has its own rate).
    next_step_time = nil,
    remaining_time = nil
  }
end

-- One track's pattern-owned state -> a plain deep-copied snapshot table (the
-- exact shape the old single-track serialize() produced).
local function serialize_track(state)
  local steps = {}
  for index, record in pairs(state.steps) do
    if Step.has_content(record) then
      steps[index] = deep_copy(record)
    end
  end
  local page_loop = {}
  for page, on in pairs(state.page_loop) do
    if on then
      page_loop[page] = true
    end
  end
  return {
    steps = steps,
    rate_index = state.rate_index,
    page_loop = page_loop
  }
end

-- Restore one track's pattern-owned state from a snapshot (or nil -> blank).
-- Transport-owned fields (play position, pass counters, timing) are NOT part
-- of a pattern snapshot; the caller preserves or resets them.
local function deserialize_track(snapshot)
  local state = blank_track_state()
  snapshot = snapshot or {}
  for index, record in pairs(snapshot.steps or {}) do
    state.steps[index] = deep_copy(record)
  end
  state.rate_index = snapshot.rate_index or 4
  state.page_loop = {}
  for page, on in pairs(snapshot.page_loop or {}) do
    if on then
      state.page_loop[page] = true
    end
  end
  if next(state.page_loop) == nil then
    state.page_loop[1] = true
  end
  return state
end

function GridSequencer.new(options)
  local self = setmetatable({}, GridSequencer)
  self.options = options or {}
  self.g = grid.connect()
  -- Per-track sequence state (Phase 1 track scaffolding): self.seq aliases the
  -- selected track's table, so with track 1 selected (the default) everything
  -- below behaves exactly as the old single-track fields did.
  self.tracks = {}
  for track = 1, TRACK_COUNT_MAX do
    self.tracks[track] = blank_track_state()
  end
  self.track = 1
  self.seq = self.tracks[1]
  self.page_mode = "select"
  self.selected_page = 1
  self.playing = false
  self.recording = false
  self.fn_down = false
  self.page_down = false
  self.keyboard_octave = 0
  self.pressed = {}
  self.loop_holds = {}
  self.loop_tap_key = nil
  self.loop_tap_kind = nil
  self.slice_holds = {}
  self.preview_active = false
  self.step_holds = {}
  self.step_press_time = {}
  self.step_edited = {}
  -- steps/page_loop/rate_index and the step timing live in self.seq (per track).
  self.manual_region = nil
  self.seq_metro = nil
  self.param_lock_holds = {}
  self.current_region_start = nil
  self.current_region_end = nil
  self.current_range_start = nil
  self.current_range_end = nil
  -- Fill (PRD §6.5) is a live performance gesture, shared across tracks; the
  -- per-track pattern_pass/last_cond_result live in self.seq.
  self.fill_active = false
  self.fill_latched = false
  self.fill_held = false
  self.ratchet_token = 0
  -- Pattern system (PRD §6): global_pos tracks the project-wide pattern cycle
  -- (which may differ from the per-track length under polymeter); pattern_mode
  -- is the grid pattern-load overlay. pattern_latched/pattern_press_time/
  -- pattern_selection_made implement the tap-latches / hold-is-momentary
  -- distinction on the (8,5) key -- see key_pattern()/key_pattern_mode().
  self.global_pos = 1
  self.pattern_mode = false
  self.pattern_latched = false
  self.pattern_press_time = nil
  self.pattern_selection_made = false
  self.crossfade = 0  -- A/B crossfader position (0 = A, 1 = B), PRD §6.6
  -- Copy/Clear/Paste buffers, one per scope (steps / page / pattern) so
  -- copying at one scope never clobbers another (Tonverk §6.6).
  self.clipboard = {steps = nil, page = nil, pattern = nil}
  self.macro_hold = nil  -- which macro key (1-4) is held; routes E2/E3 to it
  self.stop_held = false -- STOP held = CUT/PASTE modifier (see cut_paste_step)
  self.stop_used = false -- ... and whether this hold shuffled any steps
  self.cut_buffer = nil  -- the step content cut out, waiting to be pasted
  self.scene_glide_target = nil  -- fader-key glide target (0..1) while held
  self.scene_glide_metro = nil   -- reused metro that eases toward it while held
  self.g.key = function(x, y, z) self:key(x, y, z) end
  return self
end

function GridSequencer:cleanup()
  self.playing = false
  self:stop_scene_glide()
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
    self.seq_metro = nil
  end
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
  end
  if self.g ~= nil then
    self.g:all(0)
    self.g:refresh()
    self.g.key = nil
  end
end

function GridSequencer:message(text)
  if self.options.show_message ~= nil then
    self.options.show_message(text)
  end
end

function GridSequencer:request_redraw()
  if self.options.request_redraw ~= nil then
    self.options.request_redraw()
  end
end

function GridSequencer:machine()
  if self.options.get_machine ~= nil then
    return util.clamp(math.floor((self.options.get_machine() or 1) + 0.5), 1, 4)
  end
  return MACHINE_LOOP
end

function GridSequencer:pattern_steps()
  if self.options.get_pattern_steps ~= nil then
    return util.clamp(math.floor((self.options.get_pattern_steps() or 64) + 0.5), 1, 256)
  end
  return 64
end

function GridSequencer:pattern_pages()
  return util.clamp(math.ceil(self:pattern_steps() / 16), 1, 16)
end

-- Global (project-wide) pattern length: the cycle on which sequential pattern
-- switches engage and temp-jumps return (PRD §6.4). Falls back to the per-track
-- length when no distinct global length is configured.
function GridSequencer:global_length()
  if self.options.get_global_length ~= nil then
    local raw = self.options.get_global_length()
    if raw ~= nil and raw >= 1 then
      return util.clamp(math.floor(raw + 0.5), 1, 256)
    end
  end
  return self:pattern_steps()
end

function GridSequencer:loop_division()
  local raw = self.options.get_loop_division ~= nil and self.options.get_loop_division() or 16
  local division = util.clamp(math.floor(((tonumber(raw) or 16) / 2) + 0.5) * 2, 2, 32)
  return division
end

function GridSequencer:loop_units_per_key()
  return 128 / self:loop_division()
end

-- Loop keys are addressed as one combined 1-32 range: 1-16 is row 2, 17-32
-- overflows onto row 3 when the division is set above 16.
function GridSequencer:loop_key_position(key_index)
  if key_index <= 16 then
    return key_index, 2
  end
  return key_index - 16, 3
end

function GridSequencer:trig_polyphony()
  if self.options.get_trig_polyphony ~= nil then
    return util.clamp(math.floor((self.options.get_trig_polyphony() or 1) + 0.5), 1, 2)
  end
  return 1
end

function GridSequencer:slice_count()
  if self.options.get_slice_count ~= nil then
    return util.clamp(math.floor((self.options.get_slice_count() or 16) + 0.5), 1, 32)
  end
  return 16
end

function GridSequencer:slice_index()
  if self.options.get_slice_index ~= nil then
    return util.clamp(math.floor((self.options.get_slice_index() or 1) + 0.5), 1, self:slice_count())
  end
  return 1
end

function GridSequencer:base_region()
  if self.options.base_region ~= nil then
    return self.options.base_region()
  end
  return 0, 128
end

function GridSequencer:base_pitch()
  if self.options.base_pitch ~= nil then
    return self.options.base_pitch() or 0
  end
  return 0
end

function GridSequencer:default_velocity()
  if self.options.get_default_velocity ~= nil then
    return self.options.get_default_velocity() or 1
  end
  return 1
end

function GridSequencer:default_length()
  if self.options.get_default_length ~= nil then
    return self.options.get_default_length() or 1
  end
  return 1
end

function GridSequencer:step_index(page, step)
  return ((page - 1) * 16) + step
end

function GridSequencer:index_to_page_step(index)
  local page = math.floor((index - 1) / 16) + 1
  local step = ((index - 1) % 16) + 1
  return page, step
end

function GridSequencer:sync_play_page_step()
  self.seq.play_page, self.seq.play_step = self:index_to_page_step(self.seq.play_index)
end

function GridSequencer:step_record(index, create)
  if self.seq.steps[index] == nil and create then
    self.seq.steps[index] = Step.new()
  end
  return self.seq.steps[index]
end

function GridSequencer:step_record_for_page_step(page, step, create)
  return self:step_record(self:step_index(page, step), create)
end

function GridSequencer:first_held_step()
  for step = 1, 16 do
    if self.step_holds[step] then
      return step
    end
  end
  return nil
end

function GridSequencer:pattern_has_trigs()
  for _, record in pairs(self.seq.steps) do
    if record ~= nil and record.trig == true then
      return true
    end
  end
  return false
end

-- Snapshot the sequencer's per-pattern state to a plain, deep-copied table
-- (PRD §6.1). Track params (pattern_steps, machine, filter, ...) live in the
-- norns params system and are captured by the coordinator; this covers only the
-- state the sequencer itself owns: the step records, the pattern rate, and which
-- pages loop -- now for EVERY track (contract: pattern slots capture/apply ALL
-- tracks' sequences). The top-level steps/rate_index/page_loop mirror track 1
-- so a pre-multitrack script reading a new snapshot still gets track 1.
function GridSequencer:serialize()
  local tracks = {}
  for track = 1, TRACK_COUNT_MAX do
    tracks[track] = serialize_track(self.tracks[track])
  end
  return {
    steps = tracks[1].steps,
    rate_index = tracks[1].rate_index,
    page_loop = tracks[1].page_loop,
    tracks = tracks
  }
end

-- Restore a snapshot produced by serialize(). Missing fields fall back to a
-- blank/default pattern, so an empty table yields an empty sequence. OLD
-- single-track snapshots (no `tracks` key -- every pre-Phase-1 pattern and
-- project) load into track 1 and blank tracks 2-8 (compat is binding). The
-- play position / pass counters / step timing are transport state, not pattern
-- state: they carry over exactly as they did before this was track-aware (the
-- coordinator's on_pattern_applied decides whether to re-anchor).
function GridSequencer:deserialize(snapshot)
  snapshot = snapshot or {}
  local tracks = snapshot.tracks
  if tracks == nil then
    tracks = {[1] = snapshot}
  end
  for track = 1, TRACK_COUNT_MAX do
    local old = self.tracks[track]
    local state = deserialize_track(tracks[track])
    state.play_index = old.play_index
    state.play_page = old.play_page
    state.play_step = old.play_step
    state.pattern_pass = old.pattern_pass
    state.last_cond_result = old.last_cond_result
    state.next_step_time = old.next_step_time
    state.remaining_time = old.remaining_time
    self.tracks[track] = state
  end
  self.seq = self.tracks[self.track]
end

function GridSequencer:held_step_index()
  local step = self:first_held_step()
  if step == nil then
    return nil
  end
  return self:step_index(self.selected_page, step), step
end

function GridSequencer:loop_region_from_holds(holds)
  local keys = sorted_held_keys(holds)
  if #keys == 0 then
    return nil
  end

  local units = self:loop_units_per_key()
  local start_point = math.min((keys[1] - 1) * units, 127)
  local end_point = math.min(keys[#keys] * units, 128)
  if end_point <= start_point then
    end_point = math.min(start_point + units, 128)
  end
  return start_point, end_point, #keys
end

function GridSequencer:region_is_current(start_point, end_point)
  return self.current_region_start ~= nil
    and math.abs(self.current_region_start - start_point) < 0.0001
    and math.abs(self.current_region_end - end_point) < 0.0001
end

function GridSequencer:mark_region_current(start_point, end_point)
  self.current_region_start = start_point
  self.current_region_end = end_point
end

function GridSequencer:set_region(start_point, end_point)
  if self:region_is_current(start_point, end_point) then
    return
  end
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:set_region_and_phase(start_point, end_point)
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point, true)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:set_region_with_phase(start_point, end_point, phase)
  if self.options.set_loop_region ~= nil then
    self.options.set_loop_region(start_point, end_point, phase)
  end
  self:mark_region_current(start_point, end_point)
end

function GridSequencer:phase_for_position(start_point, end_point, position)
  local range = math.max(0.01, end_point - start_point)
  return ((position - start_point) / range) % 1
end

function GridSequencer:position_at_region(start_point, end_point, at_time)
  if self.options.position_at_region ~= nil then
    return self.options.position_at_region(start_point, end_point, at_time)
  end
  local phase = self.options.phase ~= nil and (self.options.phase() or 0) or 0
  return start_point + ((end_point - start_point) * phase)
end

-- Loop start/end region locks are stored as ordinary param_locks (lock ids
-- "loop_start"/"loop_end") instead of a separate field, so grid loop-key
-- presses and K2/K3 encoder edits of STRT/END while holding a step share one
-- storage location: held_param_lock/item_raw_value already show any locked
-- param as locked when holding a step, so this is what makes STRT/END show up
-- there too, with no separate display path needed. An absent loop_end means
-- start-only (end follows the track's own base region).
function GridSequencer:step_lock(page, step)
  local record = self:step_record_for_page_step(page, step, false)
  if record == nil or record.param_locks == nil or record.param_locks.loop_start == nil then
    return nil
  end
  return {
    start_point = record.param_locks.loop_start,
    end_point = record.param_locks.loop_end
  }
end

function GridSequencer:set_step_lock(page, step, start_point, end_point, start_only)
  local record = self:step_record_for_page_step(page, step, true)
  record.trig = true
  record.param_locks = record.param_locks or {}
  record.param_locks.loop_start = start_point
  -- NB: not `start_only and nil or end_point` -- that idiom always yields
  -- end_point (true and nil -> nil, nil or end_point -> end_point), which is
  -- why a single loop-key tap used to lock both ends instead of start-only.
  if start_only then
    record.param_locks.loop_end = nil
  else
    record.param_locks.loop_end = end_point
  end
end

function GridSequencer:clear_step(page, step)
  self.seq.steps[self:step_index(page, step)] = nil
end

-- Loop-only single-key tap cycling: tapping the same loop key repeatedly while
-- holding a step cycles start+end -> start-only -> start+end. The FIRST tap of a
-- key locks BOTH start and end (a tight one-key window is the common case);
-- tapping the same key again drops the end lock so it follows the track's end.
-- Holding 2+ loop keys at once (held_count > 1) always locks start+end from
-- their min/max, and resets the cycle so the next single-key tap starts fresh.
function GridSequencer:loop_tap_start_only(held_count)
  if held_count > 1 then
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    return false
  end

  local current_key = sorted_held_keys(self.loop_holds)[1]
  if self.loop_tap_key == current_key and self.loop_tap_kind == "start_end" then
    self.loop_tap_kind = "start_only"
    return true
  elseif self.loop_tap_key == current_key and self.loop_tap_kind == "start_only" then
    self.loop_tap_kind = "start_end"
    return false
  end

  self.loop_tap_key = current_key
  self.loop_tap_kind = "start_end"
  return false
end

function GridSequencer:lock_held_steps(start_point, end_point, held_count)
  local did_lock = false
  self:record_step_undo("region", self:held_step_indices(), "region")
  local machine = self:machine()
  local start_only = machine == MACHINE_LOOP and self:loop_tap_start_only(held_count)
  for step, held in pairs(self.step_holds) do
    if held then
      self:set_step_lock(self.selected_page, step, start_point, end_point, start_only)
      self.step_edited[step] = true
      did_lock = true
    end
  end
  if did_lock then
    self:message(string.format("Step %02d Lock", self:first_held_step() or 1))
  end
  return did_lock
end

-- A reset flag is active for a step when the step p-locks it on, or (no lock)
-- the track default is on. lfo_reset gates the LFO retrigger (TRIG/ONE/HOLD
-- modes) and env_reset the mod-envelope retrigger (see mod_trig in
-- enter_step); filter_reset remains a placeholder.
function GridSequencer:reset_active(record, reset_id)
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil and locks[reset_id] ~= nil then
    return locks[reset_id] == 1
  end
  if self.options.reset_default ~= nil then
    return self.options.reset_default(reset_id) == true
  end
  return true
end

-- Trig Jump for a step (per-step lock, else the global default, else on).
function GridSequencer:trig_jump_active(record)
  local locks = record ~= nil and record.param_locks or nil
  if locks ~= nil and locks.trig_jump ~= nil then
    return locks.trig_jump == 1
  end
  if self.options.get_trig_jump ~= nil then
    return self.options.get_trig_jump() == true
  end
  return true
end

-- Trig Release for a step (per-step lock, else the global trig_release param).
-- 1=Return (default -- the main loop stays perfectly synced through step
-- overrides), 2=Boomerang, 3=Reset.
function GridSequencer:step_release_mode(record)
  local locks = record ~= nil and record.param_locks or nil
  local raw = locks ~= nil and locks.trig_release or nil
  if raw == nil and self.options.get_trig_release ~= nil then
    raw = self.options.get_trig_release()
  end
  raw = math.floor((tonumber(raw) or 1) + 0.5)
  if raw == 2 then return "boomerang" end
  if raw == 3 then return "reset" end
  return "return"
end

-- Ghost triggers are derived (not a stored flag): a trig that resets nothing --
-- no start reset (loop_start lock) and env/LFO/filter resets all off. So a step
-- becomes ghost by clearing its start lock and turning its resets off, and back
-- to normal by restoring either. Ghosts carry the current state forward instead
-- of ending the previous note.
function GridSequencer:is_ghost(record)
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

function GridSequencer:toggle_step(page, step)
  local index = self:step_index(page, step)
  local record = self:step_record(index, false)
  if Step.has_content(record) then
    self.seq.steps[index] = nil
    self:message(string.format("Step %02d Clear", step))
    return
  end

  record = self:step_record(index, true)
  record.trig = true
  if is_slice_machine(self:machine()) then
    record.slices[self:slice_index()] = true
  end
  -- Loop machines: a plain trigger fires the amp envelope (note_on) but does NOT
  -- move the playhead -- the loop keeps playing. Only an explicit start/end lock
  -- repositions it (governed by Trig Jump).
  self:message(string.format("Step %02d Trig", step))
end

-- FN + tap toggles a step between normal and ghost. Ghost = no start reset and
-- env/LFO/filter resets off; normal = start reset (0) and resets on.
function GridSequencer:toggle_ghost_step(page, step)
  local index = self:step_index(page, step)
  local record = self:step_record(index, true)
  record.trig = true
  record.param_locks = record.param_locks or {}
  if self:is_ghost(record) then
    record.param_locks.env_reset = nil
    record.param_locks.lfo_reset = nil
    record.param_locks.filter_reset = nil
    self:message(string.format("Step %02d Trig", step))
  else
    record.param_locks.loop_start = nil
    record.param_locks.loop_end = nil
    record.param_locks.env_reset = 0
    record.param_locks.lfo_reset = 0
    record.param_locks.filter_reset = 0
    self:message(string.format("Step %02d Ghost", step))
  end
end

function GridSequencer:toggle_step_slice(index, slice)
  local record = self:step_record(index, true)
  record.trig = true
  record.slices = record.slices or {}
  local was_active = record.slices[slice] == true
  if self.options.get_slice_polyphony ~= nil and self.options.get_slice_polyphony() == 2 then
    record.slices = {}
  end
  record.slices[slice] = not was_active
  if table_count(record.slices) == 0 then
    record.trig = false
  end
end

function GridSequencer:set_step_pitch(index, pitch)
  local record = self:step_record(index, true)
  record.trig = true
  record.pitch = pitch
  record.param_locks = record.param_locks or {}
  record.param_locks.pitch = pitch
  -- Grid-keyboard pitch entry (rows 5-7), unlike the encoder path, wrote the
  -- lock but never pushed it live -- a held step's stopped preview or Live Step
  -- Trig hold kept sounding the old pitch until release/re-press. retrigger =
  -- true re-auditions the stopped preview at the new pitch (fresh attack);
  -- ignored during a live-held step so playback keeps its own triggering.
  self:refresh_held_step(true)
end

function GridSequencer:apply_step_pitch(record)
  local pitch = record ~= nil and record.pitch or nil
  if pitch == nil and record ~= nil and record.param_locks ~= nil then
    pitch = record.param_locks.pitch
  end
  if pitch == nil and self.param_lock_holds.pitch ~= nil then
    pitch = self.param_lock_holds.pitch.value
  end
  if self.options.set_pitch ~= nil then
    self.options.set_pitch(pitch or self:base_pitch())
  end
end

function GridSequencer:set_held_param_lock(param_id, value)
  local did_lock = false
  self:record_step_undo("plock:" .. tostring(param_id), self:held_step_indices(), param_id)
  for step, held in pairs(self.step_holds) do
    if held then
      local index = self:step_index(self.selected_page, step)
      local record = self:step_record(index, true)
      record.trig = true
      record.param_locks = record.param_locks or {}
      record.param_locks[param_id] = value
      if param_id == "pitch" then
        record.pitch = value
      elseif param_id == "velocity" then
        record.velocity = value
      elseif param_id == "length" then
        record.length = value
      end
      self.step_edited[step] = true
      did_lock = true
    end
  end
  if did_lock then
    -- Re-apply the sounding hold (stopped preview OR live-held step) so edits
    -- like pitch/range are heard immediately without re-pressing the step.
    self:refresh_held_step()
  end
  return did_lock
end

-- Re-apply the currently-sounding held step after a lock edit, whichever form
-- that hold takes: the stopped step preview, or a live-held step (Live Step
-- Trig) during playback. `retrigger` (loop/pitch-key presses while holding a
-- step) asks the STOPPED preview to re-audition from the top with a fresh amp
-- attack; it is deliberately ignored during playback, where the sequencer owns
-- envelope triggering and a live edit must not inject a spurious attack.
function GridSequencer:refresh_held_step(retrigger)
  if self.live_step_hold then
    self:refresh_live_step()
  else
    self:refresh_preview_region(retrigger)
  end
end

-- Live Step Trig: re-apply the held step's locks/pitch/range (and follow its
-- region locks) so edits made while holding are heard immediately, without
-- releasing and re-pressing the step.
function GridSequencer:refresh_live_step()
  if not self.live_step_hold or self.live_step_index == nil then
    return
  end
  local record = self:step_record(self:step_index(self.selected_page, self.live_step_index), false)
  if record == nil then
    return
  end
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(self:effective_param_locks(record))
  end
  -- Re-pin: effective_param_locks re-added this step's locks with a
  -- note-length expiry, but a live hold lasts until release.
  for lock_id in pairs(record.param_locks or {}) do
    if self.param_lock_holds[lock_id] ~= nil then
      self.param_lock_holds[lock_id].expires_at = math.huge
    end
  end
  self:apply_step_pitch(record)
  self:apply_active_range()
  local locks = record.param_locks or {}
  if locks.loop_start ~= nil or locks.loop_end ~= nil then
    -- Follow region edits without re-jumping the phase (live scrub feel).
    local start_point, end_point = self:resolve_active_region()
    self:set_region(start_point, end_point)
  end
end

-- Re-apply the currently-previewed step's range, region and pitch so lock edits
-- take effect live during a stopped step preview. `retrigger` (a loop/pitch-key
-- press while holding the step) additionally re-auditions from the region start
-- with a fresh amp attack, so the change is heard immediately without releasing
-- and re-pressing the step. Plain lock/encoder edits pass retrigger = false and
-- just update the still-sounding preview in place (no machine-gun re-attacks).
function GridSequencer:refresh_preview_region(retrigger)
  if self.playing or not self.preview_active then
    return
  end
  local index = self:held_step_index()
  if index == nil then
    return
  end
  local record = self:step_record(index, false)
  if record == nil or record.trig ~= true then
    return
  end
  local locks = record.param_locks or {}
  self:push_active_range(locks.range_start, locks.range_end)
  local start_point, end_point = self:locked_region(record)
  self:apply_step_pitch(record)
  if retrigger and not is_slice_machine(self:machine()) then
    self:set_region_with_phase(start_point, end_point, 0)
    -- retrig_note forces a fresh attack even under portamento (a plain note_on
    -- on the still-held preview note would be swallowed as legato). Falls back
    -- to note_on where the engine facade predates retrig_note.
    if self.options.retrig_note ~= nil then
      self.options.retrig_note(0)
    elseif self.options.note_on ~= nil then
      self.options.note_on(0)
    end
  else
    self:set_region(start_point, end_point)
  end
end

function GridSequencer:held_param_lock(param_id)
  local index = self:held_step_index()
  if index == nil then
    return nil
  end
  local record = self:step_record(index, false)
  if record == nil then
    return nil
  end
  if record.param_locks ~= nil and record.param_locks[param_id] ~= nil then
    return record.param_locks[param_id]
  end
  if param_id == "pitch" then
    return record.pitch
  elseif param_id == "velocity" then
    return record.velocity
  elseif param_id == "length" then
    return record.length
  end
  return nil
end

function GridSequencer:clear_held_param_lock(param_id)
  local did_clear = false
  for step, held in pairs(self.step_holds) do
    if held then
      local index = self:step_index(self.selected_page, step)
      local record = self:step_record(index, false)
      if record ~= nil then
        if record.param_locks ~= nil then
          record.param_locks[param_id] = nil
        end
        if param_id == "pitch" then
          record.pitch = nil
        elseif param_id == "velocity" then
          record.velocity = nil
        elseif param_id == "length" then
          record.length = nil
        end
        self.step_edited[step] = true
        did_clear = true
      end
    end
  end
  return did_clear
end

function GridSequencer:clear_all_param_locks(param_id)
  local did_clear = false
  for _, record in pairs(self.seq.steps) do
    if record.param_locks ~= nil and record.param_locks[param_id] ~= nil then
      record.param_locks[param_id] = nil
      did_clear = true
    end
    if param_id == "pitch" and record.pitch ~= nil then
      record.pitch = nil
      did_clear = true
    elseif param_id == "velocity" and record.velocity ~= nil then
      record.velocity = nil
      did_clear = true
    elseif param_id == "length" and record.length ~= nil then
      record.length = nil
      did_clear = true
    end
  end
  return did_clear
end

-- `state` (optional, default = the selected track) lets the background-track
-- advancement reuse the exact same logic without forking it -- same for
-- step_seconds/step_duration/condition_result/evaluate_trig below.
function GridSequencer:current_rate(state)
  return RATES[(state or self.seq).rate_index] or 1
end

function GridSequencer:current_bpm()
  if self.options.get_tempo ~= nil then
    return math.max(1, self.options.get_tempo() or 120)
  end
  if clock.get_tempo ~= nil then
    return math.max(1, clock.get_tempo())
  end
  return 120
end

function GridSequencer:step_seconds(state)
  return 60 / self:current_bpm() / 4 / self:current_rate(state)
end

function GridSequencer:note_seconds(record)
  if is_slice_machine(self:machine()) and self.options.get_hold_to_step ~= nil and self.options.get_hold_to_step() == false then
    if self.options.get_slice_hold ~= nil then
      return self.options.get_slice_hold()
    end
    return 0
  end
  return math.max(0.01, ((record ~= nil and record.length) or self:default_length()) * self:step_seconds())
end

-- Effective value of a sequencer-domain field for a step: its own p-lock if
-- present, else the track-level param (read through the coordinator getter).
function GridSequencer:step_field(record, lock_id, getter, fallback)
  if record ~= nil and record.param_locks ~= nil and record.param_locks[lock_id] ~= nil then
    return record.param_locks[lock_id]
  end
  if getter ~= nil then
    local value = getter()
    if value ~= nil then
      return value
    end
  end
  return fallback
end

-- Ratchet count for a step (1-8). 1 = a single hit (no ratchet).
function GridSequencer:effective_ratchet(record)
  local raw = self:step_field(record, "trig_ratchet", self.options.get_trig_ratchet, 1)
  return util.clamp(math.floor((tonumber(raw) or 1) + 0.5), 1, 8)
end

-- Swing percentage (50 = straight, 75 = maximum). Applied as a long/short pair
-- across consecutive steps in step_duration.
function GridSequencer:swing_amount()
  local raw = self.options.get_swing ~= nil and self.options.get_swing() or 50
  return util.clamp(tonumber(raw) or 50, 50, 75)
end

-- Duration the given step occupies before the next advance. Straight = one step;
-- swing lengthens odd steps and shortens the following even step by the same
-- amount, so each odd/even pair still spans two straight steps.
function GridSequencer:step_duration(index, state)
  local base = self:step_seconds(state)
  local swing = self:swing_amount()
  if swing <= 50 then
    return base
  end
  local ratio = swing / 100
  if index % 2 == 1 then
    return base * 2 * ratio
  end
  return base * 2 * (1 - ratio)
end

-- The kind (and full definition) of a step's trig condition. Reads the step's
-- p-lock or the track param; both index into the shared TrigConditions table so
-- the label shown and the logic run can never diverge.
-- `cond_getter` (optional) overrides the track-level fallback param read --
-- background tracks pass their own track's getter; nil = the selected track's.
function GridSequencer:condition_definition(record, cond_getter)
  local raw = self:step_field(record, "trig_condition", cond_getter or self.options.get_trig_condition, 1)
  local idx = util.clamp(math.floor((tonumber(raw) or 1) + 0.5), 1, #TrigConditions)
  return TrigConditions[idx]
end

-- Whether a step's CONDITION passes this pass (independent of the chance roll).
-- Pure read -- no side effects -- so it is safe to call for UI/preview too.
-- Fill is a shared live gesture; pattern_pass/last_cond_result are per track
-- (`state`, default = the selected track).
function GridSequencer:condition_result(record, state, cond_getter)
  state = state or self.seq
  local def = self:condition_definition(record, cond_getter)
  local kind = def ~= nil and def.kind or "none"
  if kind == "none" then
    return true
  elseif kind == "ab" then
    return ((state.pattern_pass - 1) % def.b) + 1 == def.a
  elseif kind == "fill" then
    return self.fill_active == true
  elseif kind == "nfill" then
    return self.fill_active ~= true
  elseif kind == "pre" then
    return state.last_cond_result == true
  elseif kind == "npre" then
    return state.last_cond_result ~= true
  elseif kind == "nei" or kind == "nnei" then
    -- Neighbor-track conditions: no neighbor routing exists until Phase 5, so
    -- both evaluate always-true until the neighbor machine lands (PRD §6.5).
    return true
  elseif kind == "first" then
    return state.pattern_pass == 1
  end
  return true
end

-- Decide whether an active step fires this pass. Both independent p-lockable
-- fields must pass: the condition AND the chance roll (PRD §6.5). Records the
-- outcome for a following PRE/!PRE trig, but only for steps that themselves
-- carry a condition, so a plain trig never breaks the conditional chain.
function GridSequencer:evaluate_trig(record, state, cond_getter, chance_getter)
  state = state or self.seq
  local def = self:condition_definition(record, cond_getter)
  local kind = def ~= nil and def.kind or "none"
  local fired = self:condition_result(record, state, cond_getter)
  if fired then
    local chance = util.clamp(
      self:step_field(record, "trig_chance", chance_getter or self.options.get_trig_chance, 100), 0, 100)
    if chance < 100 then
      fired = (math.random() * 100) < chance
    end
  end
  if kind ~= "none" then
    state.last_cond_result = fired
  end
  return fired
end

-- Fire a step's ratchets: the extra sub-step hits after the first. Scheduled on
-- a tempo clock at even sub-divisions of the step; a token cancels stale runs
-- when the next step (or a stop) supersedes them.
function GridSequencer:schedule_ratchets(record, count)
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
      if not self.playing or self.ratchet_token ~= token then
        return
      end
      self:retrigger_ratchet(record, machine)
    end
  end)
end

-- One ratchet sub-hit: re-attack the note and re-fire the machine's trigger, the
-- same dispatch a fresh step would do (minus the region/anchor bookkeeping, which
-- the sub-hits share with the parent step).
function GridSequencer:retrigger_ratchet(record, machine)
  -- Sub-hits re-fire the mod sources the same as the parent step, so a
  -- ratcheted note keeps its per-note LFO/mod-env articulation.
  if self.options.mod_trig ~= nil then
    self.options.mod_trig(
      self:reset_active(record, "lfo_reset"),
      self:reset_active(record, "env_reset"))
  end
  if machine == MACHINE_LOOP or machine == MACHINE_LOOP_TRIG then
    if self.options.note_on ~= nil and not self:is_ghost(record) then
      self.options.note_on(self:note_seconds(record))
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

-- Fill key (grid 16,6). Plain press = momentary fill while held; FN+press
-- toggles a latched fill. Active fill = latched OR currently held (PRD §6.5).
function GridSequencer:key_fill(z)
  if z == 1 then
    if self.fn_down then
      self.fill_latched = not self.fill_latched
    else
      self.fill_held = true
    end
  else
    self.fill_held = false
  end
  self.fill_active = self.fill_latched or self.fill_held == true
  self:message(self.fill_active and "Fill On" or "Fill Off")
end

-- A/B scene crossfader on row 5, cols 9-16 (PRD §6.6):
--   col 9  = Scene A anchor: HOLD it and turn an encoder to p-lock that param
--            into scene A (edits write the scene only, like a held step's
--            p-lock; the live sound doesn't change until the fader moves).
--            Never moves the fader. FN+anchor stores the WHOLE current state.
--   cols 10-15 = fader glide keys, targets spread 0..1 across the six keys
--            (col 10 = full A, col 15 = full B). Holding a key EASES the
--            crossfade toward its target (exponential approach, ~0.3s to
--            land) instead of jumping: tap to nudge a little, hold to land.
--            Release freezes wherever it is.
--   col 16 = Scene B anchor, same as A.
-- Row-5 crossfader layout (centered, PRD §6.6): col 10 = Scene A anchor,
-- cols 11-15 = fader glide keys spread 0..1 (11=0/full A, 13=0.5/center,
-- 15=1/full B), col 16 = Scene B anchor. Col 9 is unused.
local SCENE_A_COL, SCENE_B_COL = 10, 16
local FADER_MIN_COL, FADER_MAX_COL = 11, 15
local function fader_target(col)
  return (col - FADER_MIN_COL) / (FADER_MAX_COL - FADER_MIN_COL)
end

function GridSequencer:key_scene(x, z)
  local scene = (x == SCENE_A_COL and 1) or (x == SCENE_B_COL and 2) or nil
  if scene ~= nil then
    if z == 1 then
      if self.fn_down then
        if self.options.capture_scene ~= nil then
          self.options.capture_scene(scene)
        end
        self:message(scene == 1 and "Scene A stored" or "Scene B stored")
      else
        -- Anchor press: arm the scene-lock hold. The fader never moves here.
        if self.options.set_scene_edit ~= nil then
          self.options.set_scene_edit(scene)
        end
        self:message(scene == 1 and "Scene A hold" or "Scene B hold")
      end
    else
      if self.options.set_scene_edit ~= nil then
        self.options.set_scene_edit(nil)
      end
    end
    return
  end

  if x < FADER_MIN_COL or x > FADER_MAX_COL then
    return
  end
  if z == 1 then
    self.scene_glide_target = fader_target(x)
    -- Force-apply the crossfade at the CURRENT position now, so a param just
    -- p-locked into a scene snaps into the sound the instant a fader key is
    -- touched -- even before (or without) the position actually moving.
    if self.options.set_crossfade ~= nil and self.options.get_crossfade ~= nil then
      self.options.set_crossfade(self.options.get_crossfade() or 0)
    end
    self:start_scene_glide()
  else
    -- Released: retarget to another still-held fader key, else stop.
    local held_target = nil
    for col = FADER_MIN_COL, FADER_MAX_COL do
      if self.pressed[col .. ":5"] then
        held_target = fader_target(col)
      end
    end
    if held_target ~= nil then
      self.scene_glide_target = held_target
    else
      self:stop_scene_glide()
    end
  end
end

-- Ease the crossfade toward scene_glide_target while a fader key is held:
-- value += (target - value) * rate*dt (exponential approach -- fast over big
-- distances, easing in as it lands). Driven by a reused norns metro at ~30Hz
-- (the same reliable C-timer the sequencer runs on, not a clock coroutine);
-- each step goes through options.set_crossfade, i.e. the `crossfade` param, so
-- the MASTER-page encoder and LEDs stay in sync.
local SCENE_GLIDE_HZ = 30
local SCENE_GLIDE_RATE = 5  -- per-second approach rate (time constant ~0.2s)

-- One eased step of the crossfade toward scene_glide_target. Shared by the
-- immediate step on a fader-key press (so even a fast TAP moves) and the
-- while-held glide metro below. Returns true once it has landed on the target.
function GridSequencer:step_scene_glide()
  local target = self.scene_glide_target
  if target == nil or self.options.set_crossfade == nil or self.options.get_crossfade == nil then
    return true
  end
  local current = self.options.get_crossfade() or 0
  local factor = math.min(1, SCENE_GLIDE_RATE / SCENE_GLIDE_HZ)
  local next_value = current + (target - current) * factor
  if math.abs(target - next_value) < 0.004 then
    next_value = target
  end
  if next_value ~= current then
    self.options.set_crossfade(next_value)
    self:request_redraw()
  end
  return next_value == target
end

function GridSequencer:start_scene_glide()
  self:step_scene_glide()  -- move immediately so even a fast tap registers
  if metro == nil or metro.init == nil then
    return
  end
  -- Lazily allocate ONE glide metro and reuse it for every fader gesture (the
  -- norns metro pool is small, so never init per-press). It keeps easing while a
  -- fader key is held (a no-op once the target is reached -- cheap, and it lets
  -- a release-retarget to another still-held key resume gliding); it stops only
  -- when the target is cleared on release (stop_scene_glide).
  if self.scene_glide_metro == nil then
    self.scene_glide_metro = metro.init(function()
      if self.scene_glide_target == nil then
        if self.scene_glide_metro ~= nil then
          self.scene_glide_metro:stop()
        end
        return
      end
      self:step_scene_glide()
    end, 1 / SCENE_GLIDE_HZ, -1)
  end
  if self.scene_glide_metro ~= nil then
    self.scene_glide_metro.time = 1 / SCENE_GLIDE_HZ
    self.scene_glide_metro:start()
  end
end

function GridSequencer:stop_scene_glide()
  self.scene_glide_target = nil
  if self.scene_glide_metro ~= nil then
    self.scene_glide_metro:stop()
  end
end

-- Pattern-load key (grid 8,5). A quick TAP (press+release inside
-- PATTERN_TAP_SECONDS with no slot picked) latches the overlay open -- it
-- stays open after release, and a second tap closes it. A HOLD (press held
-- past the threshold) is momentary, exactly like the old behaviour: the
-- overlay closes as soon as the key is released. Picking a slot or renaming
-- always closes the overlay either way (see key_pattern_mode), which sets
-- pattern_selection_made so the matching release here doesn't also re-latch.
function GridSequencer:key_pattern(z)
  if z == 1 then
    if self.pattern_latched then
      -- Already latched open: this press is a "close" tap.
      self.pattern_latched = false
      self.pattern_mode = false
      self.pattern_press_time = nil
      self:message("Pattern")
      return
    end
    self.pattern_press_time = util.time()
    self.pattern_selection_made = false
    self.pattern_mode = true
    self:message("Pattern")
    return
  end

  -- Key-up. A nil press_time means this release has no matching press we
  -- started here (e.g. FN+(8,5) routed the press to the quantize-mode pop-up
  -- instead -- see the (8,5) special-case in key()) -- leave any existing
  -- overlay state untouched.
  local press_time = self.pattern_press_time
  if press_time == nil then
    return
  end
  self.pattern_press_time = nil
  if self.pattern_selection_made then
    self.pattern_selection_made = false
    return
  end
  local was_quick_tap = (util.time() - press_time) < PATTERN_TAP_SECONDS
  if was_quick_tap and self.pattern_mode then
    self.pattern_latched = true
  else
    self.pattern_mode = false
  end
end

-- Handle a key while the pattern-load overlay is open. Returns true if the key
-- was consumed by the overlay. Category keys (row 1) are NOT consumed -- they
-- close the overlay and then act normally.
function GridSequencer:key_pattern_mode(x, y, z)
  if y == 1 then
    self.pattern_mode = false
    self.pattern_latched = false
    self.pattern_selection_made = true
    return false
  end
  if z ~= 1 then
    return true  -- swallow releases of inert keys
  end
  if y == 8 then
    -- Bottom row is the 16 pattern slots; a press loads and exits.
    if self.options.load_pattern ~= nil then
      self.options.load_pattern(x)
    end
    self.pattern_mode = false
    self.pattern_latched = false
    self.pattern_selection_made = true
    return true
  end
  if x == 14 and y == 7 then
    -- Right arrow (14,7 -- matches lib/input/router.lua's binding) renames the
    -- current pattern (opens the text dialog, §7.3). Was wrongly on (13,7),
    -- the Down arrow. Exit the overlay first: the modal dialog takes over the
    -- grid, so the pattern key's release would otherwise never reach us to
    -- close it. Works the same via a hold or a latched tap.
    self.pattern_mode = false
    self.pattern_latched = false
    self.pattern_selection_made = true
    if self.options.rename_pattern ~= nil then
      self.options.rename_pattern()
    else
      self:message("Rename n/a")
    end
    return true
  end
  return true  -- pitch keys, arrows, octave: inert while the overlay is open
end

function GridSequencer:clear_param_lock_holds()
  self.param_lock_holds = {}
end

function GridSequencer:expire_param_lock_holds(now)
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

function GridSequencer:effective_param_locks(record)
  local now = util.time()
  self:expire_param_lock_holds(now)

  local locks = {}
  local has_locks = false
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
          self.param_lock_holds[lock_id] = {
            value = value,
            expires_at = now + length_seconds
          }
        end
      end
    end
  end

  return has_locks and locks or nil
end

function GridSequencer:metro_interval()
  -- The one sequence metro serves every active track: tick fast enough for the
  -- fastest track's rate (with one track this reduces to the old expression).
  local fastest = self:step_seconds()
  local count = self:active_track_count()
  for track = 1, count do
    if track ~= self.track then
      local seconds = self:step_seconds(self.tracks[track])
      if seconds < fastest then
        fastest = seconds
      end
    end
  end
  return util.clamp(fastest / 2, 0.005, 0.05)
end

function GridSequencer:ensure_sequence_metro()
  if self.seq_metro == nil then
    self.seq_metro = metro.init(function()
      self:tick_sequence()
    end, self:metro_interval(), -1)
  end
  return self.seq_metro
end

-- Resolve a single step record's region against the track base. Start and end
-- are independent: a start-only lock keeps the track end, an end-only lock keeps
-- the track start, both-locked overrides both. (Used for stopped preview; live
-- playback goes through resolve_active_region so the sequencer/loop-key/track
-- layering can take effect -- see region_layers.)
function GridSequencer:locked_region(record)
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

-- The three region layers that can drive playback, each optionally supplying a
-- start and/or an end independently:
--   track  -- always present (base_region), the bottom fallback
--   keys   -- live loop-key holds (nil when no loop keys are held)
--   seq    -- the currently-triggering step's region lock, persisted with an
--             expiry window in param_lock_holds so it reverts on its own
-- resolve_active_region walks a priority order (set by live-performance mode)
-- and, for each of start and end separately, takes the highest-priority layer
-- that provides that endpoint.
function GridSequencer:region_layers()
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
  local key_start, key_end = self:loop_region_from_holds(self.loop_holds)
  if key_start ~= nil then
    keys.start_point = key_start
    keys.end_point = key_end
  end

  return track_start, track_end, seq, keys
end

function GridSequencer:resolve_active_region()
  local track_start, track_end, seq, keys = self:region_layers()
  -- Held loop keys are a live gesture and always beat the sequenced layer.
  -- (Previously seq won outside live-performance mode, so pressing a key while a
  -- step's region lock was active did nothing -- the region resolved to the
  -- lock's [0,...] and the whole loop row lit up as if key 1 were held.)
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

-- Step Range -> Active Range override. Range (0-128 window inside file trim) is
-- layered exactly like the loop region: the range_start/range_end params are the
-- Track Range (edited on the Range page, never touched by step locks), a
-- triggering step's range lock is the Step Range, and the engine plays the
-- Actual Range. We push the Step Range (nil per endpoint = fall back to Track)
-- to the coordinator, which sets it on map_trim_point. A change also invalidates
-- the region cache so the next set_region re-maps the engine points.
function GridSequencer:push_active_range(range_start, range_end)
  if self.options.set_active_range == nil then
    return
  end
  if range_start ~= self.current_range_start or range_end ~= self.current_range_end then
    self.options.set_active_range(range_start, range_end)
    self.current_range_start = range_start
    self.current_range_end = range_end
    self.current_region_start = nil
  end
end

-- During playback the Step Range lives in param_lock_holds (with the note-length
-- expiry), the same store the loop region uses -- so it reverts to Track Range
-- on its own when the step's window elapses.
function GridSequencer:apply_active_range()
  if self.options.set_active_range == nil then
    return
  end
  self:expire_param_lock_holds(util.time())
  local range_start = self.param_lock_holds.range_start and self.param_lock_holds.range_start.value or nil
  local range_end = self.param_lock_holds.range_end and self.param_lock_holds.range_end.value or nil
  self:push_active_range(range_start, range_end)
end

-- A Track-layer region/range param was edited while the sequencer is running:
-- re-resolve and re-push the Actual region through the layered resolver, so the
-- edit is heard immediately when no step lock is shadowing it, and correctly
-- deferred (until the lock's window elapses) when one is. The cache is
-- invalidated first because the engine mapping can change (a range edit
-- re-folds the same track-space points to different engine points) even when
-- the resolved region is numerically identical.
function GridSequencer:refresh_track_region()
  self.current_region_start = nil
  self:apply_active_range()
  local start_point, end_point = self:resolve_active_region()
  self:set_region(start_point, end_point)
end

-- Best estimate of the current absolute playback position (0-128) within the
-- region currently loaded in the engine, used to preserve position across a
-- region change (Boomerang playhead return, sequencer revert continuity).
function GridSequencer:current_absolute_position()
  local cur_start = self.current_region_start
  local cur_end = self.current_region_end
  if cur_start == nil then
    return nil
  end
  return self:position_at_region(cur_start, cur_end, util.time())
end

-- Change the loaded region while keeping the absolute playback position steady:
-- recompute the phase so newStart + phase*width lands on the same sample point.
function GridSequencer:set_region_preserve_position(new_start, new_end)
  local pos = self:current_absolute_position()
  if pos == nil then
    self:set_region(new_start, new_end)
    return
  end
  local phase = self:phase_for_position(new_start, new_end, pos)
  self:set_region_with_phase(new_start, new_end, phase)
end

-- Trig Jump OFF: the region walls moved. If the walls didn't actually move,
-- do nothing at all (no engine reset -- a per-trig phase "correction" would
-- audibly jitter). If the playhead is still between the new walls, keep walking
-- (preserve absolute position); if a wall has passed it, warp to the start wall.
-- Returns true when the region actually changed (the main loop was interrupted).
function GridSequencer:set_region_within_or_warp(new_start, new_end)
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

function GridSequencer:slice_range(slice)
  if self.options.get_slice_range ~= nil then
    return self.options.get_slice_range(slice)
  end
  local count = self:slice_count()
  local width = 128 / count
  return (slice - 1) * width, slice * width
end

function GridSequencer:trigger_region(record)
  if self.options.trigger_region == nil then
    return
  end
  local start_point, end_point = self:locked_region(record)
  self:set_region_with_phase(start_point, end_point, 0)
  self.options.trigger_region(start_point, end_point, {
    velocity = record.velocity or self:default_velocity(),
    length_seconds = self:note_seconds(record),
    pitch = record.pitch or self:base_pitch()
  })
end

function GridSequencer:trigger_step_slices(record)
  if self.options.trigger_slice == nil then
    return
  end
  local first_start = nil
  local first_end = nil
  local slices = record.slices or {}
  if record.trig and table_count(slices) == 0 then
    slices = {[self:slice_index()] = true}
  end
  for slice = 1, self:slice_count() do
    if slices[slice] then
      local start_point, end_point = self:slice_range(slice)
      first_start = first_start or start_point
      first_end = first_end or end_point
      self.options.trigger_slice(slice, start_point, end_point, {
        velocity = record.velocity or self:default_velocity(),
        length_seconds = self:note_seconds(record),
        pitch = record.pitch or self:base_pitch()
      })
    end
  end
  if first_start ~= nil then
    self:mark_region_current(first_start, first_end)
  end
end

function GridSequencer:enter_step(reset_sequence)
  local record = self:step_record(self.seq.play_index, false)
  local machine = self:machine()

  if reset_sequence then
    self:clear_param_lock_holds()
    self.seq_anchor = nil
    self.keys_anchor = nil
    -- A fresh start is pass 1 with no prior conditional result (PRD §6.5).
    self.seq.pattern_pass = 1
    self.seq.last_cond_result = nil
  end

  -- Live Step Trig: a live-held step owns playback -- sequenced steps advance
  -- silently until the hold releases.
  if self.live_step_hold and not reset_sequence then
    return
  end

  -- Trig conditions: an active step (a trig, or slices on a slice machine) only
  -- FIRES if its chance roll and its condition both pass. A step that doesn't
  -- fire behaves exactly like an empty step -- no locks, pitch, note or region
  -- jump -- so lock_record is nil'd out through the firing-only paths below.
  local active = record ~= nil and (
    (is_slice_machine(machine) and table_count(record.slices) > 0)
    or record.trig == true)
  local fires = active and self:evaluate_trig(record)
  local lock_record = fires and record or nil

  -- Monophonic: a fresh non-ghost trigger ends the previous note -- clear the
  -- carried holds so unlocked params revert to base before this step's locks
  -- apply. Without this, a step's lock outlives its note-length window when the
  -- length is >= 1 and the next trigger fails to switch it (e.g. sample slot).
  -- Ghost triggers, and Poly mode, carry the previous state forward instead.
  if not reset_sequence and fires
    and self:trig_polyphony() == 1 and not self:is_ghost(record) then
    self:clear_param_lock_holds()
  end
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(self:effective_param_locks(lock_record))
  end
  self:apply_step_pitch(lock_record)
  -- Push the Step Range before any region set, so the region maps through the
  -- correct (Actual) range in the same tick.
  self:apply_active_range()

  -- Retrigger the amp envelope on each non-ghost note (ghosts leave the envelope
  -- untouched -- the env_reset semantics). Empty steps send nothing, so the
  -- envelope decays to silence between triggers.
  if (machine == MACHINE_LOOP or machine == MACHINE_LOOP_TRIG)
    and fires and not self:is_ghost(record)
    and self.options.note_on ~= nil then
    self.options.note_on(self:note_seconds(record))
  end

  -- Retrigger the modulation sources (2 LFOs + mod env) on every firing step
  -- where the corresponding reset resolves ON: lfo_reset gates the LFO trig
  -- counters (only TRIG/ONE/HOLD LFO modes react), env_reset the mod
  -- envelope's. Ghost steps resolve both off (existing ghost semantics), so
  -- they carry the running modulation forward untouched.
  if fires and self.options.mod_trig ~= nil then
    self.options.mod_trig(
      self:reset_active(record, "lfo_reset"),
      self:reset_active(record, "env_reset"))
  end

  if machine == MACHINE_LOOP then
    -- A step that carries an explicit region lock jumps the playhead to the new
    -- active start (fresh trigger). Every other step re-resolves the layered
    -- region and applies it *without* resetting phase, so an expired step lock
    -- reverts to the track region while the playhead keeps advancing (task #21).
    local record_locks_region = fires and record.param_locks ~= nil
      and (record.param_locks.loop_start ~= nil or record.param_locks.loop_end ~= nil)
    if reset_sequence then
      local start_point, end_point = self:resolve_active_region()
      self:set_region_with_phase(start_point, end_point, 0)
    elseif record_locks_region then
      -- A step that locks start/end repositions the playhead. Trig Jump on = warp
      -- to the region start; off = only reposition if the playhead is now outside
      -- the new region, otherwise keep playing (the wall/street model).
      -- If the step actually interrupts the main loop, arm the release anchor
      -- (kept from the FIRST takeover across chained region steps) so its Trig
      -- Release mode knows where the main loop would naturally be.
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
      if self.seq_anchor ~= nil and not region_hold and not any_keys(self.loop_holds) then
        -- The armed region override is gone -- its window expired (possibly
        -- silently inside effective_param_locks/apply_active_range above, whose
        -- fresh util.time() can cross the deadline the tick check just missed)
        -- or a plain mono trigger ended it. Release per the expiring step's
        -- Trig Release mode instead of a plain set_region, which would leave
        -- the phasor's 0-1 phase to be reinterpreted in the wider region (the
        -- "random position" jump).
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

function GridSequencer:start_sequence(reset_sequence)
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.playing = true
  -- Fresh start (vs. resume-from-pause): the branch below that re-enters step 1.
  local fresh_start = reset_sequence or self.seq.remaining_time == nil
  if self.seq.remaining_time ~= nil and not reset_sequence then
    self.seq.next_step_time = util.time() + self.seq.remaining_time
    self.seq.remaining_time = nil
  else
    self.seq.remaining_time = nil
    self.seq.play_index = 1
    self.global_pos = 1
    self:sync_play_page_step()
    self:enter_step(true)
    -- If the pattern has no trigs at all, fire the amp envelope once at start so
    -- the loop voice drones (with the default INF hold) without needing steps.
    if not is_slice_machine(self:machine()) and not self:pattern_has_trigs()
      and self.options.note_on ~= nil then
      self.options.note_on(self:note_seconds(nil))
      -- The droning no-trig start counts as one note for the mod sources too.
      if self.options.mod_trig ~= nil then
        self.options.mod_trig(true, true)
      end
    end
    self.seq.next_step_time = util.time() + self:step_duration(self.seq.play_index)
  end
  self:prime_background_tracks(fresh_start)
  local seq_metro = self:ensure_sequence_metro()
  if seq_metro ~= nil then
    seq_metro:start(self:metro_interval(), -1)
  end
  self:request_redraw()
end

-- Phase 1 track scaffolding: ready every non-selected active track for
-- playback. reset = re-anchor at step 1 and fire it (the same treatment the
-- selected track just got from enter_step(true)); otherwise leave their
-- positions alone -- a paused track resumes from its parked remaining_time in
-- tick_background_tracks.
function GridSequencer:prime_background_tracks(reset)
  local now = util.time()
  local count = self:active_track_count()
  for track = 1, count do
    if track ~= self.track then
      local state = self.tracks[track]
      if reset then
        state.play_index = 1
        state.play_page, state.play_step = self:index_to_page_step(1)
        state.pattern_pass = 1
        state.last_cond_result = nil
        state.remaining_time = nil
        self:enter_background_step(track, state)
        state.next_step_time = now + self:step_duration(state.play_index, state)
      end
    end
  end
end

function GridSequencer:pause_sequence()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  if self.seq.next_step_time ~= nil then
    self.seq.remaining_time = math.max(0.001, self.seq.next_step_time - util.time())
  end
  self.seq.next_step_time = nil
  -- Park every background track's step timing the same way, so resume keeps
  -- their relative phase.
  for track = 1, TRACK_COUNT_MAX do
    if track ~= self.track then
      local state = self.tracks[track]
      if state.next_step_time ~= nil then
        state.remaining_time = math.max(0.001, state.next_step_time - util.time())
      end
      state.next_step_time = nil
    end
  end
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
  end
  self:request_redraw()
end

-- Clear all transient live state (holds, step-edit flags, param-lock holds,
-- live-step, anchors, fill, preview). Used by New Project so nothing stays
-- "held" and un-editable after the reset. Does NOT touch the step records --
-- the caller reloads those from the fresh/blank pattern.
function GridSequencer:reset_live_state()
  self.loop_holds = {}
  self.slice_holds = {}
  self.step_holds = {}
  self.step_press_time = {}
  self.step_edited = {}
  self.pressed = {}
  self.loop_tap_key = nil
  self.loop_tap_kind = nil
  self.param_lock_holds = {}
  self.live_step_hold = false
  self.live_step_index = nil
  self.loop_key_programming = {}
  self.seq_anchor = nil
  self.keys_anchor = nil
  self.manual_region = nil
  self.preview_active = false
  self.seq.pattern_pass = 1
  self.seq.last_cond_result = nil
  self.fill_active = false
  self.fill_latched = false
  self.fill_held = false
  self.pattern_mode = false
  self.pattern_latched = false
  self.pattern_press_time = nil
  self.pattern_selection_made = false
  self:stop_scene_glide()
end

function GridSequencer:stop_sequence()
  self.playing = false
  if self.seq_metro ~= nil then
    self.seq_metro:stop()
  end
  self.live_step_hold = false
  self.live_step_index = nil
  self.seq_anchor = nil
  self.keys_anchor = nil
  -- Stop re-anchors EVERY track at step 1 (selected included -- self.seq is
  -- one of these), matching the old single-track reset.
  for track = 1, TRACK_COUNT_MAX do
    local state = self.tracks[track]
    state.next_step_time = nil
    state.remaining_time = nil
    state.play_index = 1
    state.play_page, state.play_step = self:index_to_page_step(1)
    state.pattern_pass = 1
    state.last_cond_result = nil
  end
  self.global_pos = 1
  if self.options.clear_pattern_pending ~= nil then
    self.options.clear_pattern_pending()
  end
  self:sync_play_page_step()
  self:clear_param_lock_holds()
  self:push_active_range(nil, nil)
  local start_point, end_point = self:base_region()
  self:set_region_with_phase(start_point, end_point, 0)
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(nil)
  end
  self:apply_step_pitch(nil)
  if self.options.release_all_slices ~= nil then
    self.options.release_all_slices()
  end
  self:request_redraw()
end

function GridSequencer:set_transport(playing, reset_sequence)
  if playing then
    self:start_sequence(reset_sequence == true)
  elseif reset_sequence then
    self:stop_sequence()
  else
    self:pause_sequence()
  end
end

function GridSequencer:tick_sequence()
  if not self.playing then
    if self.seq_metro ~= nil then
      self.seq_metro:stop()
    end
    return
  end

  local now = util.time()
  if self.seq.next_step_time == nil then
    self.seq.next_step_time = now + self:step_seconds()
  end

  local had_region_hold = self.param_lock_holds.loop_start ~= nil
    or self.param_lock_holds.loop_end ~= nil
  if self:expire_param_lock_holds(now) then
    if self.options.apply_step_param_locks ~= nil then
      self.options.apply_step_param_locks(self:effective_param_locks(nil))
    end
    -- A region/range lock that just expired (note-length window elapsed) means
    -- the active region/range should revert to whatever the remaining layers
    -- resolve to.
    self:apply_active_range()
    if self:machine() == MACHINE_LOOP then
      local region_hold = self.param_lock_holds.loop_start ~= nil
        or self.param_lock_holds.loop_end ~= nil
      local start_point, end_point = self:resolve_active_region()
      if had_region_hold and not region_hold and self.seq_anchor ~= nil
        and not self.live_step_hold and not any_keys(self.loop_holds) then
        -- The region-locking step's window elapsed: the playhead returns to the
        -- main loop per the step's Trig Release mode (Return keeps the main
        -- loop perfectly synced through step overrides).
        self:apply_release_mode(self.seq_release_mode or "return", start_point, end_point, self.seq_anchor)
        self.seq_anchor = nil
      else
        self:set_region(start_point, end_point)
        if not region_hold and not self.live_step_hold and self.seq_anchor ~= nil then
          -- Override ended while live keys were held: the keys' own release
          -- logic owns the playhead from here.
          self.seq_anchor = nil
        end
      end
    end
  end

  local advanced = false
  local guard = 0
  while self.playing and now >= self.seq.next_step_time and guard < 8 do
    self:advance_step()
    -- The step just entered holds for its swing-adjusted duration (PRD §6.5).
    self.seq.next_step_time = self.seq.next_step_time + self:step_duration(self.seq.play_index)
    advanced = true
    guard = guard + 1
  end

  if advanced and self.seq.next_step_time < now then
    self.seq.next_step_time = now + self:step_duration(self.seq.play_index)
  end

  -- Phase 1 track scaffolding: every other active track advances on its own
  -- position/rate (only the selected track is edited/displayed above).
  self:tick_background_tracks(now)

  if self.seq_metro ~= nil then
    self.seq_metro.time = self:metro_interval()
  end
end

-- ---- Background (non-selected) track advancement ---------------------------
-- Each active track keeps its own play position, pass counter and step timing
-- in self.tracks[t]; the shared primitives (step_duration/evaluate_trig) take
-- the track's state/getters instead of being forked. A firing step is handed
-- to the coordinator (options.track_step), which pushes its pitch/region locks
-- to that track's engine chain (tr-prefixed commands; graceful no-ops until
-- the engine half lands).
function GridSequencer:track_param(track, suffix)
  if self.options.get_track_param == nil then
    return nil
  end
  return self.options.get_track_param(track, suffix)
end

function GridSequencer:track_pattern_steps(track)
  local raw = self:track_param(track, "pattern_steps")
  return util.clamp(math.floor((tonumber(raw) or 16) + 0.5), 1, 256)
end

function GridSequencer:tick_background_tracks(now)
  local count = self:active_track_count()
  if count <= 1 then
    return
  end
  for track = 1, count do
    if track ~= self.track then
      local state = self.tracks[track]
      if state.next_step_time == nil then
        -- Freshly resumed (or never primed): honor a parked pause remainder.
        state.next_step_time = now + (state.remaining_time or self:step_duration(state.play_index, state))
        state.remaining_time = nil
      end
      local guard = 0
      while self.playing and now >= state.next_step_time and guard < 8 do
        self:advance_background_track(track, state)
        state.next_step_time = state.next_step_time + self:step_duration(state.play_index, state)
        guard = guard + 1
      end
      if guard > 0 and state.next_step_time < now then
        state.next_step_time = now + self:step_duration(state.play_index, state)
      end
    end
  end
end

function GridSequencer:advance_background_track(track, state)
  state.play_index = state.play_index + 1
  if state.play_index > self:track_pattern_steps(track) then
    state.play_index = 1
    state.pattern_pass = (state.pattern_pass or 1) + 1
  end
  state.play_page, state.play_step = self:index_to_page_step(state.play_index)
  self:enter_background_step(track, state)
end

function GridSequencer:enter_background_step(track, state)
  local record = state.steps[state.play_index]
  if record == nil then
    return
  end
  local machine = util.clamp(math.floor((tonumber(self:track_param(track, "machine")) or 1) + 0.5), 1, 4)
  local active = (is_slice_machine(machine) and table_count(record.slices) > 0)
    or record.trig == true
  if not active then
    return
  end
  local fires = self:evaluate_trig(record, state,
    function() return self:track_param(track, "trig_condition") end,
    function() return self:track_param(track, "trig_chance") end)
  if fires and self.options.track_step ~= nil then
    self.options.track_step(track, record)
  end
end

function GridSequencer:advance_step()
  -- Global pattern boundary (PRD §6.4): as the project-wide cycle wraps, a
  -- pending sequential switch engages or a temp-jump returns. If it does, the
  -- coordinator re-applies a pattern and re-enters step 1 itself (via
  -- on_pattern_applied), so this advance is complete.
  local next_global = (self.global_pos or 1) + 1
  if next_global > self:global_length() then
    self.global_pos = 1
    if self.options.on_global_boundary ~= nil and self.options.on_global_boundary() then
      self:request_redraw()
      return
    end
  else
    self.global_pos = next_global
  end

  self.seq.play_index = self.seq.play_index + 1
  if self.seq.play_index > self:pattern_steps() then
    self.seq.play_index = 1
    -- A new loop of the pattern: bump the pass counter that drives A:B and 1st
    -- trig conditions (PRD §6.5).
    self.seq.pattern_pass = (self.seq.pattern_pass or 1) + 1
  end
  self:sync_play_page_step()
  self:enter_step(false)
  self:request_redraw()
end

-- The coordinator calls this right after loading a pattern's state into the live
-- params/sequencer (PRD §6.3). restart = true re-anchors playback at step 1 (a
-- fresh pattern start); restart = false keeps the current playback position
-- (Direct Jump), clamped into the new pattern's length.
function GridSequencer:on_pattern_applied(restart)
  if restart then
    -- Re-anchor EVERY track at step 1 (a fresh pattern start is pattern-wide).
    for track = 1, TRACK_COUNT_MAX do
      local state = self.tracks[track]
      state.play_index = 1
      state.play_page, state.play_step = self:index_to_page_step(1)
      state.pattern_pass = 1
      state.last_cond_result = nil
    end
    self.global_pos = 1
    self:sync_play_page_step()
    if self.playing then
      self:enter_step(true)
      self.seq.next_step_time = util.time() + self:step_duration(self.seq.play_index)
      self:prime_background_tracks(true)
    end
  else
    -- Direct Jump: keep every track's position, clamped into the new lengths.
    if self.seq.play_index > self:pattern_steps() then
      self.seq.play_index = ((self.seq.play_index - 1) % self:pattern_steps()) + 1
    end
    for track = 1, TRACK_COUNT_MAX do
      if track ~= self.track then
        local state = self.tracks[track]
        local steps = self:track_pattern_steps(track)
        if state.play_index > steps then
          state.play_index = ((state.play_index - 1) % steps) + 1
          state.play_page, state.play_step = self:index_to_page_step(state.play_index)
        end
      end
    end
    if self.global_pos > self:global_length() then
      self.global_pos = ((self.global_pos - 1) % self:global_length()) + 1
    end
    self:sync_play_page_step()
  end
  self:request_redraw()
end

function GridSequencer:screen_edit()
  local index, step = self:held_step_index()
  if index == nil then
    return nil
  end
  local record = self:step_record(index, false)
  return {
    page = self.selected_page,
    step = step,
    index = index,
    trig = record ~= nil and record.trig == true,
    velocity = record ~= nil and record.velocity or self:default_velocity(),
    length = record ~= nil and record.length or self:default_length(),
    pitch = record ~= nil and record.pitch or nil,
    slices = record ~= nil and table_count(record.slices) or 0,
    locks = record ~= nil and table_count(record.param_locks) or 0,
    lock = self:step_lock(self.selected_page, step)
  }
end

function GridSequencer:held_step_is_ghost()
  local index = self:held_step_index()
  if index == nil then
    return false
  end
  return self:is_ghost(self:step_record(index, false))
end

function GridSequencer:screen_status()
  -- CUT/PASTE mode owns the header while STOP is held, so the mode is never
  -- silent -- it says whether the next step tap will cut or paste.
  if self.stop_held then
    return self.cut_buffer ~= nil and "CUT/PASTE - paste" or "CUT/PASTE - cut"
  end
  if self.manual_region ~= nil then
    return "temp " .. format_region(self.manual_region.start_point, self.manual_region.end_point)
  end

  local edit = self:screen_edit()
  if edit ~= nil then
    local record = self:step_record(edit.index, false)
    if Step.has_content(record) then
      return string.format("step %02d vel %03d len %.2f", edit.step, math.floor(edit.velocity * 100 + 0.5), edit.length)
    end
    return string.format("step %02d empty", edit.step)
  end

  return nil
end

function GridSequencer:active_region()
  if self.manual_region ~= nil then
    return self.manual_region.start_point, self.manual_region.end_point
  end

  if self.current_region_start ~= nil then
    return self.current_region_start, self.current_region_end
  end

  return self:base_region()
end

function GridSequencer:handle_page_step(x)
  if self.page_mode == "select" then
    self.selected_page = x
    self:message(string.format("Page %02d", x))
  elseif self.page_mode == "loop" then
    self.seq.page_loop[x] = not self.seq.page_loop[x]
    if not any_keys(self.seq.page_loop) then
      self.seq.page_loop[x] = true
    end
    self:message(string.format("Page %02d %s", x, self.seq.page_loop[x] and "On" or "Off"))
  elseif self.page_mode == "rate" and RATES[x] ~= nil then
    self.seq.rate_index = x
    self:message("Rate " .. rate_label(RATES[x]))
  end
end

function GridSequencer:set_page_mode(mode)
  self.page_mode = mode
  self:message(PAGE_MODE_LABELS[mode] or mode)
end

-- ---- Track select / mute keys (grid row 4, cols 8-15) ----------------------
-- Press = select (the whole editing surface -- steps, params, pages -- follows
-- the selection); FN+press = mute toggle (engine \trMute: a muted track keeps
-- advancing but outputs silence). Cols 1-7/16 of row 4 stay reserved.
local TRACK_KEY_MIN_COL, TRACK_KEY_MAX_COL = 8, 15

function GridSequencer:active_track_count()
  if self.options.get_active_track_count ~= nil then
    return util.clamp(math.floor((self.options.get_active_track_count() or 1) + 0.5), 1, TRACK_COUNT_MAX)
  end
  return 1
end

-- active_track_count dropped below the selection: snap back inside the count
-- (called by the coordinator from the param's action).
function GridSequencer:clamp_track_selection()
  local count = self:active_track_count()
  if self.track > count then
    self:select_track(count)
  end
end

function GridSequencer:select_track(track)
  track = util.clamp(math.floor((tonumber(track) or 1) + 0.5), 1, TRACK_COUNT_MAX)
  if track == self.track then
    return
  end
  -- Any steps physically held right now belong to the OLD track's editing
  -- surface: mark them edited so their release doesn't toggle a step on the
  -- new track.
  for step, held in pairs(self.step_holds) do
    if held then
      self.step_edited[step] = true
    end
  end
  -- Restore any active step-lock bases BEFORE the id funnel moves to the new
  -- track: apply_step_param_locks(nil) writes the stashed base values back
  -- through the coordinator's ui ids, which must still resolve to the OLD
  -- track's params here.
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(nil)
  end
  self.track = track
  self.seq = self.tracks[track]
  -- Live override bookkeeping (param-lock holds, region cache, anchors) was
  -- the old track's; clear it so nothing leaks across the switch. The layered
  -- resolver re-derives the new track's region from its own params/locks.
  self:clear_param_lock_holds()
  self.seq_anchor = nil
  self.keys_anchor = nil
  self.manual_region = nil
  self.current_region_start = nil
  self.current_region_end = nil
  self.current_range_start = nil
  self.current_range_end = nil
  self:sync_play_page_step()
  if self.options.on_track_selected ~= nil then
    self.options.on_track_selected(track)
  end
  self:message("Track " .. track)
  self:request_redraw()
end

function GridSequencer:track_muted(track)
  return self.options.get_track_muted ~= nil and self.options.get_track_muted(track) == true
end

function GridSequencer:key_track(track, z)
  if z ~= 1 then
    return
  end
  if track > self:active_track_count() then
    self:message("Track " .. track .. " off")
    return
  end
  if self.fn_down then
    local mute = not self:track_muted(track)
    if self.options.set_track_mute ~= nil then
      self.options.set_track_mute(track, mute)
      self:message(string.format("Track %d %s", track, mute and "muted" or "unmuted"))
    end
  else
    self:select_track(track)
  end
end

-- Macro keys (row 4, cols 1-4). Holding one routes E2 -> that macro's value
-- and E3 -> its depth (coordinator enc), so you can ride a macro live from any
-- page; with a step ALSO held the value edit p-locks onto the step, exactly
-- like editing a macro param on its page. The key is momentary -- no toggle.
function GridSequencer:key_macro(macro, z)
  if z == 1 then
    self.macro_hold = macro
    self:message(string.format("Macro %d", macro))
  elseif self.macro_hold == macro then
    self.macro_hold = nil
  end
  self:request_redraw()
end

-- Which macro key is held (1-4), or nil. Read by the coordinator's enc().
function GridSequencer:held_macro()
  return self.macro_hold
end

-- Macro-key LEDs (cols 1-4): brightness tracks the macro's value so you can see
-- where each sits; the held one reads brightest. Value comes from the injected
-- getter (0-127) so p-locks/live edits show live.
function GridSequencer:draw_macro_row()
  for macro = 1, 4 do
    local value = self.options.get_macro_value ~= nil and self.options.get_macro_value(macro) or 0
    local level = 3 + math.floor((value / 127) * 8)
    if self.macro_hold == macro then
      level = 15
    end
    self.g:led(macro, 4, self:pressed_level(macro, 4, level))
  end
end

-- Row-4 LEDs: bright = selected, mid = active-but-unselected, off = beyond the
-- active count; muted tracks read dimmer at the same positions.
function GridSequencer:draw_track_row()
  local count = self:active_track_count()
  for track = 1, TRACK_COUNT_MAX do
    local x = track + TRACK_KEY_MIN_COL - 1
    local level = 0
    if track <= count then
      local muted = self:track_muted(track)
      if track == self.track then
        level = muted and 8 or 12
      else
        level = muted and 2 or 6
      end
    end
    self.g:led(x, 4, self:pressed_level(x, 4, level))
  end
end

function GridSequencer:key(x, y, z)
  if x < 1 or x > 16 or y < 1 or y > 8 then
    return
  end

  local key_id = x .. ":" .. y
  self.pressed[key_id] = z == 1 or nil

  -- Universal input router FIRST: an open modal/focus layer claims YES/NO/arrows
  -- (and, if blocking, all keys) before any of the grid's own special-cases --
  -- otherwise the (11,6) YES special-case below would eat YES before a pop-up
  -- (New Project confirm, project browser) or settings action row could see it.
  -- With no focus layer active this returns false and the grid behaves as before.
  if self.options.ui_input ~= nil and self.options.ui_input(x, y, z) then
    self:redraw()
    self:request_redraw()
    return
  end

  if x == 16 and y == 7 then
    self.page_down = z == 1
    self:redraw()
    self:request_redraw()
    return
  end

  -- FILL (16,6): momentary fill while held, FN+press latches. Handled here (not
  -- in the z==1-only navigation path) so it sees key release for the momentary
  -- mode. Gates FILL/!FILL trig conditions (PRD §6.5).
  if x == 16 and y == 6 then
    self:key_fill(z)
    self:redraw()
    self:request_redraw()
    return
  end

  -- YES (11,6): a context key. On the File page it holds-to-preview the sample.
  -- Handled here (not in the z==1-only navigation path) so it sees key release.
  if x == 11 and y == 6 then
    self:key_yes(z)
    self:redraw()
    self:request_redraw()
    return
  end

  -- PATTERN key (8,5): tap latches / hold is momentary for the pattern-load
  -- overlay (PRD §6.2, see key_pattern). FN+press instead opens the
  -- (screen-only) pattern-quantize mode pop-up -- a distinct surface owned by
  -- the coordinator (elasticat.lua), not this grid overlay. The FN check only
  -- gates the press (z==1): the release always reaches key_pattern() so an
  -- overlay opened before FN got held still closes/latches correctly
  -- (key_pattern() is a safe no-op when no (8,5) press session is in flight).
  if x == 8 and y == 5 then
    if z == 1 and self.fn_down then
      if self.options.open_pattern_quantize_menu ~= nil then
        self.options.open_pattern_quantize_menu()
      end
      self:redraw()
      self:request_redraw()
      return
    end
    self:key_pattern(z)
    self:redraw()
    self:request_redraw()
    return
  end

  -- While the pattern-load overlay is open it captures the surface: the bottom
  -- row selects a pattern, Right arrow renames, category keys exit, everything
  -- else is inert (PRD §6.2). Category keys fall through so they act normally.
  if self.pattern_mode and self:key_pattern_mode(x, y, z) then
    self:redraw()
    self:request_redraw()
    return
  end

  if y == 1 and CATEGORY_KEYS[x] ~= nil and z == 1 then
    self:key_category(CATEGORY_KEYS[x])
  elseif y == 1 then
    self:key_controls(x, z)
  elseif self.page_down and y == 8 then
    if z == 1 then
      self:handle_page_step(x)
    end
  elseif is_slice_machine(self:machine()) and (y == 2 or y == 3) then
    self:key_slice_control(x, y, z)
  elseif y == 2 then
    self:key_loop_control(x, z)
  elseif y == 3 and self:loop_division() > 16 then
    self:key_loop_control(x + 16, z)
  elseif y == 8 then
    self:key_step_row(x, z)
  elseif y == 5 and (x == 1 or x == 2) then
    self:key_octave(x, z)
  elseif y == 5 and x >= 9 and x <= 16 then
    self:key_scene(x, z)
  elseif y == 4 and x >= 1 and x <= 4 then
    self:key_macro(x, z)
  elseif y == 4 and x >= TRACK_KEY_MIN_COL and x <= TRACK_KEY_MAX_COL then
    self:key_track(x - TRACK_KEY_MIN_COL + 1, z)
  elseif self:key_pitch_control(x, y, z) then
    -- handled
  elseif z == 1 then
    self:key_navigation(x, y)
  end

  self:redraw()
  self:request_redraw()
end

function GridSequencer:current_category()
  if self.options.current_param_category ~= nil then
    return self.options.current_param_category()
  end
  return nil
end

-- YES key. Context-dependent; only the File-page hold-to-preview is wired so
-- far. Preview itself only engages while master transport is stopped.
function GridSequencer:key_yes(z)
  if self:current_category() == "file" and self.options.set_sample_preview ~= nil then
    self.options.set_sample_preview(z == 1)
  end
end

function GridSequencer:key_category(category)
  local settings_active = self.options.param_settings_active ~= nil and self.options.param_settings_active()
  if settings_active then
    if self.fn_down then
      if self.options.return_to_param_category ~= nil then
        self.options.return_to_param_category(category)
      elseif self.options.close_param_settings ~= nil then
        self.options.close_param_settings()
      end
    else
      -- While the settings layer is open a category key acts ONLY on settings:
      -- switch to that category's settings, or (same category) cycle its
      -- settings pages -- open_param_settings does both. It must NOT also call
      -- select_param_category: that cycles the category's MAIN page underneath,
      -- so leaving settings landed you on a different page than you came from.
      if self.options.open_param_settings ~= nil then
        self.options.open_param_settings(category)
      end
    end
  elseif self.fn_down and self.options.open_param_settings ~= nil then
    self.options.open_param_settings(category)
  elseif self.options.select_param_category ~= nil then
    self.options.select_param_category(category)
  end
end

-- ---- Undo support for step edits ------------------------------------------
-- Snapshot the given step INDICES of the selected track. `false` marks a step
-- that was empty, so restoring can clear it again rather than leaving whatever
-- the edit created.
function GridSequencer:capture_steps(indices)
  local snapshot = {}
  for _, index in ipairs(indices) do
    local record = self.seq.steps[index]
    snapshot[index] = record ~= nil and deep_copy(record) or false
  end
  return snapshot
end

function GridSequencer:restore_steps(snapshot, track)
  local state = (track ~= nil and self.tracks[track]) or self.seq
  if state == nil or snapshot == nil then
    return
  end
  for index, record in pairs(snapshot) do
    state.steps[index] = (record ~= false) and deep_copy(record) or nil
  end
  self:refresh_held_step()
  self:request_redraw()
end

-- Record a step-scope undo entry (gesture-coalesced by `key`, so holding a
-- step and sweeping an encoder is one undo step). Built lazily -- the snapshot
-- only happens when a new gesture actually starts.
function GridSequencer:record_step_undo(key, indices, label)
  if self.options.undo_record == nil or #indices == 0 then
    return
  end
  local track = self.track
  self.options.undo_record(key, function()
    return {kind = "steps", label = label, track = track,
            steps = self:capture_steps(indices)}
  end)
end

-- Every step index on the selected page (for page/pattern scope entries).
function GridSequencer:page_step_indices(page)
  local indices = {}
  for step = 1, 16 do
    indices[#indices + 1] = self:step_index(page or self.selected_page, step)
  end
  return indices
end

function GridSequencer:held_step_indices()
  local indices = {}
  for step, held in pairs(self.step_holds) do
    if held then
      indices[#indices + 1] = self:step_index(self.selected_page, step)
    end
  end
  return indices
end

-- ---- Cut / Paste mode (hold STOP) -----------------------------------------
-- Hold STOP and tap steps to shuffle them around: tapping a step that has
-- content CUTS it (copied to the buffer, then cleared); tapping an empty step
-- PASTES the buffer there. The buffer survives a paste, so repeatedly tapping
-- empty steps keeps dropping the same step in. Tapping another step with
-- content cuts that one instead (replacing the buffer).
function GridSequencer:cut_paste_step(step)
  local index = self:step_index(self.selected_page, step)
  local record = self.seq.steps[index]
  local has_content = record ~= nil and Step.has_content(record)

  self:record_step_undo("cutpaste:" .. index, {index},
    has_content and "cut" or "paste")

  if has_content then
    self.cut_buffer = deep_copy(record)
    self.seq.steps[index] = nil
    self.step_edited[step] = true
    self:message(string.format("Cut step %02d", step))
  elseif self.cut_buffer ~= nil then
    self.seq.steps[index] = deep_copy(self.cut_buffer)
    self.step_edited[step] = true
    self:message(string.format("Paste step %02d", step))
  else
    self:message("Nothing cut")
  end
  self:request_redraw()
end

-- ---- Copy / Clear / Paste (Tonverk manual §6.6/§10.10.4/§19) ---------------
-- The REC/PLAY/STOP transport keys double as COPY/CLEAR/PASTE when a scope
-- modifier is held, exactly like an Elektron box:
--   hold STEP(s) + REC/PLAY/STOP  = copy / clear-locks / paste trigs
--   hold PAGE    + REC/PLAY/STOP  = copy / clear / paste the selected page
--   hold FN      + REC/PLAY/STOP  = copy / clear(confirm) / paste the pattern
-- Each scope has its own buffer (self.clipboard.steps/page/pattern), so a
-- copied step never clobbers a copied pattern. With no modifier held the keys
-- stay plain transport.

-- Copy every held step, anchored at the lowest held key: entries store the
-- offset from that anchor so a multi-step copy pastes "in the same relation to
-- each other" (Tonverk p.46) from whatever step anchors the paste.
function GridSequencer:copy_held_steps()
  local held = sorted_held_keys(self.step_holds)
  if #held == 0 then
    return
  end
  local entries = {}
  for _, step in ipairs(held) do
    local record = self:step_record_for_page_step(self.selected_page, step, false)
    entries[#entries + 1] = {
      offset = step - held[1],
      record = record ~= nil and deep_copy(record) or nil
    }
  end
  self.clipboard.steps = entries
  self:message(#held == 1 and string.format("Step %02d copied", held[1])
    or string.format("%d steps copied", #held))
end

function GridSequencer:paste_on_held_steps()
  local entries = self.clipboard.steps
  if entries == nil then
    self:message("Nothing copied")
    return
  end
  -- Snapshot every step the paste can land on (anchor + each entry's offset).
  local touched = {}
  for step, down in pairs(self.step_holds) do
    if down then
      for _, entry in ipairs(entries) do
        local target = step + entry.offset
        if target >= 1 and target <= 16 then
          touched[#touched + 1] = self:step_index(self.selected_page, target)
        end
      end
    end
  end
  self:record_step_undo("paste_steps", touched, "paste")
  local pasted = 0
  for step, down in pairs(self.step_holds) do
    if down then
      for _, entry in ipairs(entries) do
        local target = step + entry.offset
        -- Overflow past the page edge is dropped, same as pasting a trig run
        -- near the end of a pattern on the reference boxes.
        if target >= 1 and target <= 16 then
          self.seq.steps[self:step_index(self.selected_page, target)] =
            entry.record ~= nil and deep_copy(entry.record) or nil
          pasted = pasted + 1
        end
      end
    end
  end
  if pasted > 0 then
    self:message("Pasted")
    self:refresh_held_step()
  end
end

-- CLEAR on a held trig removes its parameter locks but keeps the trig itself
-- (Tonverk p.79: "[TRIG] + [PLAY] to clear all parameter locks on the trig").
function GridSequencer:clear_held_step_locks()
  for step, down in pairs(self.step_holds) do
    if down then
      local record = self:step_record_for_page_step(self.selected_page, step, false)
      if record ~= nil then
        record.pitch = nil
        record.length = nil
        record.velocity = nil
        record.param_locks = {}
      end
    end
  end
  self:message("Locks cleared")
  self:refresh_held_step()
end

-- Page scope: the 16 records of the currently-selected page.
function GridSequencer:copy_selected_page()
  local page = {}
  for step = 1, 16 do
    local record = self:step_record_for_page_step(self.selected_page, step, false)
    page[step] = record ~= nil and deep_copy(record) or nil
  end
  self.clipboard.page = page
  self:message(string.format("Page %d copied", self.selected_page))
end

function GridSequencer:paste_selected_page()
  local page = self.clipboard.page
  if page == nil then
    self:message("Nothing copied")
    return
  end
  self:record_step_undo("paste_page", self:page_step_indices(), "paste page")
  for step = 1, 16 do
    self.seq.steps[self:step_index(self.selected_page, step)] =
      page[step] ~= nil and deep_copy(page[step]) or nil
  end
  self:message(string.format("Pasted to page %d", self.selected_page))
end

function GridSequencer:clear_selected_page()
  self:record_step_undo("clear_page", self:page_step_indices(), "clear page")
  for step = 1, 16 do
    self.seq.steps[self:step_index(self.selected_page, step)] = nil
  end
  self:message(string.format("Page %d cleared", self.selected_page))
end

-- Pattern scope: buffer/apply via the coordinator (whole pattern snapshot:
-- sequence + per-pattern params). CLEAR wipes only the trigs, behind the same
-- YES-confirm popup the reference box shows.
function GridSequencer:copy_pattern()
  if self.options.copy_pattern_state ~= nil then
    self.clipboard.pattern = self.options.copy_pattern_state()
    self:message("Pattern copied")
  end
end

function GridSequencer:paste_pattern()
  if self.clipboard.pattern == nil then
    self:message("Nothing copied")
    return
  end
  if self.options.paste_pattern_state ~= nil then
    self.options.paste_pattern_state(self.clipboard.pattern)
    self:message("Pattern pasted")
  end
end

function GridSequencer:clear_pattern_trigs()
  local function wipe()
    self.seq.steps = {}
    self:message("Pattern cleared")
    self:request_redraw()
  end
  if self.options.open_confirm ~= nil then
    self.options.open_confirm("Clear pattern?", wipe)
  else
    wipe()
  end
end

function GridSequencer:key_controls(x, z)
  if x == 1 then
    self.fn_down = z == 1
    return
  end

  -- STOP doubles as the CUT/PASTE modifier (hold it, tap steps). Its transport
  -- action therefore fires on RELEASE, and only if the hold wasn't used to
  -- shuffle steps -- so a tap still stops, but shuffling never kills playback.
  if x == 5 and not any_keys(self.step_holds) then
    if z == 1 then
      self.stop_held = true
      self.stop_used = false
      self:request_redraw()
      return
    end
    self.stop_held = false
    local used = self.stop_used
    self.stop_used = false
    self:request_redraw()
    if used then
      return
    end
    if self.options.set_playing ~= nil then
      self.options.set_playing(false, true)
    end
    return
  end

  if z ~= 1 or (x ~= 3 and x ~= 4 and x ~= 5) then
    return
  end

  -- Copy/Clear/Paste scopes, most specific modifier first.
  if any_keys(self.step_holds) then
    -- Editing gesture: don't let release toggle the held trigs off.
    for step, down in pairs(self.step_holds) do
      if down then
        self.step_edited[step] = true
      end
    end
    if x == 3 then
      self:copy_held_steps()
    elseif x == 4 then
      self:clear_held_step_locks()
    else
      self:paste_on_held_steps()
    end
    self:request_redraw()
    return
  end
  if self.page_down then
    if x == 3 then
      self:copy_selected_page()
    elseif x == 4 then
      self:clear_selected_page()
    else
      self:paste_selected_page()
    end
    self:request_redraw()
    return
  end
  if self.fn_down then
    if x == 3 then
      self:copy_pattern()
    elseif x == 4 then
      self:clear_pattern_trigs()
    else
      self:paste_pattern()
    end
    self:request_redraw()
    return
  end

  -- Plain transport.
  if x == 3 then
    self.recording = not self.recording
    self:message(self.recording and "Record On" or "Record Off")
  elseif x == 4 then
    if self.options.set_playing ~= nil then
      self.options.set_playing(not self.playing, false)
    end
  elseif x == 5 then
    if self.options.set_playing ~= nil then
      self.options.set_playing(false, true)
    end
  end
end

function GridSequencer:key_navigation(x, y)
  if self.options.param_settings_active ~= nil and self.options.param_settings_active() then
    if x == 11 and y == 7 then
      if self.options.close_param_settings ~= nil then
        self.options.close_param_settings()
      end
    elseif x == 13 and y == 6 then
      if self.options.param_settings_select_delta ~= nil then
        self.options.param_settings_select_delta(-1)
      end
    elseif x == 13 and y == 7 then
      if self.options.param_settings_select_delta ~= nil then
        self.options.param_settings_select_delta(1)
      end
    elseif x == 12 and y == 7 then
      if self.options.param_settings_value_delta ~= nil then
        self.options.param_settings_value_delta(-1)
      end
    elseif x == 14 and y == 7 then
      if self.options.param_settings_value_delta ~= nil then
        self.options.param_settings_value_delta(1)
      end
    end
    return
  end

  -- NO outside the settings layer / menus: quick undo. It has no other job
  -- here, and it is the escape hatch for "I brushed the crossfader and lost
  -- the values I had just dialed in".
  if x == 11 and y == 7 then
    if self.options.undo ~= nil then
      self.options.undo()
    end
    return
  end

  if not self.page_down then
    if x == 13 and y == 6 then
      if self.options.select_param_page_delta ~= nil then
        self.options.select_param_page_delta(-1)
      end
    elseif x == 13 and y == 7 then
      if self.options.select_param_page_delta ~= nil then
        self.options.select_param_page_delta(1)
      end
    end
    return
  end

  if x == 13 and y == 6 then
    self:set_page_mode("select")
  elseif x == 13 and y == 7 then
    self:set_page_mode("loop")
  elseif x == 12 and y == 7 then
    self:set_page_mode("rate")
  elseif x == 14 and y == 7 then
    self:set_page_mode("select")
  end
end

function GridSequencer:key_octave(x, z)
  if z ~= 1 then
    return
  end
  -- FN+Octave = RAM Memorize/Recall (PRD §7.2): FN+(1,5) recalls the RAM
  -- project snapshot, FN+(2,5) memorizes the current state. Playback-safe.
  if self.fn_down then
    if x == 1 and self.options.ram_recall ~= nil then
      self.options.ram_recall()
    elseif x == 2 and self.options.ram_memorize ~= nil then
      self.options.ram_memorize()
    end
    return
  end
  if x == 1 then
    self.keyboard_octave = util.clamp(self.keyboard_octave - 1, -2, 2)
  elseif x == 2 then
    self.keyboard_octave = util.clamp(self.keyboard_octave + 1, -2, 2)
  end
  self:message(string.format("Oct %+d", self.keyboard_octave))
end

function GridSequencer:key_pitch_value(x, y)
  local semitone = nil
  if y == 7 then
    semitone = WHITE_KEYS[x]
  elseif y == 6 then
    semitone = BLACK_KEYS[x]
  end
  if semitone == nil then
    return nil
  end
  return semitone + (self.keyboard_octave * 12)
end

function GridSequencer:key_pitch_control(x, y, z)
  local pitch = self:key_pitch_value(x, y)
  if pitch == nil then
    return false
  end
  if z == 1 then
    local index, step = self:held_step_index()
    if index ~= nil then
      self:set_step_pitch(index, pitch)
      self.step_edited[step] = true
      self:message(string.format("Step %02d Pitch %+d", step, pitch))
    elseif self.options.set_pitch_param ~= nil then
      self.options.set_pitch_param(pitch)
      self:message(string.format("Pitch %+d", pitch))
    elseif self.options.set_pitch ~= nil then
      self.options.set_pitch(pitch)
      self:message(string.format("Pitch %+d", pitch))
    end
  end
  return true
end

-- A step's region lock counts as "currently triggering" while its param lock
-- (loop_start) hasn't expired yet -- see effective_param_locks/note_seconds.
-- This is only as accurate as that per-lock expiry bookkeeping (there's no
-- continuous mid-window tracking beyond it yet), but it's the same signal the
-- rest of the lock system already relies on.
function GridSequencer:step_trigger_active()
  self:expire_param_lock_holds(util.time())
  return self.param_lock_holds.loop_start ~= nil
end

function GridSequencer:live_performance_mode()
  if self.options.get_live_performance_mode ~= nil then
    return self.options.get_live_performance_mode() == true
  end
  return false
end

function GridSequencer:step_preview_enabled()
  if self.options.get_step_preview ~= nil then
    return self.options.get_step_preview() == true
  end
  return true
end

-- A held step audibly previews only when it is a real trigger (not empty, not a
-- ghost). Empty steps must stay silent even while held. (Ghost steps -- task
-- #23 -- will read record.ghost here once they exist.)
function GridSequencer:any_previewable_step_held()
  for step, held in pairs(self.step_holds) do
    if held then
      local record = self:step_record_for_page_step(self.selected_page, step, false)
      if record ~= nil and record.trig == true and not self:is_ghost(record) then
        return true
      end
    end
  end
  return false
end

-- While the sequencer is stopped, holding a loop key or a previewable step
-- should audibly preview the sample -- independent of the K3 transport, the
-- same way slice-machine hold-to-play already works. Once the sequencer is
-- running, playback belongs to the transport and this leaves it alone.
function GridSequencer:update_preview_state()
  if self.options.play == nil then
    return
  end
  if self.playing then
    self.preview_active = false
    return
  end
  local should_preview = self:step_preview_enabled()
    and (any_keys(self.loop_holds) or self:any_previewable_step_held())
  if should_preview and not self.preview_active then
    self.preview_active = true
    self.options.play(true)
    -- Open the amp envelope indefinitely so the preview sustains while held
    -- (engine noteOff): the matching note_off below closes the gate cleanly.
    if not is_slice_machine(self:machine()) and self.options.note_on ~= nil then
      self.options.note_on(0)
    end
  elseif not should_preview and self.preview_active then
    self.preview_active = false
    if self.options.note_off ~= nil then
      self.options.note_off()
    end
    self.options.play(false)
  end
end

-- 1=Return, 2=Boomerang (default), 3=Reset. Governs where the playhead goes
-- when the last live loop key is released during playback.
function GridSequencer:playhead_return_mode()
  local raw = self.options.get_playhead_return ~= nil and self.options.get_playhead_return() or 2
  raw = math.floor((tonumber(raw) or 2) + 0.5)
  if raw == 1 then return "return" end
  if raw == 3 then return "reset" end
  return "boomerang"
end

-- Apply the loop-key layer to the active region. Held keys always win the
-- region (live gesture beats the sequenced layer), so a fresh press always
-- audition-jumps to the new region start; while stopped it drives playback
-- directly.
function GridSequencer:apply_loop_key_region(is_press)
  local key_start = select(1, self:loop_region_from_holds(self.loop_holds))
  local start_point, end_point = self:resolve_active_region()

  if key_start ~= nil then
    self.manual_region = { start_point = start_point, end_point = end_point }
    if is_press then
      if self.playing then
        -- Live performance: morph the region around the current playhead WITHOUT
        -- a phase-0 restart. Snapping the playhead to the region start re-attacks
        -- the sample and reads as a spurious "envelope trigger" while playing;
        -- instead keep playing from the current position and only warp to the
        -- start when the playhead now falls outside the new region. While stopped
        -- the jump-to-start IS the preview attack we want, so keep it there.
        self:set_region_within_or_warp(start_point, end_point)
      else
        self:set_region_with_phase(start_point, end_point, 0)
      end
    else
      self:set_region(start_point, end_point)
    end
  else
    -- No loop keys held any more.
    self.manual_region = nil
    if self.playing then
      self:apply_loop_release_playhead(start_point, end_point)
    else
      self:set_region(start_point, end_point)
    end
  end
end

-- Snapshot of where the playhead is (and the region it's in) at the moment an
-- override begins -- a live loop-key performance, a region-locking step, or a
-- live-held step. Return mode later uses it to land where the main loop would
-- naturally be if the override never happened.
function GridSequencer:make_anchor()
  return {
    start_point = self.current_region_start,
    end_point = self.current_region_end,
    pos = self:current_absolute_position(),
    time = util.time()
  }
end

-- The anchor position advanced at the anchored region's own rate: where the
-- main loop would be now had it just kept playing. nil when unavailable.
-- (Assumes the anchored region's rate didn't change during the override.)
function GridSequencer:natural_phase_from(anchor)
  if anchor == nil or anchor.pos == nil or anchor.start_point == nil
    or self.options.get_loop_rate == nil then
    return nil
  end
  local width = math.max(0.01, anchor.end_point - anchor.start_point)
  local anchor_phase = ((anchor.pos - anchor.start_point) / width) % 1
  local rate = self.options.get_loop_rate(anchor.start_point, anchor.end_point) or 0
  local dir = (self.options.get_playhead_direction ~= nil and self.options.get_playhead_direction()) or 1
  local elapsed = util.time() - (anchor.time or util.time())
  return (anchor_phase + (dir * elapsed * rate)) % 1
end

-- Shared release behavior for every override layer (live keys, sequenced steps,
-- live-held steps): where the playhead lands in the region playback reverts to.
function GridSequencer:apply_release_mode(mode, start_point, end_point, anchor)
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
    -- Boomerang: keep going from the override's position (absolute position
    -- preserved across the region change).
    self:set_region_preserve_position(start_point, end_point)
  end
end

-- The last live loop key was released during playback. The playhead-return mode
-- decides where the playhead lands in the region the sequencer/track resolve to.
function GridSequencer:apply_loop_release_playhead(start_point, end_point)
  local mode = self:playhead_return_mode()
  self:message("PH " .. mode)
  self:apply_release_mode(mode, start_point, end_point, self.keys_anchor)
  self.keys_anchor = nil
end

function GridSequencer:live_step_trig_enabled()
  return self.options.get_live_step_trig ~= nil and self.options.get_live_step_trig() == true
end

-- Live Step Trig: while playing, holding a step fires it immediately and it
-- owns playback for the duration of the hold -- sequenced steps advance
-- silently (see enter_step) and the step's note length is ignored (its locks
-- are pinned until release). Loop machines only; slice machines already have
-- hold-to-play slice keys.
function GridSequencer:begin_live_step(step)
  if is_slice_machine(self:machine()) then
    return
  end
  local record = self:step_record(self:step_index(self.selected_page, step), false)
  if record == nil or record.trig ~= true then
    return
  end
  if self.seq_anchor == nil then
    self.seq_anchor = self:make_anchor()
  end
  self.seq_release_mode = self:step_release_mode(record)
  self.live_step_index = step
  self.live_step_hold = true

  if self:trig_polyphony() == 1 and not self:is_ghost(record) then
    self:clear_param_lock_holds()
  end
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(self:effective_param_locks(record))
  end
  -- No note-length window while held: pin this step's own locks until release.
  for lock_id in pairs(record.param_locks or {}) do
    if self.param_lock_holds[lock_id] ~= nil then
      self.param_lock_holds[lock_id].expires_at = math.huge
    end
  end
  self:apply_step_pitch(record)
  self:apply_active_range()
  if not self:is_ghost(record) and self.options.note_on ~= nil then
    -- Indefinite hold (engine noteOff, PRD §8): the gate stays open until
    -- end_live_step sends note_off on key release -- a real ADSR release
    -- instead of the old 3600s timed-gate hack.
    self.options.note_on(0)
  end
  local record_locks_region = record.param_locks ~= nil
    and (record.param_locks.loop_start ~= nil or record.param_locks.loop_end ~= nil)
  if record_locks_region then
    local start_point, end_point = self:resolve_active_region()
    if self:trig_jump_active(record) then
      self:set_region_with_phase(start_point, end_point, 0)
    else
      self:set_region_within_or_warp(start_point, end_point)
    end
  end
end

function GridSequencer:end_live_step()
  self.live_step_hold = false
  self.live_step_index = nil
  -- Close the held note's gate (engine noteOff): the amp/filter envelopes
  -- enter their release stage NOW, matching the finger lift. Fired before the
  -- playing check so a stop-while-held never leaves a gate open.
  if self.options.note_off ~= nil then
    self.options.note_off()
  end
  if not self.playing then
    return
  end
  -- The held note ends: clear its pinned locks, revert params/pitch/range, and
  -- release the playhead per the step's Trig Release mode.
  self:clear_param_lock_holds()
  if self.options.apply_step_param_locks ~= nil then
    self.options.apply_step_param_locks(nil)
  end
  self:apply_step_pitch(nil)
  self:apply_active_range()
  local start_point, end_point = self:resolve_active_region()
  if self.seq_anchor ~= nil and not any_keys(self.loop_holds) then
    self:apply_release_mode(self.seq_release_mode or "return", start_point, end_point, self.seq_anchor)
  else
    self:set_region(start_point, end_point)
  end
  self.seq_anchor = nil
end

function GridSequencer:key_loop_control(x, z)
  self.loop_key_programming = self.loop_key_programming or {}
  if z == 1 then
    local programming = any_keys(self.step_holds)
    local first_key = not any_keys(self.loop_holds)
    self.loop_key_programming[x] = programming or nil
    self.loop_holds[x] = true
    if programming then
      -- Holding a step: loop keys program that step's region lock (tap-cycle)
      -- and never drive the live region -- the lock only sounds when the step
      -- triggers. While stopped, the preview re-plays the step's own locks so
      -- what you hear tracks the lock state (start-only vs start+end).
      local start_point, end_point, held_count = self:loop_region_from_holds(self.loop_holds)
      if start_point ~= nil then
        self:lock_held_steps(start_point, end_point, held_count)
      end
      -- retrigger = true: pressing a loop key while holding a step re-auditions
      -- the stopped preview from the top (fresh attack) so the new lock is heard
      -- at once. Ignored during playback (refresh_held_step routes there).
      self:refresh_held_step(true)
    else
      if self.playing and first_key then
        self.keys_anchor = self:make_anchor()  -- start of a live performance
      end
      self:apply_loop_key_region(true)
    end
  else
    local programming = self.loop_key_programming[x] == true
    self.loop_key_programming[x] = nil
    self.loop_holds[x] = nil
    if programming then
      self:refresh_held_step()
    else
      self:apply_loop_key_region(false)
    end
  end
  self:update_preview_state()
end

function GridSequencer:key_slice_control(x, y, z)
  local slice = x + (y == 3 and 16 or 0)
  if slice > self:slice_count() then
    return
  end

  local index, step = self:held_step_index()
  if index ~= nil then
    if z == 1 then
      self:toggle_step_slice(index, slice)
      self.step_edited[step] = true
      self:message(string.format("Step %02d Slice %02d", step, slice))
    end
    return
  end

  if z == 1 then
    self.slice_holds[slice] = true
    if self.options.trigger_slice ~= nil then
      local start_point, end_point = self:slice_range(slice)
      local mode = self.options.get_slice_play_mode ~= nil and self.options.get_slice_play_mode() or 1
      local length_seconds = (mode >= 3) and 60 or 0
      self.options.trigger_slice(slice, start_point, end_point, {
        velocity = 1,
        length_seconds = length_seconds,
        pitch = self:base_pitch(),
        manual = true
      })
      self:mark_region_current(start_point, end_point)
    end
  else
    self.slice_holds[slice] = nil
    local mode = self.options.get_slice_play_mode ~= nil and self.options.get_slice_play_mode() or 1
    if mode ~= 1 and self.options.release_slice ~= nil then
      self.options.release_slice(slice)
    end
  end
end

function GridSequencer:key_step_row(x, z)
  -- CUT/PASTE mode (STOP held) owns the step row entirely.
  if self.stop_held then
    if z == 1 then
      self.stop_used = true
      self:cut_paste_step(x)
    end
    return
  end
  if z == 1 then
    self.step_holds[x] = true
    self.step_press_time[x] = util.time()
    self.step_edited[x] = false
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    if self.playing then
      -- During playback a held step is inert unless Live Step Trig is on:
      -- auditioning its locked region live yanked the engine region under the
      -- playing loop and popped.
      if self:live_step_trig_enabled() then
        self:begin_live_step(x)
      end
    else
      local lock = self:step_lock(self.selected_page, x)
      if lock ~= nil and lock.end_point ~= nil then
        self:set_region(lock.start_point, lock.end_point)
      end
      if self:step_preview_enabled() then
        local record = self:step_record(self:step_index(self.selected_page, x), false)
        -- Ghost steps reset nothing (no start, no region), so there is nothing to
        -- preview -- skip them, same as sequenced playback carries through them.
        if record ~= nil and record.trig == true and not self:is_ghost(record) then
          -- Apply the step's Step Range before setting the region so the preview
          -- plays the step's range window, not the whole trim.
          local locks = record.param_locks or {}
          self:push_active_range(locks.range_start, locks.range_end)
          local start_point, end_point = self:locked_region(record)
          self:set_region_with_phase(start_point, end_point, 0)
          self:apply_step_pitch(record)
        end
      end
    end
  else
    local press_time = self.step_press_time[x] or util.time()
    local was_quick_press = (util.time() - press_time) < STEP_HOLD_SECONDS
    local was_edited = self.step_edited[x] == true
    self.step_holds[x] = nil
    self.step_press_time[x] = nil
    self.step_edited[x] = nil
    self.loop_tap_key = nil
    self.loop_tap_kind = nil
    if was_quick_press and not was_edited then
      -- Snapshot BEFORE the toggle so undo can bring back a step you just
      -- tapped away (the whole record, p-locks included).
      local index = self:step_index(self.selected_page, x)
      self:record_step_undo("toggle:" .. index, {index}, "step " .. string.format("%02d", x))
      if self.fn_down then
        self:toggle_ghost_step(self.selected_page, x)
      else
        self:toggle_step(self.selected_page, x)
      end
    end
    if self.live_step_index == x then
      self:end_live_step()
    end
    if not any_keys(self.step_holds) and not any_keys(self.loop_holds)
      and not self.playing then
      -- Stopped: restore the base region/range/pitch after a preview or
      -- lock-audition hold. During playback the sequencer owns the region.
      self:push_active_range(nil, nil)
      local base_start, base_end = self:base_region()
      self:set_region(base_start, base_end)
      self:apply_step_pitch(nil)
    end
  end
  self:update_preview_state()
end

function GridSequencer:adjust_held_step(field, delta)
  local index, step = self:held_step_index()
  if index == nil then
    return false
  end

  local record = self:step_record(index, true)
  record.trig = true
  if field == "velocity" then
    record.velocity = util.clamp((record.velocity or self:default_velocity()) + (delta * 0.01), 0, 1)
    record.param_locks.velocity = record.velocity
  elseif field == "length" then
    record.length = util.clamp((record.length or self:default_length()) + (delta * 0.25), 0.25, 16)
    record.param_locks.length = record.length
  else
    return false
  end
  self.step_edited[step] = true
  self:request_redraw()
  return true
end

function GridSequencer:pressed_level(x, y, base)
  if self.pressed[x .. ":" .. y] then
    return 15
  end
  return base
end

function GridSequencer:draw_loop_lock(lock, level)
  if lock == nil then
    return
  end
  local division = self:loop_division()
  local units = self:loop_units_per_key()
  local start_key = util.clamp(math.floor(lock.start_point / units) + 1, 1, division)
  local end_key = lock.end_point ~= nil and util.clamp(math.ceil(lock.end_point / units), 1, division) or start_key
  for key_index = start_key, end_key do
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, level)
  end
end

function GridSequencer:draw_loop_row()
  local division = self:loop_division()
  for key_index = 1, division do
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, 2)
  end

  local held_step = self:first_held_step()
  if held_step ~= nil then
    self:draw_loop_lock(self:step_lock(self.selected_page, held_step), 9)
  end

  self:draw_loop_lock(self.manual_region, 10)

  for key_index, held in pairs(self.loop_holds) do
    if held then
      local gx, gy = self:loop_key_position(key_index)
      self.g:led(gx, gy, 15)
    end
  end

  -- Playhead only while actually playing; a stopped preview would show it static.
  if self.playing and self.options.phase ~= nil then
    local start_point, end_point = self:active_region()
    local phase = self.options.phase() or 0
    local position = start_point + ((end_point - start_point) * phase)
    local units = self:loop_units_per_key()
    local key_index = util.clamp(math.floor(position / units) + 1, 1, division)
    local gx, gy = self:loop_key_position(key_index)
    self.g:led(gx, gy, 12)
  end
end

function GridSequencer:draw_slice_rows()
  local count = self:slice_count()
  local held_step = self:first_held_step()
  local held_record = held_step ~= nil and self:step_record_for_page_step(self.selected_page, held_step, false) or nil
  local play_record = self.playing and self:step_record(self.seq.play_index, false) or nil

  for slice = 1, count do
    local row = slice <= 16 and 2 or 3
    local x = ((slice - 1) % 16) + 1
    local level = 3
    if held_record ~= nil and held_record.slices ~= nil and held_record.slices[slice] then
      level = 9
    end
    if play_record ~= nil and play_record.slices ~= nil and play_record.slices[slice] then
      level = 12
    end
    if self.slice_holds[slice] then
      level = 15
    end
    self.g:led(x, row, self:pressed_level(x, row, level))
  end
end

function GridSequencer:draw_keyboard()
  if self.fn_down then
    -- FN held: octave keys read as RAM Recall (1,5) / Memorize (2,5). Recall
    -- only lights up once a snapshot exists (PRD §7.2).
    local ram = self.options.ram_has ~= nil and self.options.ram_has()
    self.g:led(1, 5, self:pressed_level(1, 5, ram and 12 or 3))
    self.g:led(2, 5, self:pressed_level(2, 5, 12))
  else
    self.g:led(1, 5, self:pressed_level(1, 5, self.keyboard_octave < 0 and 9 or 3))
    self.g:led(2, 5, self:pressed_level(2, 5, self.keyboard_octave > 0 and 9 or 3))
  end
  -- Pattern-load key: bright while the overlay is open (PRD §6.2).
  self.g:led(8, 5, self:pressed_level(8, 5, self.pattern_mode and 15 or 3))

  -- A/B scene crossfader (row 5, centered): A anchor col 10, B anchor col 16
  -- (bright while held for scene-locking, mid when their scene holds locks, dim
  -- otherwise); fader keys 11-15 show the position (nearest key bright, its
  -- neighbor scaled by proximity, so the eased glide reads as a sweep). Col 9
  -- is unused. Position is global and can move from the MASTER-page encoder, so
  -- refresh from the coordinator every draw.
  if self.options.get_crossfade ~= nil then
    self.crossfade = self.options.get_crossfade()
  end
  self.g:led(9, 5, self:pressed_level(9, 5, 0))
  for x = 10, 16 do
    local level
    if x == 10 or x == 16 then
      local scene = x == 10 and 1 or 2
      local held = self.pressed[x .. ":5"] == true
      local has = self.options.scene_has ~= nil and self.options.scene_has(scene)
      level = held and 15 or (has and 8 or 4)
    else
      -- Fader keys 11..15 map 0..1; nearest to the position is brightest.
      local pos_key = 11 + (self.crossfade or 0) * 4  -- fractional key position
      local distance = math.abs(x - pos_key)
      level = distance < 0.5 and 15 or (distance < 1.5 and 6 or 2)
    end
    self.g:led(x, 5, self:pressed_level(x, 5, level))
  end

  local current_pitch = self:base_pitch()
  local edit = self:screen_edit()
  if edit ~= nil and edit.pitch ~= nil then
    current_pitch = edit.pitch
  end

  for x, semitone in pairs(BLACK_KEYS) do
    local pitch = semitone + (self.keyboard_octave * 12)
    local level = math.abs(pitch - current_pitch) < 0.001 and 10 or 3
    self.g:led(x, 6, self:pressed_level(x, 6, level))
  end

  for x, semitone in pairs(WHITE_KEYS) do
    local pitch = semitone + (self.keyboard_octave * 12)
    local level = math.abs(pitch - current_pitch) < 0.001 and 10 or 3
    self.g:led(x, 7, self:pressed_level(x, 7, level))
  end
end

function GridSequencer:draw_category_keys()
  local current_category = self.options.current_param_category ~= nil and self.options.current_param_category() or nil
  local settings_active = self.options.param_settings_active ~= nil and self.options.param_settings_active() or false
  local on_subpage = self.options.on_param_subpage ~= nil and self.options.on_param_subpage() or false
  -- Subpage indicator: the active category's key fades 5 <-> its lit level at
  -- ~2Hz whenever a sub-page (param page > 1 or settings page > 1) is showing.
  local fade = 1
  if on_subpage then
    local phase = (util.time() * 2) % 1  -- 0..1 at 2Hz
    fade = phase < 0.5 and (phase * 2) or ((1 - phase) * 2)  -- triangle 0..1..0
  end
  for x, category in pairs(CATEGORY_KEYS) do
    local level = 3
    if category == current_category then
      local target = settings_active and 14 or 10
      level = on_subpage and math.floor(5 + (target - 5) * fade + 0.5) or target
    end
    self.g:led(x, 1, self:pressed_level(x, 1, level))
  end
end

function GridSequencer:redraw()
  if self.g == nil then
    return
  end

  self.g:all(0)
  self:draw_normal_leds()
  self.g:refresh()
end

-- Draws the full normal control surface (no all(0)/refresh -- caller frames it),
-- so the visualizer page can render the keys and then overlay the comet sweep.
function GridSequencer:draw_normal_leds()
  self.g:led(1, 1, self:pressed_level(1, 1, 3))
  self.g:led(3, 1, self:pressed_level(3, 1, self.recording and 12 or 3))
  self.g:led(4, 1, self:pressed_level(4, 1, self.playing and 13 or 4))
  -- STOP is full-bright while held as the CUT/PASTE modifier.
  self.g:led(5, 1, self:pressed_level(5, 1,
    self.stop_held and 15 or (self.playing and 4 or 13)))
  self:draw_category_keys()

  if is_slice_machine(self:machine()) then
    self:draw_slice_rows()
  else
    self:draw_loop_row()
  end

  self:draw_keyboard()
  self:draw_macro_row()
  self:draw_track_row()

  -- Nav arrows / YES / NO sit at a uniform dim base and only brighten when
  -- pressed. The page-mode tint (which mode is active) shows ONLY while the
  -- PAGE key is held -- that's the only time these keys pick a page mode --
  -- rather than lighting the default "select" indicator all the time.
  self.g:led(11, 6, self:pressed_level(11, 6, 2))
  self.g:led(11, 7, self:pressed_level(11, 7, 2))
  self.g:led(12, 7, self:pressed_level(12, 7, (self.page_down and self.page_mode == "rate") and 8 or 3))
  self.g:led(13, 7, self:pressed_level(13, 7, (self.page_down and self.page_mode == "loop") and 8 or 3))
  self.g:led(14, 7, self:pressed_level(14, 7, 3))
  self.g:led(13, 6, self:pressed_level(13, 6, (self.page_down and self.page_mode == "select") and 8 or 3))
  self.g:led(16, 7, self:pressed_level(16, 7, self.page_down and 15 or 5))
  -- Fill key: bright while fill is engaged (latched or held), dim otherwise.
  self.g:led(16, 6, self:pressed_level(16, 6, self.fill_active and 15 or 3))

  if self.pattern_mode then
    self:draw_pattern_row()
  elseif self.page_down then
    self:draw_page_row()
  else
    self:draw_step_row()
  end
end

local INTRO_SWEEP_PERIOD = 2.0  -- seconds for one comet sweep across the grid

-- Randomize the 8 comet bars (one per grid row): each gets a random width, entry
-- delay, and speed so the sweep flies in from the left and exits within ~2s.
-- (Caller seeds the RNG once at start; we don't reseed per roll.)
function GridSequencer:roll_intro_bars()
  self.intro_bars = {}
  for row = 1, 8 do
    local length = math.random(8, 16)        -- bar width in grid columns
    local delay = math.random() * 0.5        -- staggered entry within 0.5s
    local cross = 1.0 + math.random() * 0.5  -- 1.0-1.5s to fully cross + exit
    self.intro_bars[row] = {
      length = length,
      delay = delay,
      speed = (16 + length) / cross          -- columns/sec
    }
  end
end

-- Draw the comet bars for local sweep time `t`, compositing over an optional cat
-- base frame (INTRO_CAT row/col levels). Where a bar covers a cell it overwrites
-- the base, so the base is revealed in the bars' wake. Caller does all(0)/refresh.
function GridSequencer:draw_sweep_bars(t, cat)
  for row = 1, 8 do
    local bar = self.intro_bars and self.intro_bars[row]
    local head = nil
    if bar ~= nil then
      local local_t = t - bar.delay
      if local_t > 0 then
        head = local_t * bar.speed             -- leading edge, moving right
      end
    end
    for x = 1, 16 do
      local level = 0
      if head ~= nil then
        local dist = head - x                  -- columns behind the head
        if dist >= 0 and dist < bar.length then
          level = math.floor(15 * (1 - dist / bar.length) + 0.5)
        end
      end
      if level <= 0 and cat ~= nil then
        level = cat[row][x]
      end
      if level > 0 then
        self.g:led(x, row, level)
      end
    end
  end
end

-- Launch intro: comet sweep over the cat spritesheet (10fps, synced to the
-- screen logo via the same elapsed clock). One-shot; bars exit by ~2s.
function GridSequencer:start_intro()
  math.randomseed(math.floor(util.time() * 1e6) % 2147483647)
  self:roll_intro_bars()
end

function GridSequencer:draw_intro(elapsed)
  if self.g == nil then
    return
  end
  self.g:all(0)
  local cat_frame = math.floor(elapsed * INTRO_CAT_FPS) + 1  -- 1-indexed
  if cat_frame < 1 then cat_frame = 1 elseif cat_frame > #INTRO_CAT then cat_frame = #INTRO_CAT end
  self:draw_sweep_bars(elapsed, INTRO_CAT[cat_frame])
  self.g:refresh()
end

-- Visualizer page: the normal control surface with the comet sweep layered on
-- top, looping and re-randomized each pass. `phase` is the tempo-scaled clock
-- from the coordinator, so sweep speed tracks BPM.
function GridSequencer:start_sweep_loop()
  math.randomseed(math.floor(util.time() * 1e6) % 2147483647)
  self.sweep_cycle = nil
  self:roll_intro_bars()
end

function GridSequencer:draw_sweep_loop(phase)
  if self.g == nil then
    return
  end
  local cycle = math.floor(phase / INTRO_SWEEP_PERIOD)
  if cycle ~= self.sweep_cycle then
    self.sweep_cycle = cycle
    self:roll_intro_bars()
  end
  self.g:all(0)
  self:draw_normal_leds()  -- the keys you'd normally see
  self:draw_sweep_bars(phase - cycle * INTRO_SWEEP_PERIOD, nil)  -- comets on top
  self.g:refresh()
end

function GridSequencer:draw_step_row()
  local flash_on = math.floor(util.time() * 8) % 2 == 0
  local pattern_steps = self:pattern_steps()
  for x = 1, 16 do
    local index = self:step_index(self.selected_page, x)
    local record = self:step_record(index, false)
    local level = index <= pattern_steps and 2 or 1
    if Step.has_content(record) then
      level = record.trig and 7 or 5
      if record.pitch ~= nil then
        level = 9
      end
      if record.trig and self:is_ghost(record) then
        -- Ghost: dimmer than a normal trig, slowly pulsing in/out over 2s.
        local fade = (math.sin(util.time() * math.pi) + 1) / 2
        level = 2 + math.floor((fade * 3) + 0.5)
      end
    end
    if self.playing and index == self.seq.play_index then
      level = flash_on and 15 or 5
    end
    if self.step_holds[x] then
      level = 15
    end
    self.g:led(x, 8, level)
  end
end

function GridSequencer:draw_page_row()
  local flash_on = math.floor(util.time() * 4) % 2 == 0
  local pattern_pages = self:pattern_pages()
  for x = 1, 16 do
    local level = x <= pattern_pages and 3 or 1
    if self.page_mode == "select" then
      level = x == self.selected_page and 12 or level
    elseif self.page_mode == "loop" then
      level = self.seq.page_loop[x] and 9 or level
    elseif self.page_mode == "rate" then
      level = RATES[x] ~= nil and 4 or 1
      if x == self.seq.rate_index then
        level = 12
      end
    end
    if self.playing and x == self.seq.play_page then
      level = flash_on and 15 or 5
    end
    self.g:led(x, 8, level)
  end
end

-- Pattern-load overlay row (PRD §6.2): the 16 pattern slots. Current pattern is
-- bright; a queued (sequential/temp) switch flashes; populated slots read at a
-- mid level, empty slots dim.
function GridSequencer:draw_pattern_row()
  local flash_on = math.floor(util.time() * 4) % 2 == 0
  local current = self.options.pattern_current ~= nil and self.options.pattern_current() or 1
  local pending = self.options.pattern_pending ~= nil and self.options.pattern_pending() or nil
  for x = 1, 16 do
    local level = 2
    if self.options.pattern_populated ~= nil and self.options.pattern_populated(x) then
      level = 6
    end
    if x == current then
      level = 15
    elseif x == pending then
      level = flash_on and 12 or 4
    end
    self.g:led(x, 8, level)
  end
end

return GridSequencer
