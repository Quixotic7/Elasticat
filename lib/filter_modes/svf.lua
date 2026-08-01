-- SVF (#10): a state-variable multimode filter (engine \elasticatFilterSVF, stereo).
-- One core yields LP/HP/BP/notch, so TYPE switching is smoother than Classic's 3
-- biquads and it is cheaper CPU. Type/Cutoff/Res/Drive, same shared ids as Classic.
-- All p-lockable.
local Mode = {id = 10, name = "svf"}

function Mode.source_items(Item)
  return {
    Item.item("filter_type", "TYPE", {lockable = true, options = 4}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
