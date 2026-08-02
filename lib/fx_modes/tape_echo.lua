-- Tape Echo (#15). The delay with the tape loop misbehaving: wow/flutter wobble
-- and saturation inside the feedback path. REUSES echo_time (division list),
-- delay_feedback (FBK) and echo_tone (loop lowpass) -- machines are exclusive per
-- slot, so sharing carries the knobs across an ECHO <-> TAPE ECHO swap. New:
-- tape_wow / tape_flutter / tape_sat. MIX = fx_mix (trailing). All p-lockable.
local Mode = {id = 15, name = "tape_echo"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  return {
    Item.item(prefix .. "echo_time", "TIME", {lockable = true, options = 15}),
    Item.item(prefix .. "delay_feedback", "FBK", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "tape_wow", "WOW", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "tape_flutter", "FLUT", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "tape_sat", "SAT", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "echo_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
  }
end

return Mode
