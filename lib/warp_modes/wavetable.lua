-- Wavetable Scan (warp mode 8 / engine mode 7). Loop-only for now. The transport
-- phase chooses WHICH window (wt_window samples) to scan; an oscillator (freq from
-- pitch, base ~C3) reads that window as a single cycle. MORF = morph from the
-- direct sample read to the wavetable oscillator; WSIZ = window (cycle) length.
local Mode = {id = 8, name = "wavetable"}

function Mode.source_items(Item)
  return {
    Item.item("mode_macro", "MORF", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
    Item.item("wt_window", "WSIZ", {lockable = true, min = 16, max = 8192, step = 1, snaps = {32, 64, 128, 256, 512, 1024, 2048, 4096}})
  }
end

return Mode
