-- Classic: an Elektron-style multimode filter. Type sweeps LP/HP/BP/notch.
-- Cutoff/Res/Drive are 0-127 amounts; Type is a 4-way option. All p-lockable.
local Mode = {id = 1, name = "classic"}

function Mode.source_items(Item)
  return {
    Item.item("filter_type", "TYPE", {lockable = true, options = 4}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
