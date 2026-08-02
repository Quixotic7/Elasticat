-- Compressor (#6). Compander-based dynamics for per-track punch or master glue.
-- MIX < 127 = parallel (NY) compression. All amount knobs (0-127); the engine
-- maps them to threshold/ratio/attack/release/makeup in real units. Reuses the
-- shared fx_mix for the dry/wet. All p-lockable.
local Mode = {id = 6, name = "comp"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  -- Snaps land on clean unit values (computed inverse of the SynthDef maps, which
  -- the ID_FORMATTERS display mirrors): THRS -30..0 dB, RATO 1..20:1, ATK 1..100
  -- ms, REL 50..800 ms, MKUP 0..+12 dB. MIX keeps quarter snaps.
  return {
    Item.item(prefix .. "comp_thresh", "THRS", {lockable = true, min = 0, max = 127, step = 1, snaps = {2, 6, 14, 30, 62, 127}}),
    Item.item(prefix .. "comp_ratio", "RATO", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 29, 59, 88, 127}}),
    Item.item(prefix .. "comp_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1, snaps = {17, 55, 72, 98, 127}}),
    Item.item(prefix .. "comp_release", "REL", {lockable = true, min = 0, max = 127, step = 1, snaps = {32, 55, 79, 103, 127}}),
    Item.item(prefix .. "comp_makeup", "MKUP", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 17, 42, 77, 126}}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
