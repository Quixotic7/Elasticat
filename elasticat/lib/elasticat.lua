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
  "razor_slice",
  "slice_poly",
  "razor_poly"
}

elasticat.modes = {
  "tape",
  "tempo_varispeed",
  "chopped",
  "granular",
  "random_ola",
  "pitch_corrected",
  "harmonizer",
  "wavetable",
  "spectral_freeze",
  "formant",
  "tape_xf",
  "tape_ugen",
  "gstretch",
  "gstretch2",
  "rubberband"
}

local sync_thread = nil
local engine_send_metro = nil
local engine_send_interval = 1 / 12
local pending_engine_sends = {}
local pending_engine_order = {}
local clock_origin = 0
local clock_sequence = 0
-- Clock-sync watchdog state: last_observation_time is stamped every time the sync
-- fiber successfully emits an observation; the watchdog metro auto-recovers a
-- wedged clock if that stops (see start_clock_watchdog).
local last_observation_time = 0
local clock_watchdog_metro = nil
local last_clock_recovery = 0
local ids = {}
-- Param id prefix (options.prefix in elasticat.params, "elasticat_" in the
-- shipping script). Declared HERE, above every reader: a local is only in
-- scope for code that follows it, so declaring it next to the tr_call helpers
-- would make elasticat.track_pid read a nil global.
local track_prefix = "elasticat_"
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

-- Which track the facade's live-gesture calls (set_loop_region, note_on,
-- play, set_pitch, trigger_slice, ...) address. 1 = the existing unprefixed
-- path, byte-for-byte unchanged. Set by the coordinator on track selection.
-- Declared here, above its first reader (set_active_range), NOT down with the
-- tr_call helpers: a local is only in scope for code that follows it, so a
-- later declaration made this read a nil global and threw on every step.
local engine_track = 1

-- Active Range override: the three-layer model the loop region also uses. Track
-- Range = the range_start/range_end params (what the Range page edits, never
-- touched by step locks). Step Range = a triggering step's range lock, pushed
-- here by GridSequencer. Actual Range (used below) = Step Range when set, else
-- Track Range. nil per endpoint means "fall through to the Track param".
-- Per TRACK, not one shared pair. These were two file-scope locals shared by
-- every track, so a step range lock on any track overwrote the range the
-- others were playing -- on the device track 2's range visibly collapsed onto
-- track 1's the moment playback started.
local active_range_start = {}
local active_range_end = {}

function elasticat.set_active_range(range_start, range_end, track)
  track = track or engine_track
  active_range_start[track] = range_start
  active_range_end[track] = range_end
end

-- The Actual Range (0-128) actually driving playback: Step Range override when
-- set, else the Track Range params. Used by the waveform view so it can follow
-- a sequenced range sweep during playback.
function elasticat.active_range(track)
  track = track or engine_track
  local rs = active_range_start[track]
  local re = active_range_end[track]
  -- Fall through to THIS track's Range params, not track 1's.
  local sid = elasticat.track_pid(track, "range_start")
  local eid = elasticat.track_pid(track, "range_end")
  if rs == nil and elasticat.param_exists(sid) then
    rs = params:get(sid)
  end
  if re == nil and elasticat.param_exists(eid) then
    re = params:get(eid)
  end
  return rs or 0, re or 128
end

-- ---- Base-value resolver (docs/BASE_VALUE_RESOLVER.md) ---------------------
-- The non-destructive switch that decides what a continuous p-lockable param
-- actually SENDS to the engine: a firing step p-lock wins, then a crossfader
-- morph, then the track's own stored param. Steps and the crossfader publish
-- into these override layers instead of mutating the track param, so the knob
-- always owns the track value (its stored bar) and a live edit is never stomped
-- by a per-tick restore. step_override is a SINGLE selected-track layer (keyed
-- by bare suffix) -- it mirrors the one active_step_lock set the UI keeps and
-- the ui_id funnel step locks already route through. crossfader_override is
-- per-track because a scene is the whole instrument. active_range (above) is the
-- region/range twin of this, resolved separately for the trim-mapped points.
local step_override = {}         -- suffix -> raw value (selected track only)
local crossfader_override = {}   -- [track] -> {suffix -> raw value}

-- The switch. track_value is the param's own stored value, passed in by the
-- caller (the param action already holds it) to save a params:get; xform/offset
-- still apply downstream exactly as for a live edit. Absent overrides fall
-- straight through, so a param that is never p-locked or morphed is unchanged.
function elasticat.resolve_base(track, suffix, track_value)
  if track == engine_track then
    local v = step_override[suffix]
    if v ~= nil then
      return v
    end
  end
  local layer = crossfader_override[track]
  if layer ~= nil then
    local v = layer[suffix]
    if v ~= nil then
      return v
    end
  end
  return track_value
end

-- The crossfader-APPLIED value of a param: the live morph override if one is in
-- effect for this track, else the track's own value. Deliberately SKIPS the
-- step_override layer (resolve_base's source 0) -- a scene capture must snapshot
-- what the CROSSFADER holds, never a transient firing step lock. This is what a
-- scene capture reads instead of the raw track param: morph to A, then re-capture
-- A, and it stores the value you HEAR (the A override) rather than the stale
-- track value the knob last wrote at B (which would clobber A with B's value).
function elasticat.crossfader_applied(track, suffix, track_value)
  local layer = crossfader_override[track]
  if layer ~= nil then
    local v = layer[suffix]
    if v ~= nil then
      return v
    end
  end
  return track_value
end

-- Range Start/End (0-128) carve a live performance window *inside* the file
-- trim window: 0 = trim start, 128 = trim end. Unlike file trim (saved per
-- sample) this is a global, p-lockable layer. Returns the window in seconds.
local function range_bounds(trim_start, trim_end, track)
  local span = trim_end - trim_start
  -- elasticat.active_range already resolves the Step Range override, then this
  -- track's own Range params. Reading the raw tables here (as this did before
  -- they became per-track) would compare a TABLE against nil and always fall
  -- through to track 1's params.
  local range_start, range_end = elasticat.active_range(track)
  local lo = trim_start + (span * (util.clamp(range_start, 0, 128) / 128))
  local hi = trim_start + (span * (util.clamp(range_end, 0, 128) / 128))
  if hi <= lo then
    hi = math.min(trim_end, lo + 0.0001)
  end
  return lo, hi
end

-- The pool slot a given track PLAYS. Track 1 is not special: it reads its own
-- `sample_slot` param exactly like the rest. active_sample_slot (the slot the
-- File page focuses) is only the last-resort fallback, for before the params
-- exist and for the "off" slot 0 -- which trim_bounds clamps exactly as it
-- always has, so track 1's behaviour is byte-for-byte unchanged.
elasticat.track_slot = function(track)
  local v = elasticat.track_param_value(tonumber(track) or 1, "sample_slot")
  if v ~= nil and v >= 1 then
    return sample_slot_number(v)
  end
  return active_sample_slot
end

-- Maps a Track point (0-128) through THAT TRACK's Range, then THAT TRACK's
-- pool-slot File Trim, into engine 0-128 (of the whole sample). One funnel:
-- every engine region call (loop points, slice ranges, set_loop_region) goes
-- through here, so both layers apply on every track with no downstream change.
--
-- This used to be SELECTED-TRACK-ONLY: it read the globally-active pool slot,
-- and range_bounds saw no track so it fell through to track 1's Range params.
-- Tracks 2-8 therefore sent RAW 0-128 points, so a step region lock on a
-- background track addressed the wrong part of the file whenever that track's
-- sample had a non-default trim or its Range was narrowed. `track` (not a
-- slot) is the argument because the slot is derived FROM the track -- passing a
-- slot could not have carried the Range layer.
local function map_trim_point(point, track)
  track = track or engine_track
  local trim_start, trim_end, duration = trim_bounds(elasticat.track_slot(track))
  if duration <= 0 then
    return util.clamp(point or 0, 0, 128)
  end
  local range_lo, range_hi = range_bounds(trim_start, trim_end, track)
  local fraction = util.clamp(point or 0, 0, 128) / 128
  return ((range_lo + ((range_hi - range_lo) * fraction)) / duration) * 128
end

-- Maps a Track-space region (0-128) to the engine-space region actually played
-- (range + trim folded in). The visual playhead needs this so its rate matches
-- the true loop length -- e.g. a narrowed range loops far faster than the Track
-- width alone implies. Per track, so a background track's playhead rate can be
-- derived from ITS region rather than the selected track's.
function elasticat.map_region(track_start, track_end, track)
  return map_trim_point(track_start, track), map_trim_point(track_end, track)
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

-- Safe param-existence check. norns' params:lookup_param() ERRORS on an unknown
-- string id rather than returning nil, so a bare `lookup_param(x) ~= nil` guard
-- throws the moment it is handed an id that isn't registered. pcall makes the
-- "does it exist?" question never throw. Hung on the module table (NOT a new
-- file-scope local): this chunk is at LuaJIT's 200-local ceiling. The
-- coordinator (elasticat.lua) assigns an identical implementation over the top
-- when it loads -- same semantics, so either definition order is safe.
elasticat.param_exists = function(full_id)
  local ok, p = pcall(params.lookup_param, params, full_id)
  return ok and p ~= nil
end

-- A per-track param id from its bare suffix. Track 1 -> the unprefixed id it
-- has always had; tracks 2-8 -> elasticat_t<N>_<suffix>. Non-per-track
-- suffixes pass through unchanged, so this is safe to apply uniformly.
elasticat.track_pid = function(track, suffix)
  return ParamsSpec.track_id(track, suffix, track_prefix)
end

-- Envelope seconds mapping is PER TRACK: env_range is a per-track param, so
-- every conversion needs to know whose envelope it is converting.
local function env_range_seconds(track)
  local pid = elasticat.track_pid(track or 1, "env_range")
  if not elasticat.param_exists(pid) then
    return 8
  end
  return ENV_RANGE_VALUES[params:get(pid)] or 8
end

-- 0-127 -> seconds on an exponential curve; 128 is the "infinite" sentinel.
local function env_value_to_seconds(v, track)
  v = v or 0
  if v >= ENV_INFINITE_VALUE then
    return ENV_INFINITE_SECONDS
  end
  local n = util.clamp(v / 127, 0, 1)
  local curve = (math.exp(ENV_TIME_SHAPE * n) - 1) / (math.exp(ENV_TIME_SHAPE) - 1)
  return env_range_seconds(track) * curve
end

local function format_env_time(param, track)
  if param:get() >= ENV_INFINITE_VALUE then
    return "INF"
  end
  local secs = env_value_to_seconds(param:get(), track)
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
-- destination index (1-5, matching the mod buses). Defined in params_spec (it
-- generates the 24 macro params from it) so there is exactly one definition.
local MACRO_DESTS = ParamsSpec.MACRO_DESTS
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

-- Both feeds now arrive from ALL 8 tracks (one mod synth + one filter each),
-- tagged with the reporting track's index (SendReply replyID). These are UI
-- state -- the "actual value" bars and the filter render only ever show the
-- SELECTED track -- so everything else is discarded here rather than stored
-- 8-deep. Calls without a track index (an engine/coordinator half that hasn't
-- landed the replyID yet) are treated as the selected track.
function elasticat.set_filter_env_mod(track, semitones)
  if semitones == nil then
    track, semitones = engine_track, track
  end
  if (tonumber(track) or 1) ~= engine_track then
    return
  end
  filter_env_semitones = tonumber(semitones) or 0
end

function elasticat.set_mod_values(track, pitch, cutoff, res, amp, pan)
  if pan == nil then
    track, pitch, cutoff, res, amp, pan = engine_track, track, pitch, cutoff, res, amp
  end
  if (tonumber(track) or 1) ~= engine_track then
    return
  end
  mod_live.pitch = tonumber(pitch) or 0
  mod_live.cutoff = tonumber(cutoff) or 0
  mod_live.res = tonumber(res) or 0
  mod_live.amp = tonumber(amp) or 0
  mod_live.pan = tonumber(pan) or 0
end

-- Route a raw /elasticat/mod report into set_mod_values. The engine sends the
-- FIVE mod sums first and appends the reporting track as a TRAILING sixth value
-- (Engine_Elasticat.sc modResponder: [pitch, cutoff, res, amp, pan, track]).
-- The coordinator used to read the leading arg as the track, which shifted every
-- value by one -- pitch was dropped, the track index landed in the pan slot, and
-- osc_track(pitch) clamped to 1 so only track 1 ever updated (with garbage). We
-- interpret the shape here, where it can be unit-tested against the engine's
-- ordering. A 5-arg message is an older, untagged (single-track) engine; it
-- applies to the current engine_track, which is 1 in that case. set_mod_values
-- gates on engine_track, so a stray other-track report is dropped.
function elasticat.route_mod_report(args)
  args = args or {}
  if #args >= 6 then
    elasticat.set_mod_values(args[6], args[1], args[2], args[3], args[4], args[5])
  else
    elasticat.set_mod_values(args[1], args[2], args[3], args[4], args[5])
  end
end

-- Route a raw /elasticat/filterEnv report into set_filter_env_mod. The engine
-- sends the cutoff contribution (semitones) FIRST and the reporting track as a
-- TRAILING second value (Engine_Elasticat.sc filterEnvResponder: [semitones,
-- track]). Same trailing-track convention as route_mod_report.
function elasticat.route_filter_env_report(args)
  args = args or {}
  if #args >= 2 then
    elasticat.set_filter_env_mod(args[2], args[1])
  else
    elasticat.set_filter_env_mod(args[1])
  end
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

-- The sample-slot gain that multiplies a track's Volume. Sample gain is a
-- property of the POOL SLOT (saved to the sample's sidecar), so it is read
-- from whichever slot the track plays -- track 1's playback slot for track 1,
-- the track's own sample_slot param for the rest.
-- The gain of the slot THIS track plays. Track 1 is not special here: it used
-- to fall back to the global `active_sample_slot` (the slot the FILE page is
-- focused on), so recomputing track 1 amp while another track was selected
-- multiplied it by the OTHER track slot gain -- turning track 2 volume moves
-- into track 1 volume moves. elasticat.track_slot owns that resolution now, so
-- gain and the region mapping can never disagree about which slot a track
-- plays.
elasticat.track_gain = function(track)
  return sample_pool.gains[elasticat.track_slot(track)] or 1
end

-- ---- SPEC-driven param behaviour (lib/tracks/params_spec.lua) -------------
-- Every per-track param's DISPLAY, its VALUE TRANSFORM on the way to the
-- engine, and the two params whose action isn't "push one value" live in these
-- three tables. params_spec names them; nothing here is per-track-branched, so
-- all 8 tracks are guaranteed identical by construction.
--
-- Hung on the module table, not new file-scope locals: this chunk is at
-- LuaJIT's 200-local ceiling, and elasticat.params() is near its 60-upvalue
-- ceiling -- reaching these through the existing `elasticat` upvalue costs
-- neither.
elasticat.param_formatters = {
  env_time = format_env_time,
  env_level = format_env_level,
  pan_127 = format_pan_127,
  filter_cutoff = format_filter_cutoff,
  filter_morph = format_filter_morph,
  filter_depth = format_filter_depth,
  filter_balance = format_filter_balance,
  lofi_bits = format_lofi_bits,
  lofi_rate = format_lofi_rate,
  integer = function(param) return tostring(math.floor(param:get() + 0.5)) end,
  decimal2 = function(param) return string.format("%.2f", param:get()) end,
  percent = function(param) return tostring(math.floor((param:get() * 100) + 0.5)) end,
  -- Rate multiplier, e.g. "0.50x" / "1.00x" (5-char safe). Matches slice rate.
  rate_x = function(param) return string.format("%.2fx", param:get()) end
}

-- Value transforms: param units -> engine units. (x, track) so the envelope
-- times can read the track's own env_range.
elasticat.param_xforms = {
  amount = function(x) return util.clamp(x / 127, 0, 1) end,          -- 0-127 -> 0..1
  bipolar = function(x) return (x - 64) / 64 end,                     -- 0-128 -> -1..1
  morph = function(x) return util.clamp(x / 128, 0, 1) end,           -- 0-128 -> 0..1
  macro_base = function(x) return x / 127 end,
  cutoff_hz = function(x) return filter_cutoff_hz(x) end,
  lofi_bits = function(x) return lofi_bits_depth(x) end,
  lofi_rate = function(x) return lofi_rate_hz(x) end,
  delay_beats = function(x) return DELAY_TIME_BEATS[x] or 1 end,
  mod_beats = function(x) return MOD_SPEED_BEATS[x] or 4 end,
  env_seconds = function(x, track) return env_value_to_seconds(x, track) end,
  -- Track-space 0-128 -> engine-space, folding in THIS track file-trim window
  -- and Range. Without it a background track Loop-page edit sent the raw value
  -- while track 1 sent a mapped one -- the same point addressed two different
  -- places depending on which track was selected.
  region_point = function(x, track) return map_trim_point(x, track) end,
  -- The engine has one gain input per track, so the sample slot's gain and the
  -- track's own Volume combine into it here (see send_effective_amp).
  amp = function(x, track) return (x / 127) * elasticat.track_gain(track) end
}

-- The one param whose action isn't a single engine push: env_range only
-- changes the 0-127 -> seconds MAPPING, so it re-sends this track's three
-- envelopes at their new seconds values.
elasticat.param_actions = {
  -- Range does not push a value of its own: it changes the MAPPING, so it
  -- re-sends this track loop points at their new engine positions. Without
  -- this, editing a background track Range did nothing until its next trig.
  -- range_start also applies the E-SNC rigid-pair linkage (elasticat.
  -- apply_range_start); range_end applies the end>start clamp. Shared by ALL
  -- tracks -- the linkage used to live only in track 1's hand-registered path.
  range_start = function(x, track)
    elasticat.apply_range_start(track, x)
    elasticat.remap_region(track)
  end,
  range_end = function(x, track)
    elasticat.apply_range_end(track, x)
    elasticat.remap_region(track)
  end,
  env_range = function(_, track)
    resend_env_times(track)
    resend_filter_env_times(track)
    resend_menv_times(track)
  end,
  -- Source machine (loop / loop_trig / slice) change: re-evaluate the free-run
  -- play gate so switching back to loop mid-run resumes, and switching to a
  -- slice machine stops the reader (slices sound from their own triggers) (#45).
  source_machine = function(_, track)
    elasticat.push_track_play_state(track)
  end
}

local function clock_param_is_internal()
  -- clock_source/clock_tempo are norns SYSTEM params, not ours: a bare
  -- lookup_param would throw rather than return nil if they ever went missing.
  return elasticat.param_exists("clock_source") and params:get("clock_source") == 1
end

local function set_internal_clock_tempo(bpm)
  if ids.clock_sync ~= nil and params:get(ids.clock_sync) ~= 1 then
    return
  end
  if not clock_param_is_internal() then
    return
  end

  if elasticat.param_exists("clock_tempo") then
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

-- engine_call is assigned further down, AFTER tr_command_name exists (it names
-- the tr* command in its "you forgot the track" diagnostic), and a Lua local is
-- only in scope for code that follows its declaration, so a closure built here
-- could not see it.

-- ---- Per-track engine facade ----------------------------------------------
-- (docs/PHASE1_CONTRACT.md, docs/PHASE2_CONTRACT.md). EVERY per-track command
-- takes a LEADING track index and is named tr + UpperCamelCase(field):
-- filter_cutoff -> \trFilterCutoff (track, value). There are no global
-- aliases: the un-prefixed per-track commands are gone from the engine, so
-- passing one of those names to the global dispatcher is a bug at the call
-- site, not a fallback -- see engine_call below.
-- The engine half is built in parallel, so every tr call no-ops gracefully
-- (warn once per command) until it lands -- the Lua half stays testable.
--
-- Name mapping: a few commands drop the "set" of their old track-1 counterpart
-- (\trPitch for setPitch, \trSampleSlot for setSampleSlot, \trSetMachine for
-- the warp reader select) or rename the unit (\trDelayBeats, \trLfo1Beats --
-- both take beats, not seconds). The alias table tries the contract name
-- first, then the mechanical tr+Capitalized fallback, so either spelling on
-- the engine side just works.
local TR_COMMAND_ALIASES = {
  setMode = {"trSetMachine", "trSetMode"},
  setSampleSlot = {"trSampleSlot", "trSetSampleSlot"},
  loadPoolSlot = {"trLoadPoolSlot"},
  setPitch = {"trPitch", "trSetPitch"},
  mute = {"trMute"},
  play = {"trPlay"},
  -- Engine names the per-track reverse command trReverse (not trSetReverse,
  -- which the mechanical fallback would guess from the spec's "setReverse").
  setReverse = {"trReverse", "trSetReverse"},
  -- Same shape: the engine has one \trPlayhead, but the facade calls it under
  -- both "playhead" and "setPlayhead".
  setPlayhead = {"trPlayhead", "trSetPlayhead"},
  -- Phase 2 signal chain: contract name first, older/alternate spelling second.
  filterMachine = {"trFilterMachine", "trSetFilterMachine"},
  fxInsertMachine = {"trFxInsertMachine", "trSetInsertMachine"},
  delayBeats = {"trDelayBeats", "trDelayTime"},
  lfo1Beats = {"trLfo1Beats", "trLfo1Speed"},
  lfo2Beats = {"trLfo2Beats", "trLfo2Speed"},
  sendTap = {"trSendTap", "trSetSendTap"},
  envMode = {"trEnvMode", "trSetEnvMode"},
  portamento = {"trPortamento", "trSetPortamento"},
  modeSwitchFade = {"trModeSwitchFade", "trSetModeSwitchFade"},
  amp = {"trAmp", "trSetAmp"},
  pan = {"trPan", "trSetPan"}
}
local tr_warned = {}

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

-- GLOBAL engine commands only -- the ~15 that genuinely have no track
-- (activeTrackCount, the sample pool, master/send-bus FX, stopAndReset,
-- targetBpm, requestStatus, reset, setDebug, the engine-wide slice settings).
--
-- There used to be a per-track FALLBACK here: an un-prefixed name that existed
-- only as a tr* command was routed to the SELECTED track. It was added to fix a
-- real no-audio bug (Phase 2 deleted the un-prefixed per-track commands while
-- ~30 track-1 call sites still used them, including `play` and `loopStart`),
-- but it made call-site INTENT invisible -- an un-prefixed `play` could not be
-- read as either "track 1" or "the selection" -- and it caused its own
-- transport bug: set_engine_play meant "track 1" and was silently retargeted,
-- so starting playback with track 2 selected never started track 1.
--
-- Every per-track call site now names its track (tr_call / tr_queue / the SPEC
-- actions), so the fallback is gone. A name that reaches here and is not a
-- global engine command is a BUG at the call site, and now says so.
engine_call = function(name, ...)
  if engine[name] ~= nil then
    engine[name](...)
    return
  end
  if not tr_warned["g:" .. name] then
    tr_warned["g:" .. name] = true
    local hint = tr_command_name(name)
    print("elasticat: engine command missing: " .. name
      .. (hint ~= nil
        and (" -- it is PER TRACK (" .. hint .. "); the call site must name a track")
        or ""))
  end
end

-- Track 1's engine loop points, re-mapped through its trim/range layers.
-- Deliberately BELOW tr_call: a Lua local is only in scope for code that
-- follows its declaration, and this used to sit ~450 lines higher where a bare
-- `tr_call` would have silently read a nil GLOBAL. Explicit track 1 (not
-- engine_track): these are the hand-registered track-1 loop params -- tracks
-- 2-8 edit their own SPEC-registered ids.
local function update_engine_loop_points()
  elasticat.push_loop_points(1)
end

-- Re-map and push ONE track's loop points. Both endpoints go together because
-- Range changes the mapping of both, and a start-only push would leave the end
-- addressing the old window.
--
-- `queued` routes through the 12Hz coalescing queue -- used when the re-map is
-- driven by a rapidly-scrubbed control (Range), so per-detent edits do not
-- flood the engine.
elasticat.push_loop_points = function(track, queued)
  track = track or engine_track
  local sid = elasticat.track_pid(track, "loop_start")
  local eid = elasticat.track_pid(track, "loop_end")
  if not elasticat.param_exists(sid) or not elasticat.param_exists(eid) then
    return
  end
  local lo = map_trim_point(params:get(sid), track)
  local hi = map_trim_point(params:get(eid), track)
  if queued then
    elasticat.tr_queue(sid, track, "loopStart", lo)
    elasticat.tr_queue(eid, track, "loopEnd", hi)
  else
    tr_call(track, "loopStart", lo)
    tr_call(track, "loopEnd", hi)
  end
  elasticat.push_chop_regions(track, params:get(sid), params:get(eid), queued)
end

-- CHOPPED "domino" model (owner): the chopped synth needs TWO regions the shared
-- loop-folded region can't express -- the RANGE as the slice AREA (the audio, cut
-- into SLCS slices) and the raw TRACK loop as the PLAYHEAD WINDOW (which of those
-- slices fire). loop_start_raw/loop_end_raw are the track loop in 0-128 (the window
-- /128); the slice area is map_trim_point(0/128) -- exactly where the full Range
-- lands in the buffer. Only pushed for a chopped track (mode 3), so no other mode
-- pays the extra sends. Called from every loop/range/scrub funnel + mode switch.
elasticat.push_chop_regions = function(track, loop_start_raw, loop_end_raw, queued)
  track = track or engine_track
  if elasticat.track_param_value(track, "mode") ~= 3 then
    return
  end
  local play_lo = util.clamp(loop_start_raw or 0, 0, 128) / 128
  local play_hi = util.clamp(loop_end_raw or 128, 0, 128) / 128
  local range_start = map_trim_point(0, track)
  local range_end = map_trim_point(128, track)
  if queued then
    elasticat.tr_queue("chopPlayLo:" .. track, track, "chopPlayLo", play_lo)
    elasticat.tr_queue("chopPlayHi:" .. track, track, "chopPlayHi", play_hi)
    elasticat.tr_queue("chopRangeStart:" .. track, track, "chopRangeStart", range_start)
    elasticat.tr_queue("chopRangeEnd:" .. track, track, "chopRangeEnd", range_end)
  else
    tr_call(track, "chopPlayLo", play_lo)
    tr_call(track, "chopPlayHi", play_hi)
    tr_call(track, "chopRangeStart", range_start)
    tr_call(track, "chopRangeEnd", range_end)
  end
end

-- Per-track E-SNC (Range End Sync) state: the range_start value BEFORE the
-- current edit, needed to compute the rigid-pair delta -- a param action fires
-- AFTER params:set has already written the new start. Module table (not a
-- file-scope local) so tracks 2-8 get the same linkage track 1 used to keep to
-- itself (docs/PHASE2_CONTRACT.md: track 1 is not special). Keyed by track.
elasticat.last_range_start = {}

-- Range Start edit for ONE track, shared by every track. When E-SNC is on,
-- range_start and range_end move as a rigid pair: the shared delta is clamped so
-- end stays <= 128 and start stays >= 0, keeping the window length constant even
-- on a fast overshoot into the boundary (moving end freely then clamping only
-- end used to collapse the gap at 128 and drag end back down -- the old "bounce
-- to 120"). When off, start clamps to end-1 so it can never cross the end
-- marker. Paired writes go back through params:set (silent, so this action does
-- not re-enter itself) so the other param + its LEDs follow.
elasticat.apply_range_start = function(track, x)
  local sid = elasticat.track_pid(track, "range_start")
  local eid = elasticat.track_pid(track, "range_end")
  if not elasticat.param_exists(sid) or not elasticat.param_exists(eid) then
    return
  end
  local sync_id = elasticat.track_pid(track, "range_end_sync")
  if elasticat.param_exists(sync_id) and params:get(sync_id) == 1 then
    local prev_start = elasticat.last_range_start[track] or 0
    local prev_end = params:get(eid) or 128
    local delta = util.clamp(x - prev_start, -prev_start, 128 - prev_end)
    local next_start = prev_start + delta
    local next_end = prev_end + delta
    if math.abs(next_start - x) > 0.000001 then
      params:set(sid, next_start, true)
    end
    params:set(eid, next_end, true)
    elasticat.last_range_start[track] = next_start
  else
    local max_start = util.clamp((params:get(eid) or 128) - 1, 0, 127)
    if x > max_start then
      params:set(sid, max_start, true)
      elasticat.last_range_start[track] = max_start
    else
      elasticat.last_range_start[track] = x
    end
  end
end

-- Range End edit for ONE track: end can never reach start, so its minimum is
-- start + 1. (E-SNC end moves are driven by apply_range_start's paired write,
-- which is silent, so this only runs on a direct end edit.)
elasticat.apply_range_end = function(track, x)
  local sid = elasticat.track_pid(track, "range_start")
  local eid = elasticat.track_pid(track, "range_end")
  if not elasticat.param_exists(eid) then
    return
  end
  local min_end = util.clamp((params:get(sid) or 0) + 1, 1, 128)
  if x < min_end then
    params:set(eid, min_end, true)
  end
end

-- Re-map a track's loop points after a Range edit. During playback the SELECTED
-- track's live region is owned by the layered resolver (region-scrub / step-lock
-- freeze -- see elasticat.region_edit_handled), so a direct push would fight it;
-- background tracks and the stopped case push straight through. This replaces
-- track 1's bespoke `if not region_edit_handled() then push_loop_points` guard
-- and folds tracks 2-8's previously-unguarded push onto the same rule.
elasticat.remap_region = function(track)
  if track == engine_track and elasticat.region_edit_handled ~= nil
    and elasticat.region_edit_handled() then
    return
  end
  elasticat.push_loop_points(track, true)
end

-- The immediate dispatcher params_spec hands every non-queued param action.
-- (key, track, cmd, ...) mirrors tr_queue below so the two are interchangeable.
--
-- During a crossfader morph (elasticat.morph_active, set around
-- scene_store:apply) the immediate sends are re-routed through the 12Hz
-- coalescing queue: a held glide drives apply() at ~30Hz, and without this the
-- ~22 non-queued morph params fire an UNCOALESCED engine send every tick. That
-- sustained burst overruns the audio engine's OSC input -- audio drops out for
-- seconds until it drains (docs/PHASE2_CONTRACT.md cost-control 4). Keyed by
-- the param id, so repeated ticks collapse to one send per param per flush.
elasticat.tr_now = function(key, track, cmd, ...)
  if elasticat.morph_active and key ~= nil then
    elasticat.tr_queue(key, track, cmd, ...)
  else
    tr_call(track, cmd, ...)
  end
end

function elasticat.set_engine_track(track)
  local next_track = util.clamp(math.floor((tonumber(track) or 1) + 0.5), 1, ParamsSpec.TRACK_COUNT_MAX)
  if next_track ~= engine_track then
    -- The live mod/filter-env feeds are the SELECTED track's only; drop the
    -- old track's last frame so the UI can't paint it onto the new one during
    -- the ~15Hz gap before the new track reports.
    mod_live.pitch, mod_live.cutoff, mod_live.res, mod_live.amp, mod_live.pan = 0, 0, 0, 0, 0
    filter_env_semitones = 0
    -- step_override is a SINGLE selected-track layer (resolve_base applies it only
    -- when track == engine_track). Drop it on a switch so a lock still firing on
    -- the old track can't leak onto the new one; the sequencer re-establishes it
    -- on the next step. (crossfader_override is per-track, so it is untouched.)
    for suffix in pairs(step_override) do
      step_override[suffix] = nil
    end
  end
  engine_track = next_track
  -- Tell the engine which track is on screen, so it forwards THAT track's phase +
  -- meter at the fast 15Hz feed (a smooth visible playhead). Idempotent; sent on
  -- every selection so a script reload re-establishes it.
  engine_call("viewTrack", next_track)
end

-- The MIX overview shows every track's meter; every other page shows only the
-- selected track's. Tell the engine which, so it doesn't forward off-screen
-- meters at 15Hz for nothing.
function elasticat.set_meter_all(on)
  engine_call("meterAll", on and 1 or 0)
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
  local pid = elasticat.track_pid(track, suffix)
  if not elasticat.param_exists(pid) then
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

-- Re-push a track's EFFECTIVE free-run play state, the same rule elasticat.play
-- uses: playing only when the transport is running AND the source machine is
-- loop (1). A source-machine change (loop <-> slice/loop_trig) must re-evaluate
-- this gate on the fresh synth, or a track switched back to loop mid-run stays
-- silent until stop/start (#45). Track 1's hand-registered machine action
-- already does this inline; this is the shared path for tracks 2-8.
elasticat.push_track_play_state = function(track)
  local machine = elasticat.track_param_value(track, "machine") or 1
  local transport = ids.play ~= nil and elasticat.param_exists(ids.play)
    and params:get(ids.play) == 1
  tr_call(track, "play", (transport and machine == 1) and 1 or 0)
end

-- elasticat.track_step DELETED (Phase 2 per-track sequencers). It was the
-- background-track step stub -- pitch, loop locks, a bare noteOn -- and the
-- reason a deselected track went quiet. Every track now runs the SAME
-- enter_position routine on its own TrackSequencer instance.

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
  -- Push through sync_entry -> ParamsSpec.entry_action: the EXACT transform and
  -- argument shape the param's own action uses.
  --
  -- This used to call tr_call(track, entry.cmd, raw_value) directly, which
  -- silently dropped two things entry_action does:
  --   * `xform` -- so `amp` sent its raw 0-127 param value where the engine
  --     wants 0-1. A track synced at amp 100 came up ~127x too loud.
  --   * `args`  -- so an INDEXED command lost its indices: macro depth sent
  --     trMacroDepth(track, 64) instead of (track, macro, dest, value). The
  --     engine read 64 as the macro index and got nil for the rest, which is
  --     the DoesNotUnderstand storm seen on the device.
  -- A bulk sync must never re-implement a param action; it must reuse it.
  -- Only the tracks that actually have an engine chain: an inactive track owns
  -- no synths, so pushing to it is pure waste (7/8 of ~1000 sends at the
  -- default count of 1). Raising the count re-runs this, which is what gives a
  -- newly activated track its parameters -- without that, activating track 2
  -- allocated a chain that had never been told its sample, amp, or region, and
  -- it stayed silent until some unrelated edit happened to push one.
  for track = 1, elasticat.active_track_count() do
    for _, entry in ipairs(ParamsSpec.SPEC) do
      if entry.cmd ~= nil then
        elasticat.sync_entry(track, entry)
      end
    end
  end
  -- ...and the pool metadata of the slot each track binds. That is NOT in the
  -- SPEC (it belongs to the sample, not the track), so without this a newly
  -- activated track kept the engine's default 16 sampleSteps and free-ran at
  -- the wrong rate for its own sample.
  elasticat.sync_track_slot_metadata()
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

-- The "number of steps" param (sample_steps) now means how many steps the
-- TRIMMED portion should span (owner) -- so a trim can warp to a clean bar. The
-- engine still derives loopBeats/derivedSourceBpm against the WHOLE buffer
-- (region = trim_fraction * range_fraction), so scale by 1/trim_fraction here:
-- a trim that is `frac` of the sample needs steps/frac WHOLE-sample steps for
-- the trim itself to span `steps`. This resolves in the engine to
-- loopBeats = (steps/4)*range_fraction and derivedSourceBpm = the trim's native
-- tempo, with NO engine change. Full-sample trims (frac 1) are unchanged.
-- Pure (no globals) so it is unit-testable; guards a zero/absent duration.
function elasticat.trim_scaled_steps(steps, trim_duration, whole_duration)
  steps = tonumber(steps)
  if steps == nil then
    return nil
  end
  whole_duration = tonumber(whole_duration) or 0
  trim_duration = tonumber(trim_duration) or 0
  if whole_duration <= 0 or trim_duration <= 0 then
    return steps
  end
  local frac = trim_duration / whole_duration
  if frac <= 0 then
    return steps
  end
  return steps / frac
end

-- The WHOLE-sample step count to send the engine for a pool slot: the stored
-- (trim-relative) step count scaled up by 1/trim_fraction (see above).
local function engine_sample_steps(slot)
  local steps = sample_pool.steps[slot]
  if steps == nil then
    return nil
  end
  local trim_start, trim_end, duration = trim_bounds(slot)
  return elasticat.trim_scaled_steps(steps, trim_end - trim_start, duration)
end

-- Push the pool metadata of the slot a track PLAYS (source BPM + steps) to that
-- track's chain. The engine derives each track's loopBeats from its own
-- sampleSteps, so a track never told its slot's step count free-runs at the
-- default 16 -- i.e. at the wrong rate for its sample. track = nil means every
-- active track, each from its own slot.
elasticat.sync_track_slot_metadata = function(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      elasticat.sync_track_slot_metadata(t)
    end
    return
  end
  local slot = elasticat.track_slot(track)
  if sample_pool.bpms[slot] ~= nil then
    tr_call(track, "sourceBpm", sample_pool.bpms[slot])
  end
  local eng_steps = engine_sample_steps(slot)
  if eng_steps ~= nil then
    tr_call(track, "setSampleSteps", eng_steps)
  end
end

-- Push a slot's freshly-detected metadata (source BPM + steps) to every ACTIVE
-- track that PLAYS it. In Phase 2 each track picks its own slot, so a load must
-- reach the track playing that slot even when the slot is not the File-page
-- focus -- otherwise the track free-runs at the default 16 steps and every
-- non-TAPE warp mode is at the wrong rate until the steps param is nudged (#45).
elasticat.sync_slot_metadata_to_tracks = function(slot)
  slot = sample_slot_number(slot)
  for t = 1, elasticat.active_track_count() do
    if elasticat.track_slot(t) == slot then
      elasticat.sync_track_slot_metadata(t)
    end
  end
end

-- Push pool metadata (bpm/steps/gain) + the mapped loop points to the engine.
-- Called when the active/playback slot changes, or when its own metadata is
-- edited. Does not touch the display params -- those follow the file-edit slot.
-- `slot` is retained for call-site readability; each track resolves its OWN
-- slot, so a pool edit reaches whichever tracks are actually playing it.
local function push_engine_slot_metadata(_slot)
  elasticat.sync_track_slot_metadata()
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

  -- Track 1's playback slot, named explicitly: this is the hand-registered
  -- track-1 `sample_slot` param: tracks 2-8 bind their slot through their own
  -- SPEC-registered id.
  if slot == 0 then
    tr_call(1, "setSampleSlot", 0)
    if not suppress_pool_callback and pool_options.on_sample_slot ~= nil then
      pool_options.on_sample_slot(0, nil)
    end
    return
  end

  -- Push the active slot's metadata to the engine (not the display params, which
  -- follow the file-edit slot).
  push_engine_slot_metadata(slot)
  tr_call(1, "setSampleSlot", slot)

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

-- The coalescing (12Hz) dispatcher params_spec hands every `queue = true` param
-- action -- the per-track twin of queue_engine_call, keyed on the param id so a
-- fast encoder sweep collapses to one send per param per tick.
elasticat.tr_queue = function(key, track, cmd, ...)
  local args = {...}
  local argc = select("#", ...)
  queue_engine_send(key, function()
    tr_call(track, cmd, unpack(args, 1, argc))
  end)
end

-- ---- Base-value resolver: publishing overrides + re-sending ---------------
-- A continuous base param is a control (not option/binary) that pushes ONE
-- value to the engine (has a cmd, no custom action) and is not a region point
-- (loop_start/end resolve through region_point + active_range instead). Only
-- these participate in the step/crossfader switch; everything else sends its own
-- value unchanged.
local function is_base_suffix(suffix)
  local entry = ParamsSpec.BY_SUFFIX[suffix]
  return entry ~= nil and entry.kind == nil and entry.cmd ~= nil
    and entry.action == nil and entry.xform ~= "region_point"
end
elasticat.is_base_suffix = is_base_suffix

-- Re-send ONE track's param through its EXACT transform + engine command, at the
-- currently-resolved base (entry_action consults resolve_base). Same 12Hz
-- coalescing queue a live edit uses, so a step firing/clearing at sequencer rate
-- collapses to one send per param per flush -- the morph flood cannot return.
local resend_deps = {
  xforms = elasticat.param_xforms,
  tr_now = elasticat.tr_now,
  tr_queue = elasticat.tr_queue,
  resolve_base = elasticat.resolve_base
}
local function resend_base(track, entry)
  if entry == nil then
    return
  end
  local pid = elasticat.track_pid(track, entry.suffix)
  if not elasticat.param_exists(pid) then
    return
  end
  ParamsSpec.entry_action(resend_deps, track, entry, pid)(params:get(pid))
end

-- Publish (value) or clear (nil) a firing step p-lock's value for a continuous
-- base param on the SELECTED track, then re-send the resolved base. Returns
-- false for params that are NOT continuous base values (discrete/option/binary
-- p-locks, region/range) so the caller falls back to the destructive params:set
-- path those still use.
-- A param is resolvable on a track when its KNOB edit also flows through
-- entry_action -- so an edit made while an override is live is itself resolved
-- and the override wins. That is every base param on tracks 2-8, and the `t1`
-- base params on track 1. Track 1's remaining hand-registered params (pitch,
-- xfade, chop/grain, slice times) bypass entry_action, so on track 1 they keep
-- the destructive path (fixed once track 1 is fully SPEC-registered --
-- docs/BASE_VALUE_RESOLVER.md follow-up).
function elasticat.is_resolvable(track, suffix)
  local entry = ParamsSpec.BY_SUFFIX[suffix]
  return entry ~= nil and is_base_suffix(suffix) and (track > 1 or entry.t1 == true)
end

function elasticat.set_step_override(suffix, value)
  if not elasticat.is_resolvable(engine_track, suffix) then
    return false
  end
  if step_override[suffix] == value then
    return true
  end
  step_override[suffix] = value
  resend_base(engine_track, ParamsSpec.BY_SUFFIX[suffix])
  return true
end

-- Crossfader morph = source 2 (docs/BASE_VALUE_RESOLVER.md). SceneStore:apply
-- publishes each morph target's interpolated value here -- per-track, since a
-- scene is the whole instrument -- instead of mutating the track param, so the
-- stored bar keeps the track value and the knob keeps source 1. Self-skips an
-- unchanged value, so a fader tick re-sends only what moved (the morph-flood fix
-- stays intact). Returns false for a non-resolvable param so the caller can fall
-- back to a direct params:set (region/range, track-1 hand-registered).
function elasticat.set_crossfader_override(track, suffix, value)
  if not elasticat.is_resolvable(track, suffix) then
    return false
  end
  local layer = crossfader_override[track]
  if layer == nil then
    layer = {}
    crossfader_override[track] = layer
  end
  if layer[suffix] ~= value then
    layer[suffix] = value
    resend_base(track, ParamsSpec.BY_SUFFIX[suffix])
  end
  return true
end

-- A normal knob edit on a morph target takes that param back from the crossfader:
-- drop its crossfader override so the track value (source 1) is what plays, until
-- the fader is next moved and re-applies the morph. Owner: "if I am not moving the
-- crossfader, adjusting the track cutoff should make it the base value." No-op
-- when the param is not currently morphing. Called from the SELECTED track's
-- normal-edit hook (scene_base_follow), so it uses engine_track.
function elasticat.knob_takes_over(suffix)
  local layer = crossfader_override[engine_track]
  if layer ~= nil and layer[suffix] ~= nil then
    layer[suffix] = nil
    resend_base(engine_track, ParamsSpec.BY_SUFFIX[suffix])
  end
end

-- Drop crossfader overrides whose param left the morph set (unlocked from both
-- scenes, or its endpoints became equal) so the knob (source 1) regains control,
-- re-sending each dropped param at its now-resolved base. active_set is
-- {full_id -> true} of the CURRENT morph targets. O(live overrides), and only
-- re-sends the few that actually dropped. Setting an existing field to nil mid
-- pairs() is defined behaviour in Lua.
function elasticat.reconcile_crossfader(active_set)
  active_set = active_set or {}
  for track, layer in pairs(crossfader_override) do
    for suffix in pairs(layer) do
      if active_set[elasticat.track_pid(track, suffix)] == nil then
        layer[suffix] = nil
        resend_base(track, ParamsSpec.BY_SUFFIX[suffix])
      end
    end
  end
end

-- True while any override layer holds a value, so the render can skip the
-- per-cell resolve entirely in the common case (nothing p-locked or morphing).
function elasticat.has_base_override()
  if next(step_override) ~= nil then
    return true
  end
  for _, layer in pairs(crossfader_override) do
    if next(layer) ~= nil then
      return true
    end
  end
  return false
end

-- The RESOLVED base of a selected-track param -- what a firing step lock (or a
-- morph) is actually sending, for the actual bar / filter curve to draw during
-- playback. Raw units, like params:get; nil if the param does not exist.
function elasticat.resolved_value(suffix)
  local pid = elasticat.track_pid(engine_track, suffix)
  if not elasticat.param_exists(pid) then
    return nil
  end
  return elasticat.resolve_base(engine_track, suffix, params:get(pid))
end

-- Re-send ONE track's envelope times (used when its env_range changes the
-- seconds mapping); guarded so it is a no-op before the params exist.
resend_env_times = function(track)
  track = track or 1
  local function resend(suffix, cmd)
    local pid = elasticat.track_pid(track, suffix)
    if elasticat.param_exists(pid) then
      elasticat.tr_queue(pid, track, cmd, env_value_to_seconds(params:get(pid), track))
    end
  end
  resend("env_attack", "envAttack")
  resend("env_decay", "envDecay")
  resend("env_release", "envRelease")
  resend("env_hold", "envHold")
end

-- The filter envelope shares the amp's seconds mapping (env_range), so a range
-- change must re-send the filter env times too.
resend_filter_env_times = function(track)
  track = track or 1
  local function resend(suffix, cmd)
    local pid = elasticat.track_pid(track, suffix)
    if elasticat.param_exists(pid) then
      elasticat.tr_queue(pid, track, cmd, env_value_to_seconds(params:get(pid), track))
    end
  end
  resend("filter_env_attack", "filterEnvAttack")
  resend("filter_env_decay", "filterEnvDecay")
  resend("filter_env_release", "filterEnvRelease")
  resend("filter_env_hold", "filterEnvHold")
end

-- The mod envelope's ATK/DEC also share the amp env's seconds mapping.
resend_menv_times = function(track)
  track = track or 1
  local function resend(suffix, cmd)
    local pid = elasticat.track_pid(track, suffix)
    if elasticat.param_exists(pid) then
      elasticat.tr_queue(pid, track, cmd, env_value_to_seconds(params:get(pid), track))
    end
  end
  resend("menv_attack", "menvAttack")
  resend("menv_decay", "menvDecay")
  resend("menv_release", "menvRelease")
end

-- Each track has one gain input (\trAmp); the per-sample "gain" param is a
-- script-side multiplier on top of the track's Volume, so both combine into
-- that single engine send instead of needing a second engine parameter. Same
-- arithmetic as the "amp" xform -- this is the path taken when the SAMPLE gain
-- moved rather than the Volume param. track = nil means every active track
-- (a pool gain edit can affect any track playing that slot).
send_effective_amp = function(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      send_effective_amp(t)
    end
    return
  end
  local pid = elasticat.track_pid(track, "amp")
  if not elasticat.param_exists(pid) then
    return
  end
  -- Track Volume is an Elektron-style 0-127 param; map to a 0..1 amplitude.
  elasticat.tr_queue(pid, track, "amp", (params:get(pid) / 127) * elasticat.track_gain(track))
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

-- Public: force the coalesced engine-send queue out NOW. Used by the sequencer
-- to send a firing step's p-locks (notably filter cutoff) BEFORE the slice/loop
-- voice triggers -- otherwise the queued (12Hz-coalesced) cutoff lands ~80ms
-- after the immediate trigger and the voice audibly "bloops" to the new cutoff.
elasticat.flush_engine_sends = function()
  flush_engine_sends()
end

local function reset_clock_origin()
  clock_origin = clock.get_beats()
  clock_sequence = 0
end

-- Track 1 transport. EXPLICITLY tr_call(1, ...) rather than engine_call: the
-- engine_call fallback routes an orphaned per-track command to the SELECTED
-- track, so with track 2 selected this started track 2 (twice, via
-- elasticat.play below) and never started track 1 at all. That is a transport
-- decision leaking out of an id-resolution helper.
local function set_engine_play(x)
  print("elasticat: params/play action " .. tostring(x))
  if x == 1 and ids.clock_sync ~= nil and params:get(ids.clock_sync) == 1 then
    reset_clock_origin()   -- global beat origin: once, not per track
    tr_call(1, "setPlayhead", 0)
  end
  tr_call(1, "play", x)
end

local function send_clock_observation()
  if ids.target_bpm == nil then
    return
  end

  local tempo = clock.get_tempo()
  -- Beats since play-start = the shared clock position. The engine locks EVERY
  -- playing loop track to its OWN expected phase from this plus that track's own
  -- loopBeats, so a loop on any track stays in sync (not just track 1's). The old
  -- track-1 expected_phase computation moved into the engine, per track.
  local beats_since_origin = clock.get_beats() - clock_origin

  clock_sequence = clock_sequence + 1
  params:set(ids.target_bpm, tempo, true)

  if engine.syncClock ~= nil then
    engine.syncClock(beats_since_origin, tempo, clock_sequence)
  elseif engine.targetBpm ~= nil then
    engine.targetBpm(tempo)
  end
  -- Proof-of-life for the watchdog: the sync fiber reached here, so the clock is
  -- advancing and observations are flowing.
  last_observation_time = util.time()
end

-- Auto-recovery for a wedged norns clock (owner: "adjusting pattern rates stops
-- the internal clock; a double-stop fixes it"). The double-stop is reset_clock ->
-- clock.cleanup(), which frees a leaked/exhausted clock-coroutine pool that the
-- sync fiber's clock.sync() can no longer resume through. This does the SAME
-- recovery automatically. It runs on a METRO -- deliberately, because a metro is
-- not a clock coroutine, so it keeps ticking even when the clock pool is
-- exhausted. Tightly gated: only while clock sync is on, only after a >3s gap in
-- observations (normal cadence is one per 1/4 beat, <=1.5s even at 40 BPM), and
-- at most once per 10s so a genuinely dead external clock source can't churn it.
function elasticat.start_clock_watchdog()
  if clock_watchdog_metro ~= nil then return end
  if metro == nil or metro.init == nil then return end
  clock_watchdog_metro = metro.init(function()
    if ids.clock_sync == nil or params:get(ids.clock_sync) ~= 1 then return end
    local now = util.time()
    if (now - last_observation_time) > 3 and (now - last_clock_recovery) > 10 then
      last_clock_recovery = now
      last_observation_time = now  -- grace period so recovery isn't re-triggered
      print("elasticat: clock wedged (>3s without a sync observation) -- auto-recovering")
      if clock ~= nil and clock.cleanup ~= nil then
        clock.cleanup()
      end
      elasticat.start_clock_sync()
    end
  end, 1, -1)
  clock_watchdog_metro:start()
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
  -- Grace period: don't let the watchdog trip on the gap between (re)starting the
  -- fiber and its first observation.
  last_observation_time = util.time()
  elasticat.start_clock_watchdog()
  sync_thread = clock.run(function()
    while true do
      clock.sync(1 / 4)
      if params:get(ids.clock_sync) == 1 then
        -- pcall so a transient error (a nil engine command mid-reload, a bad
        -- param read) can NEVER terminate this coroutine. A dead sync thread
        -- silently stops every clock observation -> loops stop re-syncing and
        -- the transport looks "stuck" until a double-stop restarts it. Keep
        -- the loop alive and just log the fault instead.
        local ok, err = pcall(send_clock_observation)
        if not ok then
          print("elasticat: clock observation error (sync loop kept alive): " .. tostring(err))
        end
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
-- Transport is GLOBAL. Play starts every active track, whichever one happens
-- to be selected: selection is an EDITING focus, not a transport scope.
--
-- This used to return early when a track above 1 was selected, playing ONLY
-- that track -- so selecting track 2 and pressing play silenced track 1, while
-- selecting track 1 played both. `all_tracks` is kept for the callers that
-- pass it, but it no longer changes what happens.
function elasticat.play(state, all_tracks)
  -- `state` is the raw transport state. EVERY track (including track 1) runs its
  -- free-running reader only on a CONTINUOUS (loop) machine; a slice machine
  -- sounds from its own triggers, so its reader stays muted. Gating track 1 by
  -- its OWN machine here is what lets a slice on track 1 coexist with a loop on
  -- track 2 -- the caller must NOT pre-gate `state` by the SELECTED track's
  -- machine (that silenced every loop track whenever a slice track was selected).
  local machine1 = elasticat.track_param_value(1, "machine") or 1
  set_engine_play((state and machine1 == 1) and 1 or 0)
  for track = 2, elasticat.active_track_count() do
    local machine = elasticat.track_param_value(track, "machine") or 1
    tr_call(track, "play", (state and machine == 1) and 1 or 0)
  end
end

function elasticat.stop_reset()
  flush_engine_sends()
  -- stopAndReset/stop are genuinely global engine commands; play/playhead are
  -- per track and must name track 1 explicitly (see set_engine_play) or they
  -- stop whichever track happens to be selected.
  if engine.stopAndReset ~= nil then
    engine_call("stopAndReset")
  elseif engine.stop ~= nil then
    engine_call("stop")
  else
    tr_call(1, "play", 0)
    tr_call(1, "playhead", 0)
  end
  for track = 2, elasticat.active_track_count() do
    tr_call(track, "play", 0)
    tr_call(track, "playhead", 0)
  end
end

function elasticat.request_status()
  engine_call("requestStatus")
end

-- ---- Live voice/region gestures, per track ---------------------------------
-- Every one of these takes an explicit `track`, defaulting to engine_track (the
-- selected track) so existing callers are unchanged. There is ONE path: the
-- track index is an argument, never a branch. They all used to be
-- `if engine_track > 1 then tr_call(...) else engine_call(...) end`, and the
-- tracks-2-8 half skipped map_trim_point entirely -- which is exactly why a
-- background track's region locks addressed raw file positions.

function elasticat.set_pitch(value, track)
  tr_call(track or engine_track, "setPitch", value)
end

function elasticat.set_reverse(reverse, track)
  tr_call(track or engine_track, "setReverse",
    (reverse == true or reverse == 1) and 1 or 0)
end

function elasticat.trigger_slice(slice_index, start_point, end_point, play_mode, reverse, velocity, length_seconds, pitch_value, track, choke_group, mono)
  track = track or engine_track
  -- mono nil = "use the engine's global default"; 0/1 forces poly/mono for this
  -- voice (the machine drives it -- Slice/Razor mono, *Poly poly).
  local mono_flag = mono == nil and -1 or (mono == 1 and 1 or 0)
  tr_call(track, "triggerSlice",
    slice_index,
    map_trim_point(start_point, track),
    map_trim_point(end_point, track),
    play_mode,
    (reverse == true or reverse == 1) and 1 or 0,
    velocity or 1,
    length_seconds or 0,
    pitch_value or 0,
    math.floor((tonumber(choke_group) or 0) + 0.5),
    mono_flag)
end

-- Panic hard-kill of every slice voice on every track (stop-twice). A plain
-- stop only opens the gate; a stuck or long-releasing voice needs the steal.
function elasticat.kill_all_slices()
  engine_call("killAllSlices")
end

-- Retrigger the amp envelope on the active reader with the given note length
-- (seconds, the ADSR gate window). Sent immediately -- envelope timing is tight.
-- Pass seconds <= 0 (any non-positive value, e.g. 0) as the "indefinite hold"
-- sentinel: the engine then leaves the ADSR gate open until note_off() closes
-- it, instead of auto-releasing after a timer -- for a live-held note (e.g. a
-- grid key held down) whose duration isn't known up front. Omitting `seconds`
-- keeps today's default one-shot length (0.1s), unchanged.
function elasticat.note_on(seconds, track)
  tr_call(track or engine_track, "noteOn", seconds or 0.1)
end

-- Close the currently-sounding note's ADSR gate now (release stage), for a
-- live-held note started via elasticat.note_on(0) (or any seconds <= 0).
-- Sent immediately, same as note_on -- envelope timing is tight. No-op (just
-- a redundant reset edge) if nothing is currently held open.
function elasticat.note_off(track)
  tr_call(track or engine_track, "noteOff")
end

-- Force a fresh amp/filter re-attack for auditioning a stopped step preview.
-- Unlike note_on, this re-attacks even under portamento (whose legato hold
-- otherwise swallows a note-on on a still-sounding preview note). seconds <= 0
-- keeps the indefinite hold used by the sustained preview.
function elasticat.retrig_note(seconds, track)
  tr_call(track or engine_track, "retrigNote", seconds or 0)
end

-- ---- Per-track engine sync -------------------------------------------------
-- Params are added with their action set afterwards (so their defaults never
-- fire) and older psets lack the newer ids entirely, which leaves the engine
-- on stale defaults until something pushes the current values. These sync
-- helpers do that -- and they drive the params through params_spec.entry_action,
-- i.e. the EXACT transform + engine command the param action itself uses, so a
-- sync can never drift from an edit.
--
-- track = nil means "every allocated track" (what init wants); an explicit
-- track syncs just that one.

-- Immediate variant of the SPEC dispatch: init ordering matters (machines are
-- re-selected last so their respawn seeds from the values just sent), so sync
-- bypasses the 12Hz coalescing queue that live edits use.
elasticat.sync_deps = {
  xforms = elasticat.param_xforms,
  tr_now = elasticat.tr_now,
  tr_queue = elasticat.tr_now,
  resolve_base = elasticat.resolve_base
}

elasticat.sync_entry = function(track, entry)
  if entry == nil then
    return
  end
  local pid = elasticat.track_pid(track, entry.suffix)
  if not elasticat.param_exists(pid) then
    return
  end
  ParamsSpec.entry_action(elasticat.sync_deps, track, entry, pid)(params:get(pid))
end

elasticat.sync_entries = function(track, suffixes)
  for _, suffix in ipairs(suffixes) do
    elasticat.sync_entry(track, ParamsSpec.BY_SUFFIX[suffix])
  end
end

-- Amp envelope + portamento + the output stage (vol/pan, which live on the
-- track FILTER synth engine-side -- that is where the mod matrix applies the
-- AMP/PAN destinations).
function elasticat.sync_amp_env(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      elasticat.sync_amp_env(t)
    end
    return
  end
  elasticat.sync_entries(track, {
    "env_mode", "env_attack", "env_decay", "env_sustain", "env_release",
    "env_hold", "portamento", "amp", "pan"
  })
end

-- Filter + filter envelope. The machine is (re)selected LAST so its respawn
-- seeds from the now-current engine-side values.
function elasticat.sync_filter(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      elasticat.sync_filter(t)
    end
    return
  end
  elasticat.sync_entries(track, {
    "filter_type", "filter_cutoff", "filter_res", "filter_drive",
    "filter_morph", "filter_balance",
    "filter_env_mode", "filter_env_attack", "filter_env_decay",
    "filter_env_sustain", "filter_env_release", "filter_env_hold",
    "filter_env_depth",
    "filter_machine"
  })
end

-- Insert 1 FX + this track\x27s send levels/tap. Machine last, same reasoning as
-- sync_filter. The send BUS effects and the master insert are shared by every
-- track, so they are pushed once by sync_bus_fx below.
function elasticat.sync_fx(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      elasticat.sync_fx(t)
    end
    elasticat.sync_bus_fx()
    return
  end
  elasticat.sync_entries(track, {
    "fx_drive", "fx_mix", "delay_time", "delay_feedback", "delay_tone",
    "reverb_size", "reverb_damp", "lofi_bits", "lofi_rate",
    "fx_insert1_machine",
    "send_tap", "send1_level", "send2_level"
  })
end

-- Send 1/2 bus FX + the master insert (PRD SS3/SS8): GLOBAL, one instance each,
-- so these keep the un-prefixed engine commands. Guarded independently since a
-- pset saved before they landed will not have these ids.
elasticat.sync_bus_fx = function()
  if ids.send1_machine == nil or not elasticat.param_exists(ids.send1_machine) then
    return
  end
  local function slot(cmd_prefix, slot_ids, machine_id, machine_cmd)
    engine_call(cmd_prefix .. "FxDrive", util.clamp((params:get(slot_ids.fx_drive) or 0) / 127, 0, 1))
    engine_call(cmd_prefix .. "FxMix", util.clamp((params:get(slot_ids.fx_mix) or 64) / 127, 0, 1))
    engine_call(cmd_prefix .. "DelayTime", DELAY_TIME_BEATS[params:get(slot_ids.delay_time) or 4] or 1)
    engine_call(cmd_prefix .. "DelayFeedback", util.clamp((params:get(slot_ids.delay_feedback) or 38) / 127, 0, 1))
    engine_call(cmd_prefix .. "DelayTone", util.clamp((params:get(slot_ids.delay_tone) or 127) / 127, 0, 1))
    engine_call(cmd_prefix .. "ReverbSize", util.clamp((params:get(slot_ids.reverb_size) or 64) / 127, 0, 1))
    engine_call(cmd_prefix .. "ReverbDamp", util.clamp((params:get(slot_ids.reverb_damp) or 64) / 127, 0, 1))
    engine_call(cmd_prefix .. "LofiBits", lofi_bits_depth(params:get(slot_ids.lofi_bits) or 127))
    engine_call(cmd_prefix .. "LofiRate", lofi_rate_hz(params:get(slot_ids.lofi_rate) or 127))
    engine_call(machine_cmd, (params:get(machine_id) or 1) - 1)
  end

  slot("send1", {
    fx_drive = ids.send1_fx_drive, fx_mix = ids.send1_fx_mix,
    delay_time = ids.send1_delay_time, delay_feedback = ids.send1_delay_feedback,
    delay_tone = ids.send1_delay_tone, reverb_size = ids.send1_reverb_size,
    reverb_damp = ids.send1_reverb_damp, lofi_bits = ids.send1_lofi_bits,
    lofi_rate = ids.send1_lofi_rate
  }, ids.send1_machine, "setSend1Machine")

  slot("send2", {
    fx_drive = ids.send2_fx_drive, fx_mix = ids.send2_fx_mix,
    delay_time = ids.send2_delay_time, delay_feedback = ids.send2_delay_feedback,
    delay_tone = ids.send2_delay_tone, reverb_size = ids.send2_reverb_size,
    reverb_damp = ids.send2_reverb_damp, lofi_bits = ids.send2_lofi_bits,
    lofi_rate = ids.send2_lofi_rate
  }, ids.send2_machine, "setSend2Machine")

  slot("master", {
    fx_drive = ids.master_fx_drive, fx_mix = ids.master_fx_mix,
    delay_time = ids.master_delay_time, delay_feedback = ids.master_delay_feedback,
    delay_tone = ids.master_delay_tone, reverb_size = ids.master_reverb_size,
    reverb_damp = ids.master_reverb_damp, lofi_bits = ids.master_lofi_bits,
    lofi_rate = ids.master_lofi_rate
  }, ids.master_fx_machine, "setMasterMachine")
end

-- Modulation: 2 LFOs + mod envelope + the 4 macros (value + 5 matrix depths
-- each), all on this track\x27s own control-rate mod synth.
function elasticat.sync_mod(track)
  if track == nil then
    for t = 1, elasticat.active_track_count() do
      elasticat.sync_mod(t)
    end
    return
  end
  elasticat.sync_entries(track, {
    "lfo1_dest", "lfo1_wave", "lfo1_speed", "lfo1_depth", "lfo1_mode",
    "lfo2_dest", "lfo2_wave", "lfo2_speed", "lfo2_depth", "lfo2_mode",
    "menv_dest", "menv_attack", "menv_decay", "menv_sustain", "menv_release",
    "menv_depth"
  })
  elasticat.sync_entries(track, ParamsSpec.MACRO_SUFFIXES)
end

-- Set a macro's live value (0-127) -- used by the grid macro keys. Routes
-- through the param so the value is displayed, saved, and (when a step is
-- held) p-locked by the normal step-lock path; the param action pushes it to
-- the engine.
function elasticat.set_macro_value(index, value, track)
  local vid = elasticat.track_pid(track or engine_track, "macro" .. index .. "_value")
  if elasticat.param_exists(vid) then
    params:set(vid, util.clamp(value, 0, 127))
  end
end

-- The macro-matrix depth param id for a macro (1-4) targeting a destination
-- (a MACRO_DESTS entry), or nil. The coordinator adjusts this param when you
-- hold a macro key and turn the destination's param -- on the SELECTED track,
-- like every other editing gesture.
function elasticat.macro_depth_id(index, dest, track)
  if dest == nil then
    return nil
  end
  return elasticat.track_pid(track or engine_track, "macro" .. index .. "_" .. dest.key .. "_depth")
end

-- Retrigger the modulation sources for a firing step. lfo_on retrigs both
-- LFOs (only their non-FREE modes react -- the synth gates the trigger by
-- mode); env_on retrigs the mod envelope. Fired by the sequencer where the
-- step's lfo_reset / env_reset resolve ON (ghosts resolve both off). Sent
-- immediately, same as note_on -- trigger timing is tight. Every track runs
-- its own mod synth, so this is a per-track command like the rest of them.
function elasticat.mod_trig(lfo_on, env_on, track)
  if not lfo_on and not env_on then
    return
  end
  tr_call(track or engine_track, "modTrig", lfo_on and 1 or 0, env_on and 1 or 0)
end

function elasticat.release_slice(slice_index, track)
  tr_call(track or engine_track, "releaseSlice", slice_index)
end

function elasticat.release_all_slices(track)
  tr_call(track or engine_track, "releaseAllSlices")
end

-- The region a track plays, in TRACK space (0-128), mapped through that track's
-- Range + File Trim on the way out. `reset_playhead`: nil = leave the playhead
-- alone, a number = warp to that phase, truthy = warp to 0.
--
-- flush_engine_sends() first, for EVERY track, not just the selected one: a
-- coalesced loopStart/loopEnd still sitting in the 12Hz queue from an encoder
-- edit would otherwise land AFTER this immediate send and overwrite the step's
-- region with a stale value.
function elasticat.set_loop_region(start_point, end_point, reset_playhead, track)
  track = track or engine_track
  flush_engine_sends()
  local engine_start = map_trim_point(start_point, track)
  local engine_end = map_trim_point(end_point, track)
  -- Chopped domino: the scrubbed/locked TRACK loop is the playhead window; refresh
  -- it (and the range slice area) alongside the shared region send. No-op unless
  -- this track is chopped.
  elasticat.push_chop_regions(track, start_point, end_point, false)
  -- nil = leave the playhead; a number = that phase; any other truthy = 0.
  -- `false` must mean "leave it" -- `reset_playhead ~= nil` would have warped
  -- to 0 on an explicit false.
  local phase = nil
  if type(reset_playhead) == "number" then
    phase = reset_playhead
  elseif reset_playhead then
    phase = 0
  end
  -- One atomic command when the playhead moves too: region and phase land in
  -- the same message, so the playhead is never reset against the OLD region
  -- (and it is one OSC message per trig instead of three).
  if phase ~= nil then
    tr_call(track, "loopRegionPlayhead", engine_start, engine_end, phase)
    return
  end
  tr_call(track, "loopStart", engine_start)
  tr_call(track, "loopEnd", engine_end)
end

-- Auditions the File-edit slot as a raw looped sample -- native rate, no
-- timestretch / pitch / warp -- through its own preview synth (engine
-- previewSlot), using the slot's trim window and gain. Only while master
-- transport is stopped so it never fights sequenced playback.
-- Live preview state: whether the File-page audition is currently running, so
-- trim/gain scrubbing can push a live region update (update_preview_region).
local preview_playing = false

-- 0..1 start/end + gain of a slot's current trim window (what the preview plays).
local function preview_region_for(slot)
  local trim_start, trim_end, duration = trim_bounds(slot)
  local start_frac, end_frac = 0, 1
  if duration > 0 then
    start_frac = util.clamp(trim_start / duration, 0, 0.999)
    end_frac = util.clamp(trim_end / duration, start_frac + 0.001, 1)
  end
  return start_frac, end_frac, sample_pool.gains[slot] or 1
end

-- Push the file-edit slot's CURRENT trim + gain to the RUNNING preview synth so
-- scrubbing trim (or gain) while auditioning follows in real time -- no re-trigger
-- (the engine Lags the region so it glides). No-op unless the preview is running.
function elasticat.update_preview_region()
  if not preview_playing then return end
  local start_frac, end_frac, gain = preview_region_for(file_edit_slot)
  engine_call("setPreviewRegion", start_frac, end_frac, gain)
end

function elasticat.preview_trim(on)
  if on then
    if ids.play ~= nil and params:get(ids.play) == 1 then
      preview_playing = false
      return
    end
    local start_frac, end_frac, gain = preview_region_for(file_edit_slot)
    flush_engine_sends()
    engine_call("previewSlot", file_edit_slot, start_frac, end_frac, gain, 1)
    preview_playing = true
  else
    engine_call("previewSlot", 0, 0, 1, 1, 0)
    preview_playing = false
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
  -- Steps now describe the TRIMMED portion (owner): grab the whole-sample step
  -- count at this BPM, scale by the trim's fraction of the sample, and store
  -- that. Reduces to trim_seconds * bpm/60 * 4. A zero/absent trim falls back to
  -- the whole sample so recalc still does something useful before any trimming.
  local trim_start, trim_end = trim_bounds(slot)
  local trim_dur = trim_end - trim_start
  if trim_dur <= 0 then
    trim_dur = duration
  end
  local multiplier = duration > 0 and (trim_dur / duration) or 1
  local steps = quantize_steps((duration * bpm / 60 * 4) * multiplier)
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
  -- Push the detected steps/bpm to whatever tracks actually play this slot
  -- (Phase 2 per-track slots), so a load reaches the engine immediately (#45).
  elasticat.sync_slot_metadata_to_tracks(slot)
  if slot == active_sample_slot then
    -- The focused slot also refreshes loop points + amp for the whole mix.
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
  ids.pattern_steps = param_id(prefix, "pattern_steps")
  ids.pattern_quantize = param_id(prefix, "pattern_quantize")
  ids.global_pattern_length = param_id(prefix, "global_pattern_length")
  ids.global_bpm = param_id(prefix, "global_bpm")
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
  ids.debug = param_id(prefix, "debug")
  ids.live_performance_mode = param_id(prefix, "live_performance_mode")
  ids.step_preview = param_id(prefix, "step_preview")
  ids.crossfade = param_id(prefix, "crossfade")

  -- Send 1/2 + Master insert FX (PRD §3/§8): send tap point, per-send level,
  -- and the three machine selects. Each slot's Drive/Mix/Delay*/Reverb*/Lofi*
  -- ids are namespaced per slot (send1_/send2_/master_) via FxRegistry's
  -- `prefix` argument -- see fx_send1_items/fx_send2_items/fx_master_items
  -- below and lib/fx_modes/*.lua.
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

  -- The whole signal chain (filter, both envelopes, insert FX, send levels,
  -- output, modulation + macros, and the per-track behaviour settings) is
  -- registered from ParamsSpec.SPEC at the END of this function -- for all 8
  -- tracks, track 1 included. Nothing signal-chain-shaped is registered by
  -- hand here any more, and no `ids.*` entry exists for those suffixes: their
  -- per-track ids come from elasticat.track_pid(track, suffix).

  -- Per-track param model (docs/PHASE1_CONTRACT.md, docs/PHASE2_CONTRACT.md).
  track_prefix = prefix
  ids.active_track_count = param_id(prefix, "active_track_count")

  -- Projects (PRD §7, workstream C).
  ids.project_auto_name = param_id(prefix, "project_auto_name")
  ids.project_load = param_id(prefix, "project_load")
  ids.project_save = param_id(prefix, "project_save")
  ids.project_save_as = param_id(prefix, "project_save_as")
  ids.project_new = param_id(prefix, "project_new")

  -- Re-push track 1's warp-mode params after a mode/machine switch (the new
  -- reader synth starts on its SynthDef defaults). Every command here is per
  -- track and names track 1 explicitly: these are the hand-registered,
  -- un-prefixed ids, which ARE track 1's -- tracks 2-8 own the t<N>_ copies and
  -- push them through their own SPEC actions.
  local function apply_current_mode_params()
    local mode = params:get(ids.mode)
    local function push(suffix, cmd, offset)
      tr_call(1, cmd, params:get(param_id(prefix, suffix)) + (offset or 0))
    end
    if mode == 1 or mode == 2 or mode == 11 or mode == 12 then
      -- tape / tempo_varispeed / tape_xf / tape_ugen: region-only readers.
      tr_call(1, "loopStart", map_trim_point(params:get(ids.loop_start), 1))
      tr_call(1, "loopEnd", map_trim_point(params:get(ids.loop_end), 1))
    elseif mode == 3 then
      push("chop_steps", "chopSteps")
      push("chop_slice_len", "chopSliceLen")
      push("chop_loop_mode", "chopLoopMode", -1)
      push("chop_attack", "chopAttack")
      push("chop_hold", "chopHold")
      push("chop_release", "chopRelease")
      -- Domino model: the slice area (Range) + playhead window (raw Track loop). The
      -- new chopped synth starts on defaults (full range, full window), so push the
      -- real regions or it slices the whole buffer with an all-slices playhead.
      elasticat.push_chop_regions(1, params:get(ids.loop_start), params:get(ids.loop_end), false)
    elseif mode == 4 then
      push("grain_size", "grainSize")
      push("grain_density", "grainDensity")
      push("grain_jitter", "grainJitter")
      push("grain_speed", "grainSpeed")
      push("grain_speed_rand", "grainSpeedRand")
      push("grain_direction", "grainDirection")
    elseif mode == 13 then
      -- GStretch (varispeed reader + pitch-correct): STRCH = grain_speed, PWIN =
      -- grain_size (window), SMTH = grain_density (shift dispersion).
      push("grain_speed", "grainSpeed")
      push("grain_size", "grainSize")
      push("grain_density", "grainDensity")
    elseif mode == 14 then
      -- GStretch2 (clock-synced): STRCH + PWIN + SMTH (grain_density = shift dispersion).
      push("grain_speed", "grainSpeed")
      push("grain_size", "grainSize")
      push("grain_density", "grainDensity")
    elseif mode == 15 then
      -- RubberBand: STRCH = grain_speed (rate); pitch held via the pitch knob.
      push("grain_speed", "grainSpeed")
    elseif mode == 5 then
      push("wsola_window", "wsolaWindow")
      push("wsola_search", "wsolaSearch")
    elseif mode == 6 then
      push("pv_window", "pvWindow")
      push("pv_dispersion", "pvDispersion")
    elseif mode == 7 then
      push("harm_interval", "harmInterval")
      push("harm_interval2", "harmInterval2")
      push("harm_interval3", "harmInterval3")
    elseif mode == 8 then
      push("wt_window", "wtWindow")
      push("wt_cycle", "wtCycle")
      push("wt_lfo_rate", "wtLfoRate")
      push("wt_lfo_depth", "wtLfoDepth")
      push("wt_lfo_shape", "wtLfoShape", -1)
    elseif mode == 9 then
      push("freeze_amount", "freezeAmount")
      push("spectral_blur", "spectralBlur")
    elseif mode == 10 then
      push("formant_shift", "formantShift")
      push("freeze_amount", "freezeAmount")
    end
    -- Rate multiplier applies to EVERY warp mode (transport scaling), so re-push it
    -- on any mode switch regardless of which branch ran above.
    push("warp_rate", "warpRate")
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
    tr_call(1, "setMode", params:get(ids.mode) - 1)
    apply_current_mode_params()
    -- Only a continuous (loop) machine free-runs its reader; slice machines
    -- sound from their own triggers. Track 1's transport, named explicitly.
    tr_call(1, "play", x == 1 and params:get(ids.play) or 0)
  end)

  params:add_option(ids.mode, "engine mode", elasticat.modes, 1)
  params:set_action(ids.mode, function(x)
    flush_engine_sends()
    tr_call(1, "setMode", x - 1)
    apply_current_mode_params()
  end)

  -- The engine names this \trModeMacro (spec field `macro`). It was being sent
  -- as "setModeMacro", which resolves to NOTHING on either side -- the mode
  -- macro was silently dropped on every track.
  add_control(ids.mode_macro, "mode macro",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) elasticat.tr_queue(ids.mode_macro, 1, "modeMacro", x) end)

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

  -- A/B scene crossfader position (PRD §6.6 requirement 2), MASTER page,
  -- encoder-adjustable. Straight 0-128 (not centered like pan/filter_balance):
  -- 0 = fully Scene A, 128 = fully Scene B. No engine call here -- this is a
  -- coordinator-side morph (SceneStore lives in elasticat.lua, not this
  -- engine-facing facade), so the action is only the pool_options.on_crossfade
  -- callback idiom (mirrors on_project_load etc. above).
  add_control(ids.crossfade, "crossfade",
    cs.new(0, 128, "lin", 1, 0, "", 1 / 128),
    function(x) if pool_options.on_crossfade ~= nil then pool_options.on_crossfade(x) end end)

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
      if file_edits_active() and params:lookup_param(param_id(prefix, "source_bpm")) ~= nil then
        params:set(param_id(prefix, "source_bpm"), x, true)
      end
      -- Coalesced (12Hz) re-push to EVERY active track from its own slot: this
      -- is pool metadata, and any track may be playing the edited slot -- not
      -- only whichever one the File page happens to be aligned with.
      queue_engine_send(ids.sample_bpm, elasticat.sync_track_slot_metadata)
    end)

  add_control(ids.sample_steps, "sample steps",
    cs.new(1, 512, "lin", 1, 16, "", 1 / 511),
    function(x)
      sample_pool.steps[file_edit_slot] = x
      mark_pool_dirty(file_edit_slot)
      queue_engine_send(ids.sample_steps, elasticat.sync_track_slot_metadata)
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
      -- The engine step count is trim-relative now, so a trim change re-scales
      -- it -- re-push (coalesced) to every track playing this slot's warp rate.
      queue_engine_send(ids.sample_steps, elasticat.sync_track_slot_metadata)
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
      -- Trim-relative steps: re-scale to the engine on a trim-end change too.
      queue_engine_send(ids.sample_steps, elasticat.sync_track_slot_metadata)
      mark_pool_dirty(slot)
    end,
    function(param) return string.format("%.3f s", param:get()) end)

  -- Set ONE trim endpoint (in seconds) INDEPENDENTLY -- unlike the trim_start
  -- knob action, moving the start here does NOT drag the end. Used by the trim
  -- SNAP editor (FN + knob), where the point is being placed precisely on a
  -- transient / zero-crossing / grid line and the other edge must stay put.
  -- Commits to the pool + display param (silent) + engine like the knob actions.
  elasticat.set_trim_point = function(point, seconds)
    local slot = file_edit_slot
    local ts, te, duration = trim_bounds(slot)
    if duration <= 0 then
      return
    end
    local target
    if point == "end" then
      target = util.clamp(seconds, math.min(duration, ts + 0.001), duration)
      sample_pool.trim_ends[slot] = target
      params:set(ids.trim_end, target, true)
    else
      target = util.clamp(seconds, 0, math.max(0, te - 0.001))
      sample_pool.trim_starts[slot] = target
      params:set(ids.trim_start, target, true)
    end
    if file_edits_active() then
      update_engine_loop_points()
    end
    queue_engine_send(ids.sample_steps, elasticat.sync_track_slot_metadata)
    mark_pool_dirty(slot)
    elasticat.update_preview_region()  -- scrubbing trim follows the audition live
    return target
  end

  add_control(ids.gain, "sample gain",
    cs.new(0, 4, "lin", 0.01, 1, "x", 0.005),
    function(x)
      local slot = file_edit_slot
      sample_pool.gains[slot] = x
      -- Push to EVERY track live, not only when the edited slot is the selected
      -- track's active slot. send_effective_amp reads each track's own slot gain,
      -- so tracks on other slots re-send an unchanged amp (harmless) and any
      -- track playing THIS slot picks the new gain up immediately. The old
      -- file_edits_active() gate made a gain edit silently do nothing whenever
      -- the edited slot was not the currently-active one (owner bug).
      send_effective_amp()
      mark_pool_dirty(slot)
      elasticat.update_preview_region()  -- gain scrub follows the audition live
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
    function(x) elasticat.tr_queue(param_id(prefix, "playhead"), 1, "setPlayhead", x) end)
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
  -- Exposed so the module-scope Range action (elasticat.remap_region) uses the
  -- exact same playback-vs-stopped resolver gate as the loop-point actions.
  elasticat.region_edit_handled = region_edit_handled

  add_control(ids.loop_start, "sample start",
    cs.new(0, 128, "lin", 0.01, 0, "", 1 / 128),
    function(x)
      if not region_edit_handled() then
        elasticat.tr_queue(ids.loop_start, 1, "loopStart", map_trim_point(x, 1))
      end
    end)

  add_control(ids.loop_end, "sample end",
    cs.new(0, 128, "lin", 0.01, 128, "", 1 / 128),
    function(x)
      if not region_edit_handled() then
        elasticat.tr_queue(ids.loop_end, 1, "loopEnd", map_trim_point(x, 1))
      end
    end)

  -- Range (range_start/range_end) is registered per-track by ParamsSpec for ALL
  -- tracks including track 1 (t1 = true), with the shared E-SNC linkage +
  -- end/start clamp in elasticat.apply_range_start / apply_range_end. Track 1's
  -- bespoke Range actions were removed here so there is one code path per the
  -- contract (the linkage used to work on track 1 only).

  -- Sample preview: momentary audition of the current sample's trim window,
  -- only while master playback is stopped (see elasticat.preview_trim). Driven
  -- by encoder on the File page and/or a grid hold.
  params:add_binary(ids.sample_preview, "sample preview", "toggle", 0)
  params:set_action(ids.sample_preview, function(x)
    elasticat.preview_trim(x == 1)
  end)

  -- Playhead-jump crossfade time (tape / tempo_varispeed). Per-track now: routed
  -- through trXfade (generated from the ParamsSpec \xfade row), not the old global
  -- \xfade command. Default 10ms.
  add_control(param_id(prefix, "xfade"), "loop xfade",
    cs.new(0, 0.25, "lin", 0.001, 0.010, "s", 0.004),
    function(x) elasticat.tr_queue(param_id(prefix, "xfade"), 1, "xfade", x) end,
    format_ms)

  add_control(param_id(prefix, "pitch"), "pitch",
    cs.new(-24, 24, "lin", 0.1, 0, "st", 0.1 / 48),
    function(x) elasticat.tr_queue(param_id(prefix, "pitch"), 1, "setPitch", x) end)

  params:add_binary(param_id(prefix, "loop_reverse"), "loop reverse", "toggle", 0)
  params:set_action(param_id(prefix, "loop_reverse"), function(x)
    elasticat.tr_queue(param_id(prefix, "loop_reverse"), 1, "setReverse", x)
  end)

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

  -- Send 1: machine is a setting (respawns the engine's send1 synth). The send
  -- LEVEL and the tap point are per-track (lib/tracks/params_spec.lua); the
  -- send BUS and its FX are shared by every track, so only the machine + its
  -- 9 knobs live here.
  params:add_group(param_id(prefix, "group_send1"), "send 1", 10)
  params:add_option(ids.send1_machine, "send 1 machine", FxRegistry.names(), 1)
  params:set_action(ids.send1_machine, function(x)
    queue_engine_call(ids.send1_machine, "setSend1Machine", x - 1)
  end)
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
  params:add_group(param_id(prefix, "group_send2"), "send 2", 10)
  params:add_option(ids.send2_machine, "send 2 machine", FxRegistry.names(), 1)
  params:set_action(ids.send2_machine, function(x)
    queue_engine_call(ids.send2_machine, "setSend2Machine", x - 1)
  end)
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

  params:add_group(param_id(prefix, "group_engine_modes"), "engine algorithms", 24)

  add_control(param_id(prefix, "chop_steps"), "chop slices",
    cs.new(1, 64, "lin", 1, 16, "slices", 1 / 63),
    function(x) elasticat.tr_queue(param_id(prefix, "chop_steps"), 1, "chopSteps", x) end)

  -- SLEN: how many steps (a step = a 16th) each slice plays before advancing to the
  -- next. With LOOP=loop the slice loops-to-fill its slot -> clean beat-repeat. This
  -- is independent of chop_steps (which sets how finely the region is cut).
  add_control(param_id(prefix, "chop_slice_len"), "chop slice length",
    cs.new(0.05, 32, "lin", 0.05, 1, "steps", 0.05 / 31.95),
    function(x) elasticat.tr_queue(param_id(prefix, "chop_slice_len"), 1, "chopSliceLen", x) end)

  -- 8 loop modes = the 4 base modes x forward/reverse SLICE READ. The engine
  -- decodes: loopMode = floor(index/2), sliceReverse = index%2 (see \elasticatChopped).
  params:add_option(param_id(prefix, "chop_loop_mode"), "chop loop mode",
    {"chop", "chop rev", "loop", "loop rev", "ping pong", "ping pong rev", "runaway", "runaway rev"}, 3)
  params:set_action(param_id(prefix, "chop_loop_mode"), function(x) tr_call(1, "chopLoopMode", x - 1) end)

  add_control(param_id(prefix, "chop_attack"), "chop attack",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.002, "s", 0.0005 / 0.1999),
    function(x) elasticat.tr_queue(param_id(prefix, "chop_attack"), 1, "chopAttack", x) end,
    format_ms)

  add_control(param_id(prefix, "chop_hold"), "chop gate",
    cs.new(0, 1, "lin", 0.01, 0.9, "", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "chop_hold"), 1, "chopHold", x) end)

  add_control(param_id(prefix, "chop_release"), "chop release",
    cs.new(0.0001, 0.2, "lin", 0.0001, 0.01, "s", 0.0005 / 0.1999),
    function(x) elasticat.tr_queue(param_id(prefix, "chop_release"), 1, "chopRelease", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_size"), "grain size",
    cs.new(0.002, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.498),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_size"), 1, "grainSize", x) end,
    format_ms)

  add_control(param_id(prefix, "grain_density"), "grain density",
    cs.new(1, 64, "lin", 1, 8, "gr/step", 1 / 63),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_density"), 1, "grainDensity", x) end)

  add_control(param_id(prefix, "grain_jitter"), "grain jitter",
    cs.new(0, 0.25, "lin", 0.001, 0.01, "s", 0.001 / 0.25),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_jitter"), 1, "grainJitter", x) end,
    format_ms)

  -- Particle grain engine: grain speed (x playhead scan), speed randomness, and the
  -- forward<->backward morph (0 = all back, 0.5 = 50/50, 1 = all forward).
  add_control(param_id(prefix, "grain_speed"), "grain speed",
    cs.new(0, 4, "lin", 0.01, 1, "x", 0.01 / 4),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_speed"), 1, "grainSpeed", x) end)

  add_control(param_id(prefix, "grain_speed_rand"), "grain speed rand",
    cs.new(0, 1, "lin", 0.01, 0, "", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_speed_rand"), 1, "grainSpeedRand", x) end)

  add_control(param_id(prefix, "grain_direction"), "grain direction",
    cs.new(0, 1, "lin", 0.01, 1, "", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "grain_direction"), 1, "grainDirection", x) end)

  add_control(param_id(prefix, "wsola_window"), "OLA window",
    cs.new(0.005, 0.5, "lin", 0.001, 0.08, "s", 0.001 / 0.495),
    function(x) elasticat.tr_queue(param_id(prefix, "wsola_window"), 1, "wsolaWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "wsola_search"), "OLA wander",
    cs.new(0, 0.1, "lin", 0.001, 0.015, "s", 0.001 / 0.1),
    function(x) elasticat.tr_queue(param_id(prefix, "wsola_search"), 1, "wsolaSearch", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_window"), "PC window",
    cs.new(0.005, 2, "lin", 0.001, 0.2, "", 0.001 / 1.995),
    function(x) elasticat.tr_queue(param_id(prefix, "pv_window"), 1, "pvWindow", x) end,
    format_ms)

  add_control(param_id(prefix, "pv_dispersion"), "PC dispersion",
    cs.new(0, 1, "lin", 0.001, 0, "", 0.001),
    function(x) elasticat.tr_queue(param_id(prefix, "pv_dispersion"), 1, "pvDispersion", x) end)

  -- New warp modes (7 harmonizer, 8 wavetable, 9 spectral_freeze, 10 formant).
  -- Track 1's warp params are hand-registered here (params_spec only registers
  -- t1-flagged entries for track 1); tracks 2-8 get these from ParamsSpec.SPEC.
  -- Without this, selecting one of these modes on track 1 hit "invalid parameter".
  add_control(param_id(prefix, "harm_interval"), "harmony interval",
    cs.new(-24, 24, "lin", 1, 7, "st", 1 / 48),
    function(x) elasticat.tr_queue(param_id(prefix, "harm_interval"), 1, "harmInterval", x) end)

  -- Two extra harmony voices (chords). 0 st = that voice OFF (owner).
  add_control(param_id(prefix, "harm_interval2"), "harmony interval 2",
    cs.new(-24, 24, "lin", 1, 0, "st", 1 / 48),
    function(x) elasticat.tr_queue(param_id(prefix, "harm_interval2"), 1, "harmInterval2", x) end)

  add_control(param_id(prefix, "harm_interval3"), "harmony interval 3",
    cs.new(-24, 24, "lin", 1, 0, "st", 1 / 48),
    function(x) elasticat.tr_queue(param_id(prefix, "harm_interval3"), 1, "harmInterval3", x) end)

  -- Wavetable Scan: WSIZ = SLICE COUNT; a built-in LFO (rate/depth/shape) auto-
  -- scans MORF. Track 1 hand-registered here; tracks 2-8 get these from the SPEC.
  add_control(param_id(prefix, "wt_window"), "wavetable slices",
    cs.new(2, 64, "lin", 1, 8, "", 1 / 62),
    function(x) elasticat.tr_queue(param_id(prefix, "wt_window"), 1, "wtWindow", x) end)

  add_control(param_id(prefix, "wt_cycle"), "wavetable cycle width",
    cs.new(16, 8192, "exp", 1, 600, "smp", 1 / 8176),
    function(x) elasticat.tr_queue(param_id(prefix, "wt_cycle"), 1, "wtCycle", x) end)

  -- LFO rate reaches AUDIO rates (up to 8 kHz) so the morph LFO can FM/AM the
  -- wavetable. Raw knob sweeps coarsely (fun for audio-rate sweeps); FN snaps to
  -- musical LFO + audio rates for precision.
  add_control(param_id(prefix, "wt_lfo_rate"), "wavetable LFO rate",
    cs.new(0, 8000, "lin", 0.001, 0, "Hz", 0.001 / 8000),
    function(x) elasticat.tr_queue(param_id(prefix, "wt_lfo_rate"), 1, "wtLfoRate", x) end)

  -- Signed 0-128 depth (64 = off): 128 sweeps MORF up to 1.0, 0 sweeps it to 0.0.
  add_control(param_id(prefix, "wt_lfo_depth"), "wavetable LFO depth",
    cs.new(0, 128, "lin", 1, 64, "", 1 / 128),
    function(x) elasticat.tr_queue(param_id(prefix, "wt_lfo_depth"), 1, "wtLfoDepth", x) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(param_id(prefix, "wt_lfo_shape"), "wavetable LFO shape", {"sine", "tri", "saw", "s&h", "rand"}, 1)
  params:set_action(param_id(prefix, "wt_lfo_shape"), function(x) tr_call(1, "wtLfoShape", x - 1) end)

  add_control(param_id(prefix, "freeze_amount"), "spectral freeze",
    cs.new(0, 1, "lin", 0.01, 0, "", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "freeze_amount"), 1, "freezeAmount", x) end)

  add_control(param_id(prefix, "spectral_blur"), "spectral blur",
    cs.new(0, 1, "lin", 0.01, 0, "", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "spectral_blur"), 1, "spectralBlur", x) end)

  add_control(param_id(prefix, "formant_shift"), "formant shift",
    cs.new(-24, 24, "lin", 1, 0, "st", 1 / 48),
    function(x) elasticat.tr_queue(param_id(prefix, "formant_shift"), 1, "formantShift", x) end)

  -- Synced rate multiplier -- warp-page slot 8, every mode (see source_warp_items).
  -- Track 1 hand-registered here; tracks 2-8 get it from ParamsSpec.SPEC.
  add_control(param_id(prefix, "warp_rate"), "warp rate",
    cs.new(0.0625, 8, "exp", 0.01, 1, "x", 0.01),
    function(x) elasticat.tr_queue(param_id(prefix, "warp_rate"), 1, "warpRate", x) end,
    function(param) return string.format("%.2fx", param:get()) end)

  params:add_group(param_id(prefix, "group_slices"), "slice machines", 13)

  add_control(param_id(prefix, "slice_count"), "slice count",
    cs.new(1, 32, "lin", 1, 16, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  add_control(param_id(prefix, "slice_index"), "slice index",
    cs.new(1, 32, "lin", 1, 1, "", 1 / 31),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) end)

  params:add_option(param_id(prefix, "slice_play_mode"), "slice play mode", {"1shot", "hold", "loop", "cont", "pong", "cloop"}, 1)
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

  -- Ratchet is Lua-scheduled (no engine cmd). Track 1 is hand-registered here;
  -- tracks 2-8 get it from ParamsSpec.SPEC. Without this, the Machine page's RTCH
  -- cell crashed track 1 with "invalid parameter" (esp. on Razor/Slice Poly).
  add_control(param_id(prefix, "slice_ratchet"), "slice ratchet",
    cs.new(1, 4, "lin", 1, 1, "x", 1 / 3),
    function(_) end,
    function(param) return tostring(math.floor(param:get() + 0.5)) .. "x" end)

  -- Default MONO (owner): one slice voice at a time keeps the slice machine
  -- cheap. Poly is opt-in. The engine's sliceMono default matches (mono) so a
  -- fresh boot agrees without needing an init push.
  params:add_option(param_id(prefix, "slice_polyphony"), "slice polyphony", {"poly 8", "mono"}, 2)
  params:set_action(param_id(prefix, "slice_polyphony"), function(x)
    engine_call("setSliceMono", x == 2 and 1 or 0)
  end)

  params:add_binary(param_id(prefix, "slice_hold_to_step"), "slice hold to step", "toggle", 1)
  params:set_action(param_id(prefix, "slice_hold_to_step"), function(_) end)

  -- Razor slice-point editor snap (owner). Off = free; Zero-X snaps edited (and
  -- Razor SNAP mode: what FN + the Start/End knobs do in the razor slice-point
  -- editor (source page 1). Grid = snap to 128/slice_count divisions; Zoom = fine
  -- precise nudge; zero-x = snap to the nearest zero crossing; Transient = snap to
  -- the prev/next detected onset; Friends = fine nudge that also drags the
  -- touching neighbour point (prev slice's end / next slice's start). Global (like
  -- the razor points), registered once. zero-x/transient DSP lands in Increment B.
  params:add_option(param_id(prefix, "slice_snap"), "razor snap",
    {"grid", "zoom", "zero-x", "transient", "friends"}, 1)
  params:set_action(param_id(prefix, "slice_snap"), function(_) end)

  -- Sample-editor TRIM snap (owner): what FN + the Trim Start/End knobs do, the
  -- trim-window parallel of razor snap. Grid = snap to the sample's step grid;
  -- Zoom = fine 0.001s nudge + the visual waveform zoom; zero-x = nearest zero
  -- crossing; transient = prev/next detected onset. No "friends" -- a trim has no
  -- neighbour slice. Without FN both knobs move in 0.01s detents (unchanged).
  -- Global, registered once. Default Zoom (the fine-adjust workhorse).
  params:add_option(param_id(prefix, "trim_snap"), "trim snap",
    {"grid", "zoom", "zero-x", "transient"}, 2)
  params:set_action(param_id(prefix, "trim_snap"), function(_) end)

  -- Auto-Chop / Transient-snap sensitivity (%). Higher = more onsets detected.
  -- Applied live over the cached onset envelope (slot_transients), so the owner
  -- can dial it on-device and re-run Auto-Chop without reloading the sample.
  -- No-op action: `request_redraw` is a COORDINATOR global, not visible in this
  -- facade module -- calling it here crashed init when a stored value banged
  -- (temp-project load). The on-device knob turn already redraws via the
  -- coordinator's encoder handler; the overlay also refreshes on the redraw
  -- metro, so the transient overlay stays in sync without forcing it here.
  add_control(param_id(prefix, "slice_chop_sense"), "chop sensitivity",
    cs.new(0, 100, "lin", 1, 50, "%", 1 / 100),
    function(_) end)

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
      cs.new(0, 128, "lin", 0.001, default_start, "", 1 / 128),
      function(x)
        -- Independent start/end (razor slice-point editor): the START sets only
        -- its own point; it no longer drags the whole slice. It just keeps end >
        -- start -- if the start crosses the end, the end is bumped to start+0.01
        -- (the owner's clamp). Friends coupling lives in razor_point_edit.
        razor_start_values[i] = x
        if razor_adjusting then
          return
        end
        local current_end = params:get(end_id)
        if current_end <= x then
          razor_adjusting = true
          params:set(end_id, util.clamp(x + 0.01, 0.01, 128))
          razor_adjusting = false
        end
      end)

    add_control(end_id, string.format("razor %02d end", i),
      cs.new(0, 128, "lin", 0.001, default_end, "", 1 / 128),
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

  -- The per-track param set: active_track_count + every SPEC entry for all 8
  -- tracks (lib/tracks/params_spec.lua). Track 1 keeps the unprefixed ids it
  -- has always had, so psets and projects load unchanged. Registered LAST so
  -- it never disturbs the existing param/pset ordering, and before any
  -- partition scanner runs (they're built lazily after init).
  ParamsSpec.register({
    params = params,
    cs = cs,
    prefix = prefix,
    tr_call = tr_call,
    tr_now = elasticat.tr_now,
    tr_queue = elasticat.tr_queue,
    resolve_base = elasticat.resolve_base,
    engine_call = engine_call,
    xforms = elasticat.param_xforms,
    formatters = elasticat.param_formatters,
    actions = elasticat.param_actions,
    machines = elasticat.machines,
    modes = elasticat.modes,
    trig_conditions = TRIG_CONDITIONS,
    filter_machines = FilterRegistry.names(),
    filter_types = FILTER_TYPE_LABELS,
    fx_machines = FxRegistry.names(),
    delay_times = DELAY_TIME_LABELS,
    mod_dests = MOD_DEST_LABELS,
    mod_waves = MOD_WAVE_LABELS,
    mod_lfo_modes = MOD_LFO_MODE_LABELS,
    mod_speeds = MOD_SPEED_LABELS,
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
