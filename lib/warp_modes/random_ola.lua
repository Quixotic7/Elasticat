local Mode = {id = 5, name = "random_ola"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "CHAOS", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("wsola_window", "OWIN", {lockable = true, min = 0.005, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
    Item.item("wsola_search", "OWAN", {lockable = true, min = 0, max = 0.1, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1}})
  }
end

return Mode
