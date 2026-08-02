-- Motion (#17). Stereo width + tempo-synced tremolo/autopan in one machine (the
-- filter M/S matrix idiom makes width nearly free). WDTH is BIPOLAR (64 = unity,
-- 0 = mono, top = wide); RATE is a synced division shared by TREM (in-phase level
-- mod) and PAN (opposite-phase L/R). No MIX -- depths at 0 = bypass. All
-- p-lockable except nothing: everything here locks.
local Mode = {id = 17, name = "motion"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "motion_width", "WDTH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item(prefix .. "motion_rate", "RATE", {lockable = true, options = 16}),
    Item.item(prefix .. "motion_trem", "TREM", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "motion_pan", "PAN", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    -- opt_coarse: 3 options flip past too fast at a detent each (owner) --
    -- require 4 detents per shape step.
    Item.item(prefix .. "motion_shape", "SHPE", {lockable = true, options = 3, opt_coarse = 4})
  }
end

return Mode
