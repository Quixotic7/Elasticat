local Mode = {id = 6, name = "pitch_corrected"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "SMEAR", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("pv_window", "PCWN", {lockable = true, min = 0.005, max = 2, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2}}),
    Item.item("pv_dispersion", "PCDS", {lockable = true, min = 0, max = 1, step = 0.001, snaps = {0, 0.25, 0.5, 0.75, 1}})
  }
end

return Mode
