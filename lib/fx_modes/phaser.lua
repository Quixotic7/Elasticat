-- Phaser (#12). Cascaded allpass sweep. Shares modfx_rate/depth with Chorus +
-- Flanger; CNTR (sweep center), STGS (2/4/6/8 allpass stages, p-lockable option)
-- and FBK (resonance) are its own. Reuses fx_mix. All p-lockable.
local Mode = {id = 12, name = "phaser"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "modfx_rate", "RATE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "modfx_depth", "DPTH", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "phaser_center", "CNTR", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "phaser_stages", "STGS", {lockable = true, options = 4}),
    Item.item(prefix .. "phaser_feedback", "FBK", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
