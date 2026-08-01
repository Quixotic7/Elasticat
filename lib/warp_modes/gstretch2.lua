local Mode = {id = 12, name = "gstretch2"}

-- GStretch2: BPM/clock-synced clean stretch. Like GStretch (varispeed reader + pitch-
-- correct, held pitch) but the read rate is TEMPO-derived -- the region traverses once
-- per loop (loopBeats), so a 16-step sample loops every 16 steps at STRCH = warp = 1.
-- STRCH and the RATE (warp) slot deviate from the grid; pitch stays held. SMTH = the
-- pitch-shifter's time dispersion (higher = smoother / less metallic, slightly softer).
function Mode.source_items(Item)
  return {
    Item.item("grain_speed", "STRCH", {lockable = true, min = 0.0625, max = 4, step = 0.01, snaps = {0.25, 0.5, 1, 2}}),
    Item.item("grain_size", "PWIN", {lockable = true, min = 0.02, max = 0.5, step = 0.001, snaps = {0.05, 0.1, 0.2, 0.3, 0.5}}),
    Item.item("grain_density", "SMTH", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 4, 8, 16, 32, 64}})
  }
end

return Mode
