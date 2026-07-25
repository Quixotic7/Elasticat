-- A/B scene crossfader (PRD §6.6). Two scene snapshots (A/B) each capture a set
-- of morphable param values; a crossfader position 0..1 morphs every captured
-- param continuously between them -- the Octatrack scene gesture, single-track.
--
-- Scene locks mirror step p-locks: while an anchor is held (edit_target), an
-- encoder edit writes the SCENE's value only -- never the live param -- and the
-- store stashes the param's pre-capture live value as its BASE. A param locked
-- in only one scene then morphs between the scene value and its base (not the
-- ever-moving live value, which would collapse the morph to a constant or
-- drift with repeated applies). A param locked in neither scene is untouched
-- by the fader.
--
-- Decoupled from params/engine (coordinator-callback idiom, like PatternStore):
--   opts.morph_ids()          -> array of param id-suffixes that can morph
--   opts.get_value(suffix)    -> current live value of a param
--   opts.set_value(suffix, v) -> set a param live (pushes to the engine)
-- Only continuous params should be listed by morph_ids(); discrete/enum params
-- would step mid-fade and are left out by the coordinator.
local SceneStore = {}
SceneStore.__index = SceneStore

local function deep_copy(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
end

function SceneStore.new(opts)
  return setmetatable({
    opts = opts or {},
    scenes = {{}, {}},  -- [1]=A, [2]=B: {suffix -> value}
    bases = {},         -- {suffix -> pre-capture live value} for locked params
    position = 0,       -- crossfade 0 = fully A, 1 = fully B
    edit_target = nil   -- anchor currently held for per-param scene editing (1/2)
  }, SceneStore)
end

function SceneStore:in_bounds(scene)
  return scene == 1 or scene == 2
end

-- Clear both scenes, the bases, the crossfade position, and the edit anchor
-- (New Project).
function SceneStore:reset()
  self.scenes = {{}, {}}
  self.bases = {}
  self.position = 0
  self.edit_target = nil
end

function SceneStore:has(scene)
  return self:in_bounds(scene) and next(self.scenes[scene]) ~= nil
end

function SceneStore:position_value()
  return self.position
end

-- The value a scene holds for one param (nil = not locked in that scene).
function SceneStore:scene_value(scene, suffix)
  if not self:in_bounds(scene) or suffix == nil then
    return nil
  end
  return self.scenes[scene][suffix]
end

-- Stash a param's base (its un-morphed live value) the first time either scene
-- locks it. Called before the scene write, while the live param still holds
-- the user's own value.
function SceneStore:ensure_base(suffix)
  if suffix ~= nil and self.bases[suffix] == nil and self.opts.get_value ~= nil then
    self.bases[suffix] = self.opts.get_value(suffix)
  end
end

-- A tracked param's base was re-edited normally (no anchor held): follow it,
-- so the un-locked end of a one-sided morph reflects the user's latest value.
function SceneStore:update_base(suffix, value)
  if suffix ~= nil and self.bases[suffix] ~= nil and value ~= nil then
    self.bases[suffix] = value
  end
end

-- Snapshot every morphable param's current live value into a scene (FN+anchor).
function SceneStore:capture(scene)
  if not self:in_bounds(scene) or self.opts.morph_ids == nil or self.opts.get_value == nil then
    return
  end
  local values = {}
  for _, suffix in ipairs(self.opts.morph_ids()) do
    self:ensure_base(suffix)
    values[suffix] = self.opts.get_value(suffix)
  end
  self.scenes[scene] = values
end

-- Store one param's value into a scene (the hold-anchor + encoder gesture).
-- The live param is deliberately NOT written: like a held step's p-lock, the
-- edit lands only in the scene, and the fader is what brings it into the
-- sound.
function SceneStore:set_scene_value(scene, suffix, value)
  if not self:in_bounds(scene) or suffix == nil then
    return
  end
  self:ensure_base(suffix)
  self.scenes[scene][suffix] = value
end

-- Track which anchor (if any) is held, so the coordinator routes param edits
-- into that scene instead of the live value.
function SceneStore:set_edit_target(scene)
  self.edit_target = self:in_bounds(scene) and scene or nil
end

function SceneStore:edit_target_scene()
  return self.edit_target
end

-- Morph to crossfade position t (0..1): every param locked in EITHER scene
-- interpolates between its two ends -- a missing end falls back to the param's
-- stashed base -- and is pushed live. Params locked in neither scene are never
-- touched.
function SceneStore:apply(t)
  t = math.max(0, math.min(1, t))
  self.position = t
  if self.opts.set_value == nil then
    return
  end
  local seen = {}
  for suffix in pairs(self.scenes[1]) do
    seen[suffix] = true
  end
  for suffix in pairs(self.scenes[2]) do
    seen[suffix] = true
  end
  for suffix in pairs(seen) do
    local av = self.scenes[1][suffix]
    local bv = self.scenes[2][suffix]
    local base = self.bases[suffix]
    av = av or base
    bv = bv or base
    if av ~= nil and bv ~= nil then
      self.opts.set_value(suffix, av + (bv - av) * t)
    end
  end
end

-- RAM snapshot for pattern/project inclusion (not yet wired into either).
function SceneStore:serialize()
  return {
    version = 1,
    scenes = {deep_copy(self.scenes[1]), deep_copy(self.scenes[2])},
    bases = deep_copy(self.bases),
    position = self.position
  }
end

function SceneStore:deserialize(data)
  data = data or {}
  local scenes = data.scenes or {}
  self.scenes = {deep_copy(scenes[1]), deep_copy(scenes[2])}
  self.bases = deep_copy(data.bases)
  self.position = data.position or 0
  self.edit_target = nil
end

return SceneStore
