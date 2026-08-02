-- FX insert machines. Mirrors lib/filter_modes/registry.lua: each machine is a
-- module returning source_items(Item, prefix) -> its p-lockable param row. The
-- active machine (per FX slot) is a *setting*, not p-lockable. Machine index is
-- aligned with the engine's fxInsertNames list in lib/Engine_Elasticat.sc --
-- index 1 (engine 0) is always the dry-passthrough None machine, so a slot's
-- chain graph is never silent when switching machines.
--
-- Shared by every FX slot (Insert 1, Send 1, Send 2, Master insert -- PRD
-- SS3/SS8): each slot passes its own `prefix` through to Registry.source_items
-- so the p-lockable param ids stay namespaced per slot (Insert 1 passes nil/""
-- for its original unprefixed ids, so existing patterns/scenes keep working).
--
-- To add a machine: append its module here + a display name in `names`, add the
-- matching SynthDef + name to the engine, and register any new param ids in
-- lib/elasticat.lua.
local ModeParamLayout = include("lib/ui/mode_param_layout")

local Registry = {}

local machines = {
  [1] = include("lib/fx_modes/none"),
  [2] = include("lib/fx_modes/drive"),
  [3] = include("lib/fx_modes/delay"),
  [4] = include("lib/fx_modes/reverb"),
  [5] = include("lib/fx_modes/lofi"),
  [6] = include("lib/fx_modes/comp"),
  [7] = include("lib/fx_modes/destroy"),
  [8] = include("lib/fx_modes/echo"),
  [9] = include("lib/fx_modes/blackhole"),
  [10] = include("lib/fx_modes/chorus"),
  [11] = include("lib/fx_modes/flanger"),
  [12] = include("lib/fx_modes/phaser"),
  [13] = include("lib/fx_modes/dj_eq"),
  [14] = include("lib/fx_modes/duck"),
  [15] = include("lib/fx_modes/tape_echo"),
  [16] = include("lib/fx_modes/cassette"),
  [17] = include("lib/fx_modes/motion"),
  [18] = include("lib/fx_modes/rings"),
  [19] = include("lib/fx_modes/limit")
}

local names = {"NONE", "DRIVE", "DELAY", "REVERB", "LOFI", "COMP", "DESTROY", "ECHO",
  "BLACKHOLE", "CHORUS", "FLANGER", "PHASER", "DJ EQ", "DUCK",
  "TAPE ECHO", "CASSETTE", "MOTION", "RINGS", "LIMIT"}

function Registry.get(machine_id)
  return machines[math.floor((tonumber(machine_id) or 1) + 0.5)] or machines[1]
end

function Registry.source_items(machine_id, Item, prefix)
  local machine = Registry.get(machine_id)
  return machine.source_items ~= nil and machine.source_items(Item, prefix) or {}
end

-- Arrange an FX slot's params into the shared Mode-Parameter page skeleton (owner:
-- the FX pages reuse the FILTER MIX / WARP layout, with the machine selector as the
-- on-page banner). Delegates to lib/ui/mode_param_layout; FX has no trailing param,
-- so callers pass a blank item for item 10.
function Registry.arrange_page(raw, banner, trailing, blank)
  return ModeParamLayout.arrange(raw, banner, trailing, blank)
end

function Registry.names()
  return names
end

function Registry.count()
  return #names
end

return Registry
