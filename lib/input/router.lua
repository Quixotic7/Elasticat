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

-- The modal nav bindings are compiled from the shared grid layout, so they use
-- the SAME buttons GridSequencer's base dispatch does -- move a key once, in
-- lib/input/grid_layout.lua, and both follow (elasticat-input-actions).
local GridLayout = include("lib/input/grid_layout")
local GRID_KEYS = {
  [GridLayout.key_id(GridLayout.yes)] = "confirm",
  [GridLayout.key_id(GridLayout.no)] = "cancel",
  [GridLayout.key_id(GridLayout.up)] = "up",
  [GridLayout.key_id(GridLayout.down)] = "down",
  [GridLayout.key_id(GridLayout.left)] = "left",
  [GridLayout.key_id(GridLayout.right)] = "right",
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

-- ---- Base-surface action layer -------------------------------------------
-- Beyond the modal focus stack, the BASE surface (param pages: norns keys +
-- encoders, and later the grid + MIDI/OSC) routes through here too, so every
-- base intent is a NAMED action bound in ONE place (rebind here, not at 40 call
-- sites) and a new device is one translator that emits the same names.
-- `bindings` maps a physical id ("key:2", "enc:2") to an action. `modifier_
-- layers` is a precedence-ordered list of {mod = <modifier name>, map =
-- {physical -> action}} whose entries OVERRIDE the base binding while that
-- modifier is active -- so one key means different things under FN / a held step
-- / a held scene anchor / a held macro, resolved most-specific-first to match the
-- hand-written precedence. `modifiers` is a table of named predicates (the
-- coordinator's fn_active / scene-held / step-held / macro-held). `handler`
-- (also the coordinator's, since it closes over nav / param_values / clear fns)
-- runs the resolved action, so the router stays device- and app-agnostic.
function InputRouter:set_base(opts)
  opts = opts or {}
  self.base_bindings = opts.bindings or {}
  self.modifier_layers = opts.modifier_layers or {}
  self.modifiers = opts.modifiers or {}
  self.base_handler = opts.handler
end

-- Resolve a physical id to its action for the CURRENT modifiers: the first
-- active modifier layer that binds it wins, else the unmodified binding.
function InputRouter:resolve_base(physical)
  for _, layer in ipairs(self.modifier_layers or {}) do
    local pred = self.modifiers ~= nil and self.modifiers[layer.mod] or nil
    if pred ~= nil and pred() and layer.map[physical] ~= nil then
      return layer.map[physical]
    end
  end
  return self.base_bindings ~= nil and self.base_bindings[physical] or nil
end

-- Run the resolved base action (value = encoder delta, nil for a key). Returns
-- true when an action ran, so a translator can report the event consumed.
function InputRouter:run_base(physical, value)
  if self.base_handler == nil then
    return false
  end
  local action = self:resolve_base(physical)
  if action == nil then
    return false
  end
  return self.base_handler(action, value, physical) ~= false
end

-- ---- Device translators. Modal focus stack first, then the base surface.
-- Return true when the event was handled (by a modal layer OR a base action).

function InputRouter:norns_key(n, z)
  if z ~= 1 then
    return false
  end
  local action = NORNS_KEYS[n]
  if action ~= nil and self:dispatch(action) then
    return true
  end
  return self:run_base("key:" .. n, nil)
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
  if action ~= nil and self:dispatch(action, d) then
    return true
  end
  return self:run_base("enc:" .. n, d)
end

return InputRouter
