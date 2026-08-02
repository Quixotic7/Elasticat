-- Echo (#8). Ableton-Echo-style stereo delay: its own tempo-synced time with the
-- full classic/dotted/triplet division list, an offset that detunes the right tap,
-- a stereo/ping-pong image, a loop tone (lowpass on the repeats) and time wobble.
-- Reuses the shared delay_feedback (FBK) and fx_mix (MIX). Its own echo_time so the
-- simpler DELAY machine's serialized division list is untouched. All p-lockable.
local Mode = {id = 8, name = "echo"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "echo_time", "TIME", {lockable = true, options = 15}),
    Item.item(prefix .. "echo_offset", "OFST", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item(prefix .. "delay_feedback", "FBK", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "echo_mode", "MODE", {lockable = true, options = 2}),
    Item.item(prefix .. "echo_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "echo_wobble", "WOBL", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
