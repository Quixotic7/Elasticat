-- Formant (warp mode 10 / engine mode 9). LOOP-ONLY and TRACK-1-ONLY. Shares the
-- \elasticatSpectral FFT def with Spectral Freeze. FORM shifts the spectral
-- envelope (a first-pass formant/timbre shift via PV_MagShift); pitchMod -> FORM.
-- FRZE is on the shared def too, so you can freeze AND formant-shift a drone.
local Mode = {id = 10, name = "formant", loop_only = true, track1_only = true}

function Mode.source_items(Item)
  return {
    Item.item("formant_shift", "FORM", {lockable = true, min = -24, max = 24, step = 1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    Item.item("freeze_amount", "FRZE", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.5, 1}})
  }
end

return Mode
