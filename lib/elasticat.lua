-- elasticat
--
-- Parameter helper for the bundled Engine_Elasticat.
--
-- Minimal script usage:
--   engine.name = "Elasticat"
--   local elasticat = include("lib/elasticat")
--   function init()
--     elasticat.params()
--   end

local cs = require "controlspec"
local unpack = table.unpack or unpack
local FilterRegistry = include("lib/filter_modes/registry")
local FxRegistry = include("lib/fx_modes/registry")
local TrigConditions = include("lib/sequencer/trig_conditions")
local ProjectStore = include("lib/project_store")  -- PRD §7: only used here for namesizer_available()
local ParamsSpec = include("lib/tracks/params_spec")  -- Phase 1 track scaffolding

-- Option labels for the trig_condition param, derived from the shared table so
-- the picker order matches the evaluator's indices exactly.
local TRIG_CONDITIONS = {}
for i, c in ipairs(TrigConditions) do TRIG_CONDITIONS[i] = c.label end

local elasticat = {}
elasticat.trig_conditions = TrigConditions  -- exposed for the coordinator/UI

elasticat.machines = {
  "loop",
  "loop_trig",
  "grid_slice",
  "razor_slice"
}

elasticat.modes = {
  "tape",
  "tempo_varispeed",
  "chopped",
  "granular",
  "random_ola",
  "pitch_corrected"
}

local sync_thread = nil
local engine_send_metro = nil
local engine_send_interval = 1 / 12
local pending_engine_sends = {}
local pending_engine_order = {}
local clock_origin = 0
local clock_sequence = 0
local ids = {}
local sample_pool = {
  paths = {},
  samples = {},
  rates = {},
  channels = {},
  bpms = {},
  steps = {},
  trim_starts = {},
  trim_ends = {},
  gains = {}
}
local active_sample_slot = 1
-- The File page edits this slot independently of the track's playback slot
-- (active_sample_slot). The sample metadata params (bpm/steps/trim/gain/file)
-- reflect file_edit_slot; playback reads the active slot's pool metadata
-- directly. Editing only touches the engine when the two slots coincide.
local file_edit_slot = 1
local pool_options = {}

local function file_edits_active()
  return file_edit_slot == active_sample_slot
end
local pool_dirty = {}
local suppress_pool_callback = false
local engine_call = nil
local send_effective_amp
local razor_adjusting = false
local razor_start_values = {}
local audio_extensions = {
  wav = true,
  aif = true,
  aiff = true,
  flac = true,
  ogg = true
}

local function param_id(prefix, suffix)
  return prefix .. suffix
end

local function add_control(id, name, spec, action, formatter)
  params:add_control(id, name, spec, formatter)
  params:set_action(id, action)
end

local function is_audio_file(path)
  local ext = path:match("%.([^%.]+)$")
  return ext ~= nil and audio_extensions[ext:lower()] == true
end

local function bpm_from_filename(path)
  local bpm = path:match("[Bb][Pp][Mm][_%-%s]*(%d+%.?%d*)")
    or path:match("(%d+%.?%d*)[_%-%s]*[Bb][Pp][Mm]")
  if bpm == nil then
    return nil
  end
  return tonumber(bpm)
end

local function quantize_steps(value)
  return math.max(1, math.floor(value + 0.5))
end

local function sample_slot_number(slot)
  return util.clamp(math.floor((tonumber(slot) or 1) + 0.5), 1, 128)
end

local function sample_duration(slot)
  slot = sample_slot_number(slot)
  local samples = sample_pool.samples[slot] or 0
  local rate = sample_pool.rates[slot] or 0
  if samples <= 0 or rate <= 0 then
    return 0
  end
  return samples / rate
end

local function sample_meta_path(path)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  local replaced = path:gsub("%.[^%.\\/]+$", ".json")
  if replaced == path then
    return path .. ".json"
  end
  return replaced
end

local function read_sample_sidecar(path)
  local meta_path = sample_meta_path(path)
  if meta_path == nil or not util.file_exists(meta_path) then
    return {}
  end

  local file = io.open(meta_path, "rb")
  if file == nil then
    return {}
  end
  local content = file:read("*all") or ""
  file:close()

  return {
    bpm = tonumber(content:match('"bpm"%s*:%s*([%d%.%-]+)')),
    steps = tonumber(content:match('"steps"%s*:%s*([%d%.%-]+)')),
    trim_start = tonumber(content:match('"trim_start"%s*:%s*([%d%.%-]+)')),
    trim_end = tonumber(content:match('"trim_end"%s*:%s*([%d%.%-]+)')),
    gain = tonumber(content:match('"gain"%s*:%s*([%d%.%-]+)'))
  }
end

local function write_sample_sidecar(slot)
  slot = sample_slot_number(slot)
  local path = sample_pool.paths[slot]
  local meta_path = sample_meta_path(path)
  if meta_path == nil then
    return
  end

  local file = io.open(meta_path, "wb")
  if file == nil then
    print("elasticat: could not write sample sidecar " .. tostring(meta_path))
    return
  end

  file:write(string.format(
    '{\n  "bpm": %.6f,\n  "steps": %.6f,\n  "trim_start": %.6f,\n  "trim_end": %.6f,\n  "gain": %.6f\n}\n',
    sample_pool.bpms[slot] or 120,
    sample_pool.steps[slot] or 16,
    sample_pool.trim_starts[slot] or 0,
    sample_pool.trim_ends[slot] or sample_duration(slot),
    sample_pool.gains[slot] or 1
  ))
  file:close()
end

local function trim_bounds(slot)
  slot = sample_slot_number(slot or active_sample_slot)
  local duration = sample_duration(slot)
  local trim_start = util.clamp(sample_pool.trim_starts[slot] or 0, 0, math.max(0, duration))
  local trim_end = util.clamp(sample_pool.trim_ends[slot] or duration, 0, math.max(0, duration))
  if duration > 0 and trim_end <= trim_start then
    trim_end = duration
    if trim_end <= trim_start then
      trim_start = 0
    end
  end
  return trim_start, trim_end, duration
end

-- Active Range override: the three-layer model the loop region also uses. Track
-- Range = the range_start/range_end params (what the Range page edits, never
-- touched by step locks). Step Range = a triggering step's range lock, pushed
-- here by GridSequencer. Actual Range (used below) = Step Range when set, else
-- Track Range. nil per endpoint means "fall through to the Track param".
local active_range_start = nil
local active_range_end = nil

function elasticat.set_active_range(range_start, range_end)
  -- Phase 1: the Active Range override maps track 1's engine points (see
  -- map_trim_point). With another track selected, a step's range lock must not
  -- silently re-map TRACK 1's loop points -- tracks 2-8 range support lands
  -- with their per-track trim mapping.
  if engine_track > 1 then
    return
  end
  active_range_start = range_start
  active_range_end = range_end
end

-- The Actual Range (0-128) actually driving playback: Step Range override when
-- set, else the Track Range params. Used by the waveform view so it can follow
-- a sequenced range sweep during playback.
function elasticat.active_range()
  local rs = active_range_start
  local re = active_range_end
  if rs == nil and ids.range_start ~= nil and params:lookup_param(ids.range_start) ~= nil then
    rs = params:get(ids.range_start)
  end
  if re == nil and ids.range_end ~= nil and params:lookup_param(ids.range_end) ~= nil then
    re = params:get(ids.range_end)
  end
  return rs or 0, re or 128
end

-- Range Start/End (0-128) carve a live performance window *inside* the file
-- trim window: 0 = trim start, 128 = trim end. Unlike file trim (saved per
-- sample) this is a global, p-lockable layer. Returns the window in seconds.
local function range_bounds(trim_start, trim_end)
  local span = trim_end - trim_start
  local range_start = active_range_start
  local range_end = active_range_end
  if range_start == nil and ids.range_start ~= nil and params:lookup_param(ids.range_start) ~= nil then
    range_start = params:get(ids.range_start)
  end
  if range_end == nil and ids.range_end ~= nil and params:lookup_param(ids.range_end) ~= nil then
    range_end = params:get(ids.range_end)
  end
  range_start = range_start or 0
  range_end = range_end or 128
  local lo = trim_start + (span * (util.clamp(range_start, 0, 128) / 128))
  local hi = trim_start + (span * (util.clamp(range_end, 0, 128) / 128))
  if hi <= lo then
    hi = math.min(trim_end, lo + 0.0001)
  end
  return lo, hi
end

-- Maps a Track point (0-128) through Range, then File Trim, into engine 0-128
-- (of the whole sample). One funnel: every engine region call (loop points,
-- slice ranges, set_loop_region) goes through here, so both the Range and the
-- File Trim layers apply everywhere with no downstream changes.
local function map_trim_point(point, slot)
  local trim_start, trim_end, duration = trim_bounds(slot)
  if duration <= 0 then
    return util.clamp(point or 0, 0, 128)
  end
  local range_lo, range_hi = range_bounds(trim_start, trim_end)
  local fraction = util.clamp(point or 0, 0, 128) / 128
  return ((range_lo + ((range_hi - range_lo) * fraction)) / duration) * 128
end

-- Maps a Track-space region (0-128) to the engine-space region actually played
-- (range + trim folded in). The visual playhead needs this so its rate matches
-- the true loop length -- e.g. a narrowed range loops far faster than the Track
-- width alone implies.
function elasticat.map_region(track_start, track_end)
  return map_trim_point(track_start), map_trim_point(track_end)
end

local function update_engine_loop_points()
  if ids.loop_start == nil or ids.loop_end == nil then
    return
  end
  local start_point = params:lookup_param(ids.loop_start) ~= nil and params:get(ids.loop_start) or 0
  local end_point = params:lookup_param(ids.loop_end) ~= nil and params:get(ids.loop_end) or 128
  engine_call("loopStart", map_trim_point(start_point))
  engine_call("loopEnd", map_trim_point(end_point))
end

local function format_ms(param)
  return tostring(math.floor((param:get() * 1000) + 0.5)) .. " ms"
end

-- Elektron-style envelope times: the 0-127 param is mapped to seconds on an
-- exponential curve. `env_range` sets the full-scale seconds (value 127 -> that
-- many seconds); the curve keeps the low end in milliseconds and ramps into
-- seconds toward the top.
local ENV_RANGE_VALUES = {1, 4, 8, 16, 32, 64, 128, 256, 512, 1024}
local ENV_TIME_SHAPE = 6  -- curve steepness; higher = more ms resolution down low
local ENV_INFINITE_VALUE = 128       -- hold/release value that means "infinite"
local ENV_INFINITE_SECONDS = 1000000 -- ~11.5 days; effectively infinite to the engine

local function env_range_seconds()
  if ids.env_range == nil or params:lookup_param(ids.env_range) == nil then
    return 8
  end
  return ENV_RANGE_VALUES[params:get(ids.env_range)] or 8
end

-- 0-127 -> seconds on an exponential curve; 128 is the "infinite" sentinel.
local function env_value_to_seconds(v)
  v = v or 0
  if v >= ENV_INFINITE_VALUE then
    return ENV_INFINITE_SECONDS
  end
  local n = util.clamp(v / 127, 0, 1)
  local curve = (math.exp(ENV_TIME_SHAPE * n) - 1) / (math.exp(ENV_TIME_SHAPE) - 1)
  return env_range_seconds() * curve
end

local function format_env_time(param)
  if param:get() >= ENV_INFINITE_VALUE then
    return "INF"
  end
  local secs = env_value_to_seconds(param:get())
  if secs < 1 then
    return string.format("%d ms", math.floor((secs * 1000) + 0.5))
  end
  return string.format("%.2f s", secs)
end

local function format_env_level(param)
  return tostring(math.floor((param:get() / 127 * 100) + 0.5)) .. "%"
end

local function format_pan_127(param)
  local v = math.floor(param:get() + 0.5) - 64
  if v == 0 then return "C" end
  return (v < 0 and "L" or "R") .. tostring(math.abs(v))
end

-- Filter cutoff: a 0-127 amount mapped exponentially across the audible range so
-- each step is a roughly constant musical interval. 0 -> 20 Hz, 127 -> 20 kHz.
local FILTER_CUTOFF_MIN = 20
local FILTER_CUTOFF_MAX = 20000
local function filter_cutoff_hz(v)
  local n = util.clamp((v or 0) / 127, 0, 1)
  return FILTER_CUTOFF_MIN * ((FILTER_CUTOFF_MAX / FILTER_CUTOFF_MIN) ^ n)
end

local function format_filter_cutoff(param)
  local hz = filter_cutoff_hz(param:get())
  if hz >= 1000 then
    return string.format("%.1fk", hz / 1000)
  end
  return string.format("%d", math.floor(hz + 0.5))
end

-- Filter type: 4-way multimode selector (Classic machines).
local FILTER_TYPE_LABELS = {"LP", "HP", "BP", "NOTCH"}
local function format_filter_type(param)
  return FILTER_TYPE_LABELS[math.floor(param:get() + 0.5)] or "LP"
end

-- Morph: centered 0-128. 0 = full low-pass, 64 = notch, 128 = full high-pass.
local function format_filter_morph(param)
  local v = math.floor(param:get() + 0.5)
  if v == 64 then return "NOTCH" end
  if v < 64 then
    return "LP" .. tostring(math.floor(((64 - v) / 64 * 100) + 0.5))
  end
  return "HP" .. tostring(math.floor(((v - 64) / 64 * 100) + 0.5))
end

-- Env depth: bipolar 0-128 (64 = no modulation), shown as a signed percentage.
local function format_filter_depth(param)
  local v = math.floor(param:get() + 0.5) - 64
  if v == 0 then return "0" end
  return string.format("%+d%%", math.floor((v / 64 * 100) + 0.5))
end

-- Filter balance: centered 0-128 (64 = center), shared by the stereo (Balance)
-- and mid/side (MS Balance) machines -- see PRD SS4.2. Shown as a signed
-- percentage since the same id/param means "L/R spread" on stereo machines
-- and "Mid/Side spread" on M/S machines; a machine-agnostic display avoids
-- baking one interpretation into the formatter.
local function format_filter_balance(param)
  local v = math.floor(param:get() + 0.5) - 64
  if v == 0 then return "C" end
  return string.format("%+d%%", math.floor((v / 64 * 100) + 0.5))
end

-- FX Insert 1 (PRD SS4.3): DELAY time is an options param (beat divisions, not
-- raw seconds -- SS5) so it stays tempo-sync'd across BPM changes. Labels are a
-- standard delay-pedal division set; index -> beats (quarter note = 1 beat,
-- matching the engine's existing chopBeats/targetBpm convention).
local DELAY_TIME_LABELS = {"1/32", "1/16", "1/8", "1/4", "3/8", "1/2", "3/4", "1 BAR", "2 BAR"}
local DELAY_TIME_BEATS = {0.125, 0.25, 0.5, 1, 1.5, 2, 3, 4, 8}

-- Modulation (MOD category): 2 LFOs + 1 mod envelope, computed engine-side on
-- control buses (one \elasticatMod synth -- see Engine_Elasticat.sc). The
-- destination list maps 1:1 onto the engine's per-destination buses; SPD is a
-- musical-division options param (same tempo-synced idiom as DELAY_TIME above)
-- sent as beats-per-cycle so LFO rates follow targetBpm across tempo changes.
-- LFO / mod-env destinations. 1-6 are direct param targets; 7-10 target one of
-- the 4 macros (the macro then re-routes through its matrix -- a 2-stage matrix).
local MOD_DEST_LABELS = {"OFF", "PITCH", "CUTOFF", "RES", "AMP", "PAN", "MACRO1", "MACRO2", "MACRO3", "MACRO4"}

-- Macro mod matrix: each macro holds a signed depth to each of these 5
-- destinations. `key` names the macro's per-dest depth param suffix
-- (macroN_<key>_depth); `param` is the ACTUAL page param the user turns while
-- holding a macro key to dial that destination in; `index` is the engine's
-- destination index (1-5, matching the mod buses).
local MACRO_DESTS = {
  {key = "pitch", param = "pitch", index = 1},
  {key = "cutoff", param = "filter_cutoff", index = 2},
  {key = "res", param = "filter_res", index = 3},
  {key = "amp", param = "amp", index = 4},
  {key = "pan", param = "pan", index = 5}
}
-- Reverse map: turned-param suffix -> its macro-matrix dest entry.
local MACRO_DEST_BY_PARAM = {}
for _, dest in ipairs(MACRO_DESTS) do
  MACRO_DEST_BY_PARAM[dest.param] = dest
end
elasticat.macro_dest_for_param = function(suffix)
  return MACRO_DEST_BY_PARAM[suffix]
end

-- ---- Live modulation feed (engine -> UI) ----------------------------------
-- The engine reports the five mod-bus sums (-1..1 each) at 15Hz on
-- /elasticat/mod. Stored here so the UI's "actual value" bars and the filter
-- render can follow LFOs / mod-env / macros during playback.
local mod_live = {pitch = 0, cutoff = 0, res = 0, amp = 0, pan = 0}
-- The filter envelope's own cutoff contribution, in SEMITONES. It is applied
-- inside the filter synth (not on a mod bus), so it arrives on its own feed.
local filter_env_semitones = 0

function elasticat.set_filter_env_mod(semitones)
  filter_env_semitones = tonumber(semitones) or 0
end

function elasticat.set_mod_values(pitch, cutoff, res, amp, pan)
  mod_live.pitch = tonumber(pitch) or 0
  mod_live.cutoff = tonumber(cutoff) or 0
  mod_live.res = tonumber(res) or 0
  mod_live.amp = tonumber(amp) or 0
  mod_live.pan = tonumber(pan) or 0
end

-- The modulation OFFSET for a param, expressed in that param's own display
-- units, so the UI can just add it to the base value. Mirrors the scaling each
-- destination synth applies:
--   pitch  +/-12 semitones      (pitch param is semitones)
--   cutoff +/-36 semitones on an exponential 20Hz-20kHz / 0-127 knob
--   res    +/-0.5 of 0..1       -> +/-63.5 of 0-127
--   pan    +/-1 of -1..1        -> +/-64 of 0-128
-- AMP is multiplicative in the engine (amp * (1 + mod)), so it is returned as a
-- FACTOR by elasticat.mod_amp_factor instead of an offset.
local CUTOFF_UNITS_PER_SEMITONE =
  127 / ((math.log(FILTER_CUTOFF_MAX / FILTER_CUTOFF_MIN) / math.log(2)) * 12)
local MOD_UNIT_SCALE = {
  pitch = 12,
  filter_cutoff = 36 * CUTOFF_UNITS_PER_SEMITONE,
  filter_res = 0.5 * 127,
  pan = 64
}
local MOD_SOURCE_KEY = {
  pitch = "pitch",
  filter_cutoff = "cutoff",
  filter_res = "res",
  pan = "pan"
}

function elasticat.mod_offset_for(suffix)
  local key = MOD_SOURCE_KEY[suffix]
  if key == nil then
    return 0
  end
  local offset = (mod_live[key] or 0) * (MOD_UNIT_SCALE[suffix] or 0)
  if suffix == "filter_cutoff" then
    -- Fold in the filter envelope's own sweep (already in semitones).
    offset = offset + (filter_env_semitones * CUTOFF_UNITS_PER_SEMITONE)
  end
  return offset
end

-- Multiplicative amp modulation (tremolo), for the VOL bar.
function elasticat.mod_amp_factor()
  return 1 + (mod_live.amp or 0)
end
local MOD_WAVE_LABELS = {"SINE", "TRI", "SAW", "RSAW", "SQR", "RAND"}
local MOD_LFO_MODE_LABELS = {"FREE", "TRIG", "ONE", "HOLD"}
local MOD_SPEED_LABELS = {"8 BAR", "4 BAR", "2 BAR", "1 BAR", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64"}
local MOD_SPEED_BEATS = {32, 16, 8, 4, 2, 1, 0.5, 0.25, 0.125, 0.0625}

-- Lofi bit depth: 0-127 amount mapped to 1..24 bits. Read as the literal output
-- bit depth (higher = cleaner, matching the BITS label), the mirror image of a
-- "crush amount" knob -- flagged in the report as a direction worth a listening
-- check.
local LOFI_BITS_MIN = 1
local LOFI_BITS_MAX = 24
local function lofi_bits_depth(v)
  local n = util.clamp((v or 0) / 127, 0, 1)
  return LOFI_BITS_MIN + (n * (LOFI_BITS_MAX - LOFI_BITS_MIN))
end

local function format_lofi_bits(param)
  return string.format("%.1f", lofi_bits_depth(param:get()))
end

-- Lofi sample rate: 0-127 amount mapped exponentially (same shape as filter
-- cutoff) to 1k..48k Hz. 0 = heavy downsampling, 127 = clean/no reduction.
local LOFI_RATE_MIN = 1000
local LOFI_RATE_MAX = 48000
local function lofi_rate_hz(v)
  local n = util.clamp((v or 0) / 127, 0, 1)
  return LOFI_RATE_MIN * ((LOFI_RATE_MAX / LOFI_RATE_MIN) ^ n)
end

local function format_lofi_rate(param)
  local hz = lofi_rate_hz(param:get())
  if hz >= 1000 then
    return string.format("%.1fk", hz / 1000)
  end
  return string.format("%d", math.floor(hz + 0.5))
end

-- resend_env_times is defined after queue_engine_call (below) so it can use it.
local resend_env_times
local resend_filter_env_times
local resend_menv_times

local function clock_param_is_internal()
  return params:lookup_param("clock_source") ~= nil and params:get("clock_source") == 1
end

local function set_internal_clock_tempo(bpm)
  if ids.clock_sync ~= nil and params:get(ids.clock_sync) ~= 1 then
    return
  end
  if not clock_param_is_internal() then
    return
  end

  if params:lookup_param("clock_tempo") ~= nil then
    params:set("clock_tempo", bpm)
  elseif clock.internal ~= nil and clock.internal.set_tempo ~= nil then
    clock.internal.set_tempo(bpm)
  end
end

local function load_sample(path)
  if engine.loadSample ~= nil then
    print("elasticat: sending engine.loadSample " .. path)
    engine.loadSample(path)
  elseif engine.commands ~= nil and engine.commands.load ~= nil then
    -- Older compiled Elasticat versions registered a command named "load".
    -- Call through the command table to avoid norns' reserved engine.load().
    print("elasticat: sending legacy engine command load " .. path)
    engine.commands.load.func(path)
  else
    print("elasticat: engine loadSample command missing; restart/recompile norns")
  end
end

engine_call = function(name, ...)
  if engine[name] ~= nil then
    engine[name](...)
  else
    print("elasticat: engine command missing: " .. name)
  end
end

-- ---- Phase 1 track scaffolding: per-track engine facade --------------------
-- (docs/PHASE1_CONTRACT.md). tr-prefixed commands take a LEADING track index;
-- the existing unprefixed commands stay exactly as-is and act on track 1.
-- The engine half is built in parallel, so every tr call no-ops gracefully
-- (warn once per command) until it lands -- the Lua half stays testable.
--
-- Name mapping: the contract names a few commands that drop the "set" of
-- their track-1 counterpart (\trPitch for setPitch, \trSampleSlot for
-- setSampleSlot, \trSetMachine for the warp reader select). The alias table
-- tries the contract name first, then the mechanical tr+Capitalized fallback,
-- so either spelling on the engine side just works.
local TR_COMMAND_ALIASES = {
  setMode = {"trSetMachine", "trSetMode"},
  setSampleSlot = {"trSampleSlot", "trSetSampleSlot"},
  loadPoolSlot = {"trLoadPoolSlot"},
  setPitch = {"trPitch", "trSetPitch"},
  mute = {"trMute"},
  play = {"trPlay"},
  -- Engine names the per-track reverse command trReverse (not trSetReverse,
  -- which the mechanical fallback would guess from the spec's "setReverse").
  setReverse = {"trReverse", "trSetReverse"}
}
local tr_warned = {}
local track_prefix = "elasticat_"
-- Which track the facade's live-gesture calls (set_loop_region, note_on,
-- play, set_pitch, trigger_slice, ...) address. 1 = the existing unprefixed
-- path, byte-for-byte unchanged. Set by the coordinator on track selection.
local engine_track = 1

local function tr_command_name(name)
  local candidates = TR_COMMAND_ALIASES[name]
  if candidates ~= nil then
    for _, cmd in ipairs(candidates) do
      if engine[cmd] ~= nil then
        return cmd
      end
    end
  end
  local fallback = "tr" .. name:sub(1, 1):upper() .. name:sub(2)
  if engine[fallback] ~= nil then
    return fallback
  end
  return nil, (candidates ~= nil and candidates[1]) or fallback
end

local function tr_call(track, name, ...)
  local cmd, missing = tr_command_name(name)
  if cmd == nil then
    if not tr_warned[name] then
      tr_warned[name] = true
      print("elasticat: engine track command missing: " .. tostring(missing)
        .. " (Phase 1 engine half not loaded; call dropped)")
    end
    return
  end
  engine[cmd](track, ...)
end
elasticat.tr_call = tr_call

function elasticat.set_engine_track(track)
  engine_track = util.clamp(math.floor((tonumber(track) or 1) + 0.5), 1, ParamsSpec.TRACK_COUNT_MAX)
end

function elasticat.engine_track()
  return engine_track
end

-- Configured active track count (1-8, default 1). The engine only allocates
-- chains up to this; the UI gates the row-4 track keys on it.
function elasticat.active_track_count()
  if ids.active_track_count == nil or params:lookup_param(ids.active_track_count) == nil then
    return 1
  end
  return util.clamp(math.floor((params:get(ids.active_track_count) or 1) + 0.5), 1, ParamsSpec.TRACK_COUNT_MAX)
end

-- Read a per-track param by bare suffix (track 1 = the unprefixed id). nil if
-- the param does not exist (e.g. a suffix outside the Phase 1 per-track set).
function elasticat.track_param_value(track, suffix)
  local pid = ParamsSpec.track_id(track, suffix, track_prefix)
  if params:lookup_param(pid) == nil then
    return nil
  end
  return params:get(pid)
end

-- FN+track-key mute (contract: engine \trMute -- a muted track advances but
-- outputs silence). State lives in the mute param so patterns/projects carry
-- it; the param action sends the engine command.
function elasticat.set_track_mute(track, on)
  local pid = ParamsSpec.track_id(track, "mute", track_prefix)
  if params:lookup_param(pid) ~= nil then
    params:set(pid, on and 1 or 0)
  else
    tr_call(track, "mute", on and 1 or 0)
  end
end

function elasticat.track_muted(track)
  local pid = ParamsSpec.track_id(track, "mute", track_prefix)
  return params:lookup_param(pid) ~= nil and params:get(pid) == 1
end

-- A background (non-selected) track's step fired: push its p-locked pitch and
-- region to that track's chain. Phase 1 scope -- the per-track chain has no
-- amp envelope yet, so sequencing a background track means region/pitch moves
-- on its continuously-running reader (trNoteOn is sent guarded for when the
-- engine grows per-track envelopes).
function elasticat.track_step(track, record)
  if record == nil then
    return
  end
  local locks = record.param_locks or {}
  local pitch = record.pitch or locks.pitch
  if pitch ~= nil then
    tr_call(track, "setPitch", pitch)
  end
  if locks.loop_start ~= nil or locks.loop_end ~= nil then
    local start_point = locks.loop_start or elasticat.track_param_value(track, "loop_start") or 0
    local end_point = locks.loop_end or elasticat.track_param_value(track, "loop_end") or 128
    if end_point <= start_point then
      end_point = math.min(start_point + 0.01, 128)
    end
    tr_call(track, "loopStart", start_point)
    tr_call(track, "loopEnd", end_point)
    local jump = locks.trig_jump
    if jump == nil then
      jump = elasticat.track_param_value(track, "trig_jump")
    end
    if jump == nil or jump == 1 then
      tr_call(track, "playhead", 0)
    end
  end
  tr_call(track, "noteOn", 0.1)
end

-- Push every per-track param (tracks 2-8) + the active count + mutes to the
-- engine on init -- same reasoning as sync_amp_env: actions are set after
-- add, so registered defaults never fire, and older psets/projects lack these
-- ids entirely. Guarded per command (warn once) while the engine half lands.
function elasticat.sync_tracks()
  if ids.active_track_count == nil or params:lookup_param(ids.active_track_count) == nil then
    return
  end
  engine_call("activeTrackCount", elasticat.active_track_count())
  tr_call(1, "mute", elasticat.track_muted(1) and 1 or 0)
  for track = 2, ParamsSpec.TRACK_COUNT_MAX do
    for _, entry in ipairs(ParamsSpec.SPEC) do
      if entry.cmd ~= nil then
        local value = elasticat.track_param_value(track, entry.suffix)
        if value ~= nil then
          tr_call(track, entry.cmd, entry.offset ~= nil and (value + entry.offset) or value)
        end
      end
    end
  end
end

local function notify_pool_change(kind, slot, path)
  if suppress_pool_callback then
    return
  end
  if pool_options.on_pool_change ~= nil then
    pool_options.on_pool_change(elasticat.pool_snapshot(), slot, path, kind)
  end
end

-- Sidecar/pool-state disk writes are deferred: edits (trim, bpm, steps, gain)
-- just mark the slot dirty and update the screen/engine live. The actual
-- write only happens on flush (sample-slot change, page navigation, or
-- script cleanup), so scrubbing an encoder never triggers disk I/O per tick.
local function mark_pool_dirty(slot)
  pool_dirty[sample_slot_number(slot)] = true
end

function elasticat.flush_dirty_pool_state()
  local flushed_slot = nil
  for slot, dirty in pairs(pool_dirty) do
    if dirty then
      write_sample_sidecar(slot)
      pool_dirty[slot] = nil
      flushed_slot = flushed_slot or slot
    end
  end
  if flushed_slot ~= nil then
    notify_pool_change("flush", active_sample_slot, sample_pool.paths[active_sample_slot])
  end
end

local function load_sample_slot(slot, path)
  slot = sample_slot_number(slot)
  if engine.loadPoolSlot ~= nil then
    print("elasticat: sending engine.loadPoolSlot " .. tostring(slot) .. " " .. path)
    engine_call("loadPoolSlot", slot, path)
  elseif slot == active_sample_slot then
    load_sample(path)
  else
    print("elasticat: engine loadPoolSlot command missing; slot " .. tostring(slot) .. " cached in script only")
  end
end

-- Push the *active* slot's pool metadata (bpm/steps/trim/gain) to the engine.
-- Called when the active/playback slot changes, or when its own metadata is
-- edited. Does not touch the display params -- those follow the file-edit slot.
local function push_engine_slot_metadata(slot)
  slot = sample_slot_number(slot)
  if sample_pool.bpms[slot] ~= nil then
    engine_call("sourceBpm", sample_pool.bpms[slot])
  end
  if sample_pool.steps[slot] ~= nil then
    engine_call("setSampleSteps", sample_pool.steps[slot])
  end
  send_effective_amp()
  update_engine_loop_points()
end

-- Load the file-edit slot's pool metadata into the display params (silently) so
-- the File page reflects that slot without disturbing playback.
local function apply_file_slot_metadata(slot)
  slot = sample_slot_number(slot)
  -- An empty slot resolves to sensible empty defaults (trim 0, no sample) so
  -- the File page never shows stale metadata from a since-cleared sample --
  -- notably trim_end sticking at a previous sample's value (or 0) after a
  -- New Project / project load emptied this slot.
  if params:lookup_param(ids.sample_bpm) ~= nil then
    params:set(ids.sample_bpm, sample_pool.bpms[slot] or 120, true)
  end
  if params:lookup_param(ids.sample_steps) ~= nil then
    params:set(ids.sample_steps, sample_pool.steps[slot] or 16, true)
  end
  if ids.trim_start ~= nil and params:lookup_param(ids.trim_start) ~= nil then
    params:set(ids.trim_start, sample_pool.trim_starts[slot] or 0, true)
  end
  if ids.trim_end ~= nil and params:lookup_param(ids.trim_end) ~= nil then
    params:set(ids.trim_end, sample_pool.trim_ends[slot] or 0, true)
  end
  if ids.gain ~= nil and params:lookup_param(ids.gain) ~= nil then
    params:set(ids.gain, sample_pool.gains[slot] or 1, true)
  end
  if ids.sample ~= nil and params:lookup_param(ids.sample) ~= nil then
    params:set(ids.sample, sample_pool.paths[slot] or _path.audio, true)
  end
end

local function sync_sample_file_param(path)
  if ids.sample ~= nil and params:lookup_param(ids.sample) ~= nil then
    params:set(ids.sample, path or _path.audio, true)
  end
end

local function set_active_pool_slot(slot)
  -- Slot 0 = Off: a deliberate silence slot (no sample loadable). The engine
  -- plays its zeroed buffers so audio stops while the transport keeps running.
  slot = util.clamp(math.floor((tonumber(slot) or 1) + 0.5), 0, 128)
  if slot ~= active_sample_slot then
    elasticat.flush_dirty_pool_state()
  end
  active_sample_slot = slot

  -- sample_slot is the SOURCE-page (track) selector; the File page has its own
  -- file_slot. We only sync the track selector here.
  if ids.sample_slot ~= nil and params:lookup_param(ids.sample_slot) ~= nil then
    if math.floor((params:get(ids.sample_slot) or 1) + 0.5) ~= slot then
      params:set(ids.sample_slot, slot, true)
    end
  end

  if slot == 0 then
    engine_call("setSampleSlot", 0)
    if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
      pool_options.on_sample_slot(0, nil)
    end
    return
  end

  -- Push the active slot's metadata to the engine (not the display params, which
  -- follow the file-edit slot).
  push_engine_slot_metadata(slot)
  engine_call("setSampleSlot", slot)

  if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
    pool_options.on_sample_slot(slot, sample_pool.paths[slot])
  end
end

-- Select which slot the File page edits, independent of playback. Loads that
-- slot's metadata into the display params so the editor reflects it.
local function set_file_edit_slot(slot)
  slot = sample_slot_number(slot)
  if slot ~= file_edit_slot then
    elasticat.flush_dirty_pool_state()
  end
  file_edit_slot = slot
  if ids.file_slot ~= nil and params:lookup_param(ids.file_slot) ~= nil then
    if math.floor((params:get(ids.file_slot) or 1) + 0.5) ~= slot then
      params:set(ids.file_slot, slot, true)
    end
  end
  apply_file_slot_metadata(slot)
  if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
    pool_options.on_sample_slot(slot, sample_pool.paths[slot])
  end
end

local flush_engine_sends

local function ensure_engine_send_metro()
  if engine_send_metro == nil then
    engine_send_metro = metro.init(function()
      flush_engine_sends()
    end, engine_send_interval, -1)
  end
  if engine_send_metro ~= nil and not engine_send_metro.is_running then
    engine_send_metro:start()
  end
end

local function queue_engine_send(key, action)
  if pending_engine_sends[key] == nil then
    table.insert(pending_engine_order, key)
  end
  pending_engine_sends[key] = action
  ensure_engine_send_metro()
end

local function queue_engine_call(key, name, ...)
  local args = {...}
  queue_engine_send(key, function()
    engine_call(name, unpack(args))
  end)
end

-- Re-send the envelope times to the engine (used when env_range changes the
-- seconds mapping); guarded so it is a no-op before the params exist.
resend_env_times = function()
  if ids.env_attack == nil or params:lookup_param(ids.env_attack) == nil then
    return
  end
  queue_engine_call(ids.env_attack, "envAttack", env_value_to_seconds(params:get(ids.env_attack)))
  queue_engine_call(ids.env_decay, "envDecay", env_value_to_seconds(params:get(ids.env_decay)))
  queue_engine_call(ids.env_release, "envRelease", env_value_to_seconds(params:get(ids.env_release)))
  queue_engine_call(ids.env_hold, "envHold", env_value_to_seconds(params:get(ids.env_hold)))
end

-- The filter envelope shares the amp's seconds mapping (env_range), so a range
-- change must re-send the filter env times too.
resend_filter_env_times = function()
  if ids.filter_env_attack == nil or params:lookup_param(ids.filter_env_attack) == nil then
    return
  end
  queue_engine_call(ids.filter_env_attack, "filterEnvAttack", env_value_to_seconds(params:get(ids.filter_env_attack)))
  queue_engine_call(ids.filter_env_decay, "filterEnvDecay", env_value_to_seconds(params:get(ids.filter_env_decay)))
  queue_engine_call(ids.filter_env_release, "filterEnvRelease", env_value_to_seconds(params:get(ids.filter_env_release)))
  queue_engine_call(ids.filter_env_hold, "filterEnvHold", env_value_to_seconds(params:get(ids.filter_env_hold)))
end

-- The mod envelope's ATK/DEC also share the amp env's seconds mapping.
resend_menv_times = function()
  if ids.menv_attack == nil or params:lookup_param(ids.menv_attack) == nil then
    return
  end
  queue_engine_call(ids.menv_attack, "menvAttack", env_value_to_seconds(params:get(ids.menv_attack)))
  queue_engine_call(ids.menv_decay, "menvDecay", env_value_to_seconds(params:get(ids.menv_decay)))
end

-- Coalesced (12Hz) version of update_engine_loop_points -- used when re-mapping
-- the loop points from a rapidly-scrubbed control (Range) during playback, so
-- per-detent edits don't flood the engine with immediate sends and feel laggy.
local function queue_engine_loop_points()
  if ids.loop_start == nil or ids.loop_end == nil then
    return
  end
  local start_point = params:lookup_param(ids.loop_start) ~= nil and params:get(ids.loop_start) or 0
  local end_point = params:lookup_param(ids.loop_end) ~= nil and params:get(ids.loop_end) or 128
  queue_engine_call(ids.loop_start, "loopStart", map_trim_point(start_point))
  queue_engine_call(ids.loop_end, "loopEnd", map_trim_point(end_point))
end

-- The engine only has one gain input (setAmp); the per-sample "gain" param
-- is a script-side multiplier on top of the track/master amp param, so both
-- combine into that single engine send instead of needing a second engine
-- parameter.
send_effective_amp = function()
  if ids.amp == nil or params:lookup_param(ids.amp) == nil then
    return
  end
  -- Track Volume is an Elektron-style 0-127 param; map to a 0..1 amplitude.
  local base = params:get(ids.amp) / 127
  local gain = sample_pool.gains[active_sample_slot] or 1
  queue_engine_call(ids.amp, "setAmp", base * gain)
end

flush_engine_sends = function()
  local sends = pending_engine_sends
  local order = pending_engine_order
  pending_engine_sends = {}
  pending_engine_order = {}

  for _, key in ipairs(order) do
    if sends[key] ~= nil then
      sends[key]()
    end
  end

  if next(pending_engine_sends) == nil and engine_send_metro ~= nil then
    engine_send_metro:stop()
  end
end

local function reset_clock_origin()
  clock_origin = clock.get_beats()
  clock_sequence = 0
end

local function set_engine_play(x)
  print("elasticat: params/play action " .. tostring(x))
  if x == 1 and ids.clock_sync ~= nil and params:get(ids.clock_sync) == 1 then
    reset_clock_origin()
    engine_call("setPlayhead", 0)
  end
  engine_call("play", x)
end

local function send_clock_observation()
  if ids.target_bpm == nil or ids.sample_steps == nil then
    return
  end

  local tempo = clock.get_tempo()
  local beats = clock.get_beats()
  local start_point = params:get(ids.loop_start) or 0
  local end_point = params:get(ids.loop_end) or 128
  local region = math.max(0.01, end_point - start_point) / 128
  local loop_beats = math.max(0.25, (params:get(ids.sample_steps) * region) / 4)
  local expected_phase = ((beats - clock_origin) / loop_beats) % 1

  clock_sequence = clock_sequence + 1
  params:set(ids.target_bpm, tempo, true)

  if engine.syncClock ~= nil then
    engine.syncClock(expected_phase, tempo, clock_sequence)
  elseif engine.targetBpm ~= nil then
    engine.targetBpm(tempo)
  end
end

function elasticat.stop_clock_sync()
  if sync_thread ~= nil then
    clock.cancel(sync_thread)
    sync_thread = nil
  end
end

function elasticat.stop_param_throttle()
  pending_engine_sends = {}
  pending_engine_order = {}
  if engine_send_metro ~= nil then
    engine_send_metro:stop()
    engine_send_metro = nil
  end
end

function elasticat.start_clock_sync()
  elasticat.stop_clock_sync()
  reset_clock_origin()
  sync_thread = clock.run(function()
    while true do
      clock.sync(1 / 4)
      if params:get(ids.clock_sync) == 1 then
        send_clock_observation()
      end
    end
  end)
end

function elasticat.log_engine_commands()
  print("elasticat: command loadSample = " .. tostring(engine.loadSample ~= nil))
  print("elasticat: command loadPoolSlot = " .. tostring(engine.loadPoolSlot ~= nil))
  print("elasticat: command setSampleSlot = " .. tostring(engine.setSampleSlot ~= nil))
  print("elasticat: command legacy load = " .. tostring(engine.commands ~= nil and engine.commands.load ~= nil))
  print("elasticat: command play = " .. tostring(engine.play ~= nil))
  print("elasticat: command setMode = " .. tostring(engine.setMode ~= nil))
  print("elasticat: command syncClock = " .. tostring(engine.syncClock ~= nil))
  print("elasticat: command triggerSlice = " .. tostring(engine.triggerSlice ~= nil))
  print("elasticat: command setSliceSyncToClock = " .. tostring(engine.setSliceSyncToClock ~= nil))
  print("elasticat: command setSliceRate = " .. tostring(engine.setSliceRate ~= nil))
end

-- all_tracks = true is the master-transport path (set_playing): drives track 1
-- exactly as before PLUS every other active track's chain (\trPlay), each gated
-- on its own machine being continuous -- mirroring track 1's
-- machine_is_continuous() gating in the coordinator. Without all_tracks this is
-- a single-track gesture (previews, grid holds) addressed to the selected
-- engine track: track 1 keeps the exact existing path.
function elasticat.play(state, all_tracks)
  if engine_track > 1 and not all_tracks then
    tr_call(engine_track, "play", state and 1 or 0)
    return
  end
  set_engine_play(state and 1 or 0)
  if all_tracks then
    for track = 2, elasticat.active_track_count() do
      local machine = elasticat.track_param_value(track, "machine") or 1
      tr_call(track, "play", (state and machine == 1) and 1 or 0)
    end
  end
end

function elasticat.stop_reset()
  flush_engine_sends()
  if engine.stopAndReset ~= nil then
    engine_call("stopAndReset")
  elseif engine.stop ~= nil then
    engine_call("stop")
  else
    engine_call("play", 0)
    engine_call("playhead", 0)
  end
  for track = 2, elasticat.active_track_count() do
    tr_call(track, "play", 0)
    tr_call(track, "playhead", 0)
  end
end

function elasticat.request_status()
  engine_call("requestStatus")
end

function elasticat.set_pitch(value)
  if engine_track > 1 then
    tr_call(engine_track, "setPitch", value)
    return
  end
  engine_call("setPitch", value)
end

function elasticat.set_reverse(reverse)
  local flag = (reverse == true or reverse == 1) and 1 or 0
  if engine_track > 1 then
    tr_call(engine_track, "setReverse", flag)
    return
  end
  engine_call("setReverse", flag)
end

function elasticat.trigger_slice(slice_index, start_point, end_point, play_mode, reverse, velocity, length_seconds, pitch_value)
  local reverse_flag = (reverse == true or reverse == 1) and 1 or 0
  if engine_track > 1 then
    -- Phase 1: tracks 2-8 send raw 0-128 points (their file-trim/range mapping
    -- lands with the per-track chain work; the pool metadata funnel below is
    -- track 1's).
    tr_call(engine_track, "triggerSlice", slice_index,
      util.clamp(start_point or 0, 0, 128), util.clamp(end_point or 128, 0, 128),
      play_mode, reverse_flag, velocity or 1, length_seconds or 0, pitch_value or 0)
    return
  end
  engine_call(
    "triggerSlice",
    slice_index,
    map_trim_point(start_point),
    map_trim_point(end_point),
    play_mode,
    reverse_flag,
    velocity or 1,
    length_seconds or 0,
    pitch_value or 0
  )
end

-- Retrigger the amp envelope on the active reader with the given note length
-- (seconds, the ADSR gate window). Sent immediately -- envelope timing is tight.
-- Pass seconds <= 0 (any non-positive value, e.g. 0) as the "indefinite hold"
-- sentinel: the engine then leaves the ADSR gate open until note_off() closes
-- it, instead of auto-releasing after a timer -- for a live-held note (e.g. a
-- grid key held down) whose duration isn't known up front. Omitting `seconds`
-- keeps today's default one-shot length (0.1s), unchanged.
function elasticat.note_on(seconds)
  if engine_track > 1 then
    tr_call(engine_track, "noteOn", seconds or 0.1)
    return
  end
  engine_call("noteOn", seconds or 0.1)
end

-- Close the currently-sounding note's ADSR gate now (release stage), for a
-- live-held note started via elasticat.note_on(0) (or any seconds <= 0).
-- Sent immediately, same as note_on -- envelope timing is tight. No-op (just
-- a redundant reset edge) if nothing is currently held open.
function elasticat.note_off()
  if engine_track > 1 then
    tr_call(engine_track, "noteOff")
    return
  end
  engine_call("noteOff")
end

-- Force a fresh amp/filter re-attack for auditioning a stopped step preview.
-- Unlike note_on, this re-attacks even under portamento (whose legato hold
-- otherwise swallows a note-on on a still-sounding preview note). seconds <= 0
-- keeps the indefinite hold used by the sustained preview.
function elasticat.retrig_note(seconds)
  if engine_track > 1 then
    tr_call(engine_track, "retrigNote", seconds or 0)
    return
  end
  engine_call("retrigNote", seconds or 0)
end

-- Push the amp-envelope + pan/vol params to the engine. Needed on init because
-- these params are added with their action set afterwards (so their defaults
-- never fire) and aren't in older psets, leaving the engine on stale defaults.
function elasticat.sync_amp_env()
  if ids.env_mode == nil or params:lookup_param(ids.env_mode) == nil then
    return
  end
  engine_call("setEnvMode", (params:get(ids.env_mode) or 2) - 1)
  engine_call("envAttack", env_value_to_seconds(params:get(ids.env_attack)))
  engine_call("envDecay", env_value_to_seconds(params:get(ids.env_decay)))
  engine_call("envSustain", util.clamp((params:get(ids.env_sustain) or 100) / 127, 0, 1))
  engine_call("envRelease", env_value_to_seconds(params:get(ids.env_release)))
  engine_call("envHold", env_value_to_seconds(params:get(ids.env_hold)))
  engine_call("setPortamento", params:get(ids.portamento) or 0)
  send_effective_amp()
  if ids.pan ~= nil then
    engine_call("setPan", ((params:get(ids.pan) or 64) - 64) / 64)
  end
end

-- Push the filter params to the engine on init (same reasoning as sync_amp_env:
-- actions are set after add, so defaults never fire, and old psets lack them).
-- Params are sent first, then the machine is (re)selected last so its respawn
-- seeds from the now-current engine-side values.
function elasticat.sync_filter()
  if ids.filter_machine == nil or params:lookup_param(ids.filter_machine) == nil then
    return
  end
  engine_call("filterType", (params:get(ids.filter_type) or 1) - 1)
  engine_call("filterCutoff", filter_cutoff_hz(params:get(ids.filter_cutoff)))
  engine_call("filterRes", util.clamp((params:get(ids.filter_res) or 0) / 127, 0, 1))
  engine_call("filterDrive", util.clamp((params:get(ids.filter_drive) or 0) / 127, 0, 1))
  engine_call("filterMorph", util.clamp((params:get(ids.filter_morph) or 64) / 128, 0, 1))
  engine_call("filterBalance", ((params:get(ids.filter_balance) or 64) - 64) / 64)
  engine_call("filterEnvMode", (params:get(ids.filter_env_mode) or 2) - 1)
  engine_call("filterEnvAttack", env_value_to_seconds(params:get(ids.filter_env_attack)))
  engine_call("filterEnvDecay", env_value_to_seconds(params:get(ids.filter_env_decay)))
  engine_call("filterEnvSustain", util.clamp((params:get(ids.filter_env_sustain) or 100) / 127, 0, 1))
  engine_call("filterEnvRelease", env_value_to_seconds(params:get(ids.filter_env_release)))
  engine_call("filterEnvHold", env_value_to_seconds(params:get(ids.filter_env_hold)))
  engine_call("filterEnvDepth", ((params:get(ids.filter_env_depth) or 64) - 64) / 64)
  engine_call("setFilterMachine", (params:get(ids.filter_machine) or 1) - 1)
end

-- Push the Insert 1 FX params to the engine on init (same reasoning as
-- sync_filter). Params are sent first, then the machine is (re)selected last so
-- its respawn seeds from the now-current engine-side values.
function elasticat.sync_fx()
  if ids.fx_insert1_machine == nil or params:lookup_param(ids.fx_insert1_machine) == nil then
    return
  end
  engine_call("fxDrive", util.clamp((params:get(ids.fx_drive) or 0) / 127, 0, 1))
  engine_call("fxMix", util.clamp((params:get(ids.fx_mix) or 64) / 127, 0, 1))
  engine_call("delayTime", DELAY_TIME_BEATS[params:get(ids.delay_time) or 4] or 1)
  engine_call("delayFeedback", util.clamp((params:get(ids.delay_feedback) or 38) / 127, 0, 1))
  engine_call("delayTone", util.clamp((params:get(ids.delay_tone) or 127) / 127, 0, 1))
  engine_call("reverbSize", util.clamp((params:get(ids.reverb_size) or 64) / 127, 0, 1))
  engine_call("reverbDamp", util.clamp((params:get(ids.reverb_damp) or 64) / 127, 0, 1))
  engine_call("lofiBits", lofi_bits_depth(params:get(ids.lofi_bits) or 127))
  engine_call("lofiRate", lofi_rate_hz(params:get(ids.lofi_rate) or 127))
  engine_call("setInsertMachine", (params:get(ids.fx_insert1_machine) or 1) - 1)

  -- Send 1/2 + Master insert (PRD §3/§8): same reasoning, seeded after Insert 1
  -- above. Guarded independently since a psets saved before this landed won't
  -- have these ids yet.
  if ids.send1_machine == nil or params:lookup_param(ids.send1_machine) == nil then
    return
  end
  engine_call("setSendTap", (params:get(ids.send_tap) or 1) - 1)
  engine_call("sendLevel1", util.clamp((params:get(ids.send1_level) or 0) / 127, 0, 1))
  engine_call("sendLevel2", util.clamp((params:get(ids.send2_level) or 0) / 127, 0, 1))

  engine_call("send1FxDrive", util.clamp((params:get(ids.send1_fx_drive) or 0) / 127, 0, 1))
  engine_call("send1FxMix", util.clamp((params:get(ids.send1_fx_mix) or 64) / 127, 0, 1))
  engine_call("send1DelayTime", DELAY_TIME_BEATS[params:get(ids.send1_delay_time) or 4] or 1)
  engine_call("send1DelayFeedback", util.clamp((params:get(ids.send1_delay_feedback) or 38) / 127, 0, 1))
  engine_call("send1DelayTone", util.clamp((params:get(ids.send1_delay_tone) or 127) / 127, 0, 1))
  engine_call("send1ReverbSize", util.clamp((params:get(ids.send1_reverb_size) or 64) / 127, 0, 1))
  engine_call("send1ReverbDamp", util.clamp((params:get(ids.send1_reverb_damp) or 64) / 127, 0, 1))
  engine_call("send1LofiBits", lofi_bits_depth(params:get(ids.send1_lofi_bits) or 127))
  engine_call("send1LofiRate", lofi_rate_hz(params:get(ids.send1_lofi_rate) or 127))
  engine_call("setSend1Machine", (params:get(ids.send1_machine) or 1) - 1)

  engine_call("send2FxDrive", util.clamp((params:get(ids.send2_fx_drive) or 0) / 127, 0, 1))
  engine_call("send2FxMix", util.clamp((params:get(ids.send2_fx_mix) or 64) / 127, 0, 1))
  engine_call("send2DelayTime", DELAY_TIME_BEATS[params:get(ids.send2_delay_time) or 4] or 1)
  engine_call("send2DelayFeedback", util.clamp((params:get(ids.send2_delay_feedback) or 38) / 127, 0, 1))
  engine_call("send2DelayTone", util.clamp((params:get(ids.send2_delay_tone) or 127) / 127, 0, 1))
  engine_call("send2ReverbSize", util.clamp((params:get(ids.send2_reverb_size) or 64) / 127, 0, 1))
  engine_call("send2ReverbDamp", util.clamp((params:get(ids.send2_reverb_damp) or 64) / 127, 0, 1))
  engine_call("send2LofiBits", lofi_bits_depth(params:get(ids.send2_lofi_bits) or 127))
  engine_call("send2LofiRate", lofi_rate_hz(params:get(ids.send2_lofi_rate) or 127))
  engine_call("setSend2Machine", (params:get(ids.send2_machine) or 1) - 1)

  engine_call("masterFxDrive", util.clamp((params:get(ids.master_fx_drive) or 0) / 127, 0, 1))
  engine_call("masterFxMix", util.clamp((params:get(ids.master_fx_mix) or 64) / 127, 0, 1))
  engine_call("masterDelayTime", DELAY_TIME_BEATS[params:get(ids.master_delay_time) or 4] or 1)
  engine_call("masterDelayFeedback", util.clamp((params:get(ids.master_delay_feedback) or 38) / 127, 0, 1))
  engine_call("masterDelayTone", util.clamp((params:get(ids.master_delay_tone) or 127) / 127, 0, 1))
  engine_call("masterReverbSize", util.clamp((params:get(ids.master_reverb_size) or 64) / 127, 0, 1))
  engine_call("masterReverbDamp", util.clamp((params:get(ids.master_reverb_damp) or 64) / 127, 0, 1))
  engine_call("masterLofiBits", lofi_bits_depth(params:get(ids.master_lofi_bits) or 127))
  engine_call("masterLofiRate", lofi_rate_hz(params:get(ids.master_lofi_rate) or 127))
  engine_call("setMasterMachine", (params:get(ids.master_fx_machine) or 1) - 1)
end

-- Push the modulation params (2 LFOs + mod env) to the engine on init (same
-- reasoning as sync_filter: actions are set after add, so defaults never fire,
-- and older psets lack these ids entirely).
function elasticat.sync_mod()
  if ids.lfo1_dest == nil or params:lookup_param(ids.lfo1_dest) == nil then
    return
  end
  engine_call("lfo1Dest", (params:get(ids.lfo1_dest) or 1) - 1)
  engine_call("lfo1Wave", (params:get(ids.lfo1_wave) or 1) - 1)
  engine_call("lfo1Speed", MOD_SPEED_BEATS[params:get(ids.lfo1_speed) or 4] or 4)
  engine_call("lfo1Depth", ((params:get(ids.lfo1_depth) or 64) - 64) / 64)
  engine_call("lfo1Mode", (params:get(ids.lfo1_mode) or 1) - 1)
  engine_call("lfo2Dest", (params:get(ids.lfo2_dest) or 1) - 1)
  engine_call("lfo2Wave", (params:get(ids.lfo2_wave) or 1) - 1)
  engine_call("lfo2Speed", MOD_SPEED_BEATS[params:get(ids.lfo2_speed) or 4] or 4)
  engine_call("lfo2Depth", ((params:get(ids.lfo2_depth) or 64) - 64) / 64)
  engine_call("lfo2Mode", (params:get(ids.lfo2_mode) or 1) - 1)
  engine_call("menvDest", (params:get(ids.menv_dest) or 1) - 1)
  engine_call("menvAttack", env_value_to_seconds(params:get(ids.menv_attack)))
  engine_call("menvDecay", env_value_to_seconds(params:get(ids.menv_decay)))
  engine_call("menvDepth", ((params:get(ids.menv_depth) or 64) - 64) / 64)
  for m = 1, 4 do
    engine_call("macroBase", m, (params:get(ids["macro" .. m .. "_value"]) or 0) / 127)
    for _, dest in ipairs(MACRO_DESTS) do
      local raw = params:get(ids["macro" .. m .. "_" .. dest.key .. "_depth"]) or 64
      engine_call("macroDepth", m, dest.index, (raw - 64) / 64)
    end
  end
end

-- Set a macro's live value (0-127) -- used by the grid macro keys. Routes
-- through the param so the value is displayed, saved, and (when a step is
-- held) p-locked by the normal step-lock path; the param action pushes it to
-- the engine.
function elasticat.set_macro_value(index, value)
  local vid = ids["macro" .. index .. "_value"]
  if vid ~= nil and params:lookup_param(vid) ~= nil then
    params:set(vid, util.clamp(value, 0, 127))
  end
end

-- The macro-matrix depth param id for a macro (1-4) targeting a destination
-- (a MACRO_DESTS entry), or nil. The coordinator adjusts this param when you
-- hold a macro key and turn the destination's param.
function elasticat.macro_depth_id(index, dest)
  return dest ~= nil and ids["macro" .. index .. "_" .. dest.key .. "_depth"] or nil
end

-- Retrigger the modulation sources for a firing step. lfo_on retrigs both
-- LFOs (only their non-FREE modes react -- the synth gates the trigger by
-- mode); env_on retrigs the mod envelope. Fired by the sequencer where the
-- step's lfo_reset / env_reset resolve ON (ghosts resolve both off). Sent
-- immediately, same as note_on -- trigger timing is tight.
function elasticat.mod_trig(lfo_on, env_on)
  if not lfo_on and not env_on then
    return
  end
  engine_call("modTrig", lfo_on and 1 or 0, env_on and 1 or 0)
end

function elasticat.release_slice(slice_index)
  if engine_track > 1 then
    tr_call(engine_track, "releaseSlice", slice_index)
    return
  end
  engine_call("releaseSlice", slice_index)
end

function elasticat.release_all_slices()
  if engine_track > 1 then
    tr_call(engine_track, "releaseAllSlices")
    return
  end
  engine_call("releaseAllSlices")
end

function elasticat.set_loop_region(start_point, end_point, reset_playhead)
  if engine_track > 1 then
    -- Phase 1: raw 0-128 points for tracks 2-8 (no per-track trim/range map yet).
    tr_call(engine_track, "loopStart", util.clamp(start_point or 0, 0, 128))
    tr_call(engine_track, "loopEnd", util.clamp(end_point or 128, 0, 128))
    if type(reset_playhead) == "number" then
      tr_call(engine_track, "playhead", reset_playhead)
    elseif reset_playhead then
      tr_call(engine_track, "playhead", 0)
    end
    return
  end
  flush_engine_sends()
  local engine_start = map_trim_point(start_point)
  local engine_end = map_trim_point(end_point)
  if reset_playhead ~= nil and engine.loopRegionPlayhead ~= nil then
    local phase = type(reset_playhead) == "number" and reset_playhead or 0
    engine_call("loopRegionPlayhead", engine_start, engine_end, phase)
    return
  end

  engine_call("loopStart", engine_start)
  engine_call("loopEnd", engine_end)
  if type(reset_playhead) == "number" then
    engine_call("playhead", reset_playhead)
  elseif reset_playhead then
    engine_call("playhead", 0)
  end
end

-- Auditions the File-edit slot as a raw looped sample -- native rate, no
-- timestretch / pitch / warp -- through its own preview synth (engine
-- previewSlot), using the slot's trim window and gain. Only while master
-- transport is stopped so it never fights sequenced playback.
function elasticat.preview_trim(on)
  if on then
    if ids.play ~= nil and params:get(ids.play) == 1 then
      return
    end
    local slot = file_edit_slot
    local trim_start, trim_end, duration = trim_bounds(slot)
    local start_frac, end_frac = 0, 1
    if duration > 0 then
      start_frac = util.clamp(trim_start / duration, 0, 0.999)
      end_frac = util.clamp(trim_end / duration, start_frac + 0.001, 1)
    end
    local gain = sample_pool.gains[slot] or 1
    flush_engine_sends()
    engine_call("previewSlot", slot, start_frac, end_frac, gain, 1)
  else
    engine_call("previewSlot", 0, 0, 1, 1, 0)
  end
end

function elasticat.active_pool_slot()
  return active_sample_slot
end

function elasticat.file_edit_slot()
  return file_edit_slot
end

-- Active (playback) slot's BPM/steps, read straight from the pool so the visual
-- playhead rate stays correct even when the File page is editing another slot.
function elasticat.active_bpm()
  return sample_pool.bpms[active_sample_slot] or 120
end

function elasticat.active_steps()
  return sample_pool.steps[active_sample_slot] or 16
end

function elasticat.pool_path(slot)
  slot = slot or active_sample_slot
  if slot == 0 then
    return nil
  end
  return sample_pool.paths[sample_slot_number(slot)]
end

function elasticat.pool_label(slot)
  local path = elasticat.pool_path(slot)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return "empty"
  end
  return path:match("[^/\\]+$") or path
end

function elasticat.pool_meta(slot)
  slot = slot or active_sample_slot
  if slot == 0 then
    return { duration = 0, gain = 1 }
  end
  slot = sample_slot_number(slot)
  return {
    path = sample_pool.paths[slot],
    samples = sample_pool.samples[slot],
    rate = sample_pool.rates[slot],
    channels = sample_pool.channels[slot],
    bpm = sample_pool.bpms[slot],
    steps = sample_pool.steps[slot],
    trim_start = sample_pool.trim_starts[slot],
    trim_end = sample_pool.trim_ends[slot],
    gain = sample_pool.gains[slot] or 1,
    duration = sample_duration(slot)
  }
end

function elasticat.pool_snapshot()
  local snapshot = {}
  for slot = 1, 128 do
    if sample_pool.paths[slot] ~= nil then
      snapshot[slot] = {
        path = sample_pool.paths[slot],
        bpm = sample_pool.bpms[slot],
        steps = sample_pool.steps[slot],
        trim_start = sample_pool.trim_starts[slot],
        trim_end = sample_pool.trim_ends[slot],
        gain = sample_pool.gains[slot]
      }
    end
  end
  return snapshot
end

function elasticat.set_pool_slot(slot)
  set_active_pool_slot(slot)
end

-- Recompute BPM (filename, else keep current) and steps (from duration * bpm)
-- for the File-edit slot, applying to the pool + params (+ engine if it's also
-- the active slot).
function elasticat.recalc_bpm_steps()
  local slot = file_edit_slot
  local path = sample_pool.paths[slot]
  local samples = sample_pool.samples[slot] or 0
  local rate = sample_pool.rates[slot] or 0
  if path == nil or samples <= 0 or rate <= 0 then
    return
  end
  local duration = samples / rate
  local bpm = bpm_from_filename(path) or sample_pool.bpms[slot] or 120
  local steps = quantize_steps(duration * bpm / 60 * 4)
  sample_pool.bpms[slot] = bpm
  sample_pool.steps[slot] = steps
  -- Silent: update the display params (which track the file-edit slot) without
  -- firing their actions, then push to the engine only if this slot is playing.
  if params:lookup_param(ids.sample_bpm) ~= nil then
    params:set(ids.sample_bpm, bpm, true)
  end
  if params:lookup_param(ids.sample_steps) ~= nil then
    params:set(ids.sample_steps, steps, true)
  end
  if file_edits_active() then
    push_engine_slot_metadata(slot)
  end
  mark_pool_dirty(slot)
end

function elasticat.load_pool_slot(slot, path, make_active)
  if math.floor((tonumber(slot) or 1) + 0.5) < 1 then
    print("elasticat: slot 0 is Off; cannot load a sample there")
    return false
  end
  slot = sample_slot_number(slot)
  print("elasticat: pool slot " .. tostring(slot) .. " load " .. tostring(path))
  if path == nil or path == "-" or path == "" or path:sub(-1) == "/" or not is_audio_file(path) then
    print("elasticat: pool slot " .. tostring(slot) .. " ignored non-audio path")
    return false
  end
  if not util.file_exists(path) then
    print("elasticat: pool slot " .. tostring(slot) .. " missing " .. path)
    return false
  end

  local channels, samples, rate = audio.file_info(path)
  print("elasticat: audio.file_info slot=" .. tostring(slot) .. " ch=" .. tostring(channels) .. " samples=" .. tostring(samples) .. " rate=" .. tostring(rate))
  if (samples or 0) <= 0 or (rate or 0) <= 0 then
    print("elasticat: not an audio file: " .. path)
    return false
  end

  local filename_bpm = bpm_from_filename(path)
  local sidecar = read_sample_sidecar(path)
  local duration = samples / rate
  local param_bpm = params:lookup_param(ids.sample_bpm) ~= nil and params:get(ids.sample_bpm) or 120
  local param_steps = params:lookup_param(ids.sample_steps) ~= nil and params:get(ids.sample_steps) or 16
  -- BPM/step derivation mode: 1 auto (json > filename > current), 2 no change
  -- (keep current), 3 json only, 4 filename only. Governs whether a load
  -- overrides the BPM/steps you already dialed in.
  local mode = ids.bpm_step_mode ~= nil and params:lookup_param(ids.bpm_step_mode) ~= nil
    and params:get(ids.bpm_step_mode) or 1
  local bpm, steps
  if mode == 2 then
    bpm = sample_pool.bpms[slot] or param_bpm
    steps = sample_pool.steps[slot] or param_steps
  elseif mode == 3 then
    bpm = sidecar.bpm or sample_pool.bpms[slot] or param_bpm
    steps = sidecar.steps or quantize_steps(duration * bpm / 60 * 4)
  elseif mode == 4 then
    bpm = filename_bpm or sample_pool.bpms[slot] or param_bpm
    steps = quantize_steps(duration * bpm / 60 * 4)
  else
    bpm = sidecar.bpm or filename_bpm or sample_pool.bpms[slot] or param_bpm
    steps = sidecar.steps or quantize_steps(duration * bpm / 60 * 4)
  end
  local trim_start = util.clamp(sidecar.trim_start or sample_pool.trim_starts[slot] or 0, 0, duration)
  local trim_end = util.clamp(sidecar.trim_end or sample_pool.trim_ends[slot] or duration, 0, duration)
  if trim_end <= trim_start then
    trim_start = 0
    trim_end = duration
  end
  local gain = sidecar.gain or sample_pool.gains[slot] or 1

  sample_pool.paths[slot] = path
  sample_pool.samples[slot] = samples
  sample_pool.rates[slot] = rate
  sample_pool.channels[slot] = channels
  sample_pool.bpms[slot] = bpm
  sample_pool.steps[slot] = steps
  sample_pool.trim_starts[slot] = trim_start
  sample_pool.trim_ends[slot] = trim_end
  sample_pool.gains[slot] = gain

  if make_active then
    set_active_pool_slot(slot)
  end

  flush_engine_sends()
  load_sample_slot(slot, path)
  -- Refresh the File-page display if this is the edit slot, and re-push metadata
  -- to the engine if this is the playing slot.
  if slot == file_edit_slot then
    apply_file_slot_metadata(slot)
  end
  if slot == active_sample_slot then
    push_engine_slot_metadata(slot)
  end
  notify_pool_change("load", slot, path)
  return true
end

-- Wipe one pool slot's script-side state AND unload its engine buffer (New
-- Project / a project load that doesn't use this slot). Freeing the engine
-- buffer is required: without it an emptied ACTIVE slot kept looping the
-- previous sample on play. Only slots that actually held a sample send the
-- engine command, so a normal load doesn't spray 128 no-op clears.
local function clear_pool_slot(slot)
  local had_sample = sample_pool.paths[slot] ~= nil
  sample_pool.paths[slot] = nil
  sample_pool.samples[slot] = nil
  sample_pool.rates[slot] = nil
  sample_pool.channels[slot] = nil
  sample_pool.bpms[slot] = nil
  sample_pool.steps[slot] = nil
  sample_pool.trim_starts[slot] = nil
  sample_pool.trim_ends[slot] = nil
  sample_pool.gains[slot] = nil
  if had_sample then
    engine_call("clearPoolSlot", slot)
  end
end

-- Make the pool EXACTLY equal to `paths`: load the slots it lists and CLEAR
-- every slot it omits. Previously this only loaded, never cleared, so New
-- Project (paths = {}) left the old pool in place and one project's samples
-- bled into the next. All three callers (project load, New Project clear,
-- session restore) pass the authoritative full pool, so clearing is correct.
function elasticat.load_pool_paths(paths, selected_slot)
  if type(paths) ~= "table" then
    return
  end

  suppress_pool_callback = true
  selected_slot = sample_slot_number(selected_slot or active_sample_slot)
  for slot = 1, 128 do
    local entry = paths[slot] or paths[tostring(slot)]
    local path = type(entry) == "table" and entry.path or entry
    if path ~= nil and path ~= "" and path ~= "-" and util.file_exists(path) then
      elasticat.load_pool_slot(slot, path, slot == selected_slot)
      if type(entry) == "table" then
        sample_pool.bpms[slot] = tonumber(entry.bpm) or sample_pool.bpms[slot]
        sample_pool.steps[slot] = tonumber(entry.steps) or sample_pool.steps[slot]
        sample_pool.trim_starts[slot] = tonumber(entry.trim_start) or sample_pool.trim_starts[slot]
        sample_pool.trim_ends[slot] = tonumber(entry.trim_end) or sample_pool.trim_ends[slot]
        sample_pool.gains[slot] = tonumber(entry.gain) or sample_pool.gains[slot]
      end
    else
      clear_pool_slot(slot)
    end
  end
  -- Refresh the display/engine for the active + file-edit slots, which may now
  -- be empty (metadata resolves to defaults, sample shows "no sample").
  push_engine_slot_metadata(active_sample_slot)
  apply_file_slot_metadata(file_edit_slot)
  suppress_pool_callback = false
  notify_pool_change("restore", selected_slot, sample_pool.paths[selected_slot])
end

function elasticat.params(options)
  options = options or {}
  pool_options = options
  local prefix = options.prefix or "elasticat_"
  local default_sync = options.clock_sync == false and 0 or 1

  ids.sample_slot = param_id(prefix, "sample_slot")
  ids.sample = param_id(prefix, "sample")
  ids.machine = param_id(prefix, "machine")
  ids.mode = param_id(prefix, "mode")
  ids.play = param_id(prefix, "play")
  ids.clock_sync = param_id(prefix, "clock_sync")
  ids.target_bpm = param_id(prefix, "target_bpm")
  ids.sample_bpm = param_id(prefix, "sample_bpm")
  ids.sample_steps = param_id(prefix, "sample_steps")
  ids.file_slot = param_id(prefix, "file_slot")
  ids.bpm_step_mode = param_id(prefix, "bpm_step_mode")
  ids.recalc_bpm_steps = param_id(prefix, "recalc_bpm_steps")
  ids.trim_start = param_id(prefix, "trim_start")
  ids.trim_end = param_id(prefix, "trim_end")
  ids.gain = param_id(prefix, "gain")
  ids.amp = param_id(prefix, "amp")
  ids.loop_division = param_id(prefix, "loop_division")
  ids.trig_polyphony = param_id(prefix, "trig_polyphony")
  ids.playhead_return = param_id(prefix, "playhead_return")
  ids.pattern_steps = param_id(prefix, "pattern_steps")
  ids.pattern_quantize = param_id(prefix, "pattern_quantize")
  ids.global_pattern_length = param_id(prefix, "global_pattern_length")
  ids.global_bpm = param_id(prefix, "global_bpm")
  ids.default_length = param_id(prefix, "default_length")
  ids.default_velocity = param_id(prefix, "default_velocity")
  ids.trig_jump = param_id(prefix, "trig_jump")
  ids.trig_release = param_id(prefix, "trig_release")
  ids.live_step_trig = param_id(prefix, "live_step_trig")
  ids.trig_chance = param_id(prefix, "trig_chance")
  ids.trig_condition = param_id(prefix, "trig_condition")
  ids.trig_ratchet = param_id(prefix, "trig_ratchet")
  ids.swing = param_id(prefix, "swing")
  ids.env_reset = param_id(prefix, "env_reset")
  ids.lfo_reset = param_id(prefix, "lfo_reset")
  ids.filter_reset = param_id(prefix, "filter_reset")
  ids.loop_start = param_id(prefix, "loop_start")
  ids.loop_end = param_id(prefix, "loop_end")
  ids.range_start = param_id(prefix, "range_start")
  ids.range_end = param_id(prefix, "range_end")
  ids.range_end_sync = param_id(prefix, "range_end_sync")
  ids.sample_preview = param_id(prefix, "sample_preview")
  ids.mode_macro = param_id(prefix, "mode_macro")
  ids.mode_switch_fade = param_id(prefix, "mode_switch_fade")
  ids.debug = param_id(prefix, "debug")
  ids.live_performance_mode = param_id(prefix, "live_performance_mode")
  ids.step_preview = param_id(prefix, "step_preview")
  ids.pan = param_id(prefix, "pan")
  ids.crossfade = param_id(prefix, "crossfade")
  ids.env_attack = param_id(prefix, "env_attack")
  ids.env_decay = param_id(prefix, "env_decay")
  ids.env_sustain = param_id(prefix, "env_sustain")
  ids.env_release = param_id(prefix, "env_release")
  ids.env_hold = param_id(prefix, "env_hold")
  ids.env_mode = param_id(prefix, "env_mode")
  ids.env_range = param_id(prefix, "env_range")
  ids.portamento = param_id(prefix, "portamento")
  ids.filter_machine = param_id(prefix, "filter_machine")
  ids.filter_type = param_id(prefix, "filter_type")
  ids.filter_cutoff = param_id(prefix, "filter_cutoff")
  ids.filter_res = param_id(prefix, "filter_res")
  ids.filter_drive = param_id(prefix, "filter_drive")
  ids.filter_morph = param_id(prefix, "filter_morph")
  ids.filter_balance = param_id(prefix, "filter_balance")
  ids.filter_env_mode = param_id(prefix, "filter_env_mode")
  ids.filter_env_attack = param_id(prefix, "filter_env_attack")
  ids.filter_env_decay = param_id(prefix, "filter_env_decay")
  ids.filter_env_sustain = param_id(prefix, "filter_env_sustain")
  ids.filter_env_release = param_id(prefix, "filter_env_release")
  ids.filter_env_hold = param_id(prefix, "filter_env_hold")
  ids.filter_env_depth = param_id(prefix, "filter_env_depth")
  ids.fx_insert1_machine = param_id(prefix, "fx_insert1_machine")
  ids.fx_drive = param_id(prefix, "fx_drive")
  ids.fx_mix = param_id(prefix, "fx_mix")
  ids.delay_time = param_id(prefix, "delay_time")
  ids.delay_feedback = param_id(prefix, "delay_feedback")
  ids.delay_tone = param_id(prefix, "delay_tone")
  ids.reverb_size = param_id(prefix, "reverb_size")
  ids.reverb_damp = param_id(prefix, "reverb_damp")
  ids.lofi_bits = param_id(prefix, "lofi_bits")
  ids.lofi_rate = param_id(prefix, "lofi_rate")

  -- Send 1/2 + Master insert FX (PRD §3/§8): send tap point, per-send level,
  -- and the three machine selects. Each slot's Drive/Mix/Delay*/Reverb*/Lofi*
  -- ids are namespaced per slot (send1_/send2_/master_) via FxRegistry's
  -- `prefix` argument -- see fx_send1_items/fx_send2_items/fx_master_items
  -- below and lib/fx_modes/*.lua.
  ids.send_tap = param_id(prefix, "send_tap")
  ids.send1_level = param_id(prefix, "send1_level")
  ids.send2_level = param_id(prefix, "send2_level")
  ids.send1_machine = param_id(prefix, "send1_machine")
  ids.send2_machine = param_id(prefix, "send2_machine")
  ids.master_fx_machine = param_id(prefix, "master_fx_machine")
  ids.send1_fx_drive = param_id(prefix, "send1_fx_drive")
  ids.send1_fx_mix = param_id(prefix, "send1_fx_mix")
  ids.send1_delay_time = param_id(prefix, "send1_delay_time")
  ids.send1_delay_feedback = param_id(prefix, "send1_delay_feedback")
  ids.send1_delay_tone = param_id(prefix, "send1_delay_tone")
  ids.send1_reverb_size = param_id(prefix, "send1_reverb_size")
  ids.send1_reverb_damp = param_id(prefix, "send1_reverb_damp")
  ids.send1_lofi_bits = param_id(prefix, "send1_lofi_bits")
  ids.send1_lofi_rate = param_id(prefix, "send1_lofi_rate")
  ids.send2_fx_drive = param_id(prefix, "send2_fx_drive")
  ids.send2_fx_mix = param_id(prefix, "send2_fx_mix")
  ids.send2_delay_time = param_id(prefix, "send2_delay_time")
  ids.send2_delay_feedback = param_id(prefix, "send2_delay_feedback")
  ids.send2_delay_tone = param_id(prefix, "send2_delay_tone")
  ids.send2_reverb_size = param_id(prefix, "send2_reverb_size")
  ids.send2_reverb_damp = param_id(prefix, "send2_reverb_damp")
  ids.send2_lofi_bits = param_id(prefix, "send2_lofi_bits")
  ids.send2_lofi_rate = param_id(prefix, "send2_lofi_rate")
  ids.master_fx_drive = param_id(prefix, "master_fx_drive")
  ids.master_fx_mix = param_id(prefix, "master_fx_mix")
  ids.master_delay_time = param_id(prefix, "master_delay_time")
  ids.master_delay_feedback = param_id(prefix, "master_delay_feedback")
  ids.master_delay_tone = param_id(prefix, "master_delay_tone")
  ids.master_reverb_size = param_id(prefix, "master_reverb_size")
  ids.master_reverb_damp = param_id(prefix, "master_reverb_damp")
  ids.master_lofi_bits = param_id(prefix, "master_lofi_bits")
  ids.master_lofi_rate = param_id(prefix, "master_lofi_rate")

  -- Modulation: 2 LFOs + mod envelope (MOD category). Per-pattern sound
  -- params, registered like their siblings above (NOT pattern-global, NOT
  -- editor prefs, so pattern snapshots auto-include them).
  ids.lfo1_dest = param_id(prefix, "lfo1_dest")
  ids.lfo1_wave = param_id(prefix, "lfo1_wave")
  ids.lfo1_speed = param_id(prefix, "lfo1_speed")
  ids.lfo1_depth = param_id(prefix, "lfo1_depth")
  ids.lfo1_mode = param_id(prefix, "lfo1_mode")
  ids.lfo2_dest = param_id(prefix, "lfo2_dest")
  ids.lfo2_wave = param_id(prefix, "lfo2_wave")
  ids.lfo2_speed = param_id(prefix, "lfo2_speed")
  ids.lfo2_depth = param_id(prefix, "lfo2_depth")
  ids.lfo2_mode = param_id(prefix, "lfo2_mode")
  ids.menv_dest = param_id(prefix, "menv_dest")
  ids.menv_attack = param_id(prefix, "menv_attack")
  ids.menv_decay = param_id(prefix, "menv_decay")
  ids.menv_depth = param_id(prefix, "menv_depth")

  -- 4 macros: each a value knob (p-lockable) + a signed matrix depth to each of
  -- the 5 destinations (macroN_<dest>_depth).
  for m = 1, 4 do
    ids["macro" .. m .. "_value"] = param_id(prefix, "macro" .. m .. "_value")
    for _, dest in ipairs(MACRO_DESTS) do
      local suffix = "macro" .. m .. "_" .. dest.key .. "_depth"
      ids[suffix] = param_id(prefix, suffix)
    end
  end

  -- Phase 1 track scaffolding (docs/PHASE1_CONTRACT.md).
  track_prefix = prefix
  ids.active_track_count = param_id(prefix, "active_track_count")

  -- Projects (PRD §7, workstream C).
  ids.project_auto_name = param_id(prefix, "project_auto_name")
  ids.project_load = param_id(prefix, "project_load")
  ids.project_save = param_id(prefix, "project_save")
  ids.project_save_as = param_id(prefix, "project_save_as")
  ids.project_new = param_id(prefix, "project_new")

  local function apply_current_mode_params()
    local mode = params:get(ids.mode)
    if mode == 1 or mode == 2 then
      engine_call("loopStart", map_trim_point(params:get(ids.loop_start)))
      engine_call("loopEnd", map_trim_point(params:get(ids.loop_end)))
    elseif mode == 3 then
      engine_call("chopSteps", params:get(param_id(prefix, "chop_steps")))
      engine_call("chopLoopMode", params:get(param_id(prefix, "chop_loop_mode")) - 1)
      engine_call("chopAttack", params:get(param_id(prefix, "chop_attack")))
      engine_call("chopHold", params:get(param_id(prefix, "chop_hold")))
      engine_call("chopRelease", params:get(param_id(prefix, "chop_release")))
    elseif mode == 4 then
      engine_call("grainSize", params:get(param_id(prefix, "grain_size")))
      engine_call("grainDensity", params:get(param_id(prefix, "grain_density")))
      engine_call("grainJitter", params:get(param_id(prefix, "grain_jitter")))
    elseif mode == 5 then
      engine_call("wsolaWindow", params:get(param_id(prefix, "wsola_window")))
      engine_call("wsolaSearch", params:get(param_id(prefix, "wsola_search")))
    elseif mode == 6 then
      engine_call("pvWindow", params:get(param_id(prefix, "pv_window")))
      engine_call("pvDispersion", params:get(param_id(prefix, "pv_dispersion")))
    end
  end

  -- ---- PROJECT group (PRD §7, workstream C) --------------------------------
  -- Load/Save/Save As New/New Project + the auto-name setting, exposed as
  -- norns param actions rather than grid keys so this never touches the
  -- contended grid key routing (docs/WORKSTREAMS.md). Actions are thin --
  -- pattern_store/project_store/text_entry/fileselect all live in the
  -- coordinator (elasticat.lua), not this engine-facing facade -- so each
  -- trigger just calls the matching on_project_* callback from `options`
  -- (same coordinator-callback idiom as on_pool_change/on_sample_slot above).
  -- Memorize/Recall (PRD §7.2 FN+Octave grid keys) is explicitly out of scope
  -- here; it belongs to whoever owns lib/grid_sequencer.lua.
  params:add_group(param_id(prefix, "group_project"), "project", 5)

  params:add_trigger(ids.project_load, "load project")
  params:set_action(ids.project_load, function()
    if pool_options.on_project_load ~= nil then pool_options.on_project_load() end
  end)

  params:add_trigger(ids.project_save, "save project")
  params:set_action(ids.project_save, function()
    if pool_options.on_project_save ~= nil then pool_options.on_project_save() end
  end)

  params:add_trigger(ids.project_save_as, "save project as new")
  params:set_action(ids.project_save_as, function()
    if pool_options.on_project_save_as ~= nil then pool_options.on_project_save_as() end
  end)

  params:add_trigger(ids.project_new, "new project")
  params:set_action(ids.project_new, function()
    if pool_options.on_project_new ~= nil then pool_options.on_project_new() end
  end)

  -- Auto-naming (PRD §7.1) for New Project: None = "untitled" (rename via the
  -- PROJECT name row / Save As), Date = yymmdd-hhmm, Namesizer = a generated
  -- name from the /dust/code/namesizer library. Namesizer is best-effort:
  -- ProjectStore.namesizer_name() falls back to Date when the library isn't
  -- installed or its call fails, so offering the option is always safe. This is
  -- an EDITOR PREF (see EDITOR_PREF_SUFFIXES in elasticat.lua) -- it persists to
  -- editor_prefs.data and never changes when loading or creating projects.
  params:add_option(ids.project_auto_name, "project auto-name", {"none", "date", "namesizer"}, 1)

  params:add_group(param_id(prefix, "group_setup"), "elasticat setup", 18)

  add_control(ids.sample_slot, "sample slot",
    cs.new(0, 128, "lin", 1, 1, "", 1 / 128),
    function(x)
      set_active_pool_slot(x)
    end,
    function(param)
      local v = math.floor(param:get() + 0.5)
      return v < 1 and "off" or tostring(v)
    end)

  -- File-editor slot: which slot the File page edits, independent of the track's
  -- playback slot (sample_slot).
  add_control(ids.file_slot, "file edit slot",
    cs.new(1, 128, "lin", 1, 1, "", 1 / 127),
    function(x)
      set_file_edit_slot(x)
    end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_file(ids.sample, "sample", options.sample or _path.audio)
  params:set_action(ids.sample, function(path)
    print("elasticat: sample param action " .. tostring(path))
    if path ~= nil and path ~= "-" and path ~= "" and is_audio_file(path) then
      if not elasticat.load_pool_slot(file_edit_slot, path) then
        params:set(ids.sample, _path.audio, true)
      end
    end
  end)

  params:add_option(ids.machine, "machine", elasticat.machines, 1)
  params:set_action(ids.machine, function(x)
    flush_engine_sends()
    engine_call("setMode", params:get(ids.mode) - 1)
    apply_current_mode_params()
    if x == 1 then
      engine_call("play", params:get(ids.play))
    else
      engine_call("play", 0)
    end
  end)

  params:add_option(ids.mode, "engine mode", elasticat.modes, 1)
  params:set_action(ids.mode, function(x)
    flush_engine_sends()
    engine_call("setMode", x - 1)
    apply_current_mode_params()
  end)

  -- Lua-side grid-interaction settings only; never sent to the engine.
  add_control(ids.loop_division, "loop key division",
    cs.new(2, 32, "lin", 2, 16, "", 2 / 30),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(ids.trig_polyphony, "trig polyphony", {"mono", "poly"}, 1)

  -- Where the playhead lands when the last live loop key is released during
  -- playback: return (rejoin the sequence), boomerang (keep going from the
  -- current position), reset (jump to the region start). grid_sequencer reads
  -- this live; no engine action.
  -- Default Return: a tempo-warped loop stays perfectly synced through live
  -- loop-key performances, same reasoning as the step-level trig_release.
  params:add_option(ids.playhead_return, "playhead return", {"return", "boomerang", "reset"}, 1)

  add_control(ids.mode_macro, "mode macro",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(ids.mode_macro, "setModeMacro", x) end)

  params:add_binary(ids.play, "play", "toggle", 0)
  params:set_action(ids.play, set_engine_play)

  params:add_binary(ids.clock_sync, "clock sync", "toggle", default_sync)
  params:set_action(ids.clock_sync, function(x)
    if x == 1 then
      send_clock_observation()
      elasticat.start_clock_sync()
    else
      elasticat.stop_clock_sync()
    end
  end)

  -- Pure UI-behavior toggles, no engine action: live performance mode governs
  -- whether held loop keys override the sequencer during playback (grid_sequencer
  -- reads this live), and step preview gates whether holding a step/loop key while
  -- stopped audibly previews it.
  params:add_binary(ids.live_performance_mode, "live performance mode", "toggle", 0)
  params:add_binary(ids.step_preview, "step preview", "toggle", 1)
  -- Global BPM (PRD §6.1): off = tempo is per-pattern; on = one project-wide
  -- tempo regardless of the loaded pattern. Read by the pattern store's apply.
  params:add_binary(ids.global_bpm, "global bpm", "toggle", 0)
  params:set_action(ids.global_bpm, function(_) end)

  -- Track Volume + Pan are Elektron-style 0-127 (Pan centered at 64). The engine
  -- still receives a 0..1 amplitude / -1..1 pan; the mapping happens here.
  add_control(ids.amp, "amp",
    cs.new(0, 127, "lin", 1, 100, "", 1 / 127),
    function(_) send_effective_amp() end,
    format_env_level)

  -- Pan is bipolar, so it uses 0-128 (129 values) for a true center at 64:
  -- 0 = hard left, 64 = center, 128 = hard right, symmetric 64 steps each side.
  add_control(ids.pan, "pan",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) queue_engine_call(ids.pan, "setPan", (x - 64) / 64) end,
    format_pan_127)

  -- A/B scene crossfader position (PRD §6.6 requirement 2), MASTER page,
  -- encoder-adjustable. Straight 0-128 (not centered like pan/filter_balance):
  -- 0 = fully Scene A, 128 = fully Scene B. No engine call here -- this is a
  -- coordinator-side morph (SceneStore lives in elasticat.lua, not this
  -- engine-facing facade), so the action is only the pool_options.on_crossfade
  -- callback idiom (mirrors on_project_load etc. above).
  add_control(ids.crossfade, "crossfade",
    cs.new(0, 128, "lin", 1, 0, "", 1 / 128),
    function(x) if pool_options.on_crossfade ~= nil then pool_options.on_crossfade(x) end end)

  -- Amp envelope (0-127 Elektron style; times mapped exponentially to seconds via
  -- env_range). ADSR uses attack/decay/sustain/release, AHR uses attack/hold/release.
  add_control(ids.env_attack, "env attack",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.env_attack, "envAttack", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.env_decay, "env decay",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.env_decay, "envDecay", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.env_sustain, "env sustain",
    cs.new(0, 127, "lin", 1, 100, "", 1 / 127),
    function(x) queue_engine_call(ids.env_sustain, "envSustain", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  -- Release and Hold reach 128 = INF: the envelope holds (AHR) / stays at sustain
  -- (ADSR) forever until the next trigger. Default AHR is 0 / INF / 0 -- an
  -- instant attack that holds full, i.e. a continuous drone.
  add_control(ids.env_release, "env release",
    cs.new(0, 128, "lin", 1, 0, "", 1 / 128),
    function(x) queue_engine_call(ids.env_release, "envRelease", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.env_hold, "env hold",
    cs.new(0, 128, "lin", 1, 128, "", 1 / 128),
    function(x) queue_engine_call(ids.env_hold, "envHold", env_value_to_seconds(x)) end,
    format_env_time)

  params:add_option(ids.env_mode, "envelope mode", {"ADSR", "AHR"}, 2)
  params:set_action(ids.env_mode, function(x)
    queue_engine_call(ids.env_mode, "setEnvMode", x - 1)  -- 0 = ADSR, 1 = AHR
  end)

  params:add_option(ids.env_range, "envelope range",
    {"1s", "4s", "8s", "16s", "32s", "64s", "128s", "256s", "512s", "1024s"}, 3)
  params:set_action(ids.env_range, function(_)
    resend_env_times()
    resend_filter_env_times()
    resend_menv_times()
  end)

  -- Portamento (mono overlap): off = a new trigger re-attacks; on = an
  -- overlapping trigger glides without re-attacking the amp envelope.
  params:add_binary(ids.portamento, "portamento", "toggle", 0)
  params:set_action(ids.portamento, function(x)
    queue_engine_call(ids.portamento, "setPortamento", x)
  end)

  add_control(param_id(prefix, "source_bpm"), "derived source bpm",
    cs.new(20, 300, "lin", 0.1, 120, "bpm", 1 / 280),
    function(_) end)

  add_control(ids.target_bpm, "target bpm",
    cs.new(20, 300, "lin", 1, 120, "bpm", 1 / 280),
    function(x)
      queue_engine_send(ids.target_bpm, function()
        set_internal_clock_tempo(x)
        engine_call("targetBpm", x)
      end)
    end)

  add_control(ids.sample_bpm, "sample bpm",
    cs.new(20, 300, "lin", 1, 120, "bpm", 1 / 280),
    function(x)
      sample_pool.bpms[file_edit_slot] = x
      mark_pool_dirty(file_edit_slot)
      if file_edits_active() then
        if params:lookup_param(param_id(prefix, "source_bpm")) ~= nil then
          params:set(param_id(prefix, "source_bpm"), x, true)
        end
        queue_engine_call(ids.sample_bpm, "sourceBpm", x)
      end
    end)

  add_control(ids.sample_steps, "sample steps",
    cs.new(1, 512, "lin", 1, 16, "", 1 / 511),
    function(x)
      sample_pool.steps[file_edit_slot] = x
      mark_pool_dirty(file_edit_slot)
      if file_edits_active() then
        queue_engine_call(ids.sample_steps, "setSampleSteps", x)
      end
    end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(ids.bpm_step_mode, "bpm/step mode",
    {"auto", "no change", "json", "filename"}, 1)

  -- Recalc trigger: selecting "run" recompiles BPM (filename, else current) and
  -- steps for the active sample slot, then snaps back to "-".
  params:add_option(ids.recalc_bpm_steps, "recalc bpm/steps", {"-", "run"}, 1)
  params:set_action(ids.recalc_bpm_steps, function(x)
    if x == 2 then
      elasticat.recalc_bpm_steps()
      params:set(ids.recalc_bpm_steps, 1, true)
    end
  end)

  add_control(ids.trim_start, "sample trim start",
    cs.new(0, 3600, "lin", 0.001, 0, "s", 0.001),
    function(x)
      local slot = file_edit_slot
      local prev_start, prev_end, duration = trim_bounds(slot)
      -- Dragging trim start shifts trim end by the same amount, so the
      -- trimmed length stays constant while scrubbing -- unless trim end is
      -- pinned at the sample's actual end, in which case it stops there and
      -- further start movement just shortens the trim. Deriving trim end
      -- from its own previous value (not a remembered "original" length)
      -- means it un-pins the instant start moves back the other way.
      local next_start = util.clamp(x, 0, duration)
      local delta = next_start - prev_start
      local next_end = util.clamp(prev_end + delta, 0, duration)
      next_start = util.clamp(next_start, 0, math.max(0, next_end - 0.001))
      sample_pool.trim_starts[slot] = next_start
      sample_pool.trim_ends[slot] = next_end
      if math.abs(next_start - x) > 0.000001 then
        params:set(ids.trim_start, next_start, true)
      end
      if math.abs(next_end - prev_end) > 0.000001 then
        params:set(ids.trim_end, next_end, true)
      end
      if file_edits_active() then
        update_engine_loop_points()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.3f s", param:get()) end)

  add_control(ids.trim_end, "sample trim end",
    cs.new(0, 3600, "lin", 0.001, 0, "s", 0.001),
    function(x)
      local slot = file_edit_slot
      local trim_start, _, duration = trim_bounds(slot)
      local next_end = util.clamp(x, math.min(duration, trim_start + 0.001), duration)
      sample_pool.trim_ends[slot] = next_end
      if math.abs(next_end - x) > 0.000001 then
        params:set(ids.trim_end, next_end, true)
      end
      if file_edits_active() then
        update_engine_loop_points()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.3f s", param:get()) end)

  add_control(ids.gain, "sample gain",
    cs.new(0, 4, "lin", 0.01, 1, "x", 0.005),
    function(x)
      local slot = file_edit_slot
      sample_pool.gains[slot] = x
      if file_edits_active() then
        send_effective_amp()
      end
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.2fx", param:get()) end)

  add_control(ids.pattern_steps, "pattern steps",
    cs.new(1, 256, "lin", 1, 16, "", 1 / 255),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  -- Pattern system (PRD §6). pattern_quantize = Tonverk-style change timing;
  -- global_pattern_length = the project-wide cycle a sequential switch engages
  -- on (per-pattern, defaults to follow the track length). No engine action --
  -- these steer the coordinator's pattern store.
  params:add_option(ids.pattern_quantize, "pattern change",
    {"sequential", "direct jump", "direct start", "temp jump"}, 1)
  params:set_action(ids.pattern_quantize, function(_) end)

  add_control(ids.global_pattern_length, "global pattern length",
    cs.new(1, 256, "lin", 1, 16, "", 1 / 255),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(ids.default_length, "default trig length",
    cs.new(0.25, 16, "lin", 0.25, 1, "", 0.25 / 15.75),
    function(_) end,
    function(param) return string.format("%.2f", param:get()) end)

  add_control(ids.default_velocity, "default velocity",
    cs.new(0, 1, "lin", 0.01, 1, "", 0.01),
    function(_) end,
    function(param) return tostring(math.floor((param:get() * 100) + 0.5)) end)

  -- Ghost-trigger reset flags (default on). A normal trigger resets envelope /
  -- LFO / filter; a ghost trigger has these off. No engine action yet -- env /
  -- LFO / filter don't exist until Phase 2/3, so these are forward-compatible
  -- placeholders that also feed the ghost/normal derivation in grid_sequencer.
  params:add_binary(ids.env_reset, "env reset", "toggle", 1)
  params:add_binary(ids.lfo_reset, "lfo reset", "toggle", 1)
  params:add_binary(ids.filter_reset, "filter reset", "toggle", 1)

  -- Trig Jump (default on, p-lockable): on = a step with a start/end lock always
  -- warps the playhead to the region start; off = it only repositions if the
  -- playhead is now outside the new region (otherwise it keeps playing). Pure
  -- sequencing behaviour in grid_sequencer -- no engine action.
  params:add_binary(ids.trig_jump, "trig jump", "toggle", 1)
  params:set_action(ids.trig_jump, function(_) end)

  -- Trig Release (default Return, p-lockable): where the playhead lands when a
  -- region-locking step's window ends. Return = where the main loop would
  -- naturally be (keeps a tempo-warped loop perfectly synced through step
  -- overrides), Boomerang = continue from the override's position, Reset =
  -- region start. Pure sequencing behaviour in grid_sequencer.
  params:add_option(ids.trig_release, "trig release", {"return", "boomerang", "reset"}, 1)
  params:set_action(ids.trig_release, function(_) end)

  -- Live Step Trig (master setting, default off): while playing, holding a step
  -- fires it immediately and it overrides the sequence until released. Off =
  -- holding a step during playback does nothing.
  params:add_binary(ids.live_step_trig, "live step trig", "toggle", 0)
  params:set_action(ids.live_step_trig, function(_) end)

  -- Conditional trigs (p-lockable; consumed at trigger time in grid_sequencer,
  -- no engine action). A step fires only if BOTH pass:
  --  * Chance: 0-100% probability. (Deliberately 0-100, not the 0-127 amount
  --    convention -- it's a literal percentage.)
  --  * Condition: none | A:B cycles | fill/!fill | pre/!pre | nei/!nei | 1st.
  --    NEI/!NEI evaluate always-true until the neighbor machine exists.
  params:add_number(ids.trig_chance, "trig chance", 0, 100, 100)
  params:set_action(ids.trig_chance, function(_) end)
  params:add_option(ids.trig_condition, "trig condition", TRIG_CONDITIONS, 1)
  params:set_action(ids.trig_condition, function(_) end)

  -- Ratchet: per-step retrig count -- the step re-triggers this many times,
  -- evenly across its duration (1 = normal single hit). P-lockable.
  params:add_number(ids.trig_ratchet, "trig ratchet", 1, 8, 1)
  params:set_action(ids.trig_ratchet, function(_) end)

  -- Swing (global; per-step micro-offset comes later): 50 = straight, higher
  -- delays every other step. Pure timing in grid_sequencer, no engine action.
  params:add_number(ids.swing, "swing", 50, 75, 50)
  params:set_action(ids.swing, function(_) end)

  params:add_group(param_id(prefix, "group_loop"), "loop playback", 6)

  add_control(param_id(prefix, "playhead"), "playhead",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(param_id(prefix, "playhead"), "setPlayhead", x) end)
  if params.hide ~= nil then
    params:hide(param_id(prefix, "playhead"))
  end

  -- Track region edits: while the sequencer is running, the coordinator's
  -- on_region_edit routes the change through the layered region resolver
  -- (Track / Step-p-lock / Actual -- the Actual layer owns the engine during
  -- playback, so a live edit is heard immediately unless a step's region lock
  -- is shadowing it). When stopped (hook returns false), push directly.
  local function region_edit_handled()
    return pool_options.on_region_edit ~= nil and pool_options.on_region_edit() == true
  end

  add_control(ids.loop_start, "sample start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x)
      if not region_edit_handled() then
        queue_engine_call(ids.loop_start, "loopStart", map_trim_point(x))
      end
    end)

  add_control(ids.loop_end, "sample end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x)
      if not region_edit_handled() then
        queue_engine_call(ids.loop_end, "loopEnd", map_trim_point(x))
      end
    end)

  -- Range narrows the trim window; changing it re-maps the current loop points
  -- through map_trim_point. During sequenced playback the grid re-sets the
  -- region every step, so this just handles the base/encoder-driven case.
  local last_range_start = 0

  add_control(ids.range_start, "range start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x)
      -- When E-SNC is on, range start and end move as one rigid pair: the shared
      -- delta is clamped so end stays <= 128 and start stays >= 0, which keeps
      -- the length constant even on a fast overshoot into the boundary. (Moving
      -- end freely then clamping only end used to collapse the gap at 128 and
      -- then drag end back down on the way out -- the "bounce to 120".)
      if ids.range_end_sync ~= nil and params:get(ids.range_end_sync) == 1 then
        local prev_start = last_range_start
        local prev_end = params:get(ids.range_end) or 128
        local delta = util.clamp(x - prev_start, -prev_start, 128 - prev_end)
        local next_start = prev_start + delta
        local next_end = prev_end + delta
        if math.abs(next_start - x) > 0.000001 then
          params:set(ids.range_start, next_start, true)
        end
        params:set(ids.range_end, next_end, true)
        last_range_start = next_start
      else
        -- Independent: start can never reach end. Clamp to end - 1 (so its max
        -- is 127 when end is 128), which stops the start marker at the end
        -- rather than crossing it.
        local max_start = util.clamp((params:get(ids.range_end) or 128) - 1, 0, 127)
        if x > max_start then
          params:set(ids.range_start, max_start, true)
          last_range_start = max_start
        else
          last_range_start = x
        end
      end
      if not region_edit_handled() then
        queue_engine_loop_points()
      end
    end)

  add_control(ids.range_end, "range end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x)
      -- End can never reach start: its minimum is start + 1.
      local min_end = util.clamp((params:get(ids.range_start) or 0) + 1, 1, 128)
      if x < min_end then
        params:set(ids.range_end, min_end, true)
      end
      if not region_edit_handled() then
        queue_engine_loop_points()
      end
    end)

  -- E-SNC: when on, range end tracks range start (see range_start action and the
  -- grid p-lock auto-lock in param_values). Default off -- a new user could be
  -- confused that start won't move independently until end is adjusted. Pure UI
  -- behavior, no engine action.
  params:add_binary(ids.range_end_sync, "range end sync", "toggle", 0)

  -- Sample preview: momentary audition of the current sample's trim window,
  -- only while master playback is stopped (see elasticat.preview_trim). Driven
  -- by encoder on the File page and/or a grid hold.
  params:add_binary(ids.sample_preview, "sample preview", "toggle", 0)
  params:set_action(ids.sample_preview, function(x)
    elasticat.preview_trim(x == 1)
  end)

  add_control(param_id(prefix, "xfade"), "loop xfade",
    cs.new(0, 0.25, "lin", 0.001, 0.005, "", 0.004),
    function(x) queue_engine_call(param_id(prefix, "xfade"), "xfade", x) end,
    format_ms)

  add_control(param_id(prefix, "pitch"), "pitch",
    cs.new(-24, 24, "lin", 0.1, 0, "st", 0.1 / 48),
    function(x) queue_engine_call(param_id(prefix, "pitch"), "setPitch", x) end)

  params:add_binary(param_id(prefix, "loop_reverse"), "loop reverse", "toggle", 0)
  params:set_action(param_id(prefix, "loop_reverse"), function(x)
    queue_engine_call(param_id(prefix, "loop_reverse"), "setReverse", x)
  end)

  params:add_group(param_id(prefix, "group_filter"), "filter", 14)

  -- Filter machine is a setting (respawns the engine's filter synth), not
  -- p-lockable. Machine index -> engine 0-based.
  params:add_option(ids.filter_machine, "filter machine", FilterRegistry.names(), 1)
  params:set_action(ids.filter_machine, function(x)
    queue_engine_call(ids.filter_machine, "setFilterMachine", x - 1)
  end)

  -- Type: 4-way multimode (Classic machines). Option 1-4 -> engine 0-3.
  params:add_option(ids.filter_type, "filter type", FILTER_TYPE_LABELS, 1)
  params:set_action(ids.filter_type, function(x)
    queue_engine_call(ids.filter_type, "filterType", x - 1)
  end)

  -- Cutoff / Res / Drive are 0-127 amounts. Cutoff maps exponentially to Hz;
  -- Res and Drive map linearly to 0..1 in the engine.
  add_control(ids.filter_cutoff, "filter cutoff",
    cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_cutoff, "filterCutoff", filter_cutoff_hz(x)) end,
    format_filter_cutoff)

  add_control(ids.filter_res, "filter resonance",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_res, "filterRes", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  add_control(ids.filter_drive, "filter drive",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_drive, "filterDrive", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  -- Morph: centered 0-128 (Morphing machines). 0 LP -> 64 notch -> 128 HP,
  -- sent to the engine as 0..1.
  add_control(ids.filter_morph, "filter morph",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) queue_engine_call(ids.filter_morph, "filterMorph", util.clamp(x / 128, 0, 1)) end,
    format_filter_morph)

  -- Balance: centered 0-128 (stereo/mid-side machines only; #3-6). Shared id
  -- across both interpretations (L/R spread on stereo, Mid/Side spread on
  -- M/S) -- same idiom as pan's (x-64)/64 mapping to the engine's -1..1
  -- filterBalance.
  add_control(ids.filter_balance, "filter balance",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) queue_engine_call(ids.filter_balance, "filterBalance", (x - 64) / 64) end,
    format_filter_balance)

  -- Filter envelope: independent mode from the amp env, but reuses the amp's
  -- seconds mapping (env_range) for its times. Whole envelope is p-lockable.
  add_control(ids.filter_env_attack, "filter env attack",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_env_attack, "filterEnvAttack", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.filter_env_decay, "filter env decay",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_env_decay, "filterEnvDecay", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.filter_env_sustain, "filter env sustain",
    cs.new(0, 127, "lin", 1, 100, "", 1 / 127),
    function(x) queue_engine_call(ids.filter_env_sustain, "filterEnvSustain", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  add_control(ids.filter_env_release, "filter env release",
    cs.new(0, 128, "lin", 1, 0, "", 1 / 128),
    function(x) queue_engine_call(ids.filter_env_release, "filterEnvRelease", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.filter_env_hold, "filter env hold",
    cs.new(0, 128, "lin", 1, 128, "", 1 / 128),
    function(x) queue_engine_call(ids.filter_env_hold, "filterEnvHold", env_value_to_seconds(x)) end,
    format_env_time)

  -- Depth: bipolar 0-128 (64 = no modulation) -> engine -1..1 (+/-6 octaves).
  add_control(ids.filter_env_depth, "filter env depth",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) queue_engine_call(ids.filter_env_depth, "filterEnvDepth", (x - 64) / 64) end,
    format_filter_depth)

  params:add_option(ids.filter_env_mode, "filter envelope mode", {"ADSR", "AHR"}, 2)
  params:set_action(ids.filter_env_mode, function(x)
    queue_engine_call(ids.filter_env_mode, "filterEnvMode", x - 1)  -- 0 = ADSR, 1 = AHR
  end)

  params:add_group(param_id(prefix, "group_fx"), "fx", 10)

  -- FX Insert 1 machine is a setting (respawns the engine's insert synth), not
  -- p-lockable -- same idiom as filter_machine. Machine index -> engine 0-based;
  -- index 0/option 1 (NONE) is the always-present dry passthrough.
  params:add_option(ids.fx_insert1_machine, "fx insert 1 machine", FxRegistry.names(), 1)
  params:set_action(ids.fx_insert1_machine, function(x)
    queue_engine_call(ids.fx_insert1_machine, "setInsertMachine", x - 1)
  end)

  -- Drive / Mix are 0-127 amounts shared by every wet FX machine (DRIVE uses
  -- fx_drive+fx_mix; DELAY/REVERB/LOFI reuse fx_mix alongside their own knobs) --
  -- same "shared id across machines" idiom as the filter's cutoff/res/drive.
  add_control(ids.fx_drive, "fx drive",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.fx_drive, "fxDrive", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  add_control(ids.fx_mix, "fx mix",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.fx_mix, "fxMix", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  -- Delay time: beat-division options param (PRD SS5), not raw seconds -- stays
  -- in sync across tempo changes since the engine recomputes seconds from
  -- targetBpm every block.
  params:add_option(ids.delay_time, "delay time", DELAY_TIME_LABELS, 4)
  params:set_action(ids.delay_time, function(x)
    queue_engine_call(ids.delay_time, "delayTime", DELAY_TIME_BEATS[x] or 1)
  end)

  add_control(ids.delay_feedback, "delay feedback",
    cs.new(0, 127, "lin", 1, 38, "", 1 / 127),
    function(x) queue_engine_call(ids.delay_feedback, "delayFeedback", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  -- Tone: the feedback-loop filter amount. 0-127, matching the other FX
  -- amounts, mapped in the engine to a lowpass cutoff (higher = brighter/more
  -- open); see the elasticatFxDelay SynthDef.
  add_control(ids.delay_tone, "delay tone",
    cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
    function(x) queue_engine_call(ids.delay_tone, "delayTone", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  add_control(ids.reverb_size, "reverb size",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.reverb_size, "reverbSize", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  add_control(ids.reverb_damp, "reverb damp",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.reverb_damp, "reverbDamp", util.clamp(x / 127, 0, 1)) end,
    format_env_level)

  -- Lofi bits/rate map to real units (bit depth / Hz), like filter cutoff, so
  -- they get dedicated formatters instead of format_env_level.
  add_control(ids.lofi_bits, "lofi bits",
    cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
    function(x) queue_engine_call(ids.lofi_bits, "lofiBits", lofi_bits_depth(x)) end,
    format_lofi_bits)

  add_control(ids.lofi_rate, "lofi rate",
    cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
    function(x) queue_engine_call(ids.lofi_rate, "lofiRate", lofi_rate_hz(x)) end,
    format_lofi_rate)

  -- Send 1/2 + Master insert FX (PRD §3/§8): each slot reuses the exact same
  -- Drive/Mix/Delay*/Reverb*/Lofi* shape as Insert 1 above -- this local
  -- helper registers one slot's 9 knobs against its own namespaced ids and
  -- engine commands (send1FxDrive/send2FxDrive/masterFxDrive, etc. -- see
  -- lib/Engine_Elasticat.sc's "Send 1/2 + Master insert FX" command block).
  local function register_send_fx_params(slot_ids, cmd_prefix, display_prefix)
    add_control(slot_ids.fx_drive, display_prefix .. " drive",
      cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.fx_drive, cmd_prefix .. "FxDrive", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    add_control(slot_ids.fx_mix, display_prefix .. " mix",
      cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.fx_mix, cmd_prefix .. "FxMix", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    params:add_option(slot_ids.delay_time, display_prefix .. " delay time", DELAY_TIME_LABELS, 4)
    params:set_action(slot_ids.delay_time, function(x)
      queue_engine_call(slot_ids.delay_time, cmd_prefix .. "DelayTime", DELAY_TIME_BEATS[x] or 1)
    end)

    add_control(slot_ids.delay_feedback, display_prefix .. " delay feedback",
      cs.new(0, 127, "lin", 1, 38, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.delay_feedback, cmd_prefix .. "DelayFeedback", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    add_control(slot_ids.delay_tone, display_prefix .. " delay tone",
      cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.delay_tone, cmd_prefix .. "DelayTone", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    add_control(slot_ids.reverb_size, display_prefix .. " reverb size",
      cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.reverb_size, cmd_prefix .. "ReverbSize", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    add_control(slot_ids.reverb_damp, display_prefix .. " reverb damp",
      cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.reverb_damp, cmd_prefix .. "ReverbDamp", util.clamp(x / 127, 0, 1)) end,
      format_env_level)

    add_control(slot_ids.lofi_bits, display_prefix .. " lofi bits",
      cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.lofi_bits, cmd_prefix .. "LofiBits", lofi_bits_depth(x)) end,
      format_lofi_bits)

    add_control(slot_ids.lofi_rate, display_prefix .. " lofi rate",
      cs.new(0, 127, "lin", 1, 127, "", 1 / 127),
      function(x) queue_engine_call(slot_ids.lofi_rate, cmd_prefix .. "LofiRate", lofi_rate_hz(x)) end,
      format_lofi_rate)
  end

  -- Send tap: which point in the chain Send 1/2 pull from -- pre-insert (i.e.
  -- post-filter) or post-insert-1 (PRD §3). A setting, not p-lockable (it's a
  -- bus-select argument on the tap synth, not a per-note articulation).
  params:add_group(param_id(prefix, "group_fx_routing"), "fx routing", 1)
  params:add_option(ids.send_tap, "send tap", {"pre insert", "post insert"}, 1)
  params:set_action(ids.send_tap, function(x)
    queue_engine_call(ids.send_tap, "setSendTap", x - 1)
  end)

  -- Send 1: machine is a setting (respawns the engine's send1 synth); level is
  -- the continuous, p-lockable send amount pushed live to the tap synth.
  params:add_group(param_id(prefix, "group_send1"), "send 1", 11)
  params:add_option(ids.send1_machine, "send 1 machine", FxRegistry.names(), 1)
  params:set_action(ids.send1_machine, function(x)
    queue_engine_call(ids.send1_machine, "setSend1Machine", x - 1)
  end)
  add_control(ids.send1_level, "send 1 level",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.send1_level, "sendLevel1", util.clamp(x / 127, 0, 1)) end,
    format_env_level)
  register_send_fx_params({
    fx_drive = ids.send1_fx_drive,
    fx_mix = ids.send1_fx_mix,
    delay_time = ids.send1_delay_time,
    delay_feedback = ids.send1_delay_feedback,
    delay_tone = ids.send1_delay_tone,
    reverb_size = ids.send1_reverb_size,
    reverb_damp = ids.send1_reverb_damp,
    lofi_bits = ids.send1_lofi_bits,
    lofi_rate = ids.send1_lofi_rate
  }, "send1", "send 1")

  -- Send 2: mirrors Send 1.
  params:add_group(param_id(prefix, "group_send2"), "send 2", 11)
  params:add_option(ids.send2_machine, "send 2 machine", FxRegistry.names(), 1)
  params:set_action(ids.send2_machine, function(x)
    queue_engine_call(ids.send2_machine, "setSend2Machine", x - 1)
  end)
  add_control(ids.send2_level, "send 2 level",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.send2_level, "sendLevel2", util.clamp(x / 127, 0, 1)) end,
    format_env_level)
  register_send_fx_params({
    fx_drive = ids.send2_fx_drive,
    fx_mix = ids.send2_fx_mix,
    delay_time = ids.send2_delay_time,
    delay_feedback = ids.send2_delay_feedback,
    delay_tone = ids.send2_delay_tone,
    reverb_size = ids.send2_reverb_size,
    reverb_damp = ids.send2_reverb_damp,
    lofi_bits = ids.send2_lofi_bits,
    lofi_rate = ids.send2_lofi_rate
  }, "send2", "send 2")

  -- Master insert: sits after Insert 1 and both send returns, before the
  -- track's one stereo output path (PRD §3). No level control -- it's always
  -- in the chain, machine NONE (default) is the bypass.
  params:add_group(param_id(prefix, "group_master_fx"), "master fx", 10)
  params:add_option(ids.master_fx_machine, "master fx machine", FxRegistry.names(), 1)
  params:set_action(ids.master_fx_machine, function(x)
    queue_engine_call(ids.master_fx_machine, "setMasterMachine", x - 1)
  end)
  register_send_fx_params({
    fx_drive = ids.master_fx_drive,
    fx_mix = ids.master_fx_mix,
    delay_time = ids.master_delay_time,
    delay_feedback = ids.master_delay_feedback,
    delay_tone = ids.master_delay_tone,
    reverb_size = ids.master_reverb_size,
    reverb_damp = ids.master_reverb_damp,
    lofi_bits = ids.master_lofi_bits,
    lofi_rate = ids.master_lofi_rate
  }, "master", "master fx")

  -- Modulation (MOD category): 2 LFOs + 1 mod envelope, all engine-side (one
  -- control-rate \elasticatMod synth; see Engine_Elasticat.sc). Each LFO slot
  -- shares the exact same 5-knob shape, so one local helper registers both
  -- against namespaced ids/commands -- the register_send_fx_params idiom.
  -- DEP is the project-standard bipolar 0-128 (64 = off/center); SPD is a
  -- tempo-synced musical division sent as beats-per-cycle; DEST/WAVE/MODE are
  -- settings-style selectors (not p-lockable in this first stab).
  local function register_lfo_params(slot_ids, cmd_prefix, display_prefix)
    params:add_option(slot_ids.dest, display_prefix .. " dest", MOD_DEST_LABELS, 1)
    params:set_action(slot_ids.dest, function(x)
      queue_engine_call(slot_ids.dest, cmd_prefix .. "Dest", x - 1)
    end)

    params:add_option(slot_ids.wave, display_prefix .. " wave", MOD_WAVE_LABELS, 1)
    params:set_action(slot_ids.wave, function(x)
      queue_engine_call(slot_ids.wave, cmd_prefix .. "Wave", x - 1)
    end)

    params:add_option(slot_ids.speed, display_prefix .. " speed", MOD_SPEED_LABELS, 4)
    params:set_action(slot_ids.speed, function(x)
      queue_engine_call(slot_ids.speed, cmd_prefix .. "Speed", MOD_SPEED_BEATS[x] or 4)
    end)

    add_control(slot_ids.depth, display_prefix .. " depth",
      cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
      function(x) queue_engine_call(slot_ids.depth, cmd_prefix .. "Depth", (x - 64) / 64) end,
      format_filter_depth)

    params:add_option(slot_ids.mode, display_prefix .. " mode", MOD_LFO_MODE_LABELS, 1)
    params:set_action(slot_ids.mode, function(x)
      queue_engine_call(slot_ids.mode, cmd_prefix .. "Mode", x - 1)
    end)
  end

  -- 14 LFO/mod-env params + 24 macro params (4 x [value + 5 matrix depths]) = 38.
  params:add_group(param_id(prefix, "group_mod"), "modulation", 38)

  register_lfo_params({
    dest = ids.lfo1_dest,
    wave = ids.lfo1_wave,
    speed = ids.lfo1_speed,
    depth = ids.lfo1_depth,
    mode = ids.lfo1_mode
  }, "lfo1", "lfo 1")

  register_lfo_params({
    dest = ids.lfo2_dest,
    wave = ids.lfo2_wave,
    speed = ids.lfo2_speed,
    depth = ids.lfo2_depth,
    mode = ids.lfo2_mode
  }, "lfo2", "lfo 2")

  -- Mod envelope: an AD burst per note (env_reset semantics -- retriggered
  -- wherever the amp env retrigs and the step's ERST resolves ON). ATK/DEC
  -- reuse the amp env's exponential seconds mapping (env_range).
  params:add_option(ids.menv_dest, "mod env dest", MOD_DEST_LABELS, 1)
  params:set_action(ids.menv_dest, function(x)
    queue_engine_call(ids.menv_dest, "menvDest", x - 1)
  end)

  add_control(ids.menv_attack, "mod env attack",
    cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
    function(x) queue_engine_call(ids.menv_attack, "menvAttack", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.menv_decay, "mod env decay",
    cs.new(0, 127, "lin", 1, 64, "", 1 / 127),
    function(x) queue_engine_call(ids.menv_decay, "menvDecay", env_value_to_seconds(x)) end,
    format_env_time)

  add_control(ids.menv_depth, "mod env depth",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) queue_engine_call(ids.menv_depth, "menvDepth", (x - 64) / 64) end,
    format_filter_depth)

  -- 4 macros. VALUE (0-127 -> 0..1) is the knob the grid macro keys / MACRO
  -- page drive, p-lockable per step. Each macro is a MOD MATRIX: a signed depth
  -- (bipolar 0-128, 64 = off) to each of the 5 destinations, dialed by holding
  -- the macro key and turning that destination's param. The macro contributes
  -- VALUE * depth[d] to destination d, summing with the LFOs/mod-env -- and an
  -- LFO/env can target the macro (DEST = MACRO1..4) to modulate VALUE. The
  -- 20 matrix-depth params are hidden from the PARAMS menu (the grid gesture is
  -- their interface) but still serialize with patterns/projects.
  for m = 1, 4 do
    local mi = m
    local vid = ids["macro" .. m .. "_value"]
    add_control(vid, "macro " .. m .. " value",
      cs.new(0, 127, "lin", 1, 0, "", 1 / 127),
      function(x) queue_engine_call(vid, "macroBase", mi, x / 127) end)
    for _, dest in ipairs(MACRO_DESTS) do
      local di = dest.index
      local pid = ids["macro" .. m .. "_" .. dest.key .. "_depth"]
      add_control(pid, "macro " .. m .. " " .. dest.key .. " depth",
        cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
        function(x) queue_engine_call(pid, "macroDepth", mi, di, (x - 64) / 64) end,
        format_filter_depth)
      params:hide(pid)
    end
  end

  params:add_group(param_id(prefix, "group_engine_modes"), "engine algorithms", 13)

  add_control(ids.mode_switch_fade, "mode switch fade",
    cs.new(0.001, 0.25, "lin", 0.001, 0.05, "", 0.001 / 0.249),
    function(x) queue_engine_call(ids.mode_switch_fade, "setModeSwitchFade", x) end)

  add_control(param_id(prefix, "chop_steps"), "chop steps",
    cs.new(0.05, 16, "lin", 0.05, 1, "steps", 0.05 / 15.95),
    function(x) queue_engine_call(param_id(prefix, "chop_steps"), "chopSteps", x) end)

  params:add_option(param_id(prefix, "chop_loop_mode"), "chop loop mode", {"forward stop", "loop forward", "ping pong"}, 1)
  params:set_action(param_id(prefix, "chop_loop_mode"), function(x) engine_call("chopLoopMode", x - 1) end)

  add_control(param_id(prefix, "chop_attack"), "chop attack",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.002, "s", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "chop_attack"), "chopAttack", x) end,
    format_ms)

  add_control(param_id(prefix, "chop_hold"), "chop hold",
    cs.new(0, 0.5, "lin", 0.001, 0.04, "s", 0.001 / 0.5),
    function(x) queue_engine_call(param_id(prefix, "chop_hold"), "chopHold", x) end,
    format_ms)

  add_control(param_id(prefix, "chop_release"), "chop release",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.01, "s", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "chop_release"), "chopRelease", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_size"), "grain size",
    cs.new(0.002, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.498),
    function(x) queue_engine_call(param_id(prefix, "grain_size"), "grainSize", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_density"), "grain density",
    cs.new(1, 64, "lin", 1, 8, "gr/step", 1 / 63),
    function(x) queue_engine_call(param_id(prefix, "grain_density"), "grainDensity", x) end)

  add_control(param_id(prefix, "grain_jitter"), "grain jitter",
    cs.new(0, 0.25, "lin", 0.001, 0.01, "s", 0.001 / 0.25),
    function(x) queue_engine_call(param_id(prefix, "grain_jitter"), "grainJitter", x) end,
    format_ms)

  add_control(param_id(prefix, "wsola_window"), "OLA window",
    cs.new(0.005, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.495),
    function(x) queue_engine_call(param_id(prefix, "wsola_window"), "wsolaWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "wsola_search"), "OLA wander",
    cs.new(0, 0.1, "lin", 0.001, 0.015, "s", 0.001 / 0.1),
    function(x) queue_engine_call(param_id(prefix, "wsola_search"), "wsolaSearch", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_window"), "PC window",
    cs.new(0.005, 2, "lin", 0.001, 0.2, "", 0.001 / 1.995),
    function(x) queue_engine_call(param_id(prefix, "pv_window"), "pvWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_dispersion"), "PC dispersion",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) queue_engine_call(param_id(prefix, "pv_dispersion"), "pvDispersion", x) end)

  params:add_group(param_id(prefix, "group_slices"), "slice machines", 11)

  add_control(param_id(prefix, "slice_count"), "slice count",
    cs.new(1, 32, "lin", 1, 16, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(param_id(prefix, "slice_index"), "slice index",
    cs.new(1, 32, "lin", 1, 1, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(param_id(prefix, "slice_play_mode"), "slice play mode", {"1 shot", "1 shot hold", "loop", "continue"}, 1)
  params:set_action(param_id(prefix, "slice_play_mode"), function(_) end)

  params:add_binary(param_id(prefix, "slice_reverse"), "slice reverse", "toggle", 0)
  params:set_action(param_id(prefix, "slice_reverse"), function(_) end)

  params:add_binary(param_id(prefix, "slice_sync"), "slice clock sync", "toggle", 1)
  params:set_action(param_id(prefix, "slice_sync"), function(x)
    queue_engine_call(param_id(prefix, "slice_sync"), "setSliceSyncToClock", x)
  end)

  add_control(param_id(prefix, "slice_rate"), "slice rate",
    cs.new(0.125, 8, "exp", 0.01, 1, "x", 0.01),
    function(x) queue_engine_call(param_id(prefix, "slice_rate"), "setSliceRate", x) end,
    function(param) return string.format("%.2fx", param:get()) end)

  params:add_option(param_id(prefix, "slice_polyphony"), "slice polyphony", {"poly 8", "mono"}, 1)
  params:set_action(param_id(prefix, "slice_polyphony"), function(x)
    engine_call("setSliceMono", x == 2 and 1 or 0)
  end)

  params:add_binary(param_id(prefix, "slice_hold_to_step"), "slice hold to step", "toggle", 1)
  params:set_action(param_id(prefix, "slice_hold_to_step"), function(_) end)

  add_control(param_id(prefix, "slice_attack"), "slice attack",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.002, "", 0.0005 / 0.1999),
    function(x) queue_engine_call(param_id(prefix, "slice_attack"), "sliceAttack", x) end,
    format_ms)

  add_control(param_id(prefix, "slice_hold"), "slice hold",
    cs.new(0, 4, "lin", 0.01, 0.25, "", 0.01 / 4),
    function(_) end,
    format_ms)

  add_control(param_id(prefix, "slice_release"), "slice release",
    cs.new(0.0001, 0.5, "lin", 0.0001, 0.02, "", 0.001 / 0.4999),
    function(x) queue_engine_call(param_id(prefix, "slice_release"), "sliceRelease", x) end,
    format_ms)

  params:add_group(param_id(prefix, "group_razor"), "razor slices", 65)

  params:add_trigger(param_id(prefix, "razor_reset"), "reset razor slices")
  params:set_action(param_id(prefix, "razor_reset"), function()
    for i = 1, 32 do
      local start_id = param_id(prefix, string.format("razor_%02d_start", i))
      local end_id = param_id(prefix, string.format("razor_%02d_end", i))
      local start_point = (i - 1) * 4
      local end_point = i * 4
      razor_start_values[i] = start_point
      params:set(start_id, start_point, true)
      params:set(end_id, end_point, true)
    end
  end)

  for i = 1, 32 do
    local start_id = param_id(prefix, string.format("razor_%02d_start", i))
    local end_id = param_id(prefix, string.format("razor_%02d_end", i))
    local default_start = (i - 1) * 4
    local default_end = i * 4
    razor_start_values[i] = default_start

    add_control(start_id, string.format("razor %02d start", i),
      cs.new(0, 128, "lin", 0.01, default_start, "", 1 / 128),
      function(x)
        if razor_adjusting then
          razor_start_values[i] = x
          return
        end
        local previous = razor_start_values[i] or default_start
        local delta = x - previous
        razor_start_values[i] = x
        if math.abs(delta) > 0 then
          local current_end = params:get(end_id)
          local next_end = util.clamp(current_end + delta, 0, 128)
          if next_end <= x then
            next_end = util.clamp(x + 0.01, 0.01, 128)
          end
          razor_adjusting = true
          params:set(end_id, next_end)
          razor_adjusting = false
        end
      end)

    add_control(end_id, string.format("razor %02d end", i),
      cs.new(0, 128, "lin", 0.01, default_end, "", 1 / 128),
      function(x)
        if razor_adjusting then
          return
        end
        local current_start = params:get(start_id)
        if x <= current_start then
          razor_adjusting = true
          params:set(end_id, util.clamp(current_start + 0.01, 0.01, 128))
          razor_adjusting = false
        end
      end)
  end

  params:add_group(param_id(prefix, "group_system"), "system", 2)

  params:add_trigger(param_id(prefix, "reset"), "reset")
  params:set_action(param_id(prefix, "reset"), function() engine_call("reset") end)

  params:add_option(ids.debug, "debug", {"errors", "lifecycle", "clock", "verbose"}, 2)
  params:set_action(ids.debug, function(x) engine_call("setDebug", x - 1) end)

  -- Phase 1 track scaffolding: active_track_count + track 1's mute + the full
  -- programmatic per-track param set for tracks 2-8 (lib/tracks/params_spec.lua).
  -- Registered LAST so it never disturbs the existing param/pset ordering, and
  -- before any partition scanner runs (they're built lazily after init).
  ParamsSpec.register({
    params = params,
    cs = cs,
    prefix = prefix,
    tr_call = tr_call,
    engine_call = engine_call,
    machines = elasticat.machines,
    modes = elasticat.modes,
    trig_conditions = TRIG_CONDITIONS,
    on_active_track_count = function(n)
      if pool_options.on_active_track_count ~= nil then
        pool_options.on_active_track_count(n)
      end
    end
  })

  if default_sync == 1 then
    send_clock_observation()
    elasticat.start_clock_sync()
  end
end

return elasticat
