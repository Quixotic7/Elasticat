-- Lofi: bit-depth + sample-rate reduction (PRD SS4.3), built from core SC UGens
-- (Latch + round-to-step) since `Decimator` is a sc3-plugins UGen not present in
-- a stock install -- see Engine_Elasticat.sc. Bits and Rate read as the literal
-- output bit depth / sample rate (higher = cleaner, lower = more crushed); Mix
-- is the usual 0-127 amount.
--
-- `prefix` namespaces the param ids per FX slot -- see drive.lua's comment.
local Mode = {id = 4, name = "lofi"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  return {
    Item.item(prefix .. "lofi_bits", "BITS", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "lofi_rate", "RATE", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
