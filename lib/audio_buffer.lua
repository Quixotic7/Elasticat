-- Audio interface (JACK buffer) control for the master AUDIO INTERFACE settings
-- page. Drives util/set-audio-buffer.sh (a systemd drop-in toggle) so the user
-- can trade latency for CPU headroom -- 128 (norns stock) / 256 / 512 -- and roll
-- back cleanly. The change needs a jack restart, so it lands on the next
-- SLEEP->wake or reboot. See [[elasticat-jack-xrun-hazard]].
--
-- os_capture is synchronous, so state is READ ONCE and cached; the settings-page
-- actions refresh it. A script reload (e.g. after the reboot) re-requires this
-- module -> cache resets -> the new live buffer is read fresh.
local AudioBuffer = {}

AudioBuffer.STOCK = 128
AudioBuffer.CHOICES = { 128, 256, 512 }

-- Absolute path to the shipped helper, derived from THIS file's own location so
-- it survives the script folder being renamed for a distribution.
local function helper_path()
  local src = debug.getinfo(1, "S").source or ""
  src = src:gsub("^@", "")                       -- @/.../elasticat/lib/audio_buffer.lua
  local dir = src:gsub("/lib/audio_buffer%.lua$", "")
  return dir .. "/util/set-audio-buffer.sh"
end
AudioBuffer.helper = helper_path()

local cache = nil  -- { live, target, stock, override, available }

local function run(arg)
  if util == nil or util.os_capture == nil then return "" end
  -- Invoke via `bash` (not the +x bit) so it survives a deploy that doesn't
  -- preserve exec perms; quote the path + merge stderr.
  return util.os_capture('bash "' .. AudioBuffer.helper .. '" ' .. arg .. " 2>&1") or ""
end

function AudioBuffer.refresh()
  local out = run("status")
  local live = tonumber(out:match("live:%s*(%d+)"))
  local target = tonumber(out:match("target:%s*(%d+)"))
  local stock = tonumber(out:match("stock:%s*(%d+)")) or AudioBuffer.STOCK
  cache = {
    live = live,
    target = target or live,
    stock = stock,
    override = out:match("override:%s*on") ~= nil,
    available = (live ~= nil),
  }
  return cache
end

function AudioBuffer.status()
  return cache or AudioBuffer.refresh()
end

-- The one-line summary for the AUDIO INTERFACE status row.
function AudioBuffer.status_label()
  local s = AudioBuffer.status()
  if not s.available then return "jack not found" end
  if s.live ~= s.target then
    return s.live .. " now, " .. s.target .. " on reboot"
  end
  return s.live .. " frames" .. (s.override and " (override)" or " (stock)")
end

-- Is `period` the current TARGET (what boots next)? Drives the row marker.
function AudioBuffer.is_target(period)
  local s = AudioBuffer.status()
  return s.target == period
end

-- Apply a choice. `period` is a number (128/256/512); 128 == reset (remove the
-- override). Returns (ok, short_message) for a show_message + flash.
function AudioBuffer.apply(period)
  local arg = (period == AudioBuffer.STOCK) and "reset" or tostring(period)
  local out = run(arg)
  AudioBuffer.refresh()
  if out:match("^ERROR") or out:match("sudo") then
    return false, "needs passwordless sudo"
  end
  if not out:match("^OK") then
    return false, "buffer change failed"
  end
  local s = AudioBuffer.status()
  local applied = (s.live == s.target)
  return true, period .. (applied and "" or " (reboot to apply)")
end

return AudioBuffer
