-- Ladder (#3): a Moog-style ladder low-pass (engine MoogFF), self-oscillation
-- flavor near max resonance. Cutoff/Res/Drive are 0-127 amounts; no Type (it is
-- LP only). Stereo -- both channels filtered identically (no spread). All
-- p-lockable, reusing the shared filter param ids.
local Mode = {id = 3, name = "ladder"}

function Mode.source_items(Item)
  return {
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
