-- Limit (#19). Brickwall limiter + loudness for the master slot: push GAIN into
-- the CEILing. Dynamics, so it reads in real units (dB / ms) like Comp and Duck,
-- with FN snaps on clean values. No MIX. All p-lockable.
local Mode = {id = 19, name = "limit"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  -- GAIN snaps 0/+3/+6/+9/+12/+18 dB (knob = dB/18*127); CEIL spans -12..0 dB
  -- (owner) and snaps -12/-6/-3/-1/-0.3/0 dB (knob = (dB+12)/12*127).
  return {
    Item.item(prefix .. "limit_gain", "GAIN", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 21, 42, 64, 85, 127}}),
    Item.item(prefix .. "limit_ceil", "CEIL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 64, 95, 116, 124, 127}}),
    Item.item(prefix .. "limit_release", "REL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
