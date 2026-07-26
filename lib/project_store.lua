-- Project store (PRD docs/PRD.md §7): the whole-project file format, built on
-- top of the pattern store's per-pattern snapshots (PRD §6.1) plus the
-- project-level (global-scope) params and the sample pool (PRD §6.1's
-- global/per-pattern split).
--
-- Deliberately decoupled from params/engine/grid, exactly like PatternStore
-- and GridSequencer: the coordinator (elasticat.lua) supplies capture/apply
-- callbacks for the GLOBAL param scope and the sample pool, and hands in the
-- already-constructed PatternStore instance -- this module calls its public
-- serialize()/deserialize() and never reimplements pattern capture (see
-- docs/WORKSTREAMS.md file ownership: lib/sequencer/pattern_store.lua is
-- workstream A's; this module only calls it). ProjectStore itself stays a
-- pure data assembler + tab.save/tab.load file-I/O layer.
--
-- Project file table shape (version 1):
--   {
--     version = 1,
--     name = "my project",
--     loaded_path = <the project file path this snapshot was taken from, or
--                    nil -- only meaningful in the temp work project, so an
--                    explicit Save after a temp-reload still lands on disk in
--                    the right place>,
--     patterns = <PatternStore:serialize() -- {version, current, slots, names}>,
--     globals = { <param suffix> = <value>, ... },  -- project-level param values
--     pool = { [slot] = {path, bpm, steps, trim_start, trim_end, gain}, ... },
--     pool_slot = <active pool slot number>
--   }
local ProjectStore = {}
ProjectStore.__index = ProjectStore

local PROJECTS_SUBDIR = "elasticat/projects/"
local TEMP_FILENAME = "elasticat/temp_work.data"

ProjectStore.EXTENSION = ".eproj"
ProjectStore.VERSION = 1

function ProjectStore.projects_dir()
  return _path.data .. PROJECTS_SUBDIR
end

function ProjectStore.temp_path()
  return _path.data .. TEMP_FILENAME
end

-- ---- Auto-naming (PRD §7.1) ------------------------------------------------

-- yymmdd-hhmm.
function ProjectStore.date_name()
  return os.date("%y%m%d-%H%M")
end

-- Runtime detection of the bundled namesizer library (lib/namesizer, added to
-- the script). The auto-name option only produces a namesizer name when it's
-- present; generate_name() falls back to Date if it's selected but missing.
function ProjectStore.namesizer_available()
  return util.file_exists ~= nil
    and util.file_exists(_path.code .. "elasticat/lib/namesizer/namesizer.lua")
end

-- Generate a project name via the bundled namesizer: NameSizer.rnd(sep) returns
-- a random "descriptor<sep>thing" pair (reading lib/namesizer/descriptors.txt
-- and things.txt). A hyphen separator keeps the result a clean, filename-safe
-- single token (e.g. "cosmic-cat"). Falls back to the Date scheme if the
-- library is missing or errors.
function ProjectStore.namesizer_name()
  if not ProjectStore.namesizer_available() then
    return ProjectStore.date_name()
  end
  local ok, NameSizer = pcall(function() return include("lib/namesizer/namesizer") end)
  if not ok or type(NameSizer) ~= "table" or type(NameSizer.rnd) ~= "function" then
    return ProjectStore.date_name()
  end
  local ok2, name = pcall(NameSizer.rnd, "-")
  if ok2 and type(name) == "string" and name ~= "" then
    return name
  end
  return ProjectStore.date_name()
end

-- auto_name mode: 1 = None (caller must resolve a name another way, e.g. the
-- text-entry dialog), 2 = Date, 3 = Namesizer (falls back to Date when
-- unavailable). Mirrors the `project_auto_name` option param's index
-- (lib/elasticat.lua) -- keep the two in sync if the option list changes.
function ProjectStore.generate_name(mode)
  if mode == 2 then
    return ProjectStore.date_name()
  elseif mode == 3 then
    return ProjectStore.namesizer_name()
  end
  return nil
end

-- ---- Construction -----------------------------------------------------

-- opts:
--   pattern_store   -- an already-constructed PatternStore instance (required
--                      for patterns to serialize/deserialize; may be swapped
--                      out later by the coordinator, e.g. for New Project --
--                      see ProjectStore:set_pattern_store).
--   capture_globals -- function() -> { suffix = value, ... }
--   apply_globals   -- function(values)
--   capture_pool    -- function() -> pool_snapshot, active_slot
--   apply_pool      -- function(pool_snapshot, active_slot)
--   default_name    -- string, used before anything is loaded/saved
function ProjectStore.new(opts)
  opts = opts or {}
  return setmetatable({
    opts = opts,
    pattern_store = opts.pattern_store,
    path = nil,
    name = opts.default_name or "untitled"
  }, ProjectStore)
end

-- New Project (PRD §7.1) swaps in a fresh PatternStore instance (the
-- coordinator constructs it; this module never touches pattern_store.lua's
-- internals directly -- same "call it, don't edit" boundary as everywhere
-- else this module talks to PatternStore).
function ProjectStore:set_pattern_store(pattern_store)
  self.pattern_store = pattern_store
end

function ProjectStore:current_path()
  return self.path
end

function ProjectStore:current_name()
  return self.name
end

function ProjectStore:set_name(name)
  if name ~= nil and name ~= "" then
    self.name = name
  end
end

function ProjectStore:is_unsaved()
  return self.path == nil
end

-- ---- Serialize / deserialize (in-memory; no file I/O) ---------------------

function ProjectStore:serialize()
  local patterns = self.pattern_store ~= nil and self.pattern_store:serialize() or nil
  local globals = self.opts.capture_globals ~= nil and self.opts.capture_globals() or {}
  local pool, pool_slot = nil, nil
  if self.opts.capture_pool ~= nil then
    pool, pool_slot = self.opts.capture_pool()
  end
  return {
    version = ProjectStore.VERSION,
    name = self.name,
    loaded_path = self.path,
    patterns = patterns,
    globals = globals,
    pool = pool,
    pool_slot = pool_slot
  }
end

-- Applies pool first (patterns/track params reference pool slots by number),
-- then the global param scope, then the per-pattern snapshots -- deliberately
-- NOT touching self.path/self.name identity; callers (save/load/save_temp/
-- load_temp below) own that so a temp-project reload behaves differently from
-- a real project load (see load_temp's doc comment).
function ProjectStore:deserialize(data)
  data = data or {}
  self.name = data.name or self.name
  if self.opts.apply_pool ~= nil then
    self.opts.apply_pool(data.pool, data.pool_slot)
  end
  if self.opts.apply_globals ~= nil and type(data.globals) == "table" then
    self.opts.apply_globals(data.globals)
  end
  if self.pattern_store ~= nil and type(data.patterns) == "table" then
    self.pattern_store:deserialize(data.patterns)
  end
end

-- ---- File I/O ---------------------------------------------------------

-- Explicit Save / Save As New (PRD §7.1): writes to `path` and that path
-- becomes the loaded project's file -- subsequent plain Save calls target it.
function ProjectStore:save(path)
  if path == nil or path == "" then
    return false
  end
  util.make_dir(ProjectStore.projects_dir())
  tab.save(self:serialize(), path)
  self.path = path
  return true
end

function ProjectStore:load(path)
  if path == nil or path == "" or not util.file_exists(path) then
    return false
  end
  local data = tab.load(path)
  if type(data) ~= "table" then
    return false
  end
  self:deserialize(data)
  self.path = path
  return true
end

-- Temp work project (PRD §7.2): the scratch copy, distinct from the loaded
-- project's own file (touched only by save()/load() above, per explicit user
-- action). Does not disturb self.path/self.name beyond what deserialize
-- already restores -- the point of save_temp/load_temp is "resume exactly
-- where you left off", not "switch to a project named temp_work".
function ProjectStore:save_temp()
  util.make_dir(_path.data .. "elasticat/")
  tab.save(self:serialize(), ProjectStore.temp_path())
  return true
end

-- Script reload / power cycle (PRD §7.2): restores the last-stopped session.
-- self.path is restored from the snapshot's embedded loaded_path (which
-- project of your own it belongs to), NOT set to the temp file's own path --
-- an explicit Save after this still writes to the real project file, or
-- nowhere (nil) if the session was never saved as a project of its own.
function ProjectStore:load_temp()
  local path = ProjectStore.temp_path()
  if not util.file_exists(path) then
    return false
  end
  local data = tab.load(path)
  if type(data) ~= "table" then
    return false
  end
  self:deserialize(data)
  self.path = data.loaded_path
  return true
end

-- Saved projects in the projects directory: {name=<display name, no
-- extension>, path=<full path>, filename=<basename>}. `sort` = "date" orders
-- newest-modified first (default, so the Load menu shows recent work on top);
-- "name" orders alphabetically. Date order uses one `ls -t` shell call
-- (util.os_capture) and falls back to name order where that isn't available
-- (e.g. a stub/test environment) so this never errors.
function ProjectStore.list(sort)
  local dir = ProjectStore.projects_dir()
  local ext = ProjectStore.EXTENSION
  local ext_len = #ext
  local filenames

  if sort == "date" and util.os_capture ~= nil then
    -- ls -t: directory contents sorted by mtime, newest first. RAW output is
    -- required: norns' util.os_capture collapses newlines to spaces unless
    -- raw=true, which turned the whole listing into one space-joined string
    -- (so only a single bogus entry survived the .eproj filter).
    filenames = {}
    local raw = util.os_capture("ls -t " .. dir .. " 2>/dev/null", true) or ""
    for line in raw:gmatch("[^\r\n]+") do
      filenames[#filenames + 1] = line
    end
  else
    if util.scandir == nil then
      return {}
    end
    filenames = util.scandir(dir) or {}
    table.sort(filenames)  -- name order
  end

  local function collect(list)
    local out = {}
    for _, filename in ipairs(list) do
      if filename:sub(-ext_len) == ext then
        out[#out + 1] = {
          name = filename:sub(1, #filename - ext_len),
          path = dir .. filename,
          filename = filename
        }
      end
    end
    return out
  end

  local out = collect(filenames)
  -- Safety net: if the date path yielded fewer projects than the directory
  -- actually holds (a shell/capture quirk), fall back to the name listing --
  -- a sort order should never be able to HIDE projects.
  if sort == "date" and util.scandir ~= nil then
    local alpha = util.scandir(dir) or {}
    table.sort(alpha)
    local fallback = collect(alpha)
    if #fallback > #out then
      return fallback
    end
  end
  return out
end

return ProjectStore
