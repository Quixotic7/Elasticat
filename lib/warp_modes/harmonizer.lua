-- Harmonizer (warp mode 7 / engine mode 6). Loop-only for now: a slice machine
-- set to this mode falls back to the raw slice voice. Dry read at the transport
-- rate + up to THREE pitch-shifted harmony voices (timing stays locked). MIX =
-- harmony level (dry always present); IN1/IN2/IN3 = the intervals in semitones,
-- 0 = that voice OFF -- so stack IN2/IN3 to build chords (owner).
local Mode = {id = 7, name = "harmonizer"}

function Mode.source_items(Item)
  local intervals = {-24, -12, -7, -5, -3, 0, 3, 4, 5, 7, 12, 24}
  return {
    Item.item("mode_macro", "MIX", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("harm_interval", "IN1", {lockable = true, min = -24, max = 24, step = 1, snaps = intervals}),
    Item.item("harm_interval2", "IN2", {lockable = true, min = -24, max = 24, step = 1, snaps = intervals}),
    Item.item("harm_interval3", "IN3", {lockable = true, min = -24, max = 24, step = 1, snaps = intervals})
  }
end

return Mode
