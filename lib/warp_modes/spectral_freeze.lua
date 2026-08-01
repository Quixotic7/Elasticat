-- Spectral Freeze (warp mode 9 / engine mode 8). LOOP-ONLY and TRACK-1-ONLY (FFT
-- cost -- other tracks fall back to tape in spawnMode). Shares the
-- \elasticatSpectral FFT def with Formant. Holds the magnitude spectrum at the
-- playhead into a drone: scrub the playhead, then raise FRZE to capture that
-- point. BLUR smears it. (FFT adds a little latency -- fine for pads.)
local Mode = {id = 9, name = "spectral_freeze", loop_only = true, track1_only = true}

function Mode.source_items(Item)
  return {
    Item.item("freeze_amount", "FRZE", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.5, 1}}),
    Item.item("spectral_blur", "BLUR", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}})
  }
end

return Mode
