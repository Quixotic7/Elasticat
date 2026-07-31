local Mode = {id = 3, name = "chopped"}

-- Slice player (ElasticatSlicer): the region between start/end is cut into SLCS equal
-- slices played as a step-sequenced slicer -- one slice every SLEN steps (a step = a 16th),
-- tempo-locked, so raising BPM triggers slices faster. SLEN is in 0.05-step increments
-- (FN snaps to whole steps): with 16 slices, SLEN 1 = one slice per step (16 slices across
-- 16 steps, like slices in the 16 sequencer positions); SLEN 0.5 = every half step. Inside
-- each slot the slice loops-to-fill (LOOP=loop) for a clean MPC-style beat-repeat. Each
-- slice has an ATK / GATE / REL envelope with a 2-head crossfade on every slice change so a
-- long attack / full gate no longer clicks. GATE = % of the slot the slice sounds (1 = full,
-- lower = rhythmic gating). LOOP has 8 modes = chop / loop / ping-pong / runaway x forward
-- and reverse (rev = the slice READ plays backward). Track REVERSE plays the slice SEQUENCE
-- in reverse ORDER (last slice first); the LOOP "rev" modes reverse each slice's READ. Pitch
-- knob transposes the slice reads.
function Mode.source_items(Item)
  return {
    Item.item("chop_steps", "SLCS", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64}}),
    Item.item("chop_slice_len", "SLEN", {lockable = true, min = 0.05, max = 32, step = 0.05, fn_snap_multiple = 1}),
    Item.item("chop_attack", "ATK", {lockable = true, min = 0.0001, max = 0.2, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2}}),
    Item.item("chop_hold", "GATE", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 0.9, 1}}),
    Item.item("chop_release", "REL", {lockable = true, min = 0.0001, max = 0.2, step = 0.0005, snaps = {0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2}}),
    Item.item("chop_loop_mode", "LOOP", {lockable = true, options = 8, slow_option = 8})
  }
end

return Mode
