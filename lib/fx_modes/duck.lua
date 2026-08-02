-- Duck (#14). Sidechain ducker: the slot signal dips whenever the dry program
-- plays (keyed off the master bus). Best on a SEND return -- delay/reverb tails
-- pump out of the way of the dry loop (MPC Mother-Ducker style). No MIX. All
-- p-lockable.
local Mode = {id = 14, name = "duck"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  -- Snaps on clean units (inverse of the SynthDef maps, mirrored by ID_FORMATTERS):
  -- AMNT -3..-20 dB max reduction, ATK 1..50 ms, REL 50..1000 ms. SENS stays raw.
  return {
    Item.item(prefix .. "duck_amount", "AMNT", {lockable = true, min = 0, max = 127, step = 1, snaps = {37, 63, 95, 114}}),
    Item.item(prefix .. "duck_sens", "SENS", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "duck_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 52, 75, 104, 127}}),
    Item.item(prefix .. "duck_release", "REL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 28, 64, 92, 120}})
  }
end

return Mode
