-- DJ EQ (#13). Three-band isolator with kills -- a performance EQ, not a
-- surgical one. LOW/MID/HIGH are BIPOLAR gains (64 = unity, 0 = full kill, top =
-- boost) and p-lockable (stepped band-kills are a legit trick); XLOW/XHI set the
-- crossover splits. No MIX (an EQ at 50% wet is a phase mess). All p-lockable.
local Mode = {id = 13, name = "dj_eq"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local bp = {0, 32, 64, 96, 128}
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "eq_low", "LOW", {lockable = true, min = 0, max = 128, step = 1, snaps = bp}),
    Item.item(prefix .. "eq_mid", "MID", {lockable = true, min = 0, max = 128, step = 1, snaps = bp}),
    Item.item(prefix .. "eq_high", "HIGH", {lockable = true, min = 0, max = 128, step = 1, snaps = bp}),
    Item.item(prefix .. "eq_xlow", "XLOW", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "eq_xhi", "XHI", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
