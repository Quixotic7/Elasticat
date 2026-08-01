-- Morphing: one Morph knob sweeps low-pass -> notch -> high-pass. Morph is a
-- centered 0-128 param (64 = notch); Cutoff/Res/Drive are 0-127 amounts. All p-lockable.
local Mode = {id = 2, name = "morphing"}

function Mode.source_items(Item)
  return {
    Item.item("filter_morph", "MRPH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
