-- Delay: tempo-synced delay with a filter in the feedback loop. Time is a beat
-- division (options param, PRD SS5 -- not raw seconds, so it stays sync'd across
-- tempo changes); Feedback/Tone/Mix are 0-127 amounts.
--
-- `prefix` namespaces the param ids per FX slot -- see drive.lua's comment.
local Mode = {id = 2, name = "delay"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  return {
    Item.item(prefix .. "delay_time", "TIME", {lockable = true, options = 9}),
    Item.item(prefix .. "delay_feedback", "FBK", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "delay_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
