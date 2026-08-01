local Mode = {id = 13, name = "chopped"}

-- CHOPPED (owner): the Digitakt-style "hacky" timestretch -- the trick you'd use on a
-- box with no timestretching. A clock-synced LINEAR RAMP sweeps the sample START across
-- the loop region (one full sweep per loop), and a grain fires every SLEN steps reading
-- from the ramp's current start at NATURAL pitch, gated by an AHR envelope. So each step
-- plays a different slice of the sample; at the native tempo they reconstruct it, at any
-- other main BPM they stretch it -- pitch unchanged. SLEN = grain rate (steps per grain);
-- GATE = how much of each slot the grain sounds (lower = rhythmic gating, 1 = smooth);
-- ATK/REL taper each grain (declick). Track reverse sweeps the ramp backward. Cheap DSP
-- (one read + envelope), so it stays responsive. Shares Domino's chop_* param ids.
-- Page order (owner): top row Warp / SLEN / GATE / -, bottom row ATK / REL / - /
-- Rate (Warp + Rate are added by the coordinator in slots 1 and 8; the blanks pad
-- the freed slots).
function Mode.source_items(Item)
  return {
    Item.item("chop_slice_len", "SLEN", {lockable = true, min = 0.05, max = 32, step = 0.05, fn_snap_multiple = 1}),
    Item.item("chop_hold", "GATE", {lockable = true, min = 0.01, max = 1, step = 0.01, snaps = {0.1, 0.25, 0.5, 0.75, 0.9, 1}}),
    Item.blank(),
    Item.item("chop_attack", "ATK", {lockable = true, min = 0.0002, max = 0.5, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5}}),
    Item.item("chop_release", "REL", {lockable = true, min = 0.0002, max = 0.5, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5}}),
    Item.blank()
  }
end

return Mode
