-- Drive: pre-insert clip/drive distortion (tanh saturation). The cheapest
-- Tier-1 FX (PRD SS4.3) and the one that validates the insert infrastructure.
-- Drive/Mix are 0-127 amounts, matching the filter drive convention.
--
-- `prefix` namespaces the param ids per FX slot (Insert 1 leaves it nil/"" for
-- its original unprefixed ids -- fx_drive/fx_mix -- so existing patterns/scenes
-- keep working; Send 1/2 pass "send1_"/"send2_", Master passes "master_").
local Mode = {id = 1, name = "drive"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  return {
    Item.item(prefix .. "fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
