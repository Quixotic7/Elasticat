-- Chorus (#10). Dual-voice modulated delay; the thickener. Shares the modulation
-- trio (modfx_rate/depth/tone) with Flanger + Phaser -- they are exclusive per
-- slot, so sharing carries the knob across a machine swap and keeps the param
-- count down. WDTH is its own (L/R LFO phase offset). Reuses fx_mix. All p-lockable.
local Mode = {id = 10, name = "chorus"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "modfx_rate", "RATE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "modfx_depth", "DPTH", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "chorus_width", "WDTH", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "modfx_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
