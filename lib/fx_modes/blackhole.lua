-- Blackhole (#9). Huge, modulated, freeze-capable reverb (Eventide Blackhole
-- reference): a modulated allpass ring whose GRAV(ity) sets decay from short to
-- infinite -- at max GRAV the tail freezes and holds forever. Reuses the shared
-- reverb_size (SIZE), reverb_damp (HI, high-frequency damping) and fx_mix (MIX);
-- GRAV/MOD/LOW/PRE are new. The "instrument" reverb; best on a send. All p-lockable.
local Mode = {id = 9, name = "blackhole"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "reverb_size", "SIZE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "bh_gravity", "GRAV", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "bh_mod", "MOD", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "bh_low", "LOW", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "reverb_damp", "HI", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "bh_predelay", "PRE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
