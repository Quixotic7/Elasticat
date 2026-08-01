-- Pattern store (PRD §6): 16 pattern slots, each a near-total snapshot of the
-- per-pattern state (sequences + step locks + track params + machine choices +
-- per-pattern BPM). The global scope (sample pool, File settings, master vol/
-- settings) lives outside a pattern and is NOT captured here.
--
-- This module is deliberately decoupled from params/engine/sequencer, exactly
-- like GridSequencer: the coordinator supplies capture/apply/blank callbacks so
-- the store stays a pure data structure + switch state machine. That also makes
-- its serialize()/deserialize() the stable format that project save/load (§7)
-- builds on -- the contract the Projects workstream depends on.
local PatternStore = {}
PatternStore.__index = PatternStore

local NUM_PATTERNS = 16

-- Tonverk-style change quantization (PRD §6.3). Index aligns with the
-- `pattern_quantize` option param so the label and behaviour can't drift.
PatternStore.QUANT = {"sequential", "direct_jump", "direct_start", "temp_jump"}

function PatternStore.new(opts)
  return setmetatable({
    opts = opts or {},
    slots = {},        -- [1..16] = snapshot table (nil = never populated)
    names = {},        -- [1..16] = user name string (nil = default "PATTERN NN")
    current = 1,
    pending = nil,     -- {index, restart} queued for the next global boundary
    temp_return = nil  -- index to auto-return to when a temp_jump pass completes
  }, PatternStore)
end

function PatternStore:count()
  return NUM_PATTERNS
end

function PatternStore:current_index()
  return self.current
end

function PatternStore:has(index)
  return self.slots[index] ~= nil
end

function PatternStore:pending_index()
  return self.pending ~= nil and self.pending.index or nil
end

function PatternStore:temp_return_index()
  return self.temp_return
end

function PatternStore:in_bounds(index)
  return type(index) == "number" and index >= 1 and index <= NUM_PATTERNS
end

-- Slot display name: user-set, else a stable default.
function PatternStore:name(index)
  return self.names[index] or string.format("PATTERN %02d", index)
end

function PatternStore:set_name(index, name)
  if not self:in_bounds(index) then
    return
  end
  if name == nil or name == "" then
    self.names[index] = nil
  else
    self.names[index] = name
  end
end

-- Snapshot the live state into a slot.
function PatternStore:capture(index)
  if not self:in_bounds(index) or self.opts.capture_state == nil then
    return
  end
  self.slots[index] = self.opts.capture_state()
end

-- Persist the current pattern's live edits before switching away from it.
function PatternStore:sync_current()
  self:capture(self.current)
end

-- The snapshot to load for a slot: its stored state, or a blank pattern (empty
-- sequence over the current track params) for a never-populated slot.
function PatternStore:resolve(index)
  if self.slots[index] ~= nil then
    return self.slots[index]
  end
  if self.opts.blank_state ~= nil then
    return self.opts.blank_state()
  end
  return nil
end

-- Apply a slot to the live state and make it current. `restart` asks the
-- coordinator to reset the sequencer to step 1 (vs. keeping playback position).
function PatternStore:load(index, restart)
  if not self:in_bounds(index) then
    return false
  end
  local snapshot = self:resolve(index)
  if snapshot ~= nil and self.opts.apply_state ~= nil then
    self.opts.apply_state(snapshot, restart == true)
  end
  self.current = index
  return true
end

-- Request a switch to `index` under quantization `mode` (a QUANT string). While
-- stopped, every mode applies immediately from step 1. While playing:
--   direct_jump   -- switch now, keep the playback position
--   direct_start  -- switch now, restart from step 1
--   temp_jump     -- switch now from step 1; auto-return after one global pass
--   sequential    -- defer to the next global pattern boundary
-- Returns true if the switch was applied immediately, false if deferred.
function PatternStore:request(index, mode, playing)
  if not self:in_bounds(index) then
    return false
  end
  self:sync_current()

  if not playing then
    self.pending = nil
    self.temp_return = nil
    self:load(index, true)
    return true
  end

  if mode == "direct_jump" then
    self.pending = nil
    self.temp_return = nil
    self:load(index, false)
    return true
  elseif mode == "direct_start" then
    self.pending = nil
    self.temp_return = nil
    self:load(index, true)
    return true
  elseif mode == "temp_jump" then
    local from = self.current
    self.pending = nil
    self:load(index, true)
    self.temp_return = from
    return true
  end

  -- sequential (default): engage at the next global boundary.
  self.pending = {index = index, restart = true}
  return false
end

-- Called by the sequencer when the GLOBAL pattern length wraps (PRD §6.4). A
-- pending sequential switch engages here; a temp_jump returns to its origin.
-- Returns true when the live pattern changed (so the caller can restart cleanly).
function PatternStore:on_global_boundary()
  if self.temp_return ~= nil then
    local ret = self.temp_return
    self.temp_return = nil
    self:sync_current()
    self:load(ret, true)
    return true
  end
  if self.pending ~= nil then
    local queued = self.pending
    self.pending = nil
    self:sync_current()
    self:load(queued.index, queued.restart)
    return true
  end
  return false
end

-- Clear any queued/temp switch (e.g. on transport stop).
function PatternStore:clear_pending()
  self.pending = nil
  self.temp_return = nil
end

-- Whole-store snapshot for project save (§7). Captures the live current pattern
-- first so the on-disk copy reflects unsaved edits.
function PatternStore:serialize()
  self:sync_current()
  local slots = {}
  for index, snapshot in pairs(self.slots) do
    slots[index] = snapshot
  end
  local names = {}
  for index, name in pairs(self.names) do
    names[index] = name
  end
  return {
    version = 1,
    current = self.current,
    slots = slots,
    names = names
  }
end

-- Restore a store from serialize() and apply the saved current pattern live.
function PatternStore:deserialize(data)
  data = data or {}
  self.slots = {}
  for index, snapshot in pairs(data.slots or {}) do
    self.slots[index] = snapshot
  end
  self.names = {}
  for index, name in pairs(data.names or {}) do
    self.names[index] = name
  end
  self.pending = nil
  self.temp_return = nil
  self.current = data.current or 1
  self:load(self.current, true)
end

return PatternStore
