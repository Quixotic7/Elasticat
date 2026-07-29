-- Wavetable Scan (warp mode 8 / engine mode 7). Loop-only. Playhead-independent:
-- the loop start/end range is a wavetable BANK -- WSIZ single-cycle slices spread
-- across it, each CYCW samples wide (its own control, so a small cycle stays clean
-- over a big range). MORF scans the bank, CROSSFADING between adjacent slice cycles
-- (smooth morph); an oscillator (freq from pitch, base C3) plays it. A built-in LFO
-- (LRAT/LDEP/LSHP: sine/tri/saw/s&h/rand) auto-scans MORF. Pitch it from the keyboard.
local Mode = {id = 8, name = "wavetable"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "MORF", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("wt_window", "WSIZ", {lockable = true, min = 2, max = 64, step = 1, snaps = {2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64}}),
    Item.item("wt_cycle", "CYCW", {lockable = true, min = 16, max = 8192, step = 1, snaps = {32, 64, 128, 256, 512, 1024, 2048, 4096}}),
    Item.item("wt_lfo_rate", "LRAT", {lockable = true, min = 0, max = 20, step = 0.01, snaps = {0, 0.1, 0.25, 0.5, 1, 2, 4, 8, 12, 16, 20}}),
    Item.item("wt_lfo_depth", "LDEP", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("wt_lfo_shape", "LSHP", {lockable = true, options = 5})
  }
end

return Mode
