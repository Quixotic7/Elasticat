-- A/B scene crossfader (PRD §6.6). Two scene snapshots (A/B) each capture a set
-- of morphable param values; a crossfader position 0..1 morphs every captured
-- param continuously between them -- the Octatrack scene gesture, across the
-- whole instrument.
--
-- Scene locks mirror step p-locks: while an anchor is held (edit_target), an
-- encoder edit writes the SCENE's value only -- never the live param -- and the
-- store stashes the param's pre-capture live value as its BASE. A param locked
-- in only one scene then morphs between the scene value and its base (not the
-- ever-moving live value, which would collapse the morph to a constant or
-- drift with repeated applies). A param locked in neither scene is untouched
-- by the fader.
--
-- KEYS ARE OPAQUE, AND THE COORDINATOR FEEDS FULL PER-TRACK PARAM IDS
-- ("elasticat_t3_filter_cutoff"), not bare suffixes. That is what lets one
-- scene hold every track at once, and it is what fixes the cross-track leak
-- described in docs/PHASE2_CONTRACT.md: a bare-suffix key is a single slot
-- shared by all 8 tracks, so whichever track happened to be selected when a
-- base was last touched owned it for everyone. This module never parses a key
-- -- track-awareness lives entirely in the coordinator's callbacks.
--
-- Decoupled from params/engine (coordinator-callback idiom, like PatternStore):
--   opts.morph_ids()          -> array of morphable param ids
--   opts.get_value(id)        -> current live value of a param (nil if absent)
--   opts.set_value(id, v)     -> set a param live (pushes to the engine)
--   opts.is_active(id)        -> false while that id's track is inactive
--                                (optional; missing = everything is active)
--   opts.legacy_key(suffix)   -> full id for a pre-v2, bare-suffix snapshot
--                                (optional; missing = discard such a snapshot)
-- Only CONTINUOUS params should be listed by morph_ids(); a half-morphed enum
-- is nonsense, so discrete/option/binary params are left out by the
-- coordinator and snap only on an outright recall.
--
-- COST CONTROL (docs/PHASE2_CONTRACT.md "Cost control"). 98 morphable params
-- per track is 784 per scene at 8 tracks, and apply() runs on every crossfader
-- tick -- naively ~23k param writes/sec, which is where audio dropouts come
-- from. Three exact (non-heuristic) reductions live here:
--   1. the morph SET is precomputed -- only params whose two ENDPOINTS differ
--      can change during a morph, so the rest are dropped once, at capture /
--      lock / base change, rather than being recomputed and re-written every
--      tick;
--   2. no-op writes are skipped (interpolated value == current value);
--   3. inactive tracks are not written at all (their stored values stay put,
--      so lowering the track count never strands a scene).
-- The writes that remain go through the coordinator's params:set, which is
-- what puts them on the facade's existing 12Hz coalescing send queue.
local SceneStore = {}
SceneStore.__index = SceneStore

-- Snapshot format version. 1 = bare suffixes (single-track, track 1 only);
-- 2 = full per-track param ids.
SceneStore.VERSION = 2

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
    scenes = {{}, {}},  -- [1]=A, [2]=B: {param id -> value}
    bases = {},         -- {param id -> pre-capture live value} for locked params
    position = 0,       -- crossfade 0 = fully A, 1 = fully B
    edit_target = nil,  -- anchor currently held for per-param scene editing (1/2)
    morph_set = nil     -- precomputed {{key, a, b}, ...}; nil = needs rebuild
  }, SceneStore)
end

function SceneStore:in_bounds(scene)
  return scene == 1 or scene == 2
end

-- Any change to a scene value or a base can change which params have differing
-- endpoints, so the precomputed morph set is dropped. Rebuilding is O(scene
-- size) and happens at most once per crossfader tick, versus the 784 param
-- writes per tick the set exists to avoid.
function SceneStore:invalidate()
  self.morph_set = nil
end

-- Clear both scenes, the bases, the crossfade position, and the edit anchor
-- (New Project).
function SceneStore:reset()
  self.scenes = {{}, {}}
  self.bases = {}
  self.position = 0
  self.edit_target = nil
  self:invalidate()
end

function SceneStore:has(scene)
  return self:in_bounds(scene) and next(self.scenes[scene]) ~= nil
end

function SceneStore:position_value()
  return self.position
end

-- The value a scene holds for one param (nil = not locked in that scene).
function SceneStore:scene_value(scene, key)
  if not self:in_bounds(scene) or key == nil then
    return nil
  end
  return self.scenes[scene][key]
end

-- The stashed (un-morphed) value for one param, or nil when it is not tracked.
function SceneStore:base_value(key)
  return key ~= nil and self.bases[key] or nil
end

-- Stash a param's base (its un-morphed live value) the first time either scene
-- locks it. Called before the scene write, while the live param still holds
-- the user's own value.
function SceneStore:ensure_base(key)
  if key ~= nil and self.bases[key] == nil and self.opts.get_value ~= nil then
    self.bases[key] = self.opts.get_value(key)
    self:invalidate()
  end
end

-- A tracked param's base was re-edited normally (no anchor held): follow it,
-- so the un-locked end of a one-sided morph reflects the user's latest value.
-- Keyed by FULL param id, so track 3's base can never be written through track
-- 1's slot (the cross-track contamination this module used to have).
function SceneStore:update_base(key, value)
  if key ~= nil and self.bases[key] ~= nil and value ~= nil
    and self.bases[key] ~= value then
    self.bases[key] = value
    self:invalidate()
  end
end

-- Is this param id one the fader may write right now? False for a track above
-- the active track count -- its stored values stay in the scene untouched, they
-- are simply not applied while it is off.
function SceneStore:is_active(key)
  return self.opts.is_active == nil or self.opts.is_active(key) ~= false
end

-- Snapshot every morphable param's current live value into a scene (FN+anchor).
-- Captures ALL ACTIVE TRACKS in one press -- a scene is "the whole instrument",
-- not one track (owner-confirmed, docs/PHASE2_CONTRACT.md). Values already held
-- for INACTIVE tracks are preserved rather than dropped, so turning tracks off
-- and on again does not lose a scene.
function SceneStore:capture(scene)
  if not self:in_bounds(scene) or self.opts.morph_ids == nil or self.opts.get_value == nil then
    return
  end
  local values = deep_copy(self.scenes[scene])
  local other = self.scenes[scene == 1 and 2 or 1]
  local get_default = self.opts.get_default
  for _, key in ipairs(self.opts.morph_ids()) do
    if self:is_active(key) then
      local value = self.opts.get_value(key)
      -- SPARSE capture (owner-requested): a param sitting at its DEFAULT is
      -- only worth storing when the OTHER scene holds a value for it -- then
      -- this side must record the default so morphing back to it really
      -- returns the param to default. Otherwise the key is REMOVED (not just
      -- skipped): it may exist from an earlier capture, and a stale
      -- non-default value would silently pull the param during a morph the
      -- user believes captured "nothing" for it. With no get_default wired,
      -- every value is stored -- sparseness is an optimisation, never a
      -- correctness requirement.
      local default = get_default ~= nil and get_default(key) or nil
      if value ~= nil and (default == nil or value ~= default or other[key] ~= nil) then
        self:ensure_base(key)
        values[key] = value
      else
        values[key] = nil
      end
    end
  end
  self.scenes[scene] = values
  self:invalidate()
end

-- Clear one param from BOTH scenes and drop its base (held Scene + B2/B3, #43).
-- With the key absent from both scenes morph_targets() no longer includes it, so
-- it is fully un-morphed and holds its live/base value across the whole fade --
-- the owner's "same value in both scenes without editing each" goal. The
-- coordinator passes the SELECTED track's full param id, so only that track's
-- lock is touched; other tracks' entries and other keys are untouched.
function SceneStore:clear_key(key)
  if key == nil then
    return false
  end
  local had = self.scenes[1][key] ~= nil or self.scenes[2][key] ~= nil
    or self.bases[key] ~= nil
  self.scenes[1][key] = nil
  self.scenes[2][key] = nil
  self.bases[key] = nil
  self:invalidate()
  return had
end

-- Store one param's value into a scene (the hold-anchor + encoder gesture).
-- The live param is deliberately NOT written: like a held step's p-lock, the
-- edit lands only in the scene, and the fader is what brings it into the
-- sound. Surgical by construction -- the coordinator passes the SELECTED
-- track's param id, so this touches that one track only.
function SceneStore:set_scene_value(scene, key, value)
  if not self:in_bounds(scene) or key == nil then
    return
  end
  self:ensure_base(key)
  self.scenes[scene][key] = value
  self:invalidate()
end

-- Track which anchor (if any) is held, so the coordinator routes param edits
-- into that scene instead of the live value.
function SceneStore:set_edit_target(scene)
  self.edit_target = self:in_bounds(scene) and scene or nil
end

function SceneStore:edit_target_scene()
  return self.edit_target
end

-- The precomputed morph set: every param locked in EITHER scene whose two ends
-- actually DIFFER (a missing end falls back to the param's stashed base). A
-- param whose ends are equal cannot change as the fader moves, so writing it
-- every tick is pure cost -- this is exact, not a heuristic. Rebuilt only when
-- a scene value or a base changes, never per tick.
function SceneStore:morph_targets()
  if self.morph_set ~= nil then
    return self.morph_set
  end
  local seen = {}
  for key in pairs(self.scenes[1]) do
    seen[key] = true
  end
  for key in pairs(self.scenes[2]) do
    seen[key] = true
  end
  local set = {}
  for key in pairs(seen) do
    local base = self.bases[key]
    local av = self.scenes[1][key]
    local bv = self.scenes[2][key]
    if av == nil then av = base end
    if bv == nil then bv = base end
    if av ~= nil and bv ~= nil and av ~= bv then
      -- Resolved ONCE here rather than per key per tick: is_active costs a
      -- param lookup, and the whole point of this set is that a fader tick
      -- does no per-param work beyond the interpolation itself. The
      -- coordinator invalidates on an active-track-count change.
      set[#set + 1] = {key = key, a = av, b = bv, active = self:is_active(key)}
    end
  end
  self.morph_set = set
  return set
end

-- How many params a fader tick actually writes at most (diagnostics/tests).
function SceneStore:morph_target_count()
  return #self:morph_targets()
end

-- The morph-target keys as a set {key -> true}, so the coordinator can tell the
-- base-value resolver which crossfader overrides are still live and drop the
-- rest (a param unlocked from both scenes must hand control back to the knob).
function SceneStore:morph_target_keys()
  local set = {}
  for _, entry in ipairs(self:morph_targets()) do
    set[entry.key] = true
  end
  return set
end

-- Morph to crossfade position t (0..1): every param in the precomputed morph
-- set interpolates between its two ends and is pushed live. Params locked in
-- neither scene -- and params whose ends are identical, which cannot move --
-- are never touched, and neither are inactive tracks.
function SceneStore:apply(t)
  t = math.max(0, math.min(1, t))
  self.position = t
  local set_value = self.opts.set_value
  if set_value == nil then
    return
  end
  local get_value = self.opts.get_value
  for _, entry in ipairs(self:morph_targets()) do
    if entry.active then
      local value = entry.a + (entry.b - entry.a) * t
      -- Skip no-op writes: at the ends of fader travel, and for any param the
      -- morph has not actually moved since the last tick, the param already
      -- holds this value and params:set would fire an action for nothing.
      if get_value == nil or get_value(entry.key) ~= value then
        set_value(entry.key, value)
      end
    end
  end
end

-- RAM snapshot for pattern/project inclusion.
function SceneStore:serialize()
  return {
    version = SceneStore.VERSION,
    scenes = {deep_copy(self.scenes[1]), deep_copy(self.scenes[2])},
    bases = deep_copy(self.bases),
    position = self.position
  }
end

-- Version 1 snapshots are keyed by BARE suffix and are single-track by
-- construction. Backwards compatibility is not required, but such a scene must
-- never be applied to the WRONG track: opts.legacy_key maps each bare suffix to
-- its track 1 param id, and without that mapping the snapshot is discarded
-- outright rather than reinterpreted.
function SceneStore:migrate_keys(map)
  local legacy_key = self.opts.legacy_key
  if legacy_key == nil then
    return {}
  end
  local out = {}
  for suffix, value in pairs(map or {}) do
    local key = legacy_key(suffix)
    if key ~= nil then
      out[key] = value
    end
  end
  return out
end

function SceneStore:deserialize(data)
  data = data or {}
  local scenes = data.scenes or {}
  local legacy = (tonumber(data.version) or 1) < SceneStore.VERSION
  if legacy then
    self.scenes = {self:migrate_keys(scenes[1]), self:migrate_keys(scenes[2])}
    self.bases = self:migrate_keys(data.bases)
  else
    self.scenes = {deep_copy(scenes[1]), deep_copy(scenes[2])}
    self.bases = deep_copy(data.bases)
  end
  self.position = data.position or 0
  self.edit_target = nil
  self:invalidate()
end

return SceneStore
