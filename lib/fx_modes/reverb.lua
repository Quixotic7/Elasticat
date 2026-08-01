-- Reverb: algorithmic reverb (SC FreeVerb2 -- see Engine_Elasticat.sc). Size,
-- Damp and Mix are 0-127 amounts.
--
-- `prefix` namespaces the param ids per FX slot -- see drive.lua's comment.
local Mode = {id = 3, name = "reverb"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  return {
    Item.item(prefix .. "reverb_size", "SIZE", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "reverb_damp", "DAMP", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
