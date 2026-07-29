-- Harmonizer (warp mode 7 / engine mode 6). Loop-only for now: a slice machine
-- set to this mode falls back to the raw slice voice. Dry read at the transport
-- rate + a granular pitch-shifted harmony (timing stays locked). MIX = harmony
-- level (dry always present); INTV = the interval in semitones.
local Mode = {id = 7, name = "harmonizer"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "MIX", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("harm_interval", "INTV", {lockable = true, min = -24, max = 24, step = 1, snaps = {-24, -12, -7, -5, 0, 3, 4, 5, 7, 12, 24}})
  }
end

return Mode
