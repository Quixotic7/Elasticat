-- Classic Mid/Side: decode L/R -> mid/side, run two independent Classic filter
-- instances (one on mid, one on side), re-encode to L/R. MS Balance reuses the
-- same centered 0-128 law as the stereo variants (64 = center): 128 pushes
-- Side cutoff up / Mid cutoff down; 0 mirrors (Mid up / Side down). Type/
-- Cutoff/Res/Drive are shared across both instances (same ids as mono
-- Classic).
local Mode = {id = 5, name = "classic_ms"}

function Mode.source_items(Item)
  return {
    Item.item("filter_balance", "MSBL", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_type", "TYPE", {lockable = true, options = 4}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
