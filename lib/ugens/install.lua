-- First-run / update installer for the compiled Elasticat UGens.
--
-- The engine's warp DSP (click-free reader, grains, slicer, wavetable) runs in a
-- compiled SuperCollider plugin (ElasticatUGens.so) that must live in the SC
-- Extensions dir -- which `;install` (a plain git clone into ~/dust/code/) cannot
-- populate. So on launch this copies the BUNDLED prebuilt .so + class wrappers into
-- Extensions whenever the installed VERSION differs from the bundled one. scsynth
-- only loads plugins at boot, so a fresh (re)install needs a SLEEP -> wake; until
-- then elasticat runs on its guarded SC-graph fallbacks (every warp mode has one).
--
-- If the prebuilt binary won't load on this device (an SC ABI mismatch -- rare, the
-- norns platform is uniform armv7l), `rebuild_from_source()` compiles the bundled
-- src on-device (norns ships g++ + the SC headers). Kept as a manual action rather
-- than auto-run, because an on-device compile spikes CPU and can xrun the live
-- audio graph on the Pi3 -- the user triggers it deliberately (ideally stopped).
local Install = {}

Install.EXT = (os.getenv("HOME") or "/home/we")
  .. "/.local/share/SuperCollider/Extensions/elasticat-ugens"

-- ---- pure helpers (unit-testable, no side effects) ----

-- Single-quote a path for /bin/sh.
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
Install.shq = shq

local function trim(s) return s and (s:gsub("^%s+", ""):gsub("%s+$", "")) or nil end

-- Whether a copy is needed: differing (or missing) installed version, given a
-- bundled version and that the prebuilt .so is present. Pure -- drives ensure().
function Install.needs_install(bundled_ver, installed_ver, so_present)
  if not bundled_ver then return false end   -- nothing to install
  if not so_present then return false end     -- no prebuilt -> source-build path
  return installed_ver ~= bundled_ver
end

-- The directory holding the bundled UGens (…/dust/code/elasticat/lib/ugens).
function Install.bundle_dir()
  local base
  if _G.norns and norns.state and norns.state.path then
    base = norns.state.path
  elseif _G._path and _path.code and _G.norns and norns.state and norns.state.name then
    base = _path.code .. norns.state.name .. "/"
  else
    base = "./"
  end
  if base:sub(-1) ~= "/" then base = base .. "/" end
  return base .. "lib/ugens"
end

-- ---- IO ----

local function read_trimmed(path)
  local f = io.open(path, "r"); if not f then return nil end
  local s = f:read("*a"); f:close()
  return trim(s)
end
Install.read_trimmed = read_trimmed

local function file_exists(path)
  local f = io.open(path, "rb"); if f then f:close(); return true end
  return false
end

-- os.execute return shape differs (luajit/5.1 = exit code number; 5.2+ = ok,"exit",code).
local function run(cmd)
  local a, _, c = os.execute(cmd)
  if type(a) == "number" then return a == 0 end
  return a == true and (c == nil or c == 0)
end

-- Copy the bundled prebuilt .so + Classes + VERSION into Extensions when the
-- installed version differs. Returns (installed:boolean, message:string). A true
-- result means a copy happened -> the caller should prompt a SLEEP -> wake.
function Install.ensure()
  local dir = Install.bundle_dir()
  local bundled = read_trimmed(dir .. "/VERSION")
  local so = dir .. "/ElasticatUGens.so"
  local so_present = file_exists(so)
  local installed = read_trimmed(Install.EXT .. "/VERSION")
  if not bundled then return false, "no bundled VERSION" end
  if not so_present then return false, "no prebuilt .so -- use rebuild_from_source()" end
  if not Install.needs_install(bundled, installed, so_present) then
    return false, "up to date (" .. bundled .. ")"
  end
  local ok = run(table.concat({
    "mkdir -p " .. shq(Install.EXT .. "/Classes"),
    "cp " .. shq(so) .. " " .. shq(Install.EXT .. "/"),
    "cp " .. shq(dir .. "/Classes") .. "/*.sc " .. shq(Install.EXT .. "/Classes/"),
    "cp " .. shq(dir .. "/VERSION") .. " " .. shq(Install.EXT .. "/VERSION"),
  }, " && "))
  if ok then return true, "installed " .. bundled end
  return false, "copy to Extensions failed"
end

-- On-device source compile (the ABI-mismatch fallback / manual rebuild). Blocking
-- (~15-30s) and CPU-heavy -- best run with playback stopped. Returns ok:boolean.
function Install.rebuild_from_source()
  return run("bash " .. shq(Install.bundle_dir() .. "/build.sh"))
end

return Install
