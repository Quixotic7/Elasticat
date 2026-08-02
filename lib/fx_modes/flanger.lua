-- Flanger (#11). Short modulated delay with feedback -- jet swooshes to metallic
-- comb drones. Shares modfx_rate/depth/tone with Chorus + Phaser; FBK is its own
-- BIPOLAR feedback (64 = off, below = hollow/negative comb). Reuses fx_mix. All
-- p-lockable.
local Mode = {id = 11, name = "flanger"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "modfx_rate", "RATE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "modfx_depth", "DPTH", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "flanger_feedback", "FBK", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item(prefix .. "modfx_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
