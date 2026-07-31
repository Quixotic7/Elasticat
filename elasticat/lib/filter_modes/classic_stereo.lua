-- Classic Stereo: two independent Classic (multimode) filter instances, one per
-- channel, with cutoff spread by Balance. Balance is a centered 0-128 param
-- (64 = center): 128 pushes R cutoff up / L cutoff down; 0 mirrors (L up / R
-- down); 64 leaves both channels identical to mono Classic. Type/Cutoff/Res/
-- Drive are shared across both channel instances (same ids as mono Classic).
local Mode = {id = 3, name = "classic_stereo"}

function Mode.source_items(Item)
  return {
    Item.item("filter_balance", "BAL", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_type", "TYPE", {lockable = true, options = 4}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
