-- Quick-undo stack for value-level edits (grid NO key).
--
-- Entries record the state BEFORE a change, so undo restores it. Pushes are
-- GESTURE-coalesced by `key`: while edits with the same key keep arriving
-- inside the coalesce window, they extend the same entry instead of stacking
-- one per encoder detent. Turning filter cutoff from 20 to 90 in one motion
-- therefore undoes to 20, not to 89 -- and a crossfader glide (which fires
-- ~30 morph applications a second) leaves ONE undoable entry, not thirty.
--
-- The entry itself is built lazily: `record(key, build)` only calls `build`
-- when a new gesture actually starts, so the common (coalesced) case costs
-- nothing -- important because the crossfade snapshot walks every morph param.
--
-- Pure state: no params/engine access. The coordinator supplies `now` and
-- decides what an entry contains and how to restore it.
local Undo = {}
Undo.__index = Undo

local DEFAULT_DEPTH = 16
local DEFAULT_COALESCE = 1.0  -- seconds of idle that ends a gesture

function Undo.new(opts)
  opts = opts or {}
  return setmetatable({
    depth = opts.depth or DEFAULT_DEPTH,
    coalesce = opts.coalesce or DEFAULT_COALESCE,
    now = opts.now or function() return 0 end,
    entries = {},
    last_key = nil,
    last_time = nil
  }, Undo)
end

-- Start (or extend) a gesture. Returns true if a new entry was pushed.
function Undo:record(key, build)
  local t = self.now()
  if key ~= nil and self.last_key == key and self.last_time ~= nil
    and (t - self.last_time) < self.coalesce then
    self.last_time = t  -- still the same gesture; keep it alive
    return false
  end
  local entry = build()
  if entry == nil then
    return false
  end
  entry.key = key
  self.last_key = key
  self.last_time = t
  self.entries[#self.entries + 1] = entry
  while #self.entries > self.depth do
    table.remove(self.entries, 1)
  end
  return true
end

-- Most recent entry, removed. nil when there is nothing to undo.
function Undo:pop()
  local n = #self.entries
  if n == 0 then
    return nil
  end
  local entry = self.entries[n]
  self.entries[n] = nil
  -- The next edit always begins a fresh gesture, so an undo followed by more
  -- turning of the same param cannot be swallowed by the coalesce window.
  self.last_key = nil
  self.last_time = nil
  return entry
end

function Undo:count()
  return #self.entries
end

function Undo:clear()
  self.entries = {}
  self.last_key = nil
  self.last_time = nil
end

return Undo
