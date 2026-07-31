local Machine = {
  id = 1,
  name = "loop",
  is_slice = false
}

function Machine.source_items(Item)
  return {
    Item.item("pitch", "P/T", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    Item.blank(),
    Item.item("xfade", "XFAD", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}}),
    Item.item("sample_slot", "SLOT", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 1, 2, 4, 8, 16, 32, 64, 128}}),
    Item.item("loop_start", "STRT", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
    Item.item("loop_end", "END", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
    Item.blank(),
    Item.item("loop_reverse", "REV", {lockable = true, binary = true, min = 0, max = 1, step = 1})
  }
end

function Machine.machine_items(Item)
  return {
    Item.item("loop_reverse", "LREV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
    Item.item("xfade", "XFAD", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}}),
    -- Playhead return mode when a step trig releases (return / boomerang / reset).
    -- P-lockable per step, so trigs with different Start points can each choose
    -- whether to snap back to the synced position (return) or hold where they land.
    Item.item("trig_release", "RLSE", {lockable = true, options = 3})
  }
end

return Machine
