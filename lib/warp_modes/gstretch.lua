local Mode = {id = 13, name = "gstretch"}

-- GStretch: clean pitch-preserving time-stretch. Architecture (owner's idea): the
-- click-free ElasticatReader reads the buffer VARISPEED (slower = stretched, pitched
-- down), then a real-time pitch-shifter restores the pitch -- so pitch is HELD,
-- independent of stretch, and the read stays scrubbable/loopable. STRCH = stretch
-- (read speed; 1 = realtime, <1 = slower/stretched). PWIN = pitch-shifter window
-- (bigger = smoother pitch, more smear). Pitch held; the track pitch knob transposes.
-- Reuses GText's grain_speed/grain_size params; its own engine (\elasticatGStretch)
-- is tuned separately from the locked GText. (SC PitchShift now; RubberBand later.)
function Mode.source_items(Item)
  return {
    Item.item("grain_speed", "STRCH", {lockable = true, min = 0.0625, max = 4, step = 0.01, snaps = {0.125, 0.25, 0.5, 1, 2}}),
    Item.item("grain_size", "PWIN", {lockable = true, min = 0.02, max = 0.5, step = 0.001, snaps = {0.05, 0.1, 0.2, 0.3, 0.5}}),
    Item.item("grain_density", "SMTH", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 4, 8, 16, 32, 64}})
  }
end

return Mode
