-- Universal UI input router (Unity-style action mapping).
--
-- Physical inputs (norns keys/encoders, grid nav keys, future MIDI) are
-- translated ONCE into semantic actions here; modal UI layers (pop-ups,
-- dialogs, pickers) register a focus handler and answer actions BY NAME. UI
-- code never checks device specifics, so every surface that answers "confirm"
-- automatically answers norns K3 AND the grid YES key AND any controller
-- mapped later -- behaviour stays universal by construction instead of by
-- N scattered per-device `if` checks that drift apart.
--
-- INPUT CONVENTIONS (project law -- change them HERE, nowhere else):
--   confirm      = norns K3 / grid YES (11,6)
--   cancel       = norns K2 / grid NO  (11,7)
--   up/down      = grid arrows (13,6)/(13,7)
--   left/right   = grid arrows (12,7)/(14,7)
--   select_delta = E2   value_delta = E3   page_delta = E1
--   norns K1 is NEVER bound to an action: it is the FN modifier only. A quick
--   K1 press is reserved by norns itself for the system menu, so K1 is only
--   usable as a hold -- which is exactly what a modifier is.
--
-- To support a new controller (MIDI Launchkey, ...): write one translator that
-- turns its events into these action names and calls dispatch() -- zero UI
-- code changes.
--
-- Focus stack: layers push a handler {name, on_action(action, value)} when
-- they open and pop it when they close; the most recently pushed layer sees an
-- action first, and returning true consumes it. With no focus layers open,
-- every translator returns false immediately, so the base surfaces (step
-- grid, param pages, settings) behave exactly as if the router didn't exist.
local InputRouter = {}
InputRouter.__index = InputRouter

local NORNS_KEYS = {
  [2] = "cancel",
  [3] = "confirm"
}

local GRID_KEYS = {
  ["11:6"] = "confirm",
  ["11:7"] = "cancel",
  ["13:6"] = "up",
  ["13:7"] = "down",
  ["12:7"] = "left",
  ["14:7"] = "right"
}

local ENCODERS = {
  [1] = "page_delta",
  [2] = "select_delta",
  [3] = "value_delta"
}

function InputRouter.new()
  return setmetatable({focus = {}}, InputRouter)
end

function InputRouter:push_focus(handler)
  if handler == nil or handler.name == nil or handler.on_action == nil then
    return
  end
  -- Re-pushing an open layer moves it to the top instead of duplicating it.
  self:pop_focus(handler.name)
  self.focus[#self.focus + 1] = handler
end

function InputRouter:pop_focus(name)
  for i = #self.focus, 1, -1 do
    if self.focus[i].name == name then
      table.remove(self.focus, i)
      return true
    end
  end
  return false
end

function InputRouter:has_focus(name)
  for i = 1, #self.focus do
    if self.focus[i].name == name then
      return true
    end
  end
  return false
end

function InputRouter:any_focus()
  return #self.focus > 0
end

-- True if any open focus layer is a full-screen modal that should swallow ALL
-- grid keys (not just nav keys), so stray step/loop presses don't leak to the
-- sequencer underneath. Set per-layer via handler.blocking = true.
function InputRouter:blocking()
  for i = #self.focus, 1, -1 do
    if self.focus[i].blocking then
      return true
    end
  end
  return false
end

-- Offer an action to the focus stack, topmost first. True = consumed.
function InputRouter:dispatch(action, value)
  for i = #self.focus, 1, -1 do
    local handler = self.focus[i]
    if handler.on_action(action, value) then
      return true
    end
  end
  return false
end

-- ---- Device translators (return true when a focus layer consumed the event).

function InputRouter:norns_key(n, z)
  if z ~= 1 then
    return false
  end
  local action = NORNS_KEYS[n]
  if action == nil then
    return false
  end
  return self:dispatch(action)
end

function InputRouter:grid_key(x, y, z)
  if #self.focus == 0 then
    return false
  end
  local blocking = self:blocking()
  if z ~= 1 then
    return blocking  -- swallow key-ups too while a modal owns the grid
  end
  local action = GRID_KEYS[x .. ":" .. y]
  if action ~= nil and self:dispatch(action) then
    return true
  end
  -- A blocking modal consumes every grid key, mapped or not.
  return blocking
end

function InputRouter:enc(n, d)
  local action = ENCODERS[n]
  if action == nil then
    return false
  end
  return self:dispatch(action, d)
end

return InputRouter
