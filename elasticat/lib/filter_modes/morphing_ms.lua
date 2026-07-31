-- Morphing Mid/Side: decode L/R -> mid/side, run two independent Morphing
-- filter instances (one on mid, one on side), re-encode to L/R. Same MS
-- Balance law as Classic Mid/Side. Morph/Cutoff/Res/Drive are shared across
-- both instances (same ids as mono Morphing).
local Mode = {id = 6, name = "morphing_ms"}

function Mode.source_items(Item)
  return {
    Item.item("filter_balance", "MSBL", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_morph", "MRPH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
