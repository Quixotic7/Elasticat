-- Cassette (#16). Play the loop like degraded media (SP-404 Cassette/Vinyl Sim
-- territory): pitch wobble, hiss, crackle, dropouts, band-limit. REUSES tape_wow /
-- tape_flutter (shared with Tape Echo, exclusive per slot). MIX = fx_mix
-- (trailing). All p-lockable.
local Mode = {id = 16, name = "cassette"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "tape_wow", "WOW", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "tape_flutter", "FLUT", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "cass_noise", "NOIS", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "cass_crackle", "CRKL", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "cass_drop", "DROP", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "cass_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
