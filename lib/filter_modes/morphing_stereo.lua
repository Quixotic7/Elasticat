-- Morphing Stereo: two independent Morphing filter instances, one per channel,
-- with cutoff spread by Balance (same law as Classic Stereo: 128 pushes R
-- cutoff up / L down; 0 mirrors; 64 = center, identical to mono Morphing).
-- Morph/Cutoff/Res/Drive are shared across both channel instances (same ids
-- as mono Morphing).
local Mode = {id = 4, name = "morphing_stereo"}

function Mode.source_items(Item)
  return {
    Item.item("filter_balance", "BAL", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_morph", "MRPH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
