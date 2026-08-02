-- Elasticat
-- timestretch loop mangler
--
-- Elektron-style sequencing +
-- p-locks over a live, tempo-
-- warped loop: scrub the loop
-- while it plays.
--
-- norns + 128 grid required.
-- github.com/Quixotic7/Elasticat

engine.name = "Elasticat"

local elasticat = include("lib/elasticat")
local GridSequencer = include("lib/grid_sequencer")
local PatternStore = include("lib/sequencer/pattern_store")
local SceneStore = include("lib/scene_store")
local ProjectStore = include("lib/project_store")
local TextEntry = include("lib/ui/text_entry")
local InputRouter = include("lib/input/router")
local ParamItem = include("lib/ui/param_item")
local ParamRenderer = include("lib/ui/param_renderer")
local Header = include("lib/ui/header")
local MachineRegistry = include("lib/machines/registry")
local WarpRegistry = include("lib/warp_modes/registry")
local FilterRegistry = include("lib/filter_modes/registry")
local FxRegistry = include("lib/fx_modes/registry")
local WavReader = include("lib/wav_reader")
local ScriptState = include("lib/script_state")
local ParamsSpec = include("lib/tracks/params_spec")
local Navigation = include("lib/pages/navigation")
local ParamValues = include("lib/ui/param_values")
local SourcePage = include("lib/ui/source_page")
local fileselect = require "fileselect"

-- Ensure the compiled warp-DSP plugin (ElasticatUGens.so) is in the SuperCollider
-- Extensions dir. This runs at SCRIPT LOAD -- before norns boots the engine's
-- scsynth -- so on a fresh `;install` the plugin is already present when scsynth
-- starts and loads THIS session with no restart. It copies the bundled prebuilt
-- only when the installed VERSION differs (a cheap two-file read otherwise), so it
-- also carries updates forward after `;update`. Wrapped in pcall: a copy failure
-- must never stop the script from loading -- every warp mode has a guarded SC-graph
-- fallback, so a missing .so only costs the compiled-DSP polish. The result hangs
-- on the elasticat table (NOT new file-scope locals -- the main chunk is at
-- LuaJIT's 200-local ceiling). See lib/ugens/install.lua + lib/ugens/README.md.
do
  local ok, installed = pcall(include("lib/ugens/install").ensure)
  elasticat._dsp_install_notice = (ok and installed) and "elasticat DSP updated" or nil
end

local PREFIX = "elasticat_"
local playing = false
local alt = false
local browsing = false
local redraw_metro = nil
local redraw_pending = true
local grid_ui = nil
local pattern_store = nil
local scene_store = nil
local text_entry = nil
-- Universal UI input router: modal layers (pop-ups/pickers) consume semantic
-- actions (confirm/cancel/up/down/deltas) instead of checking devices directly
-- -- see lib/input/router.lua for the conventions and binding tables. Also
-- hung on the elasticat module table so closures created inside init() can
-- reach it through an already-captured local (init sits at LuaJIT's
-- 60-upvalue function limit; a fresh capture pushes it over).
local input_router = InputRouter.new()
elasticat.input_router = input_router
-- Projects (PRD §7): project_store is constructed in init(); project_loading
-- guards the autosave debounce below from firing WHILE a load/deserialize is
-- actively applying params (see mark_project_dirty); mark_project_dirty is
-- forward-declared here (assigned in the Projects section further down) so
-- request_redraw -- defined next, and called from virtually everywhere -- can
-- reference it without reordering the rest of the file.
local project_store = nil
local project_loading = false
local mark_project_dirty = nil
-- Forward-declared so the project loader (defined earlier than the transport
-- control) can stop playback on load.
local set_playing = nil
-- Snapshot of every prefixed param at its registered default, taken once in
-- init before any pset/temp load, so New Project can restore a true blank slate.
local factory_param_defaults = nil
local ui_message = nil

-- Launch intro: a spritesheet logo animation on screen + a grid comet sweep,
-- played once before the normal UI takes over.
local logo_image = nil
local intro_active = false
local intro_start = 0
local LOGO_FRAMES = 55
local LOGO_FPS = 10             -- sprite advances at 10fps (norns screen refreshes ~15Hz)
local LOGO_FRAME_W = 128
local LOGO_FRAME_H = 64
local INTRO_DURATION = LOGO_FRAMES / LOGO_FPS  -- 5.5s: play the spritesheet once

-- Visualizer page (master category): a looping full-screen sprite + grid comet
-- sweep, both with playback speed scaled by tempo (120 BPM = 1x).
local dancing_image = nil
local anim_running = false
local anim_phase = 0            -- BPM-scaled seconds, drives both sprite + grid sweep
local anim_last = 0
local DANCE_FRAMES = 12
local DANCE_FPS = 10
local DANCE_FRAME_W = 128
local DANCE_FRAME_H = 64
local draw_visualizer_page  -- forward decl: draw_root_page (above) calls it
local ui_message_until = 0
local loop_trig_gate_clock = nil
local loop_trig_gate_token = 0
local previous_osc_event = osc.event
local select_sample = nil
local nav = nil
local param_values = nil
local quiet_osc_paths = {
  ["/elasticat/status"] = true,
  ["/elasticat/transport"] = true,
  ["/elasticat/pool/slot/active"] = true,
  -- 15Hz live-modulation feed: never log it (it would flood maiden).
  ["/elasticat/mod"] = true,
  ["/elasticat/filterEnv"] = true,
  ["/elasticat/fxMeter"] = true,
  -- Per-track playhead (1Hz x 8) and level (30Hz x 8) reports: same reasoning,
  -- and they arrive for every active track rather than just one.
  ["/elasticat/track/position"] = true,
  ["/elasticat/track/level"] = true,
  -- 0.5Hz CPU + idle-pause telemetry: quiet, or it stripes maiden every 2s.
  ["/elasticat/cpu"] = true
}
-- Phase 2 (docs/PHASE2_CONTRACT.md): every reading the UI used to hold as "the
-- one track's" is now keyed by 1-based track index, and the screen shows
-- whichever track is SELECTED. Sub-TABLES rather than new file-scope locals:
-- elasticat.lua's main chunk sits at LuaJIT's 200-local ceiling, so per-track
-- state has to hang off something that already exists.
--   phase/phase_time  the visual playhead anchor + when it was set. Dead
--                     reckoned forward from there by display_phase().
--   amp_l/amp_r       header meter peaks, per track.
--   amp_time          when that peak arrived, so a track the engine is not
--                     reporting draws an EMPTY meter rather than another
--                     track's level (never show track 5's audio on track 3).
--   derived_bpm       engine-derived source BPM (drives tape-mode playhead rate).
local status = {
  phase = {},
  phase_time = {},
  frames = 0,
  amp_l = {},
  amp_r = {},
  amp_time = {},
  derived_bpm = {},
  menu_was_active = false
}
-- A track whose level report is older than this reads as "no data" (empty
-- meter). On the module table, not a new local: the main chunk is AT the
-- 200-local ceiling -- one more `local` here fails to compile outright.
elasticat.METER_STALE_SECONDS = 0.75

-- Leaving the norns system menu with K1 hands the script no key-UP for that
-- press (the menu consumed it), so FN stayed latched on until you pressed and
-- released K1 again. Called every redraw tick: on the menu->script transition,
-- clear both FN mirrors. Lives on the module table because the main chunk is
-- at LuaJIT's 200-local ceiling and init() at its 60-upvalue ceiling -- the
-- redraw metro reaches it through the existing `elasticat` upvalue.
-- ---- Quick undo (grid NO key) ---------------------------------------------
-- Records the state BEFORE a change so NO can put it back. Two kinds:
--   param     -- one param's previous value (encoder edits, settings edits)
--   crossfade -- every morph param's previous value + the fader position, so
--                one press undoes a whole crossfader move. Without this,
--                brushing the crossfader with scenes mapped silently
--                overwrote the values you had just dialed in.
-- Gesture-coalesced by the Undo module, so a continuous encoder turn or fader
-- glide is ONE undo step, not one per detent/tick.
elasticat.undo = include("lib/undo").new({now = util.time})

elasticat.sync_menu_fn_state = function()
  local menu_active = norns.menu ~= nil and norns.menu.status() == true
  if status.menu_was_active and not menu_active then
    alt = false
    if grid_ui ~= nil then
      grid_ui.fn_down = false
    end
    redraw_pending = true
  end
  status.menu_was_active = menu_active
end
local phase_report_ignore_until = 0
local active_step_lock_bases = {}
local active_step_lock_ids = {}
local default_trig_length = 1
local default_trig_velocity = 1
local sample_waveforms = {}
local value_flash_until = {}
local last_trim_focus = "trim_start"
local VALUE_FLASH_SECONDS = 0.85
-- 1024 (was 126, one per screen column): the razor/trim ZOOM magnifies a small
-- slice of the waveform, so it needs many more cached peaks than the 127px width
-- to stay detailed when zoomed in. The render takes the max bucket per column,
-- so the un-zoomed view still shows the full envelope (not a decimated sample).
-- Same whole-file read cost; ~8KB/slot of cached peaks.
local WAVEFORM_BUCKETS = 1024
local SOURCE_CELL_X = {1, 33, 65, 97}
local SOURCE_CELL_WIDTH = 31
local SOURCE_CELL_HEIGHT = 11
local SOURCE_TOP_Y = 11
local SOURCE_WAVEFORM_Y = 23
local SOURCE_WAVEFORM_HEIGHT = 27
local SOURCE_BOTTOM_Y = 53

local function format_args(args)
  local out = {}
  for i, value in ipairs(args or {}) do
    out[i] = tostring(value)
  end
  return table.concat(out, " ")
end

local function id(name)
  return PREFIX .. name
end

-- Safe param-existence check. norns' params:lookup_param() ERRORS on an unknown
-- string id rather than returning nil, so guarding a set() with
-- `lookup_param(x) ~= nil` throws whenever saved data references a param that no
-- longer exists (e.g. a project/temp file written before a param was renamed or
-- removed). pcall makes the "does it exist?" question never throw.
-- Defined on the module table (not a new file-scope local): the main chunk is
-- at LuaJIT's 200-local ceiling and init() at its 60-upvalue ceiling, so
-- everything reaches this through the existing `elasticat` upvalue.
elasticat.param_exists = function(full_id)
  local ok, p = pcall(params.lookup_param, params, full_id)
  return ok and p ~= nil
end

-- ---- Phase 1 track scaffolding: selected-track id funnel -------------------
-- (docs/PHASE1_CONTRACT.md). elasticat.selected_track is which track the whole
-- EDITING surface (steps, params, pages) addresses. ui_id maps a bare suffix to
-- the selected track's param id: track 1 (or a non-per-track suffix) stays the
-- plain id() -- so with track 1 selected every path below is byte-for-byte the
-- existing single-track behavior. Serialization/capture paths deliberately keep
-- using raw id(): pattern/project snapshots enumerate every registered id
-- (including t<N>_*) and must never re-map a suffix through the selection.
-- Hung on the module table (like ui_open_confirm) so init()'s closures reach
-- them through the already-captured `elasticat` upvalue: init sits AT LuaJIT's
-- 60-upvalue limit, a fresh local capture pushes it over.
elasticat.selected_track = 1

local function ui_id(name)
  return PREFIX .. ParamsSpec.track_suffix(elasticat.selected_track or 1, name)
end
elasticat.ui_id = ui_id

-- Which sample-pool slot the SELECTED track plays. `sample_slot` is a per-track
-- suffix in ParamsSpec.SPEC, so this is just the id funnel again -- no per-track
-- branching. On track 1 the param mirrors the facade's active_pool_slot (they
-- are kept in sync both ways by set_active_pool_slot), so this returns exactly
-- what the waveform view used before. Falls back to the facade for the case
-- where the param is not registered yet (early init) or reads 0 = OFF.
-- Module table, not a local: the main chunk is at LuaJIT's 200-local ceiling.
elasticat.ui_sample_slot = function()
  local pid = ui_id("sample_slot")
  if elasticat.param_exists(pid) then
    local slot = math.floor((params:get(pid) or 0) + 0.5)
    if slot >= 1 then
      return slot
    end
    -- Slot 0 = OFF. Report it as-is so the view shows NO SAMPLE for that track
    -- instead of silently borrowing the playback slot.
    return 0
  end
  return (elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot()) or 1
end

-- The selected track's pool metadata (duration/trim/bpm/steps/channels/gain).
-- Everything that used to read the single "active" slot goes through here.
-- `track` defaults to the selected one, so every existing caller is unchanged;
-- a background track passes its own index to read ITS slot metadata.
elasticat.ui_sample_meta = function(track)
  local slot = track ~= nil and elasticat.track_slot(track) or elasticat.ui_sample_slot()
  if slot < 1 or elasticat.pool_meta == nil then
    return {}
  end
  return elasticat.pool_meta(slot) or {}
end

-- The last reported output level of `track`, as (left, right) linear amps, or
-- nil,nil when that track has not reported inside METER_STALE_SECONDS. Every
-- track's reader fires its own level at 30Hz with the track index as SendReply's
-- replyID; the UI keeps them apart here so a meter only ever shows its own
-- track. nil (rather than 0) is deliberate: "no data" and "silence" are
-- different things, and only the former should be indistinguishable from a
-- track the engine is not running.
-- Coerce a track index arriving over OSC (SendReply replyID) into a valid
-- 1..TRACK_COUNT_MAX integer. Anything unparseable becomes track 1, so a
-- malformed report can never index the per-track tables with nil.
elasticat.osc_track = function(value)
  return util.clamp(math.floor((tonumber(value) or 1) + 0.5), 1, ParamsSpec.TRACK_COUNT_MAX)
end

elasticat.track_level = function(track)
  track = track or elasticat.selected_track or 1
  local reported = status.amp_time[track]
  if reported == nil or (util.time() - reported) > elasticat.METER_STALE_SECONDS then
    return nil, nil
  end
  return status.amp_l[track] or 0, status.amp_r[track] or 0
end

-- Track selection (grid row 4). Updates the id funnel and points the engine
-- facade's live-gesture calls (region/pitch/note/play) at the track's chain.
elasticat.select_ui_track = function(track)
  elasticat.selected_track = util.clamp(math.floor((tonumber(track) or 1) + 0.5), 1, ParamsSpec.TRACK_COUNT_MAX)
  if elasticat.set_engine_track ~= nil then
    elasticat.set_engine_track(elasticat.selected_track)
  end
  -- The facade holds ONE live-modulation snapshot (the selected track's -- see
  -- the /elasticat/mod handler). Zero it on every switch: without this the
  -- outgoing track's LFO/mod-env offsets stayed frozen on the incoming track's
  -- bars and filter render until its own first report arrived, which for a
  -- track with no modulation running is never.
  if elasticat.set_mod_values ~= nil then
    elasticat.set_mod_values(0, 0, 0, 0, 0)
  end
  if elasticat.set_filter_env_mod ~= nil then
    elasticat.set_filter_env_mod(0)
  end
end

local script_state = ScriptState.new({id = id, elasticat = elasticat})

local function verbose_osc_logging()
  local param = params:lookup_param(id("debug"))
  return param ~= nil and params:get(id("debug")) >= 4
end

-- Display name for the FILE page's `sample` item (the only item flagged
-- `file = true`). That page edits the FILE-EDITOR slot, which is deliberately
-- independent of what is playing -- so this reads file_edit_slot, not the
-- playback slot. Reading the playback slot showed the wrong filename whenever
-- the editor was pointed at a different slot, and with 8 tracks pulling from
-- one pool that is now the normal case rather than the exception.
local function sample_name()
  if elasticat.pool_label ~= nil then
    local slot = elasticat.file_edit_slot ~= nil and elasticat.file_edit_slot()
      or (elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot()) or nil
    return elasticat.pool_label(slot)
  end

  local path = params:get(id("sample"))
  if path == nil or path == "-" or path == "" or path:sub(-1) == "/" then
    return "no sample"
  end
  return params:string(id("sample"))
end


local function cache_sample_waveform(slot, path)
  slot = math.floor((tonumber(slot) or 1) + 0.5)
  -- The RAW onset envelope is cached alongside the waveform, computed once per
  -- load (owner: "process and cache at sample load"). The THRESHOLD is applied
  -- later in slot_transients from the live sensitivity knob, so re-picking onsets
  -- needs no re-read. On the module table -- the coordinator is at LuaJIT's
  -- 200-local ceiling. Feeds the razor editor's Transient snap + Auto-Chop.
  elasticat.sample_onsets = elasticat.sample_onsets or {}
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    sample_waveforms[slot] = nil
    elasticat.sample_onsets[slot] = nil
    return
  end
  sample_waveforms[slot] = WavReader.read_wav_waveform(path, WAVEFORM_BUCKETS) or WavReader.fallback_waveform(path, WAVEFORM_BUCKETS)
  elasticat.sample_onsets[slot] = WavReader.read_wav_onsets(path)
end

local function active_waveform(slot)
  -- Default to the SELECTED track's slot (Phase 2), not the one global playback
  -- slot -- the waveform view has to show the sample of the track being edited.
  slot = slot or elasticat.ui_sample_slot()
  if slot < 1 then
    return nil
  end
  local waveform = sample_waveforms[slot]
  local path = elasticat.pool_path ~= nil and elasticat.pool_path(slot) or nil
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  if waveform == nil and elasticat.pool_path ~= nil then
    -- Lazy cache (owner): reading the WAV is a multi-hundred-ms FREEZE, so it is
    -- deferred to first view instead of blocking startup (the intro plays over
    -- the empty init). Two rules:
    --   * NEVER read while playing -- the user stops to view a sample. Show the
    --     synthetic fallback shape meanwhile (no I/O).
    --   * When stopped, FLAG the slot; the redraw metro shows "Loading..." one
    --     tick, then does the blocking read the next, so the message is on screen
    --     DURING the freeze rather than after it (active_waveform can't message
    --     from here -- it's defined before show_message/request_redraw).
    if not playing then
      local wp = elasticat.waveform_pending
      if wp == nil or wp.slot ~= slot then
        elasticat.waveform_pending = {slot = slot, path = path, shown = false}
      end
    end
    return WavReader.fallback_waveform(path, WAVEFORM_BUCKETS)
  end
  return waveform
end

local function request_redraw()
  redraw_pending = true
  -- Projects (PRD §7.2): every mutation path in the coordinator (and, through
  -- GridSequencer's own options.request_redraw, every grid/step edit) already
  -- calls this, so it doubles as the "something changed" signal for the
  -- debounced temp-project autosave -- no per-param/per-edit-site wiring
  -- needed. mark_project_dirty is a no-op until the Projects section below
  -- assigns it.
  if mark_project_dirty ~= nil then
    mark_project_dirty()
  end
end

-- "FN" is universal: either B1/K1 on norns (alt) or the FN key on the grid.
-- Both drive the snap/zoom behaviors in param editing and the waveform view.
local function fn_active()
  return alt or (grid_ui ~= nil and grid_ui.fn_down == true)
end

-- The playhead anchor is PER TRACK (Phase 2). `track` defaults to the selected
-- track, so every existing caller (transport start/stop, region moves, engine
-- reset echoes) keeps addressing whatever the user is looking at -- which for a
-- single-track session is track 1, exactly as before. The OSC handler passes an
-- explicit track so a background track's report never moves the selected
-- track's playhead.
local function set_visual_phase(phase, track)
  track = track or elasticat.selected_track or 1
  if phase ~= nil then
    status.phase[track] = util.clamp(tonumber(phase) or status.phase[track] or 0, 0, 1)
  end
  status.phase_time[track] = util.time()
end

-- Module table, not file-scope locals: the main chunk is AT LuaJIT's 200-local
-- ceiling, so two more `local function`s here fail to compile the script.
elasticat.visual_phase = function(track)
  return status.phase[track or elasticat.selected_track or 1] or 0
end

elasticat.visual_phase_time = function(track)
  return status.phase_time[track or elasticat.selected_track or 1] or util.time()
end

-- Transport reset is global: every track's playhead returns to its own start,
-- so all 8 anchors are cleared, not just the selected one. (Leaving the others
-- stale made a background track's playhead jump on the next track switch.)
local function reset_visual_phase()
  for track = 1, ParamsSpec.TRACK_COUNT_MAX do
    set_visual_phase(0, track)
  end
  phase_report_ignore_until = util.time() + 1
end

-- During PLAY the selected (on-screen) track follows the engine's live 15Hz
-- phase DIRECTLY (display_phase returns it un-reckoned), so its report has to be
-- accepted even while playing -- otherwise the visible playhead sludges along at
-- the ~1Hz background re-anchor rate instead of tracking the audio. Every OTHER
-- track is only dead-reckoned for trig_release "return" and must NOT be yanked
-- around by async reports mid-play, so it keeps the stopped-only gate. The
-- post-reset ignore window applies to BOTH (a stale in-flight report can't
-- clobber a fresh playhead jump). No `track` = the legacy stopped-only gate.
local function phase_reports_allowed(track)
  if util.time() < phase_report_ignore_until then return false end
  if not playing then return true end
  return track ~= nil and track == (elasticat.selected_track or 1)
end

-- ---- Per-track engine reports (Phase 2) ------------------------------------
-- Every /elasticat/* report that carries per-track state is routed here, out of
-- init()'s osc.event closure. Two reasons: init() sits at LuaJIT's 60-upvalue
-- limit, and this is the code that decides WHICH track a reading belongs to --
-- the thing that has to be right for 8 tracks and the thing worth testing on
-- its own (bin/test-elasticat-lua cannot call init(), but it can call this).
--
-- Returns true when the message was a per-track report. Logging, redraw
-- scheduling and the non-track paths stay in osc.event.
elasticat.osc_report = function(path, args)
  args = args or {}
  if path == "/elasticat/status" then
    -- The legacy status stream is track 1's (Engine_Elasticat.sc's
    -- statusResponder forwards replyID <= 1 only), so it is attributed to
    -- track 1 explicitly rather than to whatever happens to be selected.
    if phase_reports_allowed(1) then
      set_visual_phase(args[5], 1)
    end
    status.frames = tonumber(args[6]) or status.frames
    status.amp_l[1] = tonumber(args[7]) or status.amp_l[1]
    status.amp_r[1] = tonumber(args[8]) or status.amp_r[1]
    status.amp_time[1] = util.time()
    status.derived_bpm[1] = tonumber(args[10]) or status.derived_bpm[1] or 0
    if status.derived_bpm[1] > 0 then
      params:set(id("source_bpm"), status.derived_bpm[1], true)
    end
    return true
  elseif path == "/elasticat/track/position" then
    -- Per-track playhead report (1Hz, tracks 2-8). This is what lets the visual
    -- playhead follow the selected track: set_visual_phase re-anchors ONLY that
    -- track, and during play the SELECTED track's phase is drawn from this feed
    -- directly (phase_reports_allowed lets it through while playing; a background
    -- track stays stopped-gated, dead-reckoned only for trig_release).
    local pos_track = elasticat.osc_track(args[1])
    if phase_reports_allowed(pos_track) then
      set_visual_phase(args[2], pos_track)
    end
    return true
  elseif path == "/elasticat/track/level" then
    -- Per-track output level (track, ampL, ampR). Forward-compatible: the
    -- engine's per-track readers already measure this and tag it with the track
    -- index, but the responder currently drops everything above track 1. Until
    -- it forwards them, tracks 2-8 have no level data and their meters draw
    -- empty (see elasticat.track_level) rather than borrowing track 1's.
    local track = elasticat.osc_track(args[1])
    status.amp_l[track] = tonumber(args[2]) or 0
    status.amp_r[track] = tonumber(args[3]) or 0
    status.amp_time[track] = util.time()
    return true
  elseif path == "/elasticat/cpu" then
    -- 0.5Hz scsynth telemetry (avg%, peak%, idle-paused tracks, synth count)
    -- from the engine's idle-scan routine. Stored on the module table (the
    -- main chunk is at the 200-local ceiling); the header draws avg/peak.
    elasticat.cpu_report = {
      avg = tonumber(args[1]) or 0,
      peak = tonumber(args[2]) or 0,
      paused = tonumber(args[3]) or 0,
      synths = tonumber(args[4]) or 0,
      time = util.time()
    }
    return true
  elseif path == "/elasticat/mod" then
    -- Live mod-bus values (pitch/cutoff/res/amp/pan, -1..1) at 15Hz: the UI's
    -- "actual value" bars and the filter render read these. The engine forwards
    -- only the UI-selected track's stream, with the reporting track appended as
    -- a TRAILING value; the facade router interprets that shape (against the
    -- engine's ordering, where it is unit-tested) and gates on engine_track,
    -- which select_ui_track keeps equal to the selected track.
    elasticat.route_mod_report(args)
    return true
  elseif path == "/elasticat/filterEnv" then
    -- Filter-envelope cutoff contribution (semitones), 15Hz. Same trailing-track
    -- shape and selected-track routing as /elasticat/mod above.
    elasticat.route_filter_env_report(args)
    return true
  elseif path == "/elasticat/fxMeter" then
    -- Comp/Duck gain-reduction + level meter (gr, key, thresh, all dB), keyed by
    -- the meter id: 1-8 = that track's insert (engine gates to the viewed track),
    -- 101/102/103 = the global Send 1 / Send 2 / Master slots. Kept as a table so
    -- simultaneous comp/duck instances (insert + send + master) never fight over
    -- one slot; each FX page reads its own id. RAW number, NOT osc_track (which
    -- clamps to 1..8 and would fold the global ids onto tracks). Stored on the
    -- module table (no new coordinator local -- the 200-local ceiling).
    -- thresh -99 = "no threshold line" (Duck).
    local mid = math.floor(tonumber(args[4]) or 0)
    elasticat.fx_meter = elasticat.fx_meter or {}
    elasticat.fx_meter[mid] = {
      gr = tonumber(args[1]) or 0, key = tonumber(args[2]) or -60,
      thresh = tonumber(args[3]) or -99, t = util.time()
    }
    return true
  elseif path == "/elasticat/transport" then
    -- The 15Hz reader feed (/elasticat/status) is the AUTHORITY for track 1's
    -- playhead -- it carries the phase the reader actually plays. The transport
    -- phasor's 1Hz phase only AGREES for bus-following modes; for tape (native
    -- rate) and Wavetable (MORF scan position) it advances on its own, so letting
    -- it write here overwrote the real phase once a second and jittered the
    -- playhead. Fall back to it only when the reader feed has gone stale (no
    -- continuous reader streaming amp for >0.2s), so nothing regresses.
    local reader_live = (util.time() - (status.amp_time[1] or 0)) < 0.2
    if not reader_live and phase_reports_allowed(1) then
      set_visual_phase(args[1], 1)
    end
    return true
  elseif path == "/elasticat/reset" then
    -- The engine echoes every playhead move as /elasticat/reset <phase>.
    -- Honor the phase: forcing 0 here clobbered the visual playhead after every
    -- Return/Boomerang release and every preserved-position trig. Playhead
    -- moves are issued against the facade's engine_track, which select_ui_track
    -- keeps equal to the selected track, so an un-routed echo re-anchors the
    -- selected track. A <track> <phase> form is honored too, for when the
    -- engine starts tagging these.
    -- BUT: a playhead-INDEPENDENT reader (Wavetable's MORF scan) reports its own
    -- phase via the 15Hz /status feed; a sequence position-jump still moves the
    -- transport and echoes /reset with the TRANSPORT phase, which would stomp the
    -- scan phase and flicker the playhead to 0. Same fix as /transport: when
    -- track 1's reader feed is live, /status is the authority -- drop the echo.
    local reset_track = #args >= 2 and elasticat.osc_track(args[1]) or 1
    if reset_track == 1 and (util.time() - (status.amp_time[1] or 0)) < 0.2 then
      return true
    end
    if #args >= 2 then
      set_visual_phase(args[2], elasticat.osc_track(args[1]))
    else
      set_visual_phase(args[1])
    end
    return true
  elseif path == "/elasticat/requestedStatus" then
    if phase_reports_allowed(1) then
      set_visual_phase(args[4], 1)
    end
    status.frames = tonumber(args[5]) or status.frames
    status.derived_bpm[1] = tonumber(args[8]) or status.derived_bpm[1] or 0
    if status.derived_bpm[1] > 0 then
      params:set(id("source_bpm"), status.derived_bpm[1], true)
    end
    return true
  elseif path == "/elasticat/load/installed" then
    status.frames = tonumber(args[3]) or status.frames
    status.derived_bpm[1] = tonumber(args[5]) or status.derived_bpm[1] or 0
    if status.derived_bpm[1] > 0 then
      params:set(id("source_bpm"), status.derived_bpm[1], true)
    end
    return true
  elseif path == "/elasticat/pool/slot/active" then
    status.frames = tonumber(args[2]) or status.frames
    return true
  end
  return false
end

-- Header messages auto-expire after ~1s. Expiry is handled by the redraw metro
-- (see start_redraw_metro) via a timestamp rather than a per-message clock --
-- rapid encoder edits used to churn clock.run/clock.cancel and could leave a
-- message stuck on.
local function show_message(text)
  ui_message = text
  ui_message_until = util.time() + 1
  request_redraw()
end

local function visible_message()
  if ui_message ~= nil and util.time() >= ui_message_until then
    return nil
  end
  return ui_message
end

-- Selected-track-aware param read: per-track suffixes resolve through ui_id
-- (track 1 = the plain id, so single-track behavior is unchanged); global
-- suffixes pass through untouched. The capture/apply paths never use this for
-- per-track suffixes -- they enumerate full registered ids via id().
local function param_value_or(param_id, default)
  local full_id = ui_id(param_id)
  if params:lookup_param(full_id) ~= nil then
    return params:get(full_id)
  end
  return default
end

-- ---- Pattern snapshots (PRD §6.1) -----------------------------------------
-- Params that are GLOBAL (project-level) and so are NOT part of a per-pattern
-- snapshot: the sample pool + File settings, master volume + master settings,
-- and the pattern-system's own control settings. target_bpm is captured
-- separately as the pattern's BPM (unless Global BPM overrides it). Everything
-- else under our prefix is per-pattern -- which auto-includes future machine/FX
-- params without touching this list.
local PATTERN_GLOBAL_SUFFIXES = {
  play = true,
  sample = true, file_slot = true, sample_bpm = true, sample_steps = true,
  trim_start = true, trim_end = true, gain = true,
  bpm_step_mode = true, recalc_bpm_steps = true, sample_preview = true,
  amp = true, clock_sync = true, live_performance_mode = true,
  step_preview = true, live_step_trig = true, debug = true,
  target_bpm = true,
  pattern_quantize = true, global_bpm = true,
  -- A/B scene crossfader (PRD §6.6 requirement 3): the crossfade position is a
  -- single global instance, not per-pattern -- excluding it here does double
  -- duty, since morph_param_suffixes() below also treats PATTERN_GLOBAL_SUFFIXES
  -- as the morph-target exclusion list. Were `crossfade` left out of this table
  -- it would (wrongly) become a morph target itself: SceneStore:apply() would
  -- try to set_value("crossfade", ...) mid-loop, which re-enters apply() via the
  -- param's own action -- excluding it here also prevents that recursion.
  crossfade = true,
  -- Project system controls (PRD §7.1, workstream C): the auto-name setting
  -- is genuinely project-scoped data. The four project_* triggers are here so
  -- they land in the GLOBAL partition (project_store.lua's own scanner, which
  -- skips trigger-type params) rather than the per-pattern one above, whose
  -- apply path calls params:set() unconditionally and would otherwise re-fire
  -- a trigger's action (e.g. "load project") on every pattern switch.
  project_auto_name = true,
  project_load = true, project_save = true, project_save_as = true, project_new = true,
  -- Phase 1 track scaffolding: the active track count is project-global (like
  -- the sample pool -- it describes the project's shape, not one pattern).
  active_track_count = true
}
-- Per-track play state mirrors track 1's `play` (global partition): a pattern
-- switch must never start/stop tracks. Mutes stay per-pattern (Elektron-style
-- pattern mutes) by NOT being listed here.
for track = 2, ParamsSpec.TRACK_COUNT_MAX do
  PATTERN_GLOBAL_SUFFIXES["t" .. track .. "_play"] = true
  -- ...and mirror `amp` above. Phase 2 made amp per-track, so without this
  -- track 1's volume stays pattern-global and non-morphable while tracks 2-8
  -- become per-pattern AND (since this table doubles as the morph exclusion
  -- list) crossfader morph targets -- the fader would ride 7 track volumes and
  -- pointedly not the first. Track volume is a mixer setting, so all 8 match
  -- track 1. Note `pan` is deliberately NOT here: it is already per-pattern and
  -- morphable for track 1, so tracks 2-8 inherit that consistently.
  PATTERN_GLOBAL_SUFFIXES["t" .. track .. "_amp"] = true
end

-- Editor preferences (PRD §7): settings that belong to the EDITOR, not to any
-- project -- how the app behaves, not the music. They are excluded from both
-- partitions above AND from project files (project_global_suffixes skips them),
-- are NOT touched by New Project's factory reset, and instead persist to a
-- single fixed file (editor_prefs.data), loaded once at launch. So e.g. the
-- auto-name mode you pick sticks across projects and reloads.
local EDITOR_PREF_SUFFIXES = {
  project_auto_name = true,
  clock_sync = true,
  live_performance_mode = true,
  step_preview = true,
  live_step_trig = true,
  global_bpm = true,
  debug = true
}

-- Cached list of per-pattern param suffixes, built lazily (after every param --
-- including agent-added FX -- is registered).
local pattern_param_suffix_cache = nil
local function pattern_param_suffixes()
  if pattern_param_suffix_cache ~= nil then
    return pattern_param_suffix_cache
  end
  local list = {}
  local plen = #PREFIX
  for _, p in ipairs(params.params or {}) do
    local pid = p ~= nil and p.id
    if type(pid) == "string" and pid:sub(1, plen) == PREFIX then
      local suffix = pid:sub(plen + 1)
      if not PATTERN_GLOBAL_SUFFIXES[suffix] then
        -- Capture only value-bearing params (skip groups/separators/files):
        -- those whose current value is a number and round-trip through set().
        local ok, value = pcall(function() return params:get(pid) end)
        if ok and type(value) == "number" then
          list[#list + 1] = suffix
        end
      end
    end
  end
  pattern_param_suffix_cache = list
  return list
end

local applying_pattern_state = false

local function capture_pattern_state()
  local values = {}
  for _, suffix in ipairs(pattern_param_suffixes()) do
    values[suffix] = params:get(id(suffix))
  end
  return {
    params = values,
    bpm = param_value_or("target_bpm", 120),
    sequencer = grid_ui ~= nil and grid_ui:serialize() or nil
  }
end

local function apply_pattern_state(snapshot, restart)
  if snapshot == nil then
    return
  end
  applying_pattern_state = true
  for suffix, value in pairs(snapshot.params or {}) do
    local full_id = id(suffix)
    if elasticat.param_exists(full_id) then
      params:set(full_id, value)  -- fire actions so the engine follows the pattern
      -- Scene-locked params' bases follow the pattern's baseline, so the
      -- crossfader re-apply below morphs against THIS pattern's values. Keyed
      -- by FULL param id: `suffix` here is the registered suffix (it already
      -- carries any t<N>_ prefix), so id(suffix) is that param's own id.
      if scene_store ~= nil then
        scene_store:update_base(full_id, value)
      end
    end
  end
  -- BPM is per-pattern unless Global BPM is on (PRD §6.1).
  if snapshot.bpm ~= nil and param_value_or("global_bpm", 0) ~= 1
    and params:lookup_param(id("target_bpm")) ~= nil then
    params:set(id("target_bpm"), snapshot.bpm)
  end
  if grid_ui ~= nil then
    if snapshot.sequencer ~= nil then
      grid_ui:deserialize(snapshot.sequencer)
    end
    grid_ui:on_pattern_applied(restart == true)
  end
  applying_pattern_state = false
  -- Re-evaluate EVERY active track's free-run play gate against the FINAL restored
  -- state. The params:set() loop above fires each track's machine action in
  -- pairs()-arbitrary order, and the transport param's own action (set_engine_play)
  -- only ever (re)starts TRACK 1 -- so a loop on track 2-8 could land with the wrong
  -- `playing` and stay silent on load until the track was next touched/selected.
  -- One explicit pass here, after the whole pattern (and the restored transport
  -- state) has landed, gives every loop track the correct playing state. Cheap
  -- (<=8 sends) and idempotent -- setting play to its current value is a no-op.
  if elasticat.push_track_play_state ~= nil then
    for track = 1, elasticat.active_track_count() do
      elasticat.push_track_play_state(track)
    end
  end
  -- A/B scene crossfader (PRD §6.6 requirement 3): the params:set() loop above
  -- just overwrote every per-pattern param -- including any that are also morph
  -- targets -- with this pattern's raw saved values, wiping out whatever blend
  -- the crossfader had produced. Re-apply the CURRENT position (itself
  -- untouched by the switch: crossfade lives in PATTERN_GLOBAL_SUFFIXES above)
  -- so the A/B morph persists across pattern changes instead of reverting to
  -- the pattern's unblended values.
  if scene_store ~= nil then
    scene_store:apply(scene_store:position_value())
    elasticat.reconcile_crossfader(scene_store:morph_target_keys())
  end
end

-- A never-populated slot loads as a blank pattern: the current track params but
-- an empty sequence.
local function blank_pattern_state()
  local snapshot = capture_pattern_state()
  -- Old single-track sequencer format on purpose: GridSequencer:deserialize
  -- loads it into track 1 and blanks tracks 2-8 (a never-populated slot is a
  -- blank pattern on EVERY track).
  snapshot.sequencer = {
    steps = {},
    rate_index = grid_ui ~= nil and grid_ui.seq ~= nil and grid_ui.seq.rate_index or 4,
    page_loop = {[1] = true}
  }
  return snapshot
end

-- Load a pattern slot from the grid overlay, honouring the change-quantization
-- setting (PRD §6.3). Deferred (sequential) switches show as a flashing slot.
local function request_pattern_load(slot)
  if pattern_store == nil then
    return
  end
  local mode = PatternStore.QUANT[param_value_or("pattern_quantize", 1)] or "sequential"
  local applied = pattern_store:request(slot, mode, playing)
  if applied then
    show_message(string.format("Pattern %02d", slot))
  else
    show_message(string.format("Pattern %02d queued", slot))
  end
  request_redraw()
end

-- ---- FN+Pattern quantize-mode pop-up (screen-only, Tonverk-style) --------
-- A pop-up listing the four pattern_quantize modes (PatternStore.QUANT),
-- opened by FN+(8,5) on the grid (see the (8,5) special-case in
-- lib/grid_sequencer.lua:key(), which calls the open_pattern_quantize_menu
-- grid_ui option below). Distinct from the grid pattern-load overlay
-- (grid_ui.pattern_mode), which is grid-driven -- this pop-up is driven
-- entirely by the norns front panel (K1-K3/E2, see key()/enc() below).
-- Labels are display text only; PatternStore.QUANT (snake_case, used to set
-- the param) is the source of truth for ordering/count, so the two can't
-- drift out of sync in length even if wording changes here.
local PATTERN_QUANTIZE_LABELS = {"Sequential", "Direct Jump", "Direct Start", "Temp Jump"}
local pattern_quantize_menu_open = false
local pattern_quantize_menu_index = 1

-- Select-then-confirm: scrolling only moves the highlight (a PENDING choice);
-- confirm applies it to the pattern_quantize param, cancel discards it. Input
-- arrives as router actions, so norns K3/K2, the grid YES/NO keys, the grid
-- up/down arrows and E2 all work identically with no per-device checks here.
local function step_pattern_quantize_menu(delta)
  local count = #PatternStore.QUANT
  pattern_quantize_menu_index = ((pattern_quantize_menu_index + delta - 1) % count) + 1
  request_redraw()
end

local function close_pattern_quantize_menu(apply)
  if apply and params:lookup_param(id("pattern_quantize")) ~= nil then
    params:set(id("pattern_quantize"), pattern_quantize_menu_index)
    show_message("Change: " .. (PATTERN_QUANTIZE_LABELS[pattern_quantize_menu_index] or "?"))
  end
  pattern_quantize_menu_open = false
  input_router:pop_focus("pattern_quantize_menu")
  request_redraw()
end

local function toggle_pattern_quantize_menu()
  if pattern_quantize_menu_open then
    close_pattern_quantize_menu(false)
    return
  end
  pattern_quantize_menu_open = true
  pattern_quantize_menu_index = param_value_or("pattern_quantize", 1)
  input_router:push_focus({
    name = "pattern_quantize_menu",
    -- Not `blocking`: FN+(8,5) must still reach the grid to toggle this closed.
    on_action = function(action, value)
      if action == "up" then
        step_pattern_quantize_menu(-1)
      elseif action == "down" then
        step_pattern_quantize_menu(1)
      elseif action == "select_delta" then
        step_pattern_quantize_menu(value or 0)
      elseif action == "confirm" then
        close_pattern_quantize_menu(true)
      elseif action == "cancel" then
        close_pattern_quantize_menu(false)
      else
        -- Swallow every other UI action while open: this pop-up is modal.
        return true
      end
      return true
    end
  })
  request_redraw()
end

-- ---- Generic yes/no confirm pop-up ----------------------------------------
-- Modal via the input router: YES/K3/Right = yes (runs the callback), NO/K2/
-- Left/Escape = no. Reusable for any "are you sure?" gate (e.g. New Project).
local confirm_open = false
local confirm_prompt = ""
local confirm_on_yes = nil

local function close_confirm()
  confirm_open = false
  confirm_on_yes = nil
  input_router:pop_focus("confirm")
  request_redraw()
end

local function open_confirm(prompt, on_yes)
  confirm_prompt = prompt or "Are you sure?"
  confirm_on_yes = on_yes
  confirm_open = true
  input_router:push_focus({
    name = "confirm",
    blocking = true,
    on_action = function(action)
      if action == "confirm" or action == "right" then
        local cb = confirm_on_yes
        close_confirm()
        if cb ~= nil then cb() end
      elseif action == "cancel" or action == "left" then
        close_confirm()
      end
      return true  -- modal: swallow everything
    end
  })
  request_redraw()
end
-- Hung on the module table so init()'s options closures can reach it through
-- the existing `elasticat` upvalue instead of a new one (60-upvalue limit).
elasticat.ui_open_confirm = open_confirm

local function draw_confirm()
  if not confirm_open then
    return
  end
  local w, h = 112, 40
  local x, y = (128 - w) / 2, (64 - h) / 2
  screen.level(0)
  screen.rect(x, y, w, h)
  screen.fill()
  screen.level(15)
  screen.rect(x, y, w, h)
  screen.stroke()
  screen.move(64, y + 16)
  screen.text_center(confirm_prompt)
  -- YES boxed on the right (confirm/YES), NO plain on the left (cancel/NO).
  screen.level(4)
  screen.move(x + 22, y + h - 6)
  screen.text_center("NO")
  screen.level(15)
  screen.rect(x + w - 44, y + h - 15, 34, 11)
  screen.fill()
  screen.level(0)
  screen.move(x + w - 27, y + h - 6)
  screen.text_center("YES")
end

-- ---- In-script project browser (PRD §7.1) ---------------------------------
-- Replaces the norns system file-select for loading projects, so it obeys OUR
-- input conventions (a router focus layer): up/down or E2 scroll, YES/K3/Right
-- load, NO/K2/Left/Escape cancel back to the PROJECT settings page. Draws in
-- the script's own redraw (no `browsing` takeover), so cancelling never drops
-- out of the settings layer.
local project_browser_open = false
local project_browser_entries = {}
local project_browser_index = 1
local project_browser_sort = "date"  -- "date" (newest first) | "name"; E1 toggles

local function close_project_browser()
  project_browser_open = false
  input_router:pop_focus("project_browser")
  request_redraw()
end

local function load_selected_project()
  local entry = project_browser_entries[project_browser_index]
  close_project_browser()
  if entry ~= nil and project_store ~= nil then
    -- Stop the transport before swapping the whole project out, so the new
    -- project loads into a clean stopped state (press play to hear it) rather
    -- than trying to reconcile a live sequence with new patterns/params.
    if playing and set_playing ~= nil then
      set_playing(false, true)
    end
    project_loading = true
    local ok = project_store:load(entry.path)
    project_loading = false
    if ok then
      -- Replace the temp work snapshot NOW: temp means "resume where you left
      -- off", and where you left off is this freshly loaded project. Without
      -- this, temp only refreshed on the debounced edit autosave, so a
      -- load -> play/stop -> script reload resurrected the PREVIOUS session.
      project_store:save_temp()
    end
    show_message(ok and ("Loaded " .. project_store:current_name()) or "Load failed")
  end
end

local function open_project_browser()
  if project_store == nil then
    return
  end
  util.make_dir(ProjectStore.projects_dir())
  project_browser_entries = ProjectStore.list(project_browser_sort)
  if #project_browser_entries == 0 then
    show_message("No saved projects")
    return
  end
  project_browser_index = 1
  project_browser_open = true
  input_router:push_focus({
    name = "project_browser",
    blocking = true,
    on_action = function(action, value)
      local n = #project_browser_entries
      if action == "up" then
        project_browser_index = ((project_browser_index - 2) % n) + 1
      elseif action == "down" then
        project_browser_index = (project_browser_index % n) + 1
      elseif action == "select_delta" then
        project_browser_index = util.clamp(project_browser_index + (value or 0), 1, n)
      elseif action == "page_delta" then
        -- E1 toggles the sort order (date <-> name) and re-lists.
        project_browser_sort = (project_browser_sort == "date") and "name" or "date"
        project_browser_entries = ProjectStore.list(project_browser_sort)
        project_browser_index = 1
      elseif action == "confirm" or action == "right" then
        load_selected_project()
      elseif action == "cancel" or action == "left" then
        close_project_browser()
      end
      return true  -- modal
    end
  })
  request_redraw()
end

local function draw_project_browser()
  if not project_browser_open then
    return
  end
  screen.level(0)
  screen.rect(0, 0, 128, 64)
  screen.fill()
  screen.level(3)
  screen.rect(0, 0, 128, 11)
  screen.fill()
  screen.level(15)
  screen.move(4, 8)
  screen.text("LOAD PROJECT")
  -- Sort indicator (E1 toggles date <-> name).
  screen.level(9)
  screen.move(124, 8)
  screen.text_right("E1:" .. (project_browser_sort == "date" and "DATE" or "NAME"))

  local n = #project_browser_entries
  local first = util.clamp(project_browser_index - 2, 1, math.max(1, n - 4))
  for row = 0, 4 do
    local idx = first + row
    local entry = project_browser_entries[idx]
    if entry ~= nil then
      local y = 21 + row * 9
      screen.level(idx == project_browser_index and 15 or 5)
      screen.move(4, y)
      screen.text((idx == project_browser_index and ">" or " ") .. " " .. entry.name)
    end
  end
end

-- ---- A/B scene crossfader (PRD §6.6) --------------------------------------
-- Morphable params = the continuous controls (they have a controlspec) under
-- our prefix, minus the global-scope params and the structural controls whose
-- value should step, not glide. Auto-includes future FX/filter controls.
--
-- ONLY CONTINUOUS PARAMS MORPH: the `p.controlspec ~= nil` test is what
-- enforces that (option/binary/number params -- filter type, machine, LFO
-- wave/mode, mod dest, env mode -- register without one). A half-morphed enum
-- is nonsense, so those snap on an outright recall and are never faded
-- (docs/PHASE2_CONTRACT.md, "Send slowly, interpolate in the engine").
-- `playhead` is a hidden 0..1 control whose action pushes setPlayhead: it is a
-- transport POSITION, not a sound parameter, so interpolating it would scrub
-- playback on every fader tick. Structural, exactly like pattern length.
-- Only CONTINUOUS params may morph. Params with no controlspec (options,
-- binary, number) are already skipped below; this list catches the ones that
-- ARE controls but whose values are structural indices, where interpolating is
-- nonsense rather than merely odd -- morphing sample_slot 3 -> 7 would sweep
-- through slots 4, 5 and 6, and slice_count would re-cut the grid mid-fade.
-- default_length/velocity only seed NEWLY created trigs, so morphing them is
-- inaudible. `playhead` is a hidden 0..1 control whose action scrubs playback.
local MORPH_EXCLUDE = {pattern_steps = true, global_pattern_length = true,
  playhead = true,
  sample_slot = true, slice_count = true, slice_index = true,
  chop_steps = true, loop_division = true,
  default_length = true, default_velocity = true}
local morph_suffix_cache = nil
-- The BARE morphable suffixes -- ONE track's worth. Per-track ids (t<N>_*) are
-- deliberately skipped here; elasticat.morph_target_ids() below expands each
-- per-track suffix across every track instead, which is what keys a scene by
-- FULL param id rather than by a bare suffix shared by all 8 tracks.
-- PATTERN_GLOBAL_SUFFIXES doubles as the morph EXCLUSION list -- note
-- t<N>_amp is in it, so track volumes are deliberately NOT morph targets.
local function morph_param_suffixes()
  if morph_suffix_cache ~= nil then
    return morph_suffix_cache
  end
  local list = {}
  local plen = #PREFIX
  for _, p in ipairs(params.params or {}) do
    local pid = p ~= nil and p.id
    if type(pid) == "string" and pid:sub(1, plen) == PREFIX then
      local suffix = pid:sub(plen + 1)
      if p.controlspec ~= nil and suffix:match("^t%d+_") == nil
        and not PATTERN_GLOBAL_SUFFIXES[suffix] and not MORPH_EXCLUDE[suffix] then
        list[#list + 1] = suffix
      end
    end
  end
  morph_suffix_cache = list
  return list
end

-- The morph TARGET set: (track, suffix) pairs expanded to FULL param ids, so
-- ONE scene holds values for every track (docs/PHASE2_CONTRACT.md, multi-track
-- A/B crossfader scenes). A per-track suffix contributes one id per track; a
-- genuinely global continuous param (the master/send FX busses) contributes a
-- single id and is always active. Cached once, after every param is registered,
-- exactly like the suffix scan above.
-- Module table, not new file-scope locals: the main chunk is AT LuaJIT's
-- 200-local ceiling (see elasticat.param_exists).
elasticat.morph_target_cache = nil
elasticat.morph_target_track = {}
elasticat.morph_target_ids = function()
  if elasticat.morph_target_cache ~= nil then
    return elasticat.morph_target_cache
  end
  local list = {}
  for _, suffix in ipairs(morph_param_suffixes()) do
    local last = ParamsSpec.PER_TRACK[suffix] and ParamsSpec.TRACK_COUNT_MAX or 1
    for track = 1, last do
      local pid = PREFIX .. ParamsSpec.track_suffix(track, suffix)
      if elasticat.param_exists(pid) then
        list[#list + 1] = pid
        elasticat.morph_target_track[pid] = track
      end
    end
  end
  elasticat.morph_target_cache = list
  return list
end

-- Which track a morph target id belongs to (1 for a global param, and for
-- anything unrecognised -- e.g. an id restored from an older project file --
-- so an unknown key can never be filtered out as "inactive").
elasticat.morph_target_of = function(full_id)
  local track = elasticat.morph_target_track[full_id]
  if track ~= nil then
    return track
  end
  return ParamsSpec.track_of_suffix(full_id:sub(#PREFIX + 1)) or 1
end

-- Reverse-lookup set built from morph_param_suffixes(), so scene_edit_item
-- (below) can cheaply reject non-morphable params -- notably `crossfade`
-- itself (PRD §6.6 requirement 2 put it on the same MASTER page as other
-- morphable controls): a scene must never capture the fader that morphs it.
-- Snapshot the value of one param before it is edited.
elasticat.undo_record_param = function(item)
  local suffix = item ~= nil and item.id or nil
  if suffix == nil or item.blank or elasticat.undo == nil then
    return
  end
  local full_id = ui_id(suffix)
  if not elasticat.param_exists(full_id) then
    return
  end
  elasticat.undo:record("param:" .. full_id, function()
    local ok, value = pcall(function() return params:get(full_id) end)
    if not ok or type(value) ~= "number" then
      return nil
    end
    return {kind = "param", label = item.short or suffix,
            values = {[full_id] = value}}
  end)
end

-- Snapshot every morph target + the fader position before a crossfade move.
elasticat.undo_record_crossfade = function()
  if elasticat.undo == nil or scene_store == nil then
    return
  end
  elasticat.undo:record("crossfade", function()
    local values = {}
    -- Full per-track ids: the fader morphs EVERY track, so undoing it has to
    -- restore every track (id(suffix) here only ever captured track 1).
    for _, full_id in ipairs(elasticat.morph_target_ids()) do
      if elasticat.param_exists(full_id) then
        local ok, value = pcall(function() return params:get(full_id) end)
        if ok and type(value) == "number" then
          values[full_id] = value
        end
      end
    end
    return {kind = "crossfade", label = "XFADE", values = values,
            position = scene_store:position_value()}
  end)
end

-- NO key: undo the most recent recorded change.
elasticat.undo_apply = function()
  local entry = elasticat.undo ~= nil and elasticat.undo:pop() or nil
  if entry == nil then
    show_message("Nothing to undo")
    return
  end
  -- Crossfade: put the fader back first (that re-morphs from the scenes), then
  -- overwrite with the captured values so the restore is exact even if a scene
  -- base changed in between.
  if entry.kind == "crossfade" and entry.position ~= nil and scene_store ~= nil then
    scene_store:apply(entry.position)
    elasticat.reconcile_crossfader(scene_store:morph_target_keys())
  end
  for full_id, value in pairs(entry.values or {}) do
    if elasticat.param_exists(full_id) then
      params:set(full_id, value)
      -- Follow the scene base too. The low-profile cell's VALUE bar reads the
      -- scene base when one exists (that is what keeps it still under the
      -- crossfader), so without this the value came back but its bar didn't.
      -- Bases are keyed by FULL param id now, so this is the id as recorded.
      if scene_store ~= nil then
        scene_store:update_base(full_id, value)
      end
    end
  end
  -- Step-level entries (p-locks, trig toggles, cut/paste, copy/paste scopes)
  -- restore through the sequencer, which owns the step records.
  if entry.steps ~= nil and grid_ui ~= nil and grid_ui.restore_steps ~= nil then
    grid_ui:restore_steps(entry.steps, entry.track)
  end
  show_message("Undo " .. (entry.label or ""))
  request_redraw()
end


local morph_suffix_set_cache = nil
local function is_morph_suffix(suffix)
  if morph_suffix_set_cache == nil then
    morph_suffix_set_cache = {}
    for _, s in ipairs(morph_param_suffixes()) do
      morph_suffix_set_cache[s] = true
    end
  end
  return morph_suffix_set_cache[suffix] == true
end

-- Route an encoder param edit into the held scene, so "hold anchor + tweak"
-- locks that one param's new value to the scene (PRD §6.6).
-- Scene p-lock editing (PRD §6.6): while an A/B anchor is held, an encoder
-- edit is routed HERE instead of delta_item -- it adjusts the SCENE's value
-- for that param (seeded from the scene's existing lock, else the live value)
-- and never touches the live param, exactly like editing a held step's p-lock.
-- Returns true when the edit was consumed by a scene.
local function scene_edit_item(param_item, delta)
  if scene_store == nil or param_item == nil
    or param_item.blank or param_item.pseudo ~= nil or param_item.file then
    return false
  end
  local target = scene_store:edit_target_scene()
  if target == nil then
    return false
  end
  local suffix = param_item.id
  -- ui_id, not id: hold-Scene + encoder stays SURGICAL -- it locks this one
  -- param on the SELECTED track (docs/PHASE2_CONTRACT.md). id() is the track-1
  -- prefixer, so editing track 5 used to lock track 1's param instead.
  local full_id = suffix ~= nil and ui_id(suffix) or nil
  if full_id == nil or not is_morph_suffix(suffix) or not elasticat.param_exists(full_id) then
    -- Anchor held but this param can't morph: swallow the edit rather than
    -- silently changing the live value mid-gesture.
    return true
  end
  local current = scene_store:scene_value(target, full_id)
  if current == nil then
    current = params:get(full_id)
  end
  local next_value = param_values:adjusted_value(param_item, current, delta, fn_active())
  scene_store:set_scene_value(target, full_id, next_value)
  param_values:flash_item_value(param_item)
  show_message(param_values:item_long_name(param_item)
    .. (target == 1 and " A " or " B ")
    .. param_values:format_item_value(param_item, next_value))
  request_redraw()
  return true
end

-- After a NORMAL edit (no anchor held): a scene-locked param's base follows
-- the user's latest value, so the un-locked end of a one-sided morph stays
-- theirs (see SceneStore.update_base).
local function scene_base_follow(param_item)
  if scene_store == nil or param_item == nil or param_item.id == nil
    or param_item.pseudo ~= nil or param_item.blank or param_item.file then
    return
  end
  -- The full per-track id on BOTH sides. This fires on every encoder edit, and
  -- the bug it fixes was the two sides disagreeing: the value was read through
  -- ui_id (the SELECTED track) but stored under the BARE suffix, which is
  -- track 1's slot in a store keyed by suffix. So editing track 2 wrote track
  -- 2's value into track 1's base, tracks 2-8 never followed their own edits
  -- at all, and the low-profile base bar + the next crossfader move both took
  -- whichever track was touched last (docs/PHASE2_CONTRACT.md, multi-track
  -- crossfader scenes).
  local full_id = ui_id(param_item.id)
  if elasticat.param_exists(full_id) then
    scene_store:update_base(full_id, params:get(full_id))
  end
  -- A hand edit takes the param back from the crossfader: drop its morph override
  -- so the track value plays until the fader is next moved (BASE_VALUE_RESOLVER).
  elasticat.knob_takes_over(param_item.id)
end

-- =============================================================================
-- Projects (PRD §7). Workstream C: file-backed project save/load/save-as/new,
-- the temp work project + autosave-while-stopped, and the PROJECT param-menu
-- operations. Builds on pattern_store (above, workstream A) and script_state /
-- elasticat.pool_snapshot() for the sample pool -- neither is reimplemented
-- here, only composed. Memorize/Recall (PRD §7.2, FN+Octave grid keys) is
-- explicitly OUT of scope for this workstream; left for whoever owns
-- lib/grid_sequencer.lua.
-- =============================================================================

-- ---- Global param scope (PRD §7.1) -----------------------------------------
-- The complement of PATTERN_GLOBAL_SUFFIXES: every PREFIX-prefixed param whose
-- suffix IS marked global there. Mirrors pattern_param_suffixes()'s scan (same
-- cache-once-fully-registered shape) so the two partitions can never drift --
-- every param lands in exactly one. Trigger/separator-type params are skipped
-- outright (not just numeric-checked): re-applying a captured value via
-- params:set() would re-fire a trigger's action (see the PATTERN_GLOBAL_SUFFIXES
-- comment above), which is never what a project load should do.
local function is_inert_param_type(p)
  if p == nil or p.t == nil or params == nil then
    return false
  end
  return (params.tTRIGGER ~= nil and p.t == params.tTRIGGER)
    or (params.tSEPARATOR ~= nil and p.t == params.tSEPARATOR)
end

local project_global_suffix_cache = nil
local function project_global_suffixes()
  if project_global_suffix_cache ~= nil then
    return project_global_suffix_cache
  end
  local list = {}
  local plen = #PREFIX
  for _, p in ipairs(params.params or {}) do
    local pid = p ~= nil and p.id
    if type(pid) == "string" and pid:sub(1, plen) == PREFIX and not is_inert_param_type(p) then
      local suffix = pid:sub(plen + 1)
      -- Global partition MINUS editor prefs: editor prefs live in their own
      -- fixed file, never in a project.
      if PATTERN_GLOBAL_SUFFIXES[suffix] and not EDITOR_PREF_SUFFIXES[suffix] then
        local ok, value = pcall(function() return params:get(pid) end)
        if ok and type(value) == "number" then
          list[#list + 1] = suffix
        end
      end
    end
  end
  project_global_suffix_cache = list
  return list
end

local function capture_global_state()
  local values = {}
  for _, suffix in ipairs(project_global_suffixes()) do
    values[suffix] = params:get(id(suffix))
  end
  return values
end

local function apply_global_state(values)
  if values == nil then
    return
  end
  for suffix, value in pairs(values) do
    local full_id = id(suffix)
    if elasticat.param_exists(full_id) then
      params:set(full_id, value)
    end
  end
end

-- ---- Sample pool (composes elasticat.pool_snapshot()/load_pool_paths(), the
-- same functions script_state.lua already uses -- not re-serialized here). --
local function capture_pool_state()
  local slot = elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot() or 1
  return elasticat.pool_snapshot ~= nil and elasticat.pool_snapshot() or {}, slot
end

-- Memorize/Recall (PRD §7.2): a whole-project snapshot held in RAM,
-- playback-safe. ram_recalling gates the pool reload below: recalling a
-- snapshot whose pool PATHS match the current pool skips the buffer reloads
-- entirely (no audio interruption); only a genuinely different pool reloads.
local ram_snapshot = nil
local ram_recalling = false

local function pool_paths_equal(pool)
  local current = elasticat.pool_snapshot ~= nil and elasticat.pool_snapshot() or {}
  for slot = 1, 128 do
    local a = pool ~= nil and pool[slot] ~= nil and pool[slot].path or nil
    local b = current[slot] ~= nil and current[slot].path or nil
    if a ~= b then
      return false
    end
  end
  return true
end

local function apply_pool_state(pool, slot)
  if pool == nil or elasticat.load_pool_paths == nil then
    return
  end
  if ram_recalling and pool_paths_equal(pool) then
    return
  end
  elasticat.load_pool_paths(pool, slot)
  -- Keep script_state's own session copy (browser_state.data) in sync so a
  -- future script start with no temp project still resumes this pool.
  script_state:save_sample_pool_state(pool)
end

-- ---- Temp work project autosave (PRD §7.2) ---------------------------------
-- Debounced: any edit while stopped (re)schedules a save a couple seconds out;
-- the timer only actually writes if playback is STILL stopped when it elapses
-- (never mid-playback -- serialization stays out of the audio-critical path,
-- PRD §10). See request_redraw() above for the hook that calls
-- mark_project_dirty() on (almost) every edit.
local PROJECT_AUTOSAVE_DEBOUNCE = 2.0
local project_autosave_clock = nil

local function save_temp_project_now()
  if project_store ~= nil and not playing then
    project_store:save_temp()
  end
end

mark_project_dirty = function()
  if playing or project_store == nil or project_loading
    or applying_pattern_state then
    return
  end
  if project_autosave_clock ~= nil then
    clock.cancel(project_autosave_clock)
  end
  project_autosave_clock = clock.run(function()
    clock.sleep(PROJECT_AUTOSAVE_DEBOUNCE)
    project_autosave_clock = nil
    save_temp_project_now()
  end)
end

-- ---- Load / Save / Save As New / New Project (PRD §7.1) -------------------

local function sanitize_project_filename(name)
  local cleaned = (name or ""):gsub("[/\\:%*%?\"<>|]", "_")
  cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
  if cleaned == "" then
    cleaned = ProjectStore.date_name()
  end
  return cleaned
end

local function project_path_for_name(name)
  return ProjectStore.projects_dir() .. sanitize_project_filename(name) .. ProjectStore.EXTENSION
end

-- Resolve a name for a new project file per the project_auto_name setting:
-- None opens the text-entry dialog (PRD §7.3); Date/Namesizer generate one
-- immediately. `on_resolved(name)` fires either way so callers don't need two
-- code paths for the sync-vs-async cases.
local function resolve_project_name(title, on_resolved)
  local mode = param_value_or("project_auto_name", 1)
  local generated = ProjectStore.generate_name(mode)
  if generated ~= nil then
    on_resolved(generated)
    return
  end
  if text_entry == nil then
    on_resolved(ProjectStore.date_name())
    return
  end
  text_entry:open({
    text = "",
    title = title,
    confirm_label = "SAVE",
    max_length = 32,
    on_accept = function(typed)
      on_resolved(typed ~= nil and typed ~= "" and typed or ProjectStore.date_name())
    end,
    on_cancel = function() end
  })
end

-- Snapshot every prefixed value param at its current setting. Called once in
-- init (params at registered defaults) to seed factory_param_defaults.
local function capture_default_param_values()
  local values = {}
  local plen = #PREFIX
  for _, p in ipairs(params.params or {}) do
    local pid = p ~= nil and p.id
    if type(pid) == "string" and pid:sub(1, plen) == PREFIX and not is_inert_param_type(p) then
      local ok, value = pcall(function() return params:get(pid) end)
      if ok and type(value) == "number" then
        values[pid:sub(plen + 1)] = value
      end
    end
  end
  return values
end

-- New Project blank slate (PRD §7.1): empty the sample pool, restore every
-- track/pattern/global param to its factory default, and clear all live
-- lock/hold state so nothing stays "held" and un-editable (the range-locked
-- bug). The caller then swaps in a fresh pattern store and resets the scenes.
local function reset_project_state()
  -- Clear held/lock state FIRST so restoring params isn't fighting a live lock.
  if grid_ui ~= nil then
    grid_ui:set_transport(false, true)
    if grid_ui.reset_live_state ~= nil then
      grid_ui:reset_live_state()
    end
  end
  if param_values ~= nil and param_values.apply_step_param_locks ~= nil then
    param_values:apply_step_param_locks(nil)
  end
  if elasticat.load_pool_paths ~= nil then
    elasticat.load_pool_paths({}, 1)
  end
  if factory_param_defaults ~= nil then
    for suffix, value in pairs(factory_param_defaults) do
      -- Editor prefs survive New Project -- they belong to the editor, not the
      -- project (e.g. auto-name mode must not snap back to "none").
      if not EDITOR_PREF_SUFFIXES[suffix] then
        local full_id = id(suffix)
        if elasticat.param_exists(full_id) then
          params:set(full_id, value)
        end
      end
    end
  end
end

-- ---- Editor prefs persistence (PRD §7) ------------------------------------
local function editor_prefs_path()
  return _path.data .. "elasticat/editor_prefs.data"
end

local function save_editor_prefs()
  local values = {}
  for suffix in pairs(EDITOR_PREF_SUFFIXES) do
    if elasticat.param_exists(id(suffix)) then
      values[suffix] = params:get(id(suffix))
    end
  end
  util.make_dir(_path.data .. "elasticat/")
  tab.save(values, editor_prefs_path())
end

local function load_editor_prefs()
  local path = editor_prefs_path()
  if not util.file_exists(path) then
    return
  end
  local values = tab.load(path)
  if type(values) ~= "table" then
    return
  end
  for suffix, value in pairs(values) do
    if EDITOR_PREF_SUFFIXES[suffix] and elasticat.param_exists(id(suffix)) then
      params:set(id(suffix), value)
    end
  end
end

local function do_project_save_as()
  if project_store == nil or text_entry == nil then
    return
  end
  -- Save As ALWAYS prompts for a name (that's the point) -- the auto-name
  -- setting only drives New Project naming, not Save As. Prefills the current
  -- name so it can be tweaked (or CLEAR'd).
  text_entry:open({
    text = project_store:current_name() or "",
    title = "SAVE PROJECT AS",
    confirm_label = "SAVE",
    max_length = 32,
    on_accept = function(typed)
      local name = (typed ~= nil and typed ~= "") and typed or ProjectStore.date_name()
      project_store:set_name(name)
      project_store:save(project_path_for_name(name))
      show_message("Saved " .. name)
      request_redraw()
    end,
    on_cancel = function() end
  })
end

local function do_project_save()
  if project_store == nil then
    return
  end
  -- Save writes to a file named after the project (PRD §7.1). Rename via the
  -- PROJECT name row or Save As before saving if "untitled" isn't wanted.
  local name = project_store:current_name() or "untitled"
  project_store:save(project_path_for_name(name))
  show_message("Saved " .. name)
  request_redraw()
end

-- Rename the current project in memory (PRD §7.1): opens the text-entry dialog
-- from the PROJECT name row. Does NOT write to disk -- Save persists it.
local function do_project_rename()
  if project_store == nil or text_entry == nil then
    return
  end
  text_entry:open({
    text = project_store:current_name() or "",
    title = "RENAME PROJECT",
    confirm_label = "OK",
    max_length = 32,
    on_accept = function(typed)
      if typed ~= nil and typed ~= "" then
        project_store:set_name(typed)
        show_message("Renamed " .. typed)
      end
    end,
    on_cancel = function() end
  })
end

-- New Project (PRD §7.1/§7.2): reinitializes the pattern system to a single
-- blank pattern and becomes the working project under a freshly-resolved
-- name, then saves immediately so it has a real file backing it (the temp
-- work project autosave has something sensible to snapshot right away).
-- SCOPE NOTE: this resets the PATTERN scope only (the 16 slots pattern_store
-- owns) via a fresh PatternStore instance -- it deliberately leaves the
-- sample pool and other global-scope params untouched, since a full
-- params-registry sweep back to factory defaults is a separate, riskier
-- operation outside this task's spec. Flagged in the task report.
local function do_project_new()
  if project_store == nil then
    return
  end
  -- Confirm first (PRD §7.1): New Project wipes the current live state.
  open_confirm("Start from scratch?", function()
    project_loading = true
    -- Full blank slate: empty pool, factory-default params, cleared locks.
    reset_project_state()
    if scene_store ~= nil then
      scene_store:reset()
    end
    -- Fresh pattern store: 16 empty slots, slot 1 seeded blank so it reads as
    -- populated (blank_state clears the live sequence, then capture persists it).
    pattern_store = PatternStore.new({
      capture_state = capture_pattern_state,
      apply_state = apply_pattern_state,
      blank_state = blank_pattern_state
    })
    project_store:set_pattern_store(pattern_store)
    pattern_store:load(1, true)
    pattern_store:capture(1)
    project_loading = false
    -- New projects start UNSAVED (PRD §7.1): written to disk only by an explicit
    -- Save / Save As. The name follows the Auto-Name editor pref -- None gives
    -- "untitled", Date gives yymmdd-hhmm, Namesizer a generated name.
    local name = ProjectStore.generate_name(param_value_or("project_auto_name", 1)) or "untitled"
    project_store:set_name(name)
    project_store.path = nil
    -- Replace the temp work snapshot with the blank slate (same reasoning as
    -- project load): a script reload right after New Project should resume the
    -- new empty project, not resurrect the previous session.
    project_store:save_temp()
    show_message("New project " .. name .. " (unsaved)")
    request_redraw()
  end)
end

-- Load: browse the projects directory (same fileselect idiom as the sample
-- browser -- select_sample/enter_sample_browser further below -- kept
-- separate since projects and samples browse different roots).
local function do_project_load()
  -- Our own browser (above), not the norns file-select: obeys the project's
  -- input conventions and cancels back to the PROJECT settings page.
  open_project_browser()
end

-- ---- Memorize / Recall (PRD §7.2) ------------------------------------------
-- FN+Octave-Up (grid 2,5) memorizes the WHOLE project state (patterns, track
-- params, pool, scenes) into RAM; FN+Octave-Down (grid 1,5) recalls it
-- instantly -- usable during playback (a recall re-anchors the pattern at step
-- 1, like a Direct Start switch). The RAM copy is independent of the temp
-- work project on disk: memorize is a free-form "save point" for performance.
local function ram_memorize()
  if project_store == nil then
    return
  end
  ram_snapshot = {
    project = project_store:serialize(),
    scenes = scene_store ~= nil and scene_store:serialize() or nil
  }
  show_message("Memorized")
  request_redraw()
end

local function ram_recall()
  if project_store == nil then
    return
  end
  if ram_snapshot == nil then
    show_message("Nothing memorized")
    return
  end
  project_loading = true
  ram_recalling = true
  project_store:deserialize(ram_snapshot.project)
  ram_recalling = false
  project_loading = false
  if scene_store ~= nil and ram_snapshot.scenes ~= nil then
    scene_store:deserialize(ram_snapshot.scenes)
    -- Restore the fader position param silently (no re-apply loop), then
    -- morph to it so scene-locked params land where they were memorized.
    if params:lookup_param(id("crossfade")) ~= nil then
      params:set(id("crossfade"), math.floor(scene_store:position_value() * 128 + 0.5), true)
    end
    scene_store:apply(scene_store:position_value())
    elasticat.reconcile_crossfader(scene_store:morph_target_keys())
  end
  show_message("Recalled")
  request_redraw()
end

-- Reachable through the (already-captured) module table from init()'s grid
-- options, the same 60-upvalue-limit dodge as input_router above.
elasticat.ram_memorize = ram_memorize
elasticat.ram_recall = ram_recall
elasticat.ram_has = function()
  return ram_snapshot ~= nil
end

local function source_sample_items()
  return MachineRegistry.source_items(param_value_or("machine", 1), ParamItem)
end

-- Razor slice-point EDITOR (source page 1 for Razor / Razor Poly). Grid keys (or
-- the SLIC selector) pick a slice; the bottom row edits THAT slice's Start / End
-- (the real razor_NN params, global), plus the snap toggle and choke. Reverse is
-- dropped here (it lives on the Machine page). `razor_point` tags Start/End so the
-- waveform can draw their markers and FN can zoom around them. On the elasticat
-- module table (not a file local) -- the coordinator is at LuaJIT's 200-local cap.
elasticat.razor_editor_items = function()
  local sel = (grid_ui ~= nil and grid_ui.get_selected_slice ~= nil) and grid_ui:get_selected_slice() or 1
  return {
    ParamItem.item("pitch", "P/T", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    ParamItem.item("slice_play_mode", "PLAY", {lockable = true, options = 6}),
    ParamItem.item("slice_select", "SLIC", {pseudo = "slice_select", lockable = false, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    ParamItem.item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
    ParamItem.item(string.format("razor_%02d_start", sel), "STRT", {lockable = false, min = 0, max = 128, step = 0.5, razor_point = "start", razor_slice = sel}),
    ParamItem.item(string.format("razor_%02d_end", sel), "END", {lockable = false, min = 0, max = 128, step = 0.5, razor_point = "end", razor_slice = sel}),
    ParamItem.item("slice_snap", "SNAP", {lockable = false, options = 5}),
    ParamItem.item("slice_choke", "CHOK", {pseudo = "slice_choke", lockable = false, min = 0, max = 8, step = 1})
  }
end

-- Redistribute the first slice_count razor slices as EQUAL divisions of the
-- whole sample (source settings action row). By slice_count, unlike the fixed
-- 32-slice razor_reset trigger. Only razor machines read these points.
elasticat.razor_redistribute = function()
  local count = util.clamp(math.floor((param_value_or("slice_count", 16)) + 0.5), 1, 32)
  local width = 128 / count
  for i = 1, count do
    params:set(id(string.format("razor_%02d_start", i)), (i - 1) * width)
    params:set(id(string.format("razor_%02d_end", i)), i * width)
  end
  show_message(string.format("Razor: %d even slices", count))
  request_redraw()
end

-- Auto-Chop: lay one razor slice per detected transient (MPC style) and set the
-- track's slice_count to match. Slice i runs from onset i to onset i+1 (the last
-- to the end); the pre-first-onset head is left out (adjust slice 1's Start to
-- reclaim it). Uses the transients cached at sample load.
elasticat.razor_autochop = function()
  local slot = elasticat.ui_sample_slot ~= nil and elasticat.ui_sample_slot() or 1
  local list = elasticat.slot_transients(slot)
  if #list == 0 then
    show_message("Auto-Chop: no transients")
    return
  end
  local count = math.min(#list, 32)
  for i = 1, count do
    local start_point = util.clamp(list[i], 0, 128)
    local end_point = (i < count) and util.clamp(list[i + 1], 0, 128) or 128
    if end_point <= start_point then
      end_point = math.min(128, start_point + 0.01)
    end
    params:set(id(string.format("razor_%02d_start", i)), start_point)
    params:set(id(string.format("razor_%02d_end", i)), end_point)
  end
  params:set(ui_id("slice_count"), count)
  show_message(string.format("Auto-Chop: %d slices", count))
  request_redraw()
end

-- FN + PLAY on the razor source page runs a chop action WITHOUT a dedicated param
-- (owner). Interaction:
--   * hold FN, DON'T turn -> the PLAY cell shows the normal play mode.
--   * hold FN, turn: the FIRST detent ARMS the selector at "FUNC" (does nothing);
--     then turn RIGHT -> "REDIST" -> "A.CHOP", or LEFT (from FUNC) -> "EXIT".
--   * release FN -> commit: REDIST/A.CHOP run; FUNC/EXIT do nothing.
--   * no FN, turn -> normal play-mode edit.
-- Only razor machines (4/6). Module-table state (200-local ceiling). Every FN
-- DOWN (K1 or grid) re-arms (starts inactive), so a missed commit can't stick it.
elasticat.razor_action_active = false
elasticat.razor_action_sel = 0   -- -1 EXIT, 0 FUNC (neutral), 1 REDIST, 2 A.CHOP
elasticat.RAZOR_ACTION_LABELS = { [-1] = "EXIT", [0] = "FUNC", [1] = "REDIST", [2] = "A.CHOP" }
-- Called on FN DOWN: start each hold fresh (inactive) so holding FN alone shows
-- the play mode, and un-stick anything a missed FN-release commit left behind.
elasticat.razor_action_arm = function()
  elasticat.razor_action_active = false
  elasticat.razor_action_sel = 0
end
elasticat.razor_action_select = function(delta)
  local machine = param_value_or("machine", 1)
  if machine ~= 4 and machine ~= 6 then
    return false   -- not a razor machine: PLAY edits normally
  end
  if not elasticat.razor_action_active then
    -- First turn under FN ARMS at FUNC (does nothing); turn again to pick an action.
    elasticat.razor_action_active = true
    elasticat.razor_action_sel = 0
  else
    elasticat.razor_action_sel = util.clamp(
      elasticat.razor_action_sel + (delta >= 0 and 1 or -1), -1, 2)
  end
  show_message("Chop: " .. elasticat.RAZOR_ACTION_LABELS[elasticat.razor_action_sel])
  request_redraw()
  return true
end
-- The PLAY cell's label while a chop action is being selected (nil = show the
-- normal play mode -- i.e. FN held but not yet turned, or not active).
elasticat.razor_action_short = function()
  if not elasticat.razor_action_active then
    return nil
  end
  return elasticat.RAZOR_ACTION_LABELS[elasticat.razor_action_sel]
end
-- FN release: run the selected action (FUNC/EXIT = cancel), then reset.
elasticat.razor_action_commit = function()
  if not elasticat.razor_action_active then
    return
  end
  local sel = elasticat.razor_action_sel
  elasticat.razor_action_active = false
  elasticat.razor_action_sel = 0
  if sel == 1 then
    elasticat.razor_redistribute()
  elseif sel == 2 then
    elasticat.razor_autochop()
  end
  request_redraw()
end

-- The transient positions (0-128, ascending) for a pool slot at the CURRENT chop
-- sensitivity, picked from the cached onset envelope (so the sensitivity knob
-- re-picks live, no re-read). {} when the slot has no cached onsets.
elasticat.slot_transients = function(slot)
  slot = math.floor((tonumber(slot) or 1) + 0.5)
  local onsets = elasticat.sample_onsets
  onsets = (onsets ~= nil) and onsets[slot] or nil
  if onsets == nil then
    return {}
  end
  return WavReader.pick_transients(onsets, (param_value_or("slice_chop_sense", 50) or 50) / 100)
end

-- Snap a 0-128 position to the nearest zero crossing of the slot's sample (an
-- on-demand signed-window read -- crossings are everywhere, so caching them is
-- pointless). Returns the position unchanged when the slot has no readable file.
elasticat.snap_zero_cross = function(slot, pos)
  local path = elasticat.pool_path ~= nil and elasticat.pool_path(slot) or nil
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return pos
  end
  return WavReader.nearest_zero_cross(path, pos, 0.01)
end

-- The prev/next cached transient relative to `current` (delta's sign chooses the
-- direction), or nil when there is none that way -- the caller then fine-nudges.
elasticat.snap_transient = function(slot, current, delta)
  local list = elasticat.slot_transients(slot)
  if #list == 0 then
    return nil
  end
  if delta >= 0 then
    for _, p in ipairs(list) do
      if p > current + 0.05 then
        return p
      end
    end
    return nil
  end
  for i = #list, 1, -1 do
    if list[i] < current - 0.05 then
      return list[i]
    end
  end
  return nil
end

-- Edit ONE razor point (start/end of `slice`) from source page 1, honoring the
-- SNAP mode. FN held picks the snap behaviour; without FN it is a plain detent.
--   grid      FN -> snap to the nearest 128/slice_count division
--   zoom      FN -> fine nudge (precise)
--   zero-x    FN -> nearest zero crossing        (DSP, Increment B: fine for now)
--   transient FN -> prev/next detected onset     (DSP, Increment B: fine for now)
--   friends   FN -> fine; ALSO drags the touching neighbour (prev end / next
--             start) in EVERY case, then the neighbour's own clamp keeps end>start
-- On the module table -- the coordinator is at LuaJIT's 200-local ceiling, so
-- the two detents (0.5 plain, 0.1 FN-fine) are inlined below rather than kept as
-- file-scope locals (two more locals overflow the chunk).
elasticat.razor_point_edit = function(slice, point, delta, fn_held)
  slice = math.floor((tonumber(slice) or 1) + 0.5)
  if slice < 1 or slice > 32 then
    return
  end
  point = (point == "end") and "end" or "start"
  local pid = id(string.format("razor_%02d_%s", slice, point))
  if not elasticat.param_exists(pid) then
    return
  end
  local mode = math.floor((param_value_or("slice_snap", 1)) + 0.5)   -- 1..5
  local count = util.clamp(math.floor((param_value_or("slice_count", 16)) + 0.5), 1, 32)
  local slot = elasticat.ui_sample_slot ~= nil and elasticat.ui_sample_slot() or 1
  local current = params:get(pid)
  local target
  if fn_held and mode == 1 then
    -- Grid: step to the next 128/count division in the delta's direction.
    local mult = 128 / count
    if delta >= 0 then
      target = (math.floor(current / mult + 1e-6) + 1) * mult
    else
      target = (math.ceil(current / mult - 1e-6) - 1) * mult
    end
  elseif fn_held and mode == 3 then
    -- zero-x: move one detent, then land on the nearest zero crossing.
    target = elasticat.snap_zero_cross(slot, util.clamp(current + (delta * 0.5), 0, 128))
  elseif fn_held and mode == 4 then
    -- Transient: jump to the prev/next detected onset (fine nudge if none).
    target = elasticat.snap_transient(slot, current, delta) or (current + (delta * 0.001))
  elseif fn_held and mode == 2 then
    -- Zoom: match the sample-editor trim FEEL -- one detent = ~1ms of the sample
    -- (0.128/duration in 0-128 units), not a fixed 0.001. So under the same ~10%
    -- visual zoom the marker moves the same visible amount per detent as the trim
    -- editor, regardless of sample length (0.001 was ~32x too fine on a 4s file).
    local dur = elasticat.pool_meta ~= nil and (elasticat.pool_meta(slot).duration or 0) or 0
    target = current + (delta * ((dur > 0) and (0.128 / dur) or 0.03))
  elseif fn_held then
    -- Friends: ultra-fine 0.001 nudge (sample-accurate under the zoom).
    target = current + (delta * 0.001)
  else
    target = current + (delta * 0.5)   -- plain detent
  end
  params:set(pid, util.clamp(target, 0, 128))   -- the param action keeps end>start
  -- Remember the point just edited (0-128) so the source page can centre the
  -- Razor-Zoom magnification on it.
  elasticat.razor_focus_pos = params:get(pid)

  -- Friends: dragging a start also drags the PREVIOUS slice's end; dragging an
  -- end also drags the NEXT slice's start (except the outermost, which have no
  -- neighbour on that side). Use the value we actually landed on after clamping.
  if mode == 5 then
    local landed = params:get(pid)
    if point == "start" and slice > 1 then
      params:set(id(string.format("razor_%02d_end", slice - 1)), landed)
    elseif point == "end" and slice < count then
      params:set(id(string.format("razor_%02d_start", slice + 1)), landed)
    end
  end
  request_redraw()
end

-- Edit ONE trim endpoint (Trim Start/End on the sample editor) honoring the TRIM
-- snap mode -- the seconds-domain parallel of razor_point_edit. Without FN both
-- edges move in 0.01s detents; FN drives the snap. The point is placed
-- INDEPENDENTLY via the facade (snapping start never drags end). Module-table
-- function (coordinator is at the 200-local ceiling); zero-x/transient reuse the
-- razor 0-128 snap helpers via a seconds<->128 conversion.
--   grid      -> the sample's step grid (one 16th at its BPM)
--   zoom      -> fine 0.001s nudge (+ the visual waveform zoom)
--   zero-x    -> nearest zero crossing
--   transient -> prev/next detected onset (fine nudge if none that way)
elasticat.trim_point_edit = function(point, delta, fn_held)
  point = (point == "end") and "end" or "start"
  if elasticat.set_trim_point == nil then
    return
  end
  local slot = elasticat.file_edit_slot ~= nil and elasticat.file_edit_slot() or 1
  local meta = elasticat.pool_meta(slot)
  local duration = (meta and meta.duration) or 0
  local pid = id(point == "end" and "trim_end" or "trim_start")
  if duration <= 0 or not elasticat.param_exists(pid) then
    return
  end
  local current = params:get(pid)   -- seconds
  local mode = math.floor((param_value_or("trim_snap", 2)) + 0.5)   -- 1 grid 2 zoom 3 zero-x 4 transient
  local target
  if not fn_held then
    target = current + (delta * 0.01)                        -- plain 0.01s detent
  elseif mode == 1 then
    local bpm = math.max(1, (meta and meta.bpm) or 120)
    local step = 60 / (bpm * 4)                              -- one 16th, seconds
    if delta >= 0 then
      target = (math.floor(current / step + 1e-6) + 1) * step
    else
      target = (math.ceil(current / step - 1e-6) - 1) * step
    end
  elseif mode == 3 then
    local nudged = util.clamp(current + (delta * 0.005), 0, duration)
    local snapped = elasticat.snap_zero_cross(slot, (nudged / duration) * 128)
    target = (snapped / 128) * duration
  elseif mode == 4 then
    local snapped = elasticat.snap_transient(slot, (current / duration) * 128, delta)
    target = snapped ~= nil and ((snapped / 128) * duration) or (current + (delta * 0.001))
  else
    target = current + (delta * 0.001)                       -- zoom: fine
  end
  elasticat.set_trim_point(point, target)
  request_redraw()
end

local function source_machine_items()
  return MachineRegistry.machine_items(param_value_or("machine", 1), ParamItem)
end

-- The synced RATE multiplier -- constant across every warp mode, pinned to the
-- bottom-right cell (item 8). Free turn = 0.01 steps; FN snaps to the pattern-rate
-- fractions (1/16..2, triplets) plus the 3/4/6/8x octaves so the full range is
-- snap-reachable. snap_tolerance 0.012 clears the ~0.01 rounding a snapped fraction
-- is stored at, and stays under half the smallest fraction gap (~0.042) so a snap
-- step never skips one.
local function warp_rate_item()
  return ParamItem.item("warp_rate", "RATE", {
    lockable = true, min = 0.0625, max = 8, step = 0.01, snap_tolerance = 0.012,
    snaps = {
      1 / 16, 1 / 8, 1 / 6, 1 / 4, 1 / 3, 3 / 8, 1 / 2, 5 / 8, 2 / 3, 3 / 4,
      5 / 6, 7 / 8, 1, 7 / 6, 5 / 4, 4 / 3, 3 / 2, 5 / 3, 7 / 4, 11 / 6, 2, 3, 4, 6, 8
    }
  })
end

local function source_warp_items()
  -- Arrange the current mode's params into the reusable Mode-Parameter skeleton
  -- (owner, mirrors FILTER MIX): two full rows of 4 for the mode's params, then the
  -- WARP selector as the bottom-left banner (item 9, K2) with RATE to its right
  -- (item 10, K3). Envelope Attack/Release are forced to the second row. The banner
  -- is NOT p-lockable and only changes stopped + FN-held: swapping the warp engine
  -- mid-run respawns the reader (and needs a different per-warp slice def), so one
  -- warp per session. no_edit_playing + fn_to_edit gate the encoder. RATE stays
  -- freely editable via K3. Arrangement + envelope handling live in WarpRegistry.
  local raw = WarpRegistry.source_items(param_value_or("mode", 1), ParamItem)
  local banner = ParamItem.item("mode", "WARP", {
    mode_param = true, lockable = false,
    no_edit_playing = true, fn_to_edit = true, options = #elasticat.modes})
  return WarpRegistry.arrange_page(raw, banner, warp_rate_item(), ParamItem.blank)
end

-- AMP page: layout depends on envelope mode. Top row is the envelope (ADSR or
-- AHR), bottom row is empty, empty, Pan, Track Volume.
local function amp_env_items()
  local env_time = {lockable = true, min = 0, max = 127, step = 1}
  local env_long = {lockable = true, min = 0, max = 128, step = 1}
  local items
  if param_value_or("env_mode", 2) == 1 then  -- ADSR
    items = {
      ParamItem.item("env_attack", "ATCK", env_time),
      ParamItem.item("env_decay", "DECAY", env_time),
      ParamItem.item("env_sustain", "SUST", env_time),
      ParamItem.item("env_release", "REL", env_long)
    }
  else  -- AHR (default)
    items = {
      ParamItem.item("env_attack", "ATCK", env_time),
      ParamItem.item("env_hold", "HOLD", env_long),
      ParamItem.item("env_release", "REL", env_long),
      ParamItem.blank()
    }
  end
  -- Bottom row (all four cells): the track's output stage.
  items[5] = ParamItem.item("send1_level", "SND 1", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  items[6] = ParamItem.item("send2_level", "SND 2", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  items[7] = ParamItem.item("pan", "PAN", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
  items[8] = ParamItem.item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  return items
end

-- MOD ENV page (MOD category page 3): the mod envelope is a full ADSR now, so
-- it gets the same treatment as the other envelopes -- stages on top, envelope
-- render in the middle, DEST/DEPTH in the bottom row's cells 3 and 4.
elasticat.mod_env_lowprofile_items = function()
  local env_time = {lockable = true, min = 0, max = 127, step = 1}
  return {
    ParamItem.item("menv_attack", "ATCK", env_time),
    ParamItem.item("menv_decay", "DECAY", env_time),
    ParamItem.item("menv_sustain", "SUST", env_time),
    ParamItem.item("menv_release", "REL", env_time),
    ParamItem.item("menv_dest", "DEST", {lockable = false, options = 10}),
    ParamItem.item("menv_depth", "DEPTH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
  }
end

-- FILTER page 1: the active machine's p-lockable macro row (Type/Cutoff/Res/
-- Drive, or Morph/... etc). Machine is a setting, so this list changes when the
-- filter machine changes -- same dynamic pattern as the WARP page.
local function filter_machine_items()
  return FilterRegistry.source_items(param_value_or("filter_machine", 1), ParamItem)
end

-- FILTER page 1 (owner low-profile redesign): a curated 4 -- CUT, RES, the
-- machine's morph knob (morphing family) or TYPE (classic), and the filter
-- envelope DEPTH (pulled onto this page though the full env lives on page 2).
-- These 4 are what the low-profile row + bar render draw and what K2/K3 edit.
-- Low-profile cells draw TWO values: the base track value (the bar that must
-- hold still) and the "actual" value after everything acting on it. Returns
-- base_raw, actual_raw, modulated.
--   crossfader -- scene_store applies the morph by writing the live param, so
--     the live value IS the actual; the untouched track value is the scene
--     base it stashed. Without this the base bar moved with the fader.
--   macro assign -- while a macro key is held, preview current +/- that
--     macro's depth to this destination, so you can see what you're dialing.
-- (Live LFO/env modulation joins here once the engine reports mod-bus values.)
elasticat.param_display_values = function(item, raw)
  local base, actual, modulated = raw, raw, false
  if type(raw) ~= "number" or item == nil or item.id == nil then
    return base, actual, false
  end
  local suffix = item.id

  -- Base-value resolver (docs/BASE_VALUE_RESOLVER.md): the ACTUAL bar follows the
  -- value actually SENT -- a firing step p-lock (or a morph) overriding the track
  -- value -- while the STORED bar (base) stays the track value the knob edits.
  -- Guarded so the common case (nothing p-locked/morphing) pays nothing.
  if elasticat.has_base_override ~= nil and elasticat.has_base_override() then
    local resolved = elasticat.resolved_value(suffix)
    if type(resolved) == "number" then
      actual = resolved
      if math.abs(actual - base) > 0.0001 then
        modulated = true
      end
    end
  end

  -- Scene bases are keyed by FULL per-track param id, so the bar reads the
  -- SELECTED track's base -- a bare suffix here showed track 1's base on every
  -- track's page.
  if scene_store ~= nil then
    local scene_base = scene_store:base_value(ui_id(suffix))
    if type(scene_base) == "number" then
      base = scene_base
      if math.abs(actual - base) > 0.0001 then
        modulated = true
      end
    end
  end

  local held = (grid_ui ~= nil and grid_ui.held_macro ~= nil) and grid_ui:held_macro() or nil
  if held ~= nil and elasticat.macro_dest_for_param ~= nil then
    local dest = elasticat.macro_dest_for_param(suffix)
    local pid = dest ~= nil and elasticat.macro_depth_id(held, dest) or nil
    if pid ~= nil and elasticat.param_exists(pid) then
      local depth = ((params:get(pid) or 64) - 64) / 64  -- -1..1
      local span = (item.max or 127) - (item.min or 0)
      actual = actual + (depth * span)
      modulated = true
    end
  else
    -- Live modulation (LFOs / mod env / macros), fed from the engine at 15Hz.
    -- ONLY while the transport is running: LFOs free-run in the engine, so
    -- while stopped this made the actual bar wobble under a param you were
    -- barely nudging. Stopped, the bar shows only the crossfade/macro layers
    -- above. Skipped while a macro key is held so the assign preview owns the
    -- bar. AMP is multiplicative in the engine, everything else an offset.
    if not playing then
      return base, actual, modulated
    end
    if suffix == "amp" then
      local factor = elasticat.mod_amp_factor()
      if math.abs(factor - 1) > 0.001 then
        actual = actual * factor
        modulated = true
      end
    else
      local offset = elasticat.mod_offset_for(suffix)
      if math.abs(offset) > 0.001 then
        actual = actual + offset
        modulated = true
      end
    end
  end

  return base, actual, modulated
end

-- Machine-AWARE filter page 1: each filter machine renders its OWN p-lockable
-- param row (lib/filter_modes/<machine>.source_items) plus the shared filter-
-- envelope DEPTH cell. This replaced the old "machine % 2 == 0 -> MORPH else TYPE"
-- heuristic, which only knew Classic vs Morphing -- so machines 3-6 (Balance) and
-- the new character filters (Comb/Ladder/Formant/SVF) now surface their real
-- controls instead of a fixed CUT/RES/[TYPE|MORPH] triad.
-- On the module table (not a new local): the main chunk is at LuaJIT's 200-local
-- ceiling (see elasticat.param_exists).
elasticat.filter_lowprofile_items = function()
  local machine = math.floor(param_value_or("filter_machine", 1) + 0.5)
  local src = FilterRegistry.source_items(machine, ParamItem)
  -- Pull CUT/RES out by id so they land in the SAME cell on every machine (owner:
  -- CUT = slot 1, RES = slot 2, env DEPTH = slot 4). The machine's own param ORDER
  -- decides which control is the "primary" one at slot 3 (its first non-CUT/RES
  -- item -- Type / Morph / Balance / Drive / ...); anything after that fills 5+.
  local cut, res, others = nil, nil, {}
  for _, it in ipairs(src) do
    if it.id == "filter_cutoff" then cut = it
    elseif it.id == "filter_res" then res = it
    else others[#others + 1] = it end
  end
  local items = {
    cut or ParamItem.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    res or ParamItem.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    others[1] or ParamItem.blank(),
    ParamItem.item("filter_env_depth", "DEPTH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
  }
  for i = 2, #others do items[#items + 1] = others[i] end
  return items
end

-- FILTER page 2 (envelope), low-profile redesign. Items 1-4 are the TOP row --
-- ATCK/DECAY/SUST/REL for ADSR, ATCK/HOLD/REL + blank for AHR -- and items 5-6
-- are DRIVE/DEPTH, which the renderer places at the BOTTOM row's cells 3 and 4.
-- Keeping them adjacent in the list (rather than padding to index 7/8) means
-- K2/K3 never lands on an all-blank pair.
elasticat.filter_env_lowprofile_items = function()
  -- Safe to share now that ParamItem.item copies its opts (it used to alias
  -- every item that shared one table into a single item).
  local env_time = {lockable = true, min = 0, max = 127, step = 1}
  local items
  if param_value_or("filter_env_mode", 2) == 1 then  -- ADSR
    items = {
      ParamItem.item("filter_env_attack", "ATCK", env_time),
      ParamItem.item("filter_env_decay", "DECAY", env_time),
      ParamItem.item("filter_env_sustain", "SUST", env_time),
      ParamItem.item("filter_env_release", "REL", {lockable = true, min = 0, max = 128, step = 1})
    }
  else  -- AHR
    items = {
      ParamItem.item("filter_env_attack", "ATCK", env_time),
      ParamItem.item("filter_env_hold", "HOLD", {lockable = true, min = 0, max = 128, step = 1}),
      ParamItem.item("filter_env_release", "REL", {lockable = true, min = 0, max = 128, step = 1}),
      ParamItem.blank()
    }
  end
  items[5] = ParamItem.item("filter_drive", "DRIVE", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  items[6] = ParamItem.item("filter_env_depth", "DEPTH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
  return items
end

-- FX pages: each FX slot's active machine's p-lockable row (Drive/Mix, Delay's
-- Time/Feedback/Tone/Mix, etc.). Machine is a setting, so a slot's list changes
-- when its machine selector changes -- same dynamic pattern as FILTER/WARP.
-- One helper serves all four slots (Insert 1 / Send 1 / Send 2 / Master):
-- `machine_suffix` names the slot's machine selector param and `prefix`
-- namespaces the item ids per slot (nil for Insert 1's original unprefixed
-- ids; "send1_"/"send2_"/"master_" match the params registered in
-- lib/elasticat.lua). NONE returns no items, which draw_root_page renders as
-- the blank "empty" page.
-- FX slot page (Insert 1 / Send 1 / Send 2 / Master) as a Mode-Parameter page
-- (owner): the machine's params fill the two rows, and the machine SELECTOR is the
-- bottom-left banner so the FX can be changed on-page without the settings menu.
-- The banner is NOT p-lockable and requires FN to change (guards an accidental
-- turn), but -- unlike the WARP/FILTER mode banners -- it has NO no_edit_playing,
-- so the FX can be swapped live (it is a freely-changeable setting today, and the
-- engine respawns the FX synth without stopping playback). No trailing param, so
-- item 10 is blank. `machine_suffix` resolves per-track for the Insert (it is in
-- ParamsSpec) and globally for the shared Send/Master machines -- ui_id handles
-- both -- so the banner reads/writes the right param either way.
local function fx_slot_items(machine_suffix, item_prefix)
  local labels = {
    fx_insert1_machine = "INSERT 1", send1_machine = "SEND 1",
    send2_machine = "SEND 2", master_fx_machine = "MASTER"
  }
  local machine = math.floor(param_value_or(machine_suffix, 1) + 0.5)
  local raw = FxRegistry.source_items(machine, ParamItem, item_prefix)
  local banner = ParamItem.item(machine_suffix, labels[machine_suffix] or "FX", {
    mode_param = true, lockable = false, fn_to_edit = true, options = FxRegistry.count()})
  -- Universal dry/wet (owner): fx_mix moves OUT of the rows and into the trailing
  -- slot (item 10, bottom-right next to the banner), like RATE on the WARP page,
  -- so MIX always lives in the same place. Machines with no wet/dry (Destroy, DJ
  -- EQ, Duck, Motion, Limit) don't list fx_mix, so their trailing stays blank.
  local mix_id = (item_prefix or "") .. "fx_mix"
  local trailing = ParamItem.blank()
  local rows = {}
  for _, it in ipairs(raw) do
    if it.id == mix_id then
      trailing = it
    else
      rows[#rows + 1] = it
    end
  end
  -- Always-wet machines get a static "WET" tag in the MIX position, so the
  -- empty cell reads as a statement (this machine is always fully wet) rather
  -- than a missing param. NONE (machine 1) stays truly blank -- there is
  -- nothing to be wet.
  if trailing.blank and machine > 1 then
    trailing.tag = "WET"
  end
  return FxRegistry.arrange_page(rows, banner, trailing, ParamItem.blank)
end

-- FILTER page 2: the filter envelope, laid out by its (independent) mode -- ADSR
-- or AHR -- with DEPTH (cutoff modulation amount) on the bottom row.
local function filter_env_items()
  local items
  if param_value_or("filter_env_mode", 2) == 1 then  -- ADSR
    items = {
      ParamItem.item("filter_env_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1}),
      ParamItem.item("filter_env_decay", "DEC", {lockable = true, min = 0, max = 127, step = 1}),
      ParamItem.item("filter_env_sustain", "SUS", {lockable = true, min = 0, max = 127, step = 1}),
      ParamItem.item("filter_env_release", "REL", {lockable = true, min = 0, max = 128, step = 1})
    }
  else  -- AHR (default)
    items = {
      ParamItem.item("filter_env_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1}),
      ParamItem.item("filter_env_hold", "HOLD", {lockable = true, min = 0, max = 128, step = 1}),
      ParamItem.item("filter_env_release", "REL", {lockable = true, min = 0, max = 128, step = 1}),
      ParamItem.blank()
    }
  end
  table.insert(items, ParamItem.item("filter_env_depth", "DPTH", {lockable = true, min = 0, max = 128, step = 1}))
  table.insert(items, ParamItem.blank())
  table.insert(items, ParamItem.blank())
  table.insert(items, ParamItem.blank())
  return items
end

-- TRIG page 2 (machine trig): behavior params that only apply to the loop
-- machines' continuous playhead -- empty for slice machines.
local function trig_machine_items()
  if param_value_or("machine", 1) >= 3 then  -- 3/4 = grid/razor slice
    return {}
  end
  return {
    ParamItem.item("trig_jump", "JUMP", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
    ParamItem.item("trig_release", "RLSE", {lockable = true, options = 3})
  }
end

local function page_items_for(category, page, page_index)
  if category == "amp" and page_index == 1 then
    return amp_env_items()
  elseif category == "filter" and page_index == 1 then
    return elasticat.filter_lowprofile_items()
  elseif category == "filter" and page_index == 2 then
    return elasticat.filter_env_lowprofile_items()
  elseif category == "mod" and page_index == 3 then
    return elasticat.mod_env_lowprofile_items()
  elseif category == "fx" and page_index == 1 then
    return fx_slot_items("fx_insert1_machine", nil)
  elseif category == "fx" and page_index == 3 then
    return fx_slot_items("send1_machine", "send1_")
  elseif category == "fx" and page_index == 4 then
    return fx_slot_items("send2_machine", "send2_")
  elseif category == "fx" and page_index == 5 then
    return fx_slot_items("master_fx_machine", "master_")
  elseif category == "trig" and page_index == 3 then
    return trig_machine_items()
  elseif category == "source" and page_index == 1 then
    local machine = param_value_or("machine", 1)
    if machine == 4 or machine == 6 then   -- Razor / Razor Poly: slice-point editor
      return elasticat.razor_editor_items()
    end
    return source_sample_items()
  elseif category == "source" and page_index == 2 then
    return source_machine_items()
  elseif category == "source" and page_index == 3 then
    local machine = param_value_or("machine", 1)
    local machine_items = MachineRegistry.source_page2_items(machine, ParamItem)
    if machine_items ~= nil then
      return machine_items
    end
    -- WARP page: WARP selector + the current warp mode's params (grain size/
    -- density, OLA window, PC window, ...), same as the loop machine. Slice SYNC
    -- and RATE are NOT added here -- they live on the Machine page, and appending
    -- them could overrun the warp mode's own params and render on top of them
    -- (owner: the chopped engine collided).
    return source_warp_items()
  end
  return page.items or {}
end

nav = Navigation.new({
  page_items_for = page_items_for,
  show_message = show_message,
  request_redraw = request_redraw,
  on_navigate = function()
    -- Leaving a page stops any sample preview in progress.
    if params:lookup_param(id("sample_preview")) ~= nil and params:get(id("sample_preview")) == 1 then
      params:set(id("sample_preview"), 0)
    end
    if elasticat.flush_dirty_pool_state ~= nil then
      elasticat.flush_dirty_pool_state()
    end
    -- The MIX overview (master page 2) shows all 8 meters; every other page shows
    -- only the selected track's. Tell the engine which meters to feed at 15Hz.
    local _, page_index = nav:current_page()
    elasticat.set_meter_all(nav:current_category() == "master" and page_index == 2)
  end
})

param_values = ParamValues.new({
  -- Selected-track id funnel (Phase 1): per-track suffixes resolve to the
  -- selected track's params; everything else passes through unchanged.
  id = ui_id,
  show_message = show_message,
  sample_name = sample_name,
  param_value_or = param_value_or,
  get_grid_ui = function() return grid_ui end,
  get_alt = fn_active,
  -- Razor slice-point editor: Start/End edits route here so the coordinator can
  -- apply the SNAP mode + friends coupling (razor_point_edit, module table).
  razor_edit = function(slice, point, delta, fn) elasticat.razor_point_edit(slice, point, delta, fn) end,
  trim_edit = function(point, delta, fn) elasticat.trim_point_edit(point, delta, fn) end,
  -- FN + PLAY on the razor page selects/commits a chop action (no dedicated param).
  razor_action_select = function(delta) return elasticat.razor_action_select(delta) end,
  razor_action_short = function() return elasticat.razor_action_short() end,
  -- A/B scene p-locks (PRD §6.6): while an anchor is held, params locked in
  -- that scene display the SCENE's value with the lock visuals, exactly like
  -- a held step's p-locks.
  get_scene_edit = function()
    return scene_store ~= nil and scene_store:edit_target_scene() or nil
  end,
  -- ui_id: scenes are keyed by full per-track id, so a held anchor shows the
  -- SELECTED track's locked value (not track 1's).
  get_scene_value = function(suffix)
    if scene_store == nil then
      return nil
    end
    return scene_store:scene_value(scene_store:edit_target_scene(), ui_id(suffix))
  end,
  get_select_sample = function() return select_sample end,
  get_default_trig_length = function() return default_trig_length end,
  set_default_trig_length = function(v) default_trig_length = v end,
  get_default_trig_velocity = function() return default_trig_velocity end,
  set_default_trig_velocity = function(v) default_trig_velocity = v end,
  set_last_trim_focus = function(v) last_trim_focus = v end,
  -- Sizes the trim-scan detent (~1/128 of the file) for trim_start/trim_end.
  -- Those are FILE-page params editing the file-editor slot, so the duration
  -- has to come from that slot -- using the playback slot's made the detent
  -- the wrong size whenever the editor was on a different sample.
  get_sample_duration = function()
    local slot = elasticat.file_edit_slot ~= nil and elasticat.file_edit_slot()
      or (elasticat.active_pool_slot ~= nil and elasticat.active_pool_slot()) or 1
    local meta = elasticat.pool_meta ~= nil and elasticat.pool_meta(slot) or {}
    return meta.duration or 0
  end,
  active_step_lock_bases = active_step_lock_bases,
  active_step_lock_ids = active_step_lock_ids,
  -- Base-value resolver (docs/BASE_VALUE_RESOLVER.md): a firing continuous
  -- p-lock publishes a non-destructive override on the selected track instead of
  -- mutating the track param; returns false for params that keep the destructive
  -- path, so apply_step_param_locks falls back for those.
  set_base_override = elasticat.set_step_override,
  value_flash_until = value_flash_until,
  value_flash_seconds = VALUE_FLASH_SECONDS
})

local function clear_lock_for_slot(slot, all_steps)
  local param_item = ({nav:current_group_items()})[slot]
  if param_item == nil or param_item.lockable ~= true or grid_ui == nil then
    return false
  end

  local lock_id = param_item.lock_id or param_item.id
  local did_clear
  if all_steps then
    did_clear = grid_ui:clear_all_param_locks(lock_id)
  else
    did_clear = grid_ui:clear_held_param_lock(lock_id)
  end
  if did_clear then
    show_message(param_values:item_long_name(param_item) .. " lock clear")
    request_redraw()
  end
  return did_clear
end

-- Held Scene anchor + B2/B3: clear the SELECTED param's scene lock (#43). The
-- pair is resolved from the SAME items list the page renders (current_group_
-- items), so it targets the param under the K2/K3 cursor -- never the generic
-- grid position. Clears the param from BOTH scenes for the SELECTED track only
-- (ui_id funnels to the selected track's full id, the scene key), so it becomes
-- fully un-morphed and holds one value across the fade.
local function clear_scene_lock_for_slot(slot)
  local param_item = ({nav:current_group_items()})[slot]
  if param_item == nil or param_item.lockable ~= true or scene_store == nil then
    return false
  end
  local key = ui_id(param_item.id)
  if not elasticat.param_exists(key) then
    return false
  end
  local cleared = scene_store:clear_key(key)
  if cleared then
    show_message(param_values:item_long_name(param_item) .. " scene lock clear")
    -- The param just left the morph set: drop its crossfader override so the knob
    -- (source 1) takes back control even with the fader idle (BASE_VALUE_RESOLVER).
    elasticat.reconcile_crossfader(scene_store:morph_target_keys())
  end
  request_redraw()
  return cleared
end

local function settings_delta_value(delta)
  local items = nav:settings_items()
  local index = nav.settings_item_index[nav:current_settings_category()] or 1
  local param_item = items[index]
  if param_item == nil then
    return
  end
  -- PROJECT settings rows (master settings page 2, see lib/pages/model.lua and
  -- draw_settings_page() below) carry a `project_row` marker instead of a real
  -- param id -- they're the status row and the Load/Save/Save As New/New
  -- Project action buttons, not adjustable params. E3 (and the grid's
  -- value-delta buttons, which call this same function via the
  -- param_settings_value_delta option) have nothing to change on them;
  -- confirming an action row is K3's job (see key(n,z)'s settings-layer
  -- branch). Falling through to item_raw_value below would error: those rows
  -- have no `.id`, so `params:lookup_param` would be handed a nil suffix.
  if param_item.project_row ~= nil or param_item.razor_action ~= nil or param_item.audio_row ~= nil then
    return   -- action rows (Load/Save, Redistribute/Auto-Chop, audio buffer): no value to edit
  end
  local current = param_values:item_raw_value(param_item)
  elasticat.undo_record_param(param_item)
  param_values:apply_item_value(param_item, param_values:adjusted_value(param_item, current, delta, false))
  param_values:flash_item_value(param_item)
  show_message(param_values:item_long_name(param_item) .. " " .. param_values:item_display_value(param_item))
  -- Editor-pref items (auto-name, live-perf toggles, ...) don't live in a
  -- project, so persist them to the fixed prefs file the instant they change on
  -- a settings page -- otherwise the new value would only survive if the script
  -- exited cleanly through cleanup().
  if param_item.id ~= nil and EDITOR_PREF_SUFFIXES[param_item.id] then
    save_editor_prefs()
  end
  request_redraw()
end

local function pset_path(n)
  return norns.state.data .. norns.state.shortname .. "-" .. string.format("%02d", n) .. ".pset"
end

local function load_startup_pset()
  local path = pset_path(1)
  if util.file_exists(path) then
    print("elasticat: loading startup pset 1")
    params:read(1)
  end
end

local function active_region()
  if grid_ui ~= nil and grid_ui.active_region ~= nil then
    return grid_ui:active_region()
  end
  return params:get(ui_id("loop_start")) or 0, params:get(ui_id("loop_end")) or 128
end

local function visual_param_value(param_id, fallback)
  local lock_id = param_id
  local step_edit = grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() or nil
  if step_edit ~= nil and grid_ui.held_param_lock ~= nil then
    local held = grid_ui:held_param_lock(lock_id)
    if held ~= nil then
      return held
    end
  end
  if active_step_lock_bases[lock_id] ~= nil then
    return active_step_lock_bases[lock_id]
  end
  -- param_exists, not a bare lookup_param: this resolver is handed to the page
  -- renderers, which ask for ids that need not exist on every page (e.g. the
  -- envelope renderer reads <prefix>hold for all three envelopes, but the mod
  -- env is ADSR-only and has no menv_hold). An unknown id must read as "use
  -- the fallback", never throw and blank the page.
  return elasticat.param_exists(ui_id(param_id)) and params:get(ui_id(param_id)) or fallback
end

-- `track` defaults to the selected one. A background track passes its own
-- index so its "return" release resolves against ITS region, rate and sample
-- rather than whatever happens to be on screen.
local function loop_phase_rate(start_point, end_point, track)
  track = track or elasticat.selected_track or 1
  local function tid(suffix) return elasticat.track_pid(track, suffix) end
  start_point = start_point or params:get(tid("loop_start")) or 0
  end_point = end_point or params:get(tid("loop_end")) or 128
  -- Rate must reflect the region *as played* -- range + trim mapped -- not the
  -- Track width, or a narrowed range makes the playhead crawl (looks like it
  -- doesn't match the audio).
  local eng_start, eng_end = start_point, end_point
  if elasticat.map_region ~= nil then
    eng_start, eng_end = elasticat.map_region(start_point, end_point, track)
  end
  local region = math.max(0.01, eng_end - eng_start) / 128
  -- Use the SELECTED TRACK's slot steps/bpm from the pool, not the sample_*
  -- params (which follow the File-editor slot), so the playhead rate matches
  -- what that track is playing even while another slot is being edited.
  -- Phase 2: this is per-track via the `sample_slot` suffix in the id funnel --
  -- on track 1 it resolves to the same slot elasticat.active_steps() returns,
  -- so single-track behavior is unchanged.
  local track_meta = elasticat.ui_sample_meta(track)
  local active_steps = track_meta.steps
    or (elasticat.active_steps ~= nil and elasticat.active_steps())
    or params:get(id("sample_steps"))
  local steps = math.max(1, active_steps or 16)
  local loop_beats = math.max(0.03125, (steps / 4) * region)

  -- Only tape (warp mode 1) drives its phase from pitch + source BPM (varispeed).
  -- Every other warp mode reads the tempo-locked transport phase, so pitch does
  -- NOT change its playhead rate -- using source_bpm*pitch there made the visual
  -- playhead speed up (e.g. PC mode) while the audio stayed put.
  local mode = elasticat.param_exists(tid("mode")) and params:get(tid("mode")) or 1
  if params:get(tid("machine")) == 1 and mode == 1 then
    local active_bpm = track_meta.bpm
      or (elasticat.active_bpm ~= nil and elasticat.active_bpm())
      or params:get(id("sample_bpm"))
    -- derived_bpm is the engine's own measurement, reported per track.
    local derived = status.derived_bpm[track] or 0
    local bpm = derived > 0 and derived or active_bpm
    local pitch_ratio = math.pow(2, (params:get(tid("pitch")) or 0) / 12)
    return (bpm / 60 / loop_beats) * pitch_ratio
  end

  local base_rate = (params:get(id("target_bpm")) or 120) / 60 / loop_beats
  if params:get(tid("machine")) == 1 and mode == 2 then
    -- tempo_varispeed now varispeeds audio-side too (pitch drifts the read
    -- position off the transport, PRD §8): scale the visual playhead the same
    -- way so it tracks what's heard.
    return base_rate * math.pow(2, (params:get(tid("pitch")) or 0) / 12)
  end
  return base_rate
end

-- +1 forward, -1 when loop reverse is on, so the visual playhead travels the
-- same direction as the audio.
local function playhead_direction(track)
  -- track_pid, not ui_id: a background track must read ITS OWN loop_reverse.
  local rid = elasticat.track_pid(track or elasticat.selected_track or 1, "loop_reverse")
  if elasticat.param_exists(rid) and params:get(rid) == 1 then
    return -1
  end
  return 1
end

-- The playhead position to DRAW, 0..1: the selected track's anchor dead
-- reckoned forward at the selected track's own loop rate. On the module table
-- alongside visual_phase/visual_phase_time (they are one family) -- which also
-- keeps a file-scope local free, and the main chunk is at LuaJIT's 200 ceiling.
elasticat.display_phase = function(track)
  -- No argument = the SELECTED track, which is what the screen draws (one
  -- playhead, by design). The sequencer passes a track so a BACKGROUND track
  -- can resolve its own trig_release "return" position.
  local sel = track == nil
  track = track or elasticat.selected_track or 1
  local phase = elasticat.visual_phase(track)
  local previewing = grid_ui ~= nil and grid_ui.preview_active == true
  if not playing and not previewing then
    return phase
  end

  -- The on-screen (selected) track gets a live 15Hz engine phase feed while the
  -- transport plays -- use it DIRECTLY. The engine's true rate carries a dynamic
  -- clock `correction` the Lua dead-reckon can't know, so reckoning on top always
  -- diverged and each report yanked it back (a constant wobble). The norns screen
  -- only refreshes at 15Hz anyway, so interpolating buys nothing here. Dead-reckon
  -- is still used where there is NO live feed: a stopped preview (no transport),
  -- or a background track the sequencer resolves for trig_release.
  if sel and playing then
    return phase
  end

  local elapsed = util.time() - elasticat.visual_phase_time(track)
  local start_point, end_point
  if sel then
    start_point, end_point = active_region()
  else
    -- active_region() reads the grid's live loop-key override, which only
    -- applies to the selected track; a background track uses its own params.
    start_point = params:get(elasticat.track_pid(track, "loop_start")) or 0
    end_point = params:get(elasticat.track_pid(track, "loop_end")) or 128
  end
  return (phase
    + (playhead_direction(track) * elapsed
       * loop_phase_rate(start_point, end_point, track))) % 1
end

-- `track` defaults to the selected one. This is what trig_release "return"
-- resolves against, so a background track passing its own index is the whole
-- difference between "return" working and silently degrading to "reset".
local function position_at_region(start_point, end_point, at_time, track)
  track = track or elasticat.selected_track or 1
  local elapsed = (at_time or util.time()) - elasticat.visual_phase_time(track)
  local unwrapped = elasticat.visual_phase(track)
    + (playhead_direction(track) * elapsed * loop_phase_rate(start_point, end_point, track))
  local nearest = math.floor(unwrapped + 0.5)
  local phase
  if nearest == 1 and math.abs(unwrapped - nearest) < 0.01 then
    phase = 1
  else
    phase = unwrapped % 1
  end
  return start_point + ((end_point - start_point) * phase)
end

local function draw_page_header(title, page_number)
  local grid_status = nil
  local ghost = false
  if grid_ui ~= nil then
    if grid_ui.screen_status ~= nil then
      grid_status = grid_ui:screen_status()
    end
    if grid_ui.held_step_is_ghost ~= nil then
      ghost = grid_ui:held_step_is_ghost()
    end
  end

  -- Per-track meter (Phase 2): the header shows the SELECTED track's level.
  -- Both values are nil for a track the engine is not currently reporting,
  -- which Header.draw_meter renders as an empty meter -- never as some other
  -- track's audio.
  local level_l, level_r = elasticat.track_level(elasticat.selected_track or 1)

  -- DSP overload warning (see Header.draw): shown only while a FRESH report is
  -- hot, so a stale reading from before a stop can't pin the warning on.
  local cpu_hot = nil
  local cpu = elasticat.cpu_report
  if cpu ~= nil and cpu.peak >= 80 and (util.time() - (cpu.time or 0)) < 6 then
    cpu_hot = math.floor(cpu.peak + 0.5)
  end

  Header.draw({
    track = elasticat.selected_track or 1,
    ghost = ghost,
    -- A muted track is silent downstream of the meter, so the header says so.
    muted = grid_ui ~= nil and grid_ui.track_muted ~= nil
      and grid_ui:track_muted(elasticat.selected_track or 1) or false,
    -- A latched jack frame-time stall outranks every other message: the clock
    -- is dead and only a reboot fixes it (see the watchdog in lib/elasticat).
    message = (elasticat.clock_stalled and "CLOCK STALLED - REBOOT")
      or visible_message() or grid_status or title or "ELASTICAT",
    tempo = param_value_or("target_bpm", 120),
    cpu_hot = cpu_hot,
    amp_l = level_l,
    amp_r = level_r,
    page = page_number or 1
  })
end

-- Elektron-style renderer for the generic param pages (lib/ui/page_render.lua):
-- 2x4 label/value/bar cells + per-category widgets (filter curve, env sketches,
-- FX identity). Pure rendering -- it reads through param_values/param_value_or
-- only. Constructed at file scope (like source_page below) to stay clear of
-- init()'s 60-upvalue limit.
local page_render = include("lib/ui/page_render").new({
  param_values = param_values,
  value = param_value_or,
  -- FN held: low-profile cells swap their NAME for their VALUE (owner), a quick
  -- "what's this set to" readout without leaving the page. Either FN source counts.
  fn_held = fn_active,
  -- The RESOLVED base (a firing step p-lock / morph overriding the track value)
  -- for the filter curve to follow during playback, matching the low-profile
  -- actual bar. nil-safe: returns the track value when nothing overrides.
  resolved_value = function(suffix) return elasticat.resolved_value(suffix) end,
  display_values = function(item, raw) return elasticat.param_display_values(item, raw) end,
  mod_offsets = function()
    return elasticat.mod_offset_for("filter_cutoff"), elasticat.mod_offset_for("filter_res")
  end,
  filter_names = FilterRegistry.names(),
  fx_names = FxRegistry.names()
})

local source_page = SourcePage.new({
  elasticat = elasticat,
  MachineRegistry = MachineRegistry,
  ParamRenderer = ParamRenderer,
  param_values = param_values,
  nav = nav,
  param_value_or = param_value_or,
  sample_name = sample_name,
  draw_page_header = draw_page_header,
  active_waveform = active_waveform,
  active_region = active_region,
  -- True while a held loop-key / firing-step region is OVERRIDING the base loop, so
  -- the waveform shade knows when to follow active_region() vs the live loop knobs.
  active_region_override = function()
    return grid_ui ~= nil and grid_ui.region_is_override ~= nil and grid_ui:region_is_override()
  end,
  active_range = function() return elasticat.active_range() end,
  get_playing = function() return playing end,
  display_phase = elasticat.display_phase,
  visual_param_value = visual_param_value,
  -- Selected-track id funnel (Phase 1): the source page's per-track reads
  -- (slice_count) follow the selection; globals pass through unchanged.
  id = ui_id,
  get_alt = fn_active,
  get_last_trim_focus = function() return last_trim_focus end,
  -- Slices currently sounding on the selected track (sequenced while playing +
  -- live grid holds), for the waveform to light up which slice is playing.
  active_slices = function()
    return grid_ui ~= nil and grid_ui.active_slices ~= nil and grid_ui:active_slices() or {}
  end,
  -- A slice's [start, end] in 0-128 for the waveform boundaries: equal divisions
  -- (Grid) or the razor points (Razor). Selected track.
  slice_bounds = function(slice)
    return elasticat.seq_slice_range(elasticat.engine_track(), slice)
  end,
  -- The slice the Razor editor is editing, so the waveform marks its Start/End.
  selected_slice = function()
    return grid_ui ~= nil and grid_ui.get_selected_slice ~= nil and grid_ui:get_selected_slice() or 1
  end,
  -- Razor Zoom mode: the last-edited razor point (0-128) to centre the FN
  -- magnification on, and the current SNAP mode (only Zoom/friends zoom).
  get_razor_focus = function() return elasticat.razor_focus_pos end,
  get_slice_snap = function() return math.floor((param_value_or("slice_snap", 1)) + 0.5) end
})

-- ---- MIX overview page (master category, page 2) ---------------------------
-- Builds the 8 track descriptors lib/ui/mixer_page.lua renders. Everything is
-- resolved through ParamsSpec.track_id, so a suffix moving into
-- ParamsSpec.SPEC turns that column per-track with no change here -- and
-- param_exists (never a bare lookup_param, which THROWS on norns) means a
-- suffix that is not per-track yet just reads as the shared value instead of
-- blanking the page.
-- Module table, not a local: the main chunk is at LuaJIT's 200-local ceiling.
-- On the module table rather than a file-scope `local MixerPage = ...`: the
-- main chunk is AT LuaJIT's 200-local ceiling and one more local fails to
-- compile the whole script.
elasticat.MixerPage = include("lib/ui/mixer_page")

elasticat.mixer_track_value = function(track, suffix, fallback)
  local pid = ParamsSpec.track_id(track, suffix, PREFIX)
  if not elasticat.param_exists(pid) then
    return fallback
  end
  return params:get(pid) or fallback
end

-- The MIX page's bottom param strip: label + display value for each of the
-- page's items, with the active K2/K3 pair flagged. Values resolve through
-- param_values, which already applies the ui_id funnel -- so the strip shows
-- the SELECTED track's numbers, and E2/E3 edit exactly what it displays.
elasticat.mixer_strip = function(items, group)
  local strip = {}
  local sel_lo = ((group or 1) - 1) * 2 + 1
  for i, param_item in ipairs(items or {}) do
    if not param_item.blank then
      strip[#strip + 1] = {
        label = param_item.short or param_item.id,
        value = param_values:item_display_value(param_item),
        selected = i == sel_lo or i == sel_lo + 1
      }
    end
  end
  return strip
end

elasticat.mixer_tracks = function()
  local out = {}
  local count = param_value_or("active_track_count", 1)
  local selected = elasticat.selected_track or 1
  for track = 1, ParamsSpec.TRACK_COUNT_MAX do
    local level_l, level_r = elasticat.track_level(track)
    local level_frac = nil
    if level_l ~= nil then
      -- Peak of the two channels, on the same 0..1 scale the bars want.
      level_frac = util.clamp(math.max(level_l, level_r or 0), 0, 1)
    end
    out[track] = {
      active = track <= count,
      selected = track == selected,
      muted = elasticat.track_muted ~= nil and elasticat.track_muted(track) == true,
      machine = math.floor((elasticat.mixer_track_value(track, "machine", 1)) + 0.5),
      slot = math.floor((elasticat.mixer_track_value(track, "sample_slot", 0)) + 0.5),
      vol_frac = util.clamp(elasticat.mixer_track_value(track, "amp", 0) / 127, 0, 1),
      level_frac = level_frac,
      has_content = grid_ui ~= nil and grid_ui.track_has_content ~= nil
        and grid_ui:track_has_content(track) or false,
      position_frac = grid_ui ~= nil and grid_ui.track_progress ~= nil
        and grid_ui:track_progress(track) or nil
    }
  end
  return out
end

local function draw_root_page()
  local page, page_index, model = nav:current_page()
  local title = page.title or model.title or "ELASTICAT"

  if page.animation then
    draw_visualizer_page()  -- full-screen looping sprite, no header/UI
    return
  end

  if page.mixer then
    -- The mixer is the "what is my kit doing" page, so it carries the standing
    -- CPU readout (avg/peak% from /elasticat/cpu; the header only warns when
    -- hot). Composed into the title -- the header layout stays untouched.
    local cpu = elasticat.cpu_report
    if cpu ~= nil then
      title = string.format("%s CPU %d/%d%%", title,
        math.floor(cpu.avg + 0.5), math.floor(cpu.peak + 0.5))
    end
    draw_page_header(title, page_index)
    elasticat.MixerPage.draw(elasticat.mixer_tracks(),
      elasticat.mixer_strip(page_items_for("master", page, page_index), nav:clamp_current_group()))
    return
  end

  local items = page_items_for(nav:current_category(), page, page_index)

  if nav:current_category() == "file" then
    source_page:draw_file_page(page, items)
    return
  end

  if nav:current_category() == "source" and (page_index == 1 or page_index == 4) then
    source_page:draw_sample_page(page, items)
    return
  end

  if nav:current_category() == "filter" and page_index == 1 then
    -- Owner low-profile filter redesign (elasticat-design-images/filterDesign.png).
    draw_page_header(title, page_index)
    page_render:draw_filter_page(items, nav:clamp_current_group(), playing)
    return
  end

  if nav:current_category() == "amp" and page_index == 1 then
    draw_page_header(title, page_index)
    page_render:draw_amp_page(items, nav:clamp_current_group())
    return
  end

  if nav:current_category() == "mod" and page_index == 3 then
    draw_page_header(title, page_index)
    page_render:draw_mod_env_page(items, nav:clamp_current_group())
    return
  end

  if nav:current_category() == "filter" and page_index == 2 then
    -- Filter envelope, same low-profile treatment: params top and bottom,
    -- envelope drawn on the filter render's 2px bar grid between them.
    draw_page_header(title, page_index)
    page_render:draw_filter_env_page(items, nav:clamp_current_group())
    return
  end

  -- Mode-Parameter pages (owner redesign): FILTER MIX, the WARP page, and the FX
  -- slot pages (Insert 1 / Send 1 / Send 2 / Master) all curate their items so the
  -- machine/mode selector is a `mode_param` banner at item 9. Any such page renders
  -- with the shared two-row + banner layout. This runs after the category-specific
  -- dispatches above, none of which put a mode_param at item 9 -- so the single
  -- check covers every current and future Mode-Parameter page. (The FX SENDS page,
  -- page 2, has no banner and falls through to the generic renderer below.)
  if items[9] ~= nil and items[9].mode_param == true then
    draw_page_header(title, page_index)
    page_render:draw_mode_param_page(items, nav:clamp_current_group(), playing)
    -- FX slot pages with Comp (6) or Duck (14): overlay the live gain-reduction /
    -- level meter. It positions ITSELF in the free wedge right of the banner /
    -- above the MIX cell (page_render's FMIX_METER_*) -- passing a position from
    -- here is what once put it over the parameter rows. Each page reads ITS OWN
    -- meter id (insert = the selected track; Send 1/2 / Master = 101/102/103), so
    -- simultaneous instances never mix on screen. Draw only while the feed is
    -- fresh. Duck's natural home is a send return, which is exactly pages 3/4.
    if nav:current_category() == "fx" then
      local slots = {
        [1] = {machine = "fx_insert1_machine", meter = elasticat.selected_track},
        [3] = {machine = "send1_machine", meter = 101},
        [4] = {machine = "send2_machine", meter = 102},
        [5] = {machine = "master_fx_machine", meter = 103}
      }
      local slot = slots[page_index]
      if slot ~= nil then
        local fx_machine = math.floor(param_value_or(slot.machine, 1) + 0.5)
        local m = elasticat.fx_meter ~= nil and elasticat.fx_meter[slot.meter] or nil
        if (fx_machine == 6 or fx_machine == 14 or fx_machine == 19) and m ~= nil
          and (util.time() - (m.t or 0)) < 0.3 then
          -- COMP + LIMIT show the threshold/ceiling tick; DUCK has no threshold.
          page_render:draw_fx_meter(m.key, m.gr, m.thresh,
            fx_machine == 6 or fx_machine == 19)
        end
      end
    end
    return
  end

  draw_page_header(title, page_index)
  page_render:draw(nav:current_category(), page_index, items, nav:clamp_current_group())
end

-- JACK buffer control for the AUDIO INTERFACE settings page (master page 3).
-- On the module table, not a file local (elasticat.lua is at LuaJIT's 200-local
-- ceiling -- see [[elasticat-luajit-limits-and-param-guard]]).
elasticat.AudioBuffer = include("lib/audio_buffer")

-- ---- PROJECT settings page (master settings, page 2; PRD §7) --------------
-- lib/pages/model.lua's master.settings page 2 rows carry a `project_row`
-- marker (status / load / save / save_as / new) instead of a real param id,
-- so they bypass ParamValues entirely here (it assumes every item resolves to
-- a norns param via params:lookup_param) -- both for reading their display
-- value and for invoking their action. The one real param on that page,
-- AUTO-NAME (project_auto_name), has no `project_row` and flows through the
-- normal param_values path below, same as every item on every other settings
-- page.

-- Right-column text for a settings row: the live project name (+ "*" while
-- unsaved) for the status row, "K3" as the confirm hint for action rows, and
-- the normal ParamValues-rendered value for everything else (incl. AUTO-NAME).
local function project_settings_row_value(param_item)
  if param_item.project_row == "status" then
    if project_store == nil then
      return ""
    end
    local name = project_store:current_name() or "untitled"
    return project_store:is_unsaved() and (name .. " *") or name
  elseif param_item.audio_row == "status" then
    return elasticat.AudioBuffer.status_label()
  elseif param_item.audio_row ~= nil or param_item.project_row ~= nil or param_item.razor_action ~= nil then
    return "[ ]"  -- clickable: press YES / B3 / Right arrow to activate
  end
  return param_values:item_display_value(param_item)
end

-- Action buttons (the "[ ]" rows: razor redistribute/auto-chop/recalc, project
-- load/save/new) flash a filled checkbox for ~1s when they run, so a one-shot
-- function gives clear "it executed" feedback (owner). Keyed by the action name.
-- On the module table (not file locals) -- the coordinator is at LuaJIT's
-- 200-local ceiling. See [[elasticat-luajit-limits-and-param-guard]].
elasticat.action_flash = {}
elasticat.flash_action = function(param_item)
  local key = param_item ~= nil and (param_item.razor_action or param_item.project_row or param_item.audio_row) or nil
  if key == nil then
    return
  end
  elasticat.action_flash[key] = util.time() + 1
  request_redraw()
  -- The settings page is not on the playback redraw loop, so schedule the clear.
  if clock ~= nil and clock.run ~= nil then
    clock.run(function() clock.sleep(1.05); request_redraw() end)
  end
end
elasticat.action_flashing = function(param_item)
  local key = param_item ~= nil and (param_item.razor_action or param_item.project_row or param_item.audio_row) or nil
  return key ~= nil and (elasticat.action_flash[key] or 0) > util.time()
end

-- The action-button checkbox at the right of a settings row: a 6x5 hollow box,
-- filled with a small 2x1 centre mark (separated from the border) for ~1s after
-- it executes -- the visual confirmation of a one-shot function.
elasticat.draw_action_checkbox = function(param_item, y, level)
  local bx, by = 121, y - 6
  screen.level(level or 5)
  screen.rect(bx, by, 6, 1)
  screen.fill()
  screen.rect(bx, by + 4, 6, 1)
  screen.fill()
  screen.rect(bx, by, 1, 5)
  screen.fill()
  screen.rect(bx + 5, by, 1, 5)
  screen.fill()
  local marked = elasticat.action_flashing(param_item)
  if not marked and param_item.audio_row ~= nil then
    -- persistent fill on the buffer choice that boots next (the active target)
    local period = tonumber((param_item.audio_row):match("buf_(%d+)"))
    marked = period ~= nil and elasticat.AudioBuffer.is_target(period)
  end
  if marked then
    screen.level(15)
    screen.rect(bx + 2, by + 2, 2, 1)
    screen.fill()
  end
end

-- K3 on a selected PROJECT action row invokes the matching do_project_*()
-- (already defined above, PRD §7.1 -- reused as-is, not reimplemented).
-- Returns true iff `param_item` was an action row (so the caller in key(n,z)
-- knows to swallow the keypress instead of moving the settings cursor); false
-- for every other item, including the status row (informational only) and
-- ordinary settings items (whose K3 stays "move selection down", unchanged).
local function invoke_project_settings_action(param_item)
  if param_item == nil then
    return false
  end
  -- Source-settings razor action rows (Increment B): Redistribute / Auto-Chop.
  if param_item.razor_action == "redistribute" then
    elasticat.razor_redistribute()
    elasticat.flash_action(param_item)
    return true
  elseif param_item.razor_action == "autochop" then
    elasticat.razor_autochop()
    elasticat.flash_action(param_item)
    return true
  elseif param_item.razor_action == "recalc" then
    -- File-page RECALC button: recompute BPM + the trimmed-portion step count.
    elasticat.recalc_bpm_steps()
    show_message("Recalc BPM/steps")
    elasticat.flash_action(param_item)
    return true
  end
  -- AUDIO INTERFACE rows (master settings page 3): JACK buffer headroom. STATUS
  -- re-reads + reports; DEFAULT/HEADROOM/MAX set -p 128/256/512 via the helper
  -- (reversible, applies on the next SLEEP->wake).
  if param_item.audio_row ~= nil then
    if param_item.audio_row == "status" then
      elasticat.AudioBuffer.refresh()
      show_message("Buffer: " .. elasticat.AudioBuffer.status_label())
    else
      local period = tonumber((param_item.audio_row):match("buf_(%d+)"))
      if period ~= nil then
        local ok, msg = elasticat.AudioBuffer.apply(period)
        show_message(ok and ("Buffer " .. msg) or ("Buffer: " .. msg))
        if ok then elasticat.flash_action(param_item) end
      end
    end
    return true
  end
  if param_item.project_row == nil then
    return false
  end
  if param_item.project_row == "load" then
    do_project_load()
  elseif param_item.project_row == "save" then
    do_project_save()
  elseif param_item.project_row == "save_as" then
    do_project_save_as()
  elseif param_item.project_row == "new" then
    do_project_new()
  elseif param_item.project_row == "status" then
    do_project_rename()  -- the name row: YES/Right opens the rename dialog
  else
    return false
  end
  if param_item.project_row ~= "status" then
    elasticat.flash_action(param_item)
  end
  return true
end

-- Resident settings-layer focus handler (lib/input/router.lua), registered
-- once from init(). Active only while nav.settings_layer is open -- otherwise
-- every action falls through and the base surfaces behave as if the router
-- weren't there. This is the ONE place the settings key map lives:
--   confirm (K3 / grid YES)     invoke the selected action row (LOAD/SAVE/..)
--   cancel  (K2 / grid NO)      exit settings
--   up/down (grid arrows) / E2  move the selection (crosses pages)
--   left/right (grid arrows)    change the value; on an action row,
--                               right = confirm (same as K3/YES)
--   E3                          change the value
--   E1                          switch settings category (FN+E1 left exits)
-- (Registered at file scope, below its definition, rather than from init():
-- keeps init() under LuaJIT's 60-upvalue function limit. Registration at load
-- time is safe -- the handler is inert until nav.settings_layer opens.)
local function register_settings_focus_handler()
  input_router:push_focus({
    name = "settings_layer",
    on_action = function(action, value)
      if nav == nil or not nav.settings_layer then
        return false
      end
      -- While the norns file browser (Load) owns the screen, swallow grid nav
      -- keys so a stray NO/Left doesn't silently close the settings layer
      -- underneath it -- otherwise cancelling the browser (K2) would land on
      -- the master page instead of returning to the PROJECT settings page.
      if browsing then
        return true
      end
      local function selected_item()
        local items = nav:settings_items()
        return items[nav.settings_item_index[nav:current_settings_category()] or 1]
      end
      if action == "cancel" then
        nav:close_param_settings()
      elseif action == "confirm" then
        invoke_project_settings_action(selected_item())
      elseif action == "up" then
        nav:settings_select_delta(-1)
      elseif action == "down" then
        nav:settings_select_delta(1)
      elseif action == "select_delta" then
        nav:settings_select_delta(value or 0)
      elseif action == "left" then
        settings_delta_value(-1)
      elseif action == "right" then
        if not invoke_project_settings_action(selected_item()) then
          settings_delta_value(1)
        end
      elseif action == "value_delta" then
        settings_delta_value(value or 0)
      elseif action == "page_delta" then
        -- Preserve the FN+E1-leftward "close settings" gesture; a plain E1
        -- walks every settings page across all categories (so norns-only users
        -- can reach master's PROJECT page). fn_active(): the grid FN counts too,
        -- not just norns K1 -- one FN source of truth.
        if fn_active() and (value or 0) < 0 then
          nav:close_param_settings()
        else
          nav:settings_page_or_category_delta(value or 0)
        end
      else
        return false
      end
      request_redraw()
      return true
    end
  })
end

register_settings_focus_handler()

local function draw_settings_page()
  local category = nav:current_settings_category()
  local model = nav:category_model(category)
  local page = nav:current_settings_page()
  draw_page_header((page.title or model.title or category) .. " SETTINGS", 1)

  local items = nav:settings_items()
  if #items == 0 then
    screen.level(4)
    screen.move(0, 34)
    screen.text("empty")
    return
  end

  local selected = util.clamp(nav.settings_item_index[category] or 1, 1, #items)
  nav.settings_item_index[category] = selected
  local first = util.clamp(selected - 2, 1, math.max(1, #items - 4))

  for row = 0, 4 do
    local index = first + row
    local param_item = items[index]
    if param_item ~= nil then
      local y = 20 + (row * 9)
      screen.level(index == selected and 15 or 5)
      screen.move(0, y)
      screen.text(index == selected and ">" or " ")
      screen.move(10, y)
      if param_item.project_row == "status" or param_item.audio_row == "status" then
        -- The status row shows ONLY its summary (project name, or the live/next
        -- JACK buffer), full width -- a short label collided with long values.
        screen.text_trim(project_settings_row_value(param_item), 118)
      else
        -- Action rows show a graphical checkbox on the right (fills for ~1s when
        -- run, or persistently for the active audio-buffer choice); their label
        -- gets the wide column. Ordinary rows keep room for their value.
        local action_row = param_item.project_row ~= nil or param_item.razor_action ~= nil
          or param_item.audio_row ~= nil
        screen.text_trim(param_item.short or param_item.id, action_row and 100 or 42)
        if action_row then
          elasticat.draw_action_checkbox(param_item, y, index == selected and 15 or 5)
        else
          screen.move(128, y)
          screen.text_right(project_settings_row_value(param_item))
        end
      end
    end
  end
end

set_playing = function(state, reset_transport)
  reset_transport = reset_transport == true
  -- Starting master transport cancels any File-page sample preview (silently --
  -- the transport is about to drive the engine's play state itself).
  if state and params:lookup_param(id("sample_preview")) ~= nil and params:get(id("sample_preview")) == 1 then
    params:set(id("sample_preview"), 0, true)
  end
  local frozen_phase = playing and elasticat.display_phase() or elasticat.visual_phase()
  if not state and loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
    loop_trig_gate_token = loop_trig_gate_token + 1
  end
  playing = state
  if reset_transport then
    reset_visual_phase()
  elseif not playing then
    set_visual_phase(frozen_phase)
  else
    -- Starting the transport re-anchors EVERY track's dead reckoning to now;
    -- anchoring only the selected one left the others reckoning from a stale
    -- timestamp, so switching to them mid-playback showed a playhead that had
    -- "run ahead" by however long the script had been sitting stopped.
    for track = 1, ParamsSpec.TRACK_COUNT_MAX do
      status.phase_time[track] = util.time()
    end
  end
  params:set(id("play"), playing and 1 or 0, true)
  print("elasticat: K3/play state " .. tostring(playing and 1 or 0))
  if not reset_transport then
    -- Transport is GLOBAL: hand elasticat.play the raw state and let it gate EACH
    -- track's reader by that track's own machine. Pre-gating by the selected
    -- track's machine (machine_is_continuous) silenced every loop track whenever
    -- a slice track was the editing focus (e.g. a slice on track 1, loop on 2).
    elasticat.play(playing, true)
  end
  if grid_ui ~= nil then
    grid_ui:set_transport(playing, reset_transport)
  end
  if reset_transport then
    elasticat.stop_reset()
    reset_visual_phase()
  end
  -- Projects (PRD §7.2): the playing->stopped transition is one of the two
  -- explicit temp-project-autosave triggers (the other is the debounce in
  -- request_redraw/mark_project_dirty). save_temp_project_now is a no-op
  -- before project_store exists (early init) or if this call is actually a
  -- transition TO playing.
  if not playing then
    save_temp_project_now()
  end
  request_redraw()
end

local function trigger_loop_region(start_point, end_point, options)
  if loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
  end

  loop_trig_gate_token = loop_trig_gate_token + 1
  local token = loop_trig_gate_token
  elasticat.set_loop_region(start_point, end_point, 0)
  elasticat.play(true)

  local length_seconds = options.length_seconds or 0
  if length_seconds > 0 then
    loop_trig_gate_clock = clock.run(function()
      clock.sleep(length_seconds)
      if token == loop_trig_gate_token and playing and params:get(id("machine")) == 2 then
        elasticat.play(false)
      end
    end)
  end
end

-- ---- Per-track sequencer sinks ---------------------------------------------
-- Every callback the per-track sequencers write through takes the TRACK as its
-- first argument. That is the structural half of "a sequencer cannot P-Lock
-- other tracks' parameters": a step lock's only exit is
-- elasticat.seq_apply_locks(track, locks), which resolves ids with
-- elasticat.track_pid(track, suffix) -- the selected-track ui_id funnel is not
-- reachable from here at all.
--
-- Module-table functions, not file-scope locals: this chunk is AT LuaJIT's
-- 200-local ceiling and init() at its 60-upvalue ceiling.

-- Locks that are consumed by the sequencer or layered by it, never written to
-- a param (mirrors ParamValues:apply_param_lock_value, which owns the same
-- list for the selected track's display bookkeeping).
elasticat.SEQ_UNWRITABLE_LOCKS = {
  length = true, velocity = true,
  loop_start = true, loop_end = true, range_start = true, range_end = true,
  env_reset = true, lfo_reset = true, filter_reset = true,
  trig_jump = true, trig_release = true
}

-- Track -> {lock_id -> base value} stashed when a lock first takes hold, so it
-- can be restored when the lock's window elapses. Per track, so track 3's
-- bases can never be written back onto track 1.
elasticat.seq_lock_bases = {}

elasticat.seq_apply_locks = function(track, locks)
  track = math.floor((tonumber(track) or 1) + 0.5)
  -- The SELECTED track additionally drives the UI's step-lock display
  -- bookkeeping (which value a page shows while a lock is active). That is a
  -- display concern and it resolves the SAME ids, because ui_id(suffix) is by
  -- definition track_id(selected, suffix).
  if track == (elasticat.selected_track or 1) and param_values ~= nil then
    param_values:apply_step_param_locks(locks)
    -- Send the just-applied step p-locks (esp. filter cutoff) to the engine NOW,
    -- so they land BEFORE this step's slice/loop trigger instead of ~80ms later
    -- (the coalesced queue) -- which made each slice "bloop" to its new cutoff.
    elasticat.flush_engine_sends()
    return
  end
  locks = locks or {}
  local bases = elasticat.seq_lock_bases[track]
  if bases == nil then
    bases = {}
    elasticat.seq_lock_bases[track] = bases
  end
  for lock_id, base in pairs(bases) do
    if locks[lock_id] == nil then
      local pid = elasticat.track_pid(track, lock_id)
      if elasticat.param_exists(pid) then
        params:set(pid, base)
      end
      bases[lock_id] = nil
    end
  end
  for lock_id, value in pairs(locks) do
    if not elasticat.SEQ_UNWRITABLE_LOCKS[lock_id] then
      local pid = elasticat.track_pid(track, lock_id)
      if elasticat.param_exists(pid) then
        if bases[lock_id] == nil then
          bases[lock_id] = params:get(pid)
        end
        params:set(pid, value)
      end
    end
  end
  -- Background track: same reason -- send the p-locks before the trigger.
  elasticat.flush_engine_sends()
end

elasticat.seq_selected = function(track)
  return math.floor((tonumber(track) or 1) + 0.5) == (elasticat.selected_track or 1)
end

elasticat.seq_set_pitch = function(track, value)
  if elasticat.seq_selected(track) then
    elasticat.set_pitch(value)
    return
  end
  elasticat.tr_now(nil, track, "setPitch", value or 0)
end

-- ONE path for every track. The selected/background split below sent tracks
-- 2-8 RAW 0-128 points, because the facade's trim+range mapping was
-- selected-track-only -- so a region lock on a background track addressed the
-- wrong part of its sample whenever that track had a non-default trim or a
-- reduced Range. The facade now takes an explicit `track`, so the branch is
-- gone. set_visual_phase runs for ALL tracks: a background track otherwise
-- never gets a phase anchor, which is what trig_release "return" needs.
elasticat.seq_set_loop_region = function(track, start_point, end_point, reset_playhead)
  elasticat.set_loop_region(start_point, end_point, reset_playhead, track)
  if type(reset_playhead) == "number" then
    set_visual_phase(reset_playhead, track)
  elseif reset_playhead then
    set_visual_phase(0, track)
  end
end

elasticat.seq_set_active_range = function(track, range_start, range_end)
  elasticat.set_active_range(range_start, range_end, track)
end

elasticat.seq_note_on = function(track, seconds)
  elasticat.tr_now(nil, track, "noteOn", seconds or 0.1)
end

elasticat.seq_note_off = function(track)
  elasticat.tr_now(nil, track, "noteOff")
end

elasticat.seq_retrig_note = function(track, seconds)
  elasticat.tr_now(nil, track, "retrigNote", seconds or 0)
end

elasticat.seq_mod_trig = function(track, lfo_on, env_on)
  elasticat.mod_trig(lfo_on, env_on, track)
end

elasticat.seq_release_slice = function(track, slice)
  elasticat.tr_now(nil, track, "releaseSlice", slice)
end

-- track = nil releases every allocated track (transport stop / cleanup).
elasticat.seq_release_all_slices = function(track)
  if track ~= nil then
    elasticat.tr_now(nil, track, "releaseAllSlices")
    return
  end
  for t = 1, elasticat.active_track_count() do
    elasticat.tr_now(nil, t, "releaseAllSlices")
  end
end

elasticat.seq_trigger_slice = function(track, slice, start_point, end_point, options)
  local mode = (elasticat.track_param_value(track, "slice_play_mode") or 1) - 1
  local reverse = elasticat.track_param_value(track, "slice_reverse") == 1
  -- Voicing is the MACHINE now: Slice (3) / Razor (4) are MONO, Slice Poly (5) /
  -- Razor Poly (6) are POLY. A mono voice steals this track's previous slice on
  -- the next trig; poly stacks up to the voice cap.
  local machine = elasticat.track_param_value(track, "machine") or 1
  local mono = (machine == 3 or machine == 4) and 1 or 0
  -- One path: the facade applies THIS track's file-trim/range mapping. The
  -- background branch that used to live here sent raw points (see
  -- seq_set_loop_region above). options.choke is the slice's per-slice choke
  -- group (MPC mute group), resolved per slice by the caller.
  local ratchet = math.max(1, math.min(8, math.floor((tonumber(options.ratchet) or 1) + 0.5)))
  if ratchet > 1 and (tonumber(options.step_seconds) or 0) > 0 then
    -- Ratchet: fire the slice `ratchet` times evenly across the step slot. A Lua
    -- clock (no engine change) so each hit is a fresh voice/attack -- mono steals
    -- the previous (a machine-gun retrigger), poly stacks.
    local interval = options.step_seconds / ratchet
    clock.run(function()
      for r = 1, ratchet do
        elasticat.trigger_slice(slice, start_point, end_point, mode, reverse,
          options.velocity, options.length_seconds, options.pitch, track, options.choke, mono)
        if r < ratchet then clock.sleep(interval) end
      end
    end)
  else
    elasticat.trigger_slice(slice, start_point, end_point, mode, reverse,
      options.velocity, options.length_seconds, options.pitch, track, options.choke, mono)
  end
end

elasticat.seq_trigger_region = function(track, start_point, end_point, options)
  if elasticat.seq_selected(track) then
    trigger_loop_region(start_point, end_point, options)
    return
  end
  -- Loop Trig on a background track: jump its region to the start and open its
  -- amp gate for the note length. (The selected-track path additionally gates
  -- the GLOBAL transport, which is not a per-track thing to do.)
  elasticat.seq_set_loop_region(track, start_point, end_point, 0)
  elasticat.tr_now(nil, track, "noteOn", options.length_seconds or 0.1)
end

-- Grid Slice divides THIS track's loop region; Razor reads the shared split
-- table (still global -- 64 params x 8 tracks is deferred, see params_spec).
elasticat.seq_slice_range = function(track, slice)
  local machine = elasticat.track_param_value(track, "machine") or 1
  if machine == 4 or machine == 6 then   -- Razor + Razor Poly: arbitrary points
    local start_point = params:get(id(string.format("razor_%02d_start", slice)))
    local end_point = params:get(id(string.format("razor_%02d_end", slice)))
    if end_point <= start_point then
      end_point = math.min(start_point + 0.01, 128)
    end
    return start_point, end_point
  end
  local count = math.max(1, elasticat.track_param_value(track, "slice_count") or 16)
  local loop_start = elasticat.track_param_value(track, "loop_start") or 0
  local loop_end = elasticat.track_param_value(track, "loop_end") or 128
  local width = (loop_end - loop_start) / count
  return loop_start + ((slice - 1) * width), loop_start + (slice * width)
end

-- Write a slice's start/end points, for the slice copy/paste "All" gesture. Only
-- Razor / Razor Poly (4/6) have per-slice points (the shared razor split table);
-- Grid divisions are derived from loop_start/end + slice_count, so pasting a
-- region there is a no-op. Returns whether points were written.
elasticat.seq_set_slice_range = function(track, slice, start_point, end_point)
  local machine = elasticat.track_param_value(track, "machine") or 1
  if machine ~= 4 and machine ~= 6 then
    return false
  end
  if end_point <= start_point then
    end_point = math.min(start_point + 0.01, 128)
  end
  params:set(id(string.format("razor_%02d_start", slice)), util.clamp(start_point, 0, 128))
  params:set(id(string.format("razor_%02d_end", slice)), util.clamp(end_point, 0, 128))
  return true
end

local function load_file(path)
  print("elasticat: file browser returned " .. tostring(path))
  browsing = false
  if path ~= "cancel" then
    script_state:save_browser_folder(ScriptState.parent_folder(path))
    if elasticat.load_pool_slot ~= nil then
      -- The browser is opened from the File page, so loads target the file-edit
      -- slot, not the track's playback slot.
      local slot = elasticat.file_edit_slot ~= nil and elasticat.file_edit_slot() or param_value_or("file_slot", 1)
      elasticat.load_pool_slot(slot, path)
    else
      params:set(id("sample"), path)
    end
    value_flash_until.sample = util.time() + VALUE_FLASH_SECONDS
  end
  request_redraw()
end

local function enter_sample_browser(root)
  fileselect.enter(root, load_file, "audio")
  local browser_enc = enc
  enc = function(n, d)
    if n == 3 and playing then
      return
    end
    if browser_enc ~= nil then
      browser_enc(n, d)
    end
  end
end

select_sample = function()
  local folder = script_state:browser_folder()
  browsing = true
  if ScriptState.folder_starts_with(folder, _path.dust) then
    enter_sample_browser(_path.dust)
    fileselect.pushd(folder)
  else
    enter_sample_browser(_path.audio)
  end
end

local function image_path(name)
  return _path.code .. norns.state.shortname .. "/images/" .. name
end

local function start_intro()
  local ok, img = pcall(function()
    return screen.load_png(image_path("q7logoanim.png"))
  end)
  logo_image = (ok and img) or nil
  local ok2, dance = pcall(function()
    return screen.load_png(image_path("dancingcat.png"))
  end)
  dancing_image = (ok2 and dance) or nil
  if grid_ui ~= nil and grid_ui.start_intro ~= nil then
    grid_ui:start_intro()
  end
  intro_start = util.time()
  intro_active = true
end

-- True while the visualizer page is the active view (no settings, no browser).
local function on_visualizer_page()
  if nav.settings_layer or browsing then
    return false
  end
  local page = nav:current_page()
  return page ~= nil and page.animation == true
end

-- Advance the tempo-scaled animation clock and return the current phase. Called
-- once per redraw-metro tick while the visualizer page is showing.
local function advance_anim_phase()
  local now = util.time()
  if not anim_running then
    anim_running = true
    anim_phase = 0
    anim_last = now
    if grid_ui ~= nil and grid_ui.start_sweep_loop ~= nil then
      grid_ui:start_sweep_loop()
    end
  end
  local dt = util.clamp(now - anim_last, 0, 0.25)
  anim_last = now
  local bpm = params:get(id("target_bpm")) or 120
  anim_phase = anim_phase + dt * (bpm / 120)  -- 120 BPM = 1x speed
  return anim_phase
end

draw_visualizer_page = function()
  if dancing_image == nil then
    return
  end
  local frame = math.floor(anim_phase * DANCE_FPS) % DANCE_FRAMES
  screen.display_image_region(dancing_image, frame * DANCE_FRAME_W, 0, DANCE_FRAME_W, DANCE_FRAME_H, 0, 0)
end

local function draw_intro_screen(elapsed)
  screen.clear()
  if logo_image ~= nil then
    local frame = math.floor(elapsed * LOGO_FPS)
    frame = util.clamp(frame, 0, LOGO_FRAMES - 1)
    screen.display_image_region(logo_image, frame * LOGO_FRAME_W, 0, LOGO_FRAME_W, LOGO_FRAME_H, 0, 0)
  else
    -- No spritesheet found: keep the launch from being a blank screen.
    screen.level(15)
    screen.font_face(1)
    screen.font_size(16)
    screen.move(64, 38)
    screen.text_center("elasticat")
  end
  screen.update()
end

local function start_redraw_metro()
  if redraw_metro ~= nil then
    redraw_metro:stop()
  end

  redraw_metro = metro.init(function()
    -- Un-stick FN if the user just exited the norns menu with K1 (see above).
    elasticat.sync_menu_fn_state()
    -- Lazy waveform cache (flagged by active_waveform when a viewed sample isn't
    -- cached and we're stopped): show "Loading..." this tick, do the blocking WAV
    -- read the NEXT tick -- so the message covers the freeze. Runs every tick,
    -- before the intro/visualizer early-returns, so it never starves.
    local wp = elasticat.waveform_pending
    if wp ~= nil and not playing then
      if not wp.shown then
        wp.shown = true
        show_message("Loading...")
        redraw_pending = true
      else
        elasticat.waveform_pending = nil
        cache_sample_waveform(wp.slot, wp.path)
        redraw_pending = true
      end
    end
    -- Play the launch intro (screen logo + grid sweep) before the normal UI.
    if intro_active then
      local elapsed = util.time() - intro_start
      if elapsed < INTRO_DURATION then
        if not browsing and norns.menu.status() == false then
          draw_intro_screen(elapsed)
        end
        if grid_ui ~= nil and grid_ui.draw_intro ~= nil then
          grid_ui:draw_intro(elapsed)
        end
        return
      end
      intro_active = false
      logo_image = nil
      redraw_pending = true
    end
    -- Visualizer page: drive the tempo-scaled sprite + looping grid sweep,
    -- redrawing every frame and taking over the grid (its key handler still
    -- works, so the encoders/grid can navigate away).
    if on_visualizer_page() and norns.menu.status() == false then
      advance_anim_phase()
      redraw()
      if grid_ui ~= nil and grid_ui.draw_sweep_loop ~= nil then
        grid_ui:draw_sweep_loop(anim_phase)
      end
      return
    elseif anim_running then
      anim_running = false
      redraw_pending = true
    end
    -- Expire the header message and force one redraw so it clears even when
    -- stopped (redraw is otherwise gated on redraw_pending).
    if ui_message ~= nil and util.time() >= ui_message_until then
      ui_message = nil
      redraw_pending = true
    end
    if not browsing and norns.menu.status() == false then
      if playing or redraw_pending then
        redraw_pending = false
        redraw()
      end
    end
    if grid_ui ~= nil then
      if text_entry ~= nil and text_entry:is_open() then
        text_entry:grid_redraw(grid_ui.g)
      else
        grid_ui:redraw()
      end
    end
  end, 1 / 30, -1)

  if redraw_metro ~= nil then
    redraw_metro:start()
  end
end

function init()
  elasticat.params({
    prefix = PREFIX,
    name = "elasticat",
    clock_sync = false,
    on_pool_change = function(snapshot, slot, path)
      -- Lazy caching (owner): DON'T read the WAV here -- that froze startup while
      -- a project's whole pool was read. Just invalidate this slot's cache so the
      -- (new or removed) sample re-reads lazily on first view (active_waveform).
      sample_waveforms[slot] = nil
      if elasticat.sample_onsets ~= nil then
        elasticat.sample_onsets[slot] = nil
      end
      if not param_values.applying_step_locks then
        script_state:save_sample_pool_state(snapshot)
      end
      request_redraw()
    end,
    on_sample_slot = function(slot, path)
      -- Lazy caching: no WAV read here either -- the waveform for a track's slot
      -- is read on first view, not on every slot switch.
      if not param_values.applying_step_locks then
        script_state:save_sample_pool_state()
      end
      request_redraw()
    end,
    -- Projects (PRD §7.1): the PROJECT param group's triggers (lib/elasticat.lua)
    -- are thin -- they just call these coordinator callbacks, since
    -- pattern_store/project_store/text_entry/fileselect all live here, not in
    -- the engine-facing facade.
    on_project_load = function() do_project_load() end,
    on_project_save = function() do_project_save() end,
    on_project_save_as = function() do_project_save_as() end,
    on_project_new = function() do_project_new() end,
    -- Track region/range edited while the sequencer runs: route through the
    -- layered resolver (Track / Step-p-lock / Actual) instead of a direct
    -- engine push, so an active step lock keeps shadowing the Track values
    -- until its window elapses -- and a plain edit is heard immediately.
    -- Returns false while stopped: the param action then pushes the engine
    -- directly, exactly as before.
    on_region_edit = function()
      if not playing or grid_ui == nil then
        return false
      end
      grid_ui:refresh_track_region()
      return true
    end,
    -- A/B scene crossfader (PRD §6.6 requirement 2): the MASTER-page `crossfade`
    -- param (lib/elasticat.lua, 0-128) is the single source of truth for the
    -- fader position -- its action lands here and drives the actual morph.
    -- scene_store is assigned further down in this same init(); by the time a
    -- user can move the param (grid or encoder) init() has already finished,
    -- so the upvalue is populated (same idiom as on_project_load above).
    on_crossfade = function(x)
      if scene_store ~= nil then
        elasticat.undo_record_crossfade()
        -- Coalesce every morph write (incl. the immediate params) onto the 12Hz
        -- engine queue for the duration of this apply, so a held glide can't
        -- flood the engine with per-tick sends (see elasticat.tr_now).
        elasticat.morph_active = true
        scene_store:apply(x / 128)
        elasticat.reconcile_crossfader(scene_store:morph_target_keys())
        elasticat.morph_active = false
      end
    end,
    -- Phase 1 track scaffolding: active_track_count changed -- snap the grid's
    -- selected track back inside the new count and refresh the row-4 LEDs.
    on_active_track_count = function(_)
      -- Raising the count allocates engine chains for the newly active tracks,
      -- but a fresh chain knows nothing -- no sample, amp, region or filter --
      -- because param actions only fire on EDIT. Push their stored values now,
      -- or the new track is silent until some unrelated edit happens to reach
      -- it (which reads as "track 2 randomly started working").
      elasticat.sync_tracks()
      -- The scene morph set caches which of its targets are on ACTIVE tracks
      -- (so a fader tick does no param lookups); the count just moved, so drop
      -- it. Values stored for a track that just went inactive stay put -- they
      -- are simply not applied until it comes back.
      if scene_store ~= nil then
        scene_store:invalidate()
      end
      if grid_ui ~= nil and grid_ui.clamp_track_selection ~= nil then
        grid_ui:clamp_track_selection()
      end
      request_redraw()
    end
  })
  -- Capture factory defaults now, while every param is still at its registered
  -- default (before any pset / temp-project load overrides them) so New Project
  -- can restore a true blank slate (PRD §7.1).
  factory_param_defaults = capture_default_param_values()
  load_startup_pset()
  -- Editor prefs (auto-name, clock sync, live-perf toggles, ...) live in their
  -- own fixed file, NOT in any project or the startup pset, and are authoritative
  -- over whatever the pset happened to carry -- so load them last of the param
  -- restores. Projects never touch these (EDITOR_PREF_SUFFIXES is excluded from
  -- project save/reset), so the later temp-project load won't clobber them.
  load_editor_prefs()
  script_state:load_sample_pool_state()
  script_state:load_browser_folder()
  pattern_store = PatternStore.new({
    capture_state = capture_pattern_state,
    apply_state = apply_pattern_state,
    blank_state = blank_pattern_state
  })
  scene_store = SceneStore.new({
    -- FULL per-track param ids, every track at once: one scene is the whole
    -- instrument, and FN+Scene snapshots all active tracks in one press
    -- (docs/PHASE2_CONTRACT.md, multi-track A/B crossfader scenes).
    morph_ids = elasticat.morph_target_ids,
    -- Guarded so a scene that referenced a since-removed param (e.g. the old
    -- macro depth morph targets) is skipped instead of throwing on load.
    get_value = function(full_id)
      return elasticat.param_exists(full_id) and params:get(full_id) or nil
    end,
    -- CAPTURE reads this, not get_value: the crossfader-APPLIED value, so a scene
    -- snapshots what is actually SOUNDING. Morphing publishes a non-destructive
    -- override (it never writes the track param), so mid-morph the track value is
    -- stale -- capturing it clobbered the just-morphed scene with the OTHER
    -- scene's value (owner's A->B->A workflow). crossfader_applied skips the
    -- transient step_override so a firing step lock is never baked into a scene.
    get_applied_value = function(full_id)
      if not elasticat.param_exists(full_id) then
        return nil
      end
      local body = full_id:sub(#PREFIX + 1)
      local track = ParamsSpec.track_of_suffix(body) or 1
      local suffix = body:gsub("^t%d+_", "")
      return elasticat.crossfader_applied(track, suffix, params:get(full_id))
    end,
    -- Base-value model (docs/BASE_VALUE_RESOLVER.md): the morph is SOURCE 2. It
    -- publishes a non-destructive crossfader override (which re-sends the
    -- resolved base through the same 12Hz coalescing queue a params:set action
    -- would) instead of mutating the track param, so the stored bar keeps the
    -- track value the knob owns. Region/range + track-1 hand-registered params
    -- are not resolvable, so those fall back to the old direct params:set.
    set_value = function(full_id, value)
      if not elasticat.param_exists(full_id) then
        return
      end
      local body = full_id:sub(#PREFIX + 1)
      local track = ParamsSpec.track_of_suffix(body) or 1
      local suffix = body:gsub("^t%d+_", "")
      if not elasticat.set_crossfader_override(track, suffix, value) then
        params:set(full_id, value)
      end
    end,
    -- Sparse capture: a param at its registered default is stored only when
    -- the other scene needs a counterpart (see SceneStore:capture). Every
    -- morph target is a controlspec param, so .controlspec.default exists;
    -- pcall-guarded lookup via param_exists keeps unknown ids at nil, which
    -- capture treats as "store unconditionally" -- sparse is an optimisation,
    -- never a correctness gate.
    get_default = function(full_id)
      if not elasticat.param_exists(full_id) then return nil end
      local p = params:lookup_param(full_id)
      return p ~= nil and p.controlspec ~= nil and p.controlspec.default or nil
    end,
    -- Cost control 3, and "lowering active_track_count must not strand stored
    -- values": an inactive track's captured values stay in the scene, they are
    -- simply not applied while that track is off.
    is_active = function(full_id)
      return elasticat.morph_target_of(full_id) <= param_value_or("active_track_count", 1)
    end,
    -- Pre-multi-track project files keyed scenes by BARE suffix. Load them as
    -- TRACK 1 values (which is what they were) rather than letting a bare
    -- suffix land on some other track.
    legacy_key = function(suffix) return PREFIX .. suffix end
  })
  text_entry = TextEntry.new({})
  grid_ui = GridSequencer.new({
    set_playing = set_playing,
    -- ---- Track-first sequencer sinks ----------------------------------------
    -- Each of these takes the TRACK as its first argument; the per-track
    -- sequencers have no track-less variant to call. See the
    -- elasticat.seq_* block above for why that is the p-lock isolation.
    set_loop_region = elasticat.seq_set_loop_region,
    note_on = elasticat.seq_note_on,
    note_off = elasticat.seq_note_off,
    retrig_note = elasticat.seq_retrig_note,
    -- Modulation retrigger (2 LFOs + mod env, MOD category): fired per step
    -- where lfo_reset / env_reset resolve ON (see TrackSequencer:enter_step).
    mod_trig = elasticat.seq_mod_trig,
    set_active_range = elasticat.seq_set_active_range,
    set_pitch = elasticat.seq_set_pitch,
    trigger_region = elasticat.seq_trigger_region,
    trigger_slice = elasticat.seq_trigger_slice,
    release_slice = elasticat.seq_release_slice,
    release_all_slices = elasticat.seq_release_all_slices,
    kill_all_slices = elasticat.kill_all_slices,
    -- Grid FN mirrors K1 for the razor chop action (arm on press / commit on
    -- release); the grid FN key handler calls these.
    razor_action_arm = elasticat.razor_action_arm,
    razor_action_commit = elasticat.razor_action_commit,
    -- Double-stop (panic) recovery for a wedged/leaked norns clock (owner): free
    -- EVERY clock coroutine -- including any leaked fiber a script reload didn't
    -- reclaim -- then re-establish our clock-sync fiber. The clock SOURCE
    -- (tempo/beats) and the sequencer metro are untouched, so timing survives.
    -- If double-stop recovers a dead clock, the wedge is a Lua fiber-pool leak
    -- (vs a scsynth/system wedge, which this can't fix).
    reset_clock = function()
      if clock ~= nil and clock.cleanup ~= nil then
        clock.cleanup()
      end
      elasticat.start_clock_sync()
      show_message("Clock reset")
    end,
    apply_step_param_locks = elasticat.seq_apply_locks,
    get_track_slice_range = elasticat.seq_slice_range,
    set_track_slice_range = elasticat.seq_set_slice_range,
    -- Macro key LEDs read the live macro value (0-127) for their brightness.
    get_macro_value = function(macro)
      local vid = id("macro" .. macro .. "_value")
      return params:lookup_param(vid) ~= nil and params:get(vid) or 0
    end,
    -- Copy/Clear/Paste pattern scope (FN+REC/PLAY/STOP on the grid): buffer =
    -- the same whole-pattern snapshot the pattern slots use; paste re-applies
    -- it to the live state without restarting the transport. Clear runs behind
    -- the standard YES/NO confirm popup.
    copy_pattern_state = capture_pattern_state,
    paste_pattern_state = function(snapshot)
      apply_pattern_state(snapshot, false)
    end,
    open_confirm = function(prompt, on_yes)
      elasticat.ui_open_confirm(prompt, on_yes)
    end,
    -- NB: per-track getters below read through elasticat.ui_id -- the selected
    -- track's params (track 1 = the plain ids, unchanged). Global params keep
    -- plain id(); elasticat.ui_id passes non-per-track suffixes through anyway.
    base_region = function()
      return params:get(elasticat.ui_id("loop_start")), params:get(elasticat.ui_id("loop_end"))
    end,
    get_machine = function()
      return params:get(elasticat.ui_id("machine"))
    end,
    get_pattern_steps = function()
      return params:get(elasticat.ui_id("pattern_steps"))
    end,
    get_global_length = function()
      return param_value_or("global_pattern_length", nil)
    end,
    on_global_boundary = function()
      return pattern_store ~= nil and pattern_store:on_global_boundary() or false
    end,
    load_pattern = request_pattern_load,
    rename_pattern = function()
      if text_entry == nil or pattern_store == nil then
        return
      end
      local slot = pattern_store:current_index()
      text_entry:open({
        text = pattern_store:name(slot),
        title = "RENAME PATTERN",
        max_length = 16,
        on_accept = function(new_name)
          pattern_store:set_name(slot, new_name)
          show_message(string.format("Pattern %02d: %s", slot, pattern_store:name(slot)))
          request_redraw()
        end,
        on_cancel = function() end
      })
    end,
    pattern_current = function()
      return pattern_store ~= nil and pattern_store:current_index() or 1
    end,
    pattern_populated = function(slot)
      return pattern_store ~= nil and pattern_store:has(slot)
    end,
    pattern_pending = function()
      if pattern_store == nil then
        return nil
      end
      return pattern_store:pending_index() or pattern_store:temp_return_index()
    end,
    clear_pattern_pending = function()
      if pattern_store ~= nil then
        pattern_store:clear_pending()
      end
    end,
    -- Pattern-name pop-up (screen, "pop up UI box showing pattern name"):
    -- slot -> display name, backing draw_pattern_name_popup() below.
    pattern_name = function(slot)
      return pattern_store ~= nil and pattern_store:name(slot) or nil
    end,
    -- FN+Pattern (8,5): opens/closes the screen-only pattern-quantize mode
    -- pop-up (see the "FN+Pattern quantize-mode pop-up" section above) --
    -- distinct from the grid pattern-load overlay wired above it.
    open_pattern_quantize_menu = toggle_pattern_quantize_menu,
    capture_scene = function(scene)
      if scene_store ~= nil then
        scene_store:capture(scene)
        -- Sparse capture can drop a param from the morph set (re-captured at its
        -- default); clear any now-stale crossfader override so it isn't stuck.
        elasticat.reconcile_crossfader(scene_store:morph_target_keys())
      end
    end,
    -- PRD §6.6 requirement 2: route grid fader/anchor-tap position jumps through
    -- the `crossfade` MASTER param (0-128) instead of calling scene_store:apply
    -- directly, so the param's action does the actual morph -- the encoder then
    -- always reads the true position, and there's one write path, not two.
    set_crossfade = function(t)
      t = util.clamp(t, 0, 1)
      -- Apply the morph ALWAYS (even if the position didn't change), so a param
      -- just p-locked into a scene is pushed live the moment the fader is
      -- touched -- the param action's change-detection would otherwise skip it.
      if scene_store ~= nil then
        elasticat.undo_record_crossfade()
        scene_store:apply(t)
        elasticat.reconcile_crossfader(scene_store:morph_target_keys())
      end
      -- Sync the MASTER-page display param SILENTLY (3rd arg true = no action):
      -- firing on_crossfade here would apply the morph a second time.
      if params:lookup_param(id("crossfade")) ~= nil then
        params:set(id("crossfade"), t * 128, true)
      end
    end,
    -- Current crossfade position (0..1), for the grid LEDs to mirror the param
    -- every redraw -- position can also move from the MASTER-page encoder, not
    -- just the grid, so the grid can't rely solely on its own last keypress.
    get_crossfade = function()
      return scene_store ~= nil and scene_store:position_value() or 0
    end,
    set_scene_edit = function(scene)
      if scene_store ~= nil then
        scene_store:set_edit_target(scene)
      end
    end,
    scene_has = function(scene)
      return scene_store ~= nil and scene_store:has(scene)
    end,
    -- PRD §6.6 requirement 1: did the just-released anchor hold actually
    -- capture a param edit? Distinguishes a tap (snap to that scene) from a
    -- hold-to-capture gesture (leave the crossfade position alone).
    -- ui_id, not id: Phase 2 made these per-track, and the sequencer always
    -- operates on the SELECTED track. A raw id() here would silently read
    -- track 1's setting while editing track 5.
    get_loop_division = function()
      return params:get(ui_id("loop_division"))
    end,
    get_trig_polyphony = function()
      return params:get(ui_id("trig_polyphony"))
    end,
    get_live_performance_mode = function()
      return params:get(id("live_performance_mode")) == 1
    end,
    get_step_preview = function()
      return params:get(id("step_preview")) == 1
    end,
    get_playhead_return = function()
      -- The live-loop-key release mode is NOT a separate param anymore: it reads
      -- the SELECTED track's trig_release (the RLSE param on the Machine page), so
      -- one setting governs both trigs and live loop keys. A step p-lock on
      -- trig_release overrides it for that trig (resolved in the sequencer);
      -- there is no step for a live-key release, so it uses the track value.
      return params:get(ui_id("trig_release"))
    end,
    get_loop_rate = function(start_point, end_point, track)
      return loop_phase_rate(start_point, end_point, track)
    end,
    get_playhead_direction = function(track)
      return playhead_direction(track)
    end,
    play = function(state)
      elasticat.play(state)
    end,
    set_sample_preview = function(on)
      params:set(id("sample_preview"), on and 1 or 0)
    end,
    reset_default = function(reset_id)
      return params:lookup_param(elasticat.ui_id(reset_id)) ~= nil and params:get(elasticat.ui_id(reset_id)) == 1
    end,
    get_trig_jump = function()
      return params:lookup_param(elasticat.ui_id("trig_jump")) ~= nil and params:get(elasticat.ui_id("trig_jump")) == 1
    end,
    get_trig_release = function()
      return params:lookup_param(elasticat.ui_id("trig_release")) ~= nil and params:get(elasticat.ui_id("trig_release")) or 1
    end,
    get_trig_chance = function()
      return params:lookup_param(elasticat.ui_id("trig_chance")) ~= nil and params:get(elasticat.ui_id("trig_chance")) or 100
    end,
    get_trig_condition = function()
      return params:lookup_param(elasticat.ui_id("trig_condition")) ~= nil and params:get(elasticat.ui_id("trig_condition")) or 1
    end,
    get_trig_ratchet = function()
      return params:lookup_param(elasticat.ui_id("trig_ratchet")) ~= nil and params:get(elasticat.ui_id("trig_ratchet")) or 1
    end,
    get_swing = function()
      return params:lookup_param(id("swing")) ~= nil and params:get(id("swing")) or 50
    end,
    get_live_step_trig = function()
      return params:lookup_param(id("live_step_trig")) ~= nil and params:get(id("live_step_trig")) == 1
    end,
    get_slice_count = function()
      return params:get(elasticat.ui_id("slice_count"))
    end,
    get_slice_index = function()
      return params:get(elasticat.ui_id("slice_index"))
    end,
    get_slice_play_mode = function()
      return params:get(elasticat.ui_id("slice_play_mode"))
    end,
    get_slice_polyphony = function()
      return params:get(elasticat.ui_id("slice_polyphony"))
    end,
    get_hold_to_step = function()
      return params:get(elasticat.ui_id("slice_hold_to_step")) == 1
    end,
    get_slice_hold = function()
      return params:get(elasticat.ui_id("slice_hold"))
    end,
    get_tempo = function()
      return params:get(id("target_bpm"))
    end,
    get_default_velocity = function()
      return param_value_or("default_velocity", default_trig_velocity)
    end,
    get_default_length = function()
      return param_value_or("default_length", default_trig_length)
    end,
    base_pitch = function()
      return params:get(elasticat.ui_id("pitch"))
    end,
    set_pitch_param = function(pitch)
      params:set(elasticat.ui_id("pitch"), pitch)
    end,
    -- Universal input router: grid nav keys (YES/NO/arrows) become semantic
    -- actions for whatever focus layer is open (settings, pop-ups); with none
    -- open this returns false and the grid behaves exactly as before.
    -- (Reached via the module table -- see the input_router construction
    -- comment -- to avoid a fresh init() upvalue.)
    ui_input = function(x, y, z)
      return elasticat.input_router:grid_key(x, y, z)
    end,
    -- Memorize/Recall (PRD §7.2, FN+Octave keys) -- module-table access for
    -- the same upvalue reason.
    ram_memorize = function()
      elasticat.ram_memorize()
    end,
    ram_recall = function()
      elasticat.ram_recall()
    end,
    ram_has = function()
      return elasticat.ram_has()
    end,
    current_param_category = function()
      return nav:current_category()
    end,
    -- True when the current category is showing a page beyond its first (a
    -- param sub-page or a settings sub-page) -- drives the category key's
    -- subpage fade indicator.
    on_param_subpage = function()
      if nav.settings_layer then
        return nav:current_settings_page_index() > 1
      end
      local _, page_index = nav:current_page()
      return (page_index or 1) > 1
    end,
    select_param_category = function(category)
      nav:select_category(category)
    end,
    select_param_page_delta = function(delta)
      nav:select_page_delta(delta)
    end,
    open_param_settings = function(category)
      -- Pressing a category key whose settings are ALREADY open cycles that
      -- category's settings pages (master: MASTER -> PROJECT -> back), the
      -- same repeat-press gesture as cycling a category's main pages.
      if nav.settings_layer and nav:current_settings_category() == category
        and nav:settings_page_count(category) > 1 then
        nav:settings_page_cycle(category)
      else
        nav:open_param_settings(category)
      end
    end,
    close_param_settings = function()
      nav:close_param_settings()
    end,
    -- Grid NO outside menus: quick undo (it has no other job there).
    undo = function()
      elasticat.undo_apply()
    end,
    -- Step-scope undo: the sequencer owns the records, so it builds the
    -- snapshot and we just hold it on the shared undo stack.
    undo_record = function(key, build)
      if elasticat.undo ~= nil then
        elasticat.undo:record(key, build)
      end
    end,
    return_to_param_category = function(category)
      nav:return_to_param_category(category)
    end,
    param_settings_active = function()
      return nav.settings_layer
    end,
    param_settings_select_delta = function(delta)
      nav:settings_select_delta(delta)
    end,
    param_settings_value_delta = settings_delta_value,
    -- Phase 1 track scaffolding: row-4 track select/mute keys + background
    -- track advancement (all callbacks reach the engine facade through the
    -- already-captured `elasticat` upvalue -- init() is AT the 60-upvalue
    -- limit, so no new locals may be referenced here).
    get_active_track_count = function()
      return param_value_or("active_track_count", 1)
    end,
    on_track_selected = function(track)
      elasticat.select_ui_track(track)
      request_redraw()
    end,
    get_track_muted = function(track)
      return elasticat.track_muted(track) == true
    end,
    set_track_mute = function(track, on)
      elasticat.set_track_mute(track, on)
    end,
    get_track_param = function(track, suffix)
      return elasticat.track_param_value(track, suffix)
    end,
    phase = elasticat.display_phase,
    position_at_region = position_at_region,
    show_message = show_message,
    request_redraw = request_redraw
  })

  -- Projects (PRD §7.2): script reload / power cycle resumes the temp work
  -- project if one was left behind (autosave-while-stopped, above); otherwise
  -- this is a fresh init and pattern slot 1 is seeded with the loaded/default
  -- state so it reads as populated and switching away can restore it (§6.1) --
  -- the original pre-Projects behavior, unchanged when no temp file exists.
  project_store = ProjectStore.new({
    pattern_store = pattern_store,
    capture_globals = capture_global_state,
    apply_globals = apply_global_state,
    capture_pool = capture_pool_state,
    apply_pool = apply_pool_state,
    -- A/B crossfader scenes travel with the project (PRD §6.6).
    capture_scenes = function()
      return scene_store ~= nil and scene_store:serialize() or nil
    end,
    apply_scenes = function(snapshot)
      if scene_store == nil then
        return
      end
      if snapshot ~= nil then
        scene_store:deserialize(snapshot)
        -- Re-apply the restored crossfade position so the loaded project SOUNDS
        -- like it did when saved, not like its unblended pattern values.
        scene_store:apply(scene_store:position_value())
        elasticat.reconcile_crossfader(scene_store:morph_target_keys())
      else
        scene_store:reset()  -- pre-scenes project: start clean, don't inherit
      end
    end,
    default_name = "untitled"
  })
  project_loading = true
  local resumed = project_store:load_temp()
  project_loading = false
  if not resumed and pattern_store ~= nil then
    pattern_store:capture(1)
  end

  -- Text-entry modal arbitration: the dialog gets first look at every grid key
  -- while open, and GridSequencer sees nothing until it closes (PRD §7.3).
  if grid_ui ~= nil and text_entry ~= nil then
    local grid_default_key = grid_ui.g.key
    grid_ui.g.key = function(x, y, z)
      if not text_entry:grid_key(x, y, z) then
        grid_default_key(x, y, z)
      end
      request_redraw()
    end
  end

  elasticat.log_engine_commands()
  osc.event = function(path, args, from)
    if path:sub(1, #"/elasticat") == "/elasticat" then
      if not quiet_osc_paths[path] or verbose_osc_logging() then
        print("elasticat: osc " .. path .. " " .. format_args(args))
      end
      -- Per-track engine reports (playhead / level / modulation) all route
      -- through elasticat.osc_report above, which owns the "which track does
      -- this belong to" decision and is unit-testable without init().
      elasticat.osc_report(path, args)
      if not browsing and not quiet_osc_paths[path] then
        request_redraw()
      end
    elseif previous_osc_event ~= nil then
      previous_osc_event(path, args, from)
    end
  end

  set_playing(false, true)
  elasticat.sync_amp_env()  -- push env/pan/vol defaults (their actions don't fire on add)
  elasticat.sync_filter()   -- push filter machine/params defaults (same reasoning)
  elasticat.sync_fx()       -- push fx insert 1 machine/params defaults (same reasoning)
  elasticat.sync_mod()      -- push LFO/mod-env defaults (same reasoning)
  elasticat.sync_tracks()   -- push active track count + tracks 2-8 params (Phase 1)
  start_intro()
  start_redraw_metro()
  -- If the compiled DSP plugin was (re)installed at load, note it (it already
  -- loaded this session via the top-level ensure; after a live `;update` a
  -- SLEEP -> wake may be needed -- see lib/ugens/README.md).
  if elasticat._dsp_install_notice ~= nil then show_message(elasticat._dsp_install_notice) end
  redraw()
end

-- ---- Pattern-load key UX pop-ups (screen) ----------------------------------
-- Two self-contained overlays for the pattern-load-key UX overhaul. Neither
-- touches the sequencer/param state directly -- the name pop-up reads through
-- the pattern_name/pattern_current grid_ui options wired above, and the
-- quantize-mode pop-up reads the local state set up in the "FN+Pattern
-- quantize-mode pop-up" section above. Both are drawn from redraw() and
-- skipped while the text-entry modal is open (see redraw()).

-- Pattern-name pop-up ("pop up UI box showing pattern name"): shown for as
-- long as the grid pattern-load overlay (grid_ui.pattern_mode) is open,
-- whether that's a momentary hold or a latched tap. Selecting a slot always
-- closes the grid overlay first (see key_pattern_mode in
-- lib/grid_sequencer.lua), so there is no separate "highlighted but not yet
-- picked" pattern to show -- this always reflects the current pattern.
local function draw_pattern_name_popup()
  -- Both pop-ups are centered at the same screen position; if FN+(8,5) opens
  -- the quantize-mode menu while the grid overlay happens to still be latched
  -- open from an earlier tap, let the (larger, more deliberately-triggered)
  -- quantize menu win rather than draw the two boxes on top of each other.
  if grid_ui == nil or grid_ui.pattern_mode ~= true or pattern_quantize_menu_open then
    return
  end
  local options = grid_ui.options or {}
  local slot = options.pattern_current ~= nil and options.pattern_current() or 1
  local name = options.pattern_name ~= nil and options.pattern_name(slot) or nil

  local box_w, box_h = 104, 22
  local box_x, box_y = (128 - box_w) / 2, (64 - box_h) / 2

  screen.level(0)
  screen.rect(box_x, box_y, box_w, box_h)
  screen.fill()
  screen.level(15)
  screen.rect(box_x, box_y, box_w, box_h)
  screen.stroke()

  screen.level(15)
  screen.move(64, box_y + 9)
  screen.text_center(string.format("PATTERN %02d", slot))
  screen.level(10)
  screen.move(64, box_y + 18)
  screen.text_center(name ~= nil and name ~= "" and name or "-")
end

-- FN+Pattern quantize-mode pop-up ("pop up UI box that lets me select the
-- pattern change mode, exactly like Tonverk"): a 4-item list, current
-- selection highlighted, driven by K1-K3/E2 (see key()/enc() below).
local function draw_pattern_quantize_menu()
  if not pattern_quantize_menu_open then
    return
  end

  local box_w, box_h = 108, 46
  local box_x, box_y = (128 - box_w) / 2, (64 - box_h) / 2

  screen.level(0)
  screen.rect(box_x, box_y, box_w, box_h)
  screen.fill()
  screen.level(15)
  screen.rect(box_x, box_y, box_w, box_h)
  screen.stroke()

  screen.level(3)
  screen.rect(box_x + 1, box_y + 1, box_w - 2, 9)
  screen.fill()
  screen.level(15)
  screen.move(64, box_y + 8)
  screen.text_center("PATTERN CHANGE MODE")

  for i, label in ipairs(PATTERN_QUANTIZE_LABELS) do
    local row_top = box_y + 10 + ((i - 1) * 8)
    if i == pattern_quantize_menu_index then
      screen.level(15)
      screen.rect(box_x + 3, row_top, box_w - 6, 8)
      screen.fill()
      screen.level(0)
    else
      screen.level(6)
    end
    screen.move(64, row_top + 6)
    screen.text_center(label)
  end
end

-- ---- Base-surface input actions (elasticat-input-actions) ------------------
-- The norns key/encoder base surface routes through the input router's action
-- layer: physical inputs -> NAMED actions bound in ONE table, modifier-aware, so
-- a remap is one edit (here) not 40, and a new device (MIDI/OSC, knob
-- controllers) is one translator that emits the same action names. The handler
-- closes over the coordinator state the actions need. param_edit carries the
-- pair SLOT (1/2) -- the seam a future MIDI knob binds to, to address any page
-- param, not just norns' selected pair.
input_router:set_base({
  bindings = {
    ["key:2"] = "nav_prev", ["key:3"] = "nav_next",
    ["enc:1"] = "page_delta", ["enc:2"] = "param_edit_left", ["enc:3"] = "param_edit_right",
  },
  -- Most specific first: a held macro re-purposes E2/E3; a held scene anchor /
  -- held step / FN re-purpose the keys; FN also re-purposes E1.
  modifier_layers = {
    {mod = "macro_held", map = {["enc:2"] = "macro_assign_left", ["enc:3"] = "macro_assign_right"}},
    {mod = "scene_held", map = {["key:2"] = "clear_scene_lock", ["key:3"] = "clear_scene_lock"}},
    {mod = "step_held",  map = {["key:2"] = "clear_step_lock",  ["key:3"] = "clear_step_lock"}},
    -- A held SLICE (no step) routes B2/B3 to the same clear -- clear_held_param_
    -- lock resolves to the held slice's own p-lock (MPC chop program). Placed
    -- before fn so FN+slice+B2 still clears just that slice.
    {mod = "slice_held", map = {["key:2"] = "clear_step_lock",  ["key:3"] = "clear_step_lock"}},
    {mod = "fn",         map = {["key:2"] = "clear_all_step_locks", ["key:3"] = "clear_all_step_locks",
                                ["enc:1"] = "settings_delta"}},
  },
  modifiers = {
    fn = fn_active,
    scene_held = function() return scene_store ~= nil and scene_store:edit_target_scene() ~= nil end,
    step_held = function() return grid_ui ~= nil and grid_ui.screen_edit ~= nil and grid_ui:screen_edit() ~= nil end,
    slice_held = function() return grid_ui ~= nil and grid_ui.slice_edit ~= nil and grid_ui:slice_edit() ~= nil end,
    macro_held = function() return grid_ui ~= nil and grid_ui.held_macro ~= nil and grid_ui:held_macro() ~= nil end,
  },
  handler = function(action, value, physical)
    local slot = (physical == "key:3" or physical == "enc:3") and 2 or 1
    if action == "nav_prev" then
      nav:cycle_group(-1)
    elseif action == "nav_next" then
      nav:cycle_group(1)
    elseif action == "clear_scene_lock" then
      clear_scene_lock_for_slot(slot)
    elseif action == "clear_step_lock" then
      clear_lock_for_slot(slot, false)
    elseif action == "clear_all_step_locks" then
      clear_lock_for_slot(slot, true)
    elseif action == "page_delta" then
      nav:select_global_page_delta(value)
    elseif action == "settings_delta" then
      if value > 0 then
        nav:open_param_settings(nav:current_category())
      elseif value < 0 then
        nav:close_param_settings()
      end
    elseif action == "param_edit_left" or action == "param_edit_right" then
      local left, right = nav:current_group_items()
      local item = slot == 2 and right or left
      -- Owner: warp mode (no_edit_playing) can't change while the transport runs.
      if item ~= nil and item.no_edit_playing == true and playing then
        show_message("Stop to change " .. (item.short or "this"))
      -- Owner: the Warp Type (fn_to_edit) only changes with FN held, so the knob
      -- can't flip the warp engine by accident.
      elseif item ~= nil and item.fn_to_edit == true and not fn_active() then
        show_message("FN + turn to change " .. (item.short or "this"))
      -- Held A/B anchor: the edit p-locks into that scene instead (PRD §6.6).
      elseif not scene_edit_item(item, value) then
        elasticat.undo_record_param(item)
        param_values:delta_item(item, value)
        scene_base_follow(item)
      end
    elseif action == "macro_assign_left" or action == "macro_assign_right" then
      -- Held macro = mod-matrix assign: E2/E3 dial the SIGNED depth from this
      -- macro to the target param's mod destination (never edits the value).
      local held_macro = grid_ui ~= nil and grid_ui:held_macro() or nil
      local left, right = nav:current_group_items()
      local target = slot == 2 and right or left
      local dest = (held_macro ~= nil and target ~= nil) and elasticat.macro_dest_for_param(target.id) or nil
      if dest ~= nil then
        local pid = elasticat.macro_depth_id(held_macro, dest)
        if pid ~= nil and params:lookup_param(pid) ~= nil then
          params:set(pid, util.clamp((params:get(pid) or 64) + value, 0, 128))
          show_message(string.format("M%d %s %+d", held_macro,
            target.short or dest.key, (params:get(pid) or 64) - 64))
        end
      elseif held_macro ~= nil then
        show_message(string.format("M%d: turn a mod dest", held_macro))
      end
    end
  end,
})

function key(n, z)
  -- The text-entry modal swallows all front-panel input while open (PRD §7.3).
  if text_entry ~= nil and text_entry:key(n, z) then
    request_redraw()
    return
  end
  -- K1 is the FN modifier only (never an action) -- track its norns source;
  -- fn_active() OR's this with the grid FN. Modals never see K1.
  if n == 1 then
    alt = z == 1
    -- FN (K1): arm a fresh razor chop selection on press; commit it on release.
    if z == 1 then
      elasticat.razor_action_arm()
    else
      elasticat.razor_action_commit()
    end
    request_redraw()
    return
  end
  -- Base key actions fire on key-DOWN only (matches the old z==0 early return).
  if z ~= 1 then
    return
  end
  -- Modal focus stack first (K3=confirm / K2=cancel), then the base-surface
  -- action layer (nav / clear, modifier-resolved) -- both via the router.
  input_router:norns_key(n, z)
  request_redraw()
end

function enc(n, d)
  if text_entry ~= nil and text_entry:enc(n, d) then
    request_redraw()
    return
  end
  -- The ONE place the GRID FN differs from the norns FN (owner): norns FN + E1
  -- toggles main<->settings (for grid-less use), but with a grid you navigate
  -- another way, so GRID FN + E1 changes TEMPO instead. Intercepted here, before
  -- the router (whose settings_delta binding keys on fn_active() = either FN), so
  -- grid FN + E1 never opens settings. norns FN + E1 still falls through.
  if n == 1 and grid_ui ~= nil and grid_ui.fn_down == true
    and elasticat.param_exists(id("target_bpm")) then
    local next_bpm = util.clamp((params:get(id("target_bpm")) or 120) + d, 20, 300)
    params:set(id("target_bpm"), next_bpm)
    show_message("Tempo " .. math.floor(next_bpm + 0.5))
    request_redraw()
    return
  end
  -- Modal focus stack first (E2=select_delta, ...), then the base-surface action
  -- layer (page nav / param edit / macro assign / settings, modifier-resolved) --
  -- both via the router. All the old E1/E2/E3 + FN + macro-held + scene-anchor
  -- branches now live in the base handler registered above (set_base).
  input_router:enc(n, d)
  request_redraw()
end

function redraw()
  if browsing or intro_active then
    return
  end

  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  -- Draw the page defensively. A Lua error inside a page draw used to abort
  -- redraw() silently: the screen kept whatever frame was drawn last, so the
  -- page looked like it simply never appeared (and cycling looked like it
  -- skipped a page). Now the error is shown on the screen and printed once.
  local ok, err
  if nav.settings_layer then
    ok, err = pcall(draw_settings_page)
  else
    ok, err = pcall(draw_root_page)
  end
  if not ok then
    local text = tostring(err)
    if elasticat.last_draw_error ~= text then
      elasticat.last_draw_error = text
      print("elasticat: page draw error: " .. text)
    end
    screen.level(15)
    screen.move(0, 30)
    screen.text("PAGE ERROR")
    screen.level(4)
    screen.move(0, 40)
    screen.text_trim(text:gsub("^.*/", ""), 128)
  end

  -- Pattern-name pop-up + FN+Pattern quantize-mode pop-up: screen-only
  -- surfaces for the pattern-load-key UX overhaul (see the section above
  -- init()). Skipped while the text-entry modal owns the screen (PRD §7.3
  -- guard) -- renaming already closes the grid overlay before opening the
  -- dialog, but this keeps the two surfaces from ever fighting even if that
  -- changes.
  if text_entry == nil or not text_entry:is_open() then
    draw_pattern_name_popup()
    draw_pattern_quantize_menu()
    draw_confirm()
  end

  -- Full-screen project browser draws over the settings page (PRD §7.1).
  draw_project_browser()

  -- Modal dialog draws over everything else (PRD §7.3).
  if text_entry ~= nil and text_entry:is_open() then
    text_entry:draw()
  end

  screen.update()
end

function cleanup()
  -- Persist editor prefs on the way out so any that were changed through the
  -- norns PARAMS menu (which bypasses settings_delta_value's per-edit save)
  -- still survive the next launch.
  save_editor_prefs()
  if elasticat.flush_dirty_pool_state ~= nil then
    elasticat.flush_dirty_pool_state()
  end
  if loop_trig_gate_clock ~= nil then
    clock.cancel(loop_trig_gate_clock)
    loop_trig_gate_clock = nil
  end
  if grid_ui ~= nil then
    grid_ui:cleanup()
    grid_ui = nil
  end
  if redraw_metro ~= nil then
    redraw_metro:stop()
    redraw_metro = nil
  end
  elasticat.stop_param_throttle()
  elasticat.stop_clock_sync()
  osc.event = previous_osc_event
  print("elasticat: cleanup play 0")
  elasticat.play(false)
end
