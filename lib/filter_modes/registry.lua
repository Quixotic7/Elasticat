-- Filter machines. Mirrors lib/warp_modes/registry.lua: each machine is a module
-- returning source_items(Item) -> its p-lockable param row. The active machine is
-- a *setting* (filter_machine), not p-lockable. Machine index is aligned with the
-- engine's filterSynthNames list in lib/Engine_Elasticat.sc.
--
-- To add a machine: append its module here + a display name in `names`, add the
-- matching SynthDef + name to the engine, and register any new param ids in
-- lib/elasticat.lua. Stereo / mid-side / comb / ladder / formant machines slot in
-- the same way.
local Registry = {}

-- Reduced catalog (2026-08-01, owner): 5 base filters. Stereo vs Mid/Side is now a
-- per-filter FILTER MIX MODE (filter_mix_mode + balance), not separate machines --
-- the old dedicated ST/MS variants (classic_stereo/morphing_stereo/classic_ms/
-- morphing_ms) are retired, and SVF is shelved (svf.lua kept, not registered).
local machines = {
  [1] = include("lib/filter_modes/classic"),
  [2] = include("lib/filter_modes/morphing"),
  [3] = include("lib/filter_modes/ladder"),
  [4] = include("lib/filter_modes/comb"),
  [5] = include("lib/filter_modes/formant")
}

local names = {"CLASSIC", "MORPHING", "LADDER", "COMB", "FORMANT"}

function Registry.get(machine_id)
  return machines[math.floor((tonumber(machine_id) or 1) + 0.5)] or machines[1]
end

function Registry.source_items(machine_id, Item)
  local machine = Registry.get(machine_id)
  return machine.source_items ~= nil and machine.source_items(Item) or {}
end

function Registry.names()
  return names
end

function Registry.count()
  return #names
end

return Registry
