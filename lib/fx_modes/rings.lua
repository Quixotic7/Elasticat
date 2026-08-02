-- Rings (#18). Ring mod + frequency shifter in one machine: RING = sig * SinOsc
-- (bells/robots), SHIFT = FreqShift with feedback (barberpole smear). FREQ is
-- BIPOLAR (direction matters for SHIFT); FINE adds slow-beat offsets. Reuses
-- modfx_tone (wet lowpass; exclusive per slot with the mod trio). MIX = fx_mix
-- (trailing). All p-lockable.
local Mode = {id = 18, name = "rings"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  local bp = {0, 32, 64, 96, 128}
  return {
    Item.item(prefix .. "rings_mode", "MODE", {lockable = true, options = 2}),
    Item.item(prefix .. "rings_freq", "FREQ", {lockable = true, min = 0, max = 128, step = 1, snaps = bp}),
    Item.item(prefix .. "rings_fine", "FINE", {lockable = true, min = 0, max = 128, step = 1, snaps = bp}),
    Item.item(prefix .. "rings_feedback", "FBK", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "modfx_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
