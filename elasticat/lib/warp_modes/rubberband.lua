local Mode = {id = 15, name = "rubberband"}

-- RubberBand: studio-grade time-stretch via the RubberBand UGen (two mono instances,
-- true stereo). STRCH = the playback rate (1 = realtime, 0.5 = half-speed / 2x stretch,
-- >1 = faster); pitch is held independent of stretch, and the track pitch knob
-- transposes (pitchShift). Forward only (a phase vocoder can't reverse). CPU-heavy
-- (two phase vocoders) -- a hero / 1-2 track mode. Needs the RubberBand .so built +
-- installed on the norns (ugens/build-rubberband.sh); falls back to a plain read
-- without it. (GPL v2+ library.)
function Mode.source_items(Item)
  return {
    Item.item("grain_speed", "STRCH", {lockable = true, min = 0.0625, max = 4, step = 0.01, snaps = {0.25, 0.5, 1, 2}})
  }
end

return Mode
