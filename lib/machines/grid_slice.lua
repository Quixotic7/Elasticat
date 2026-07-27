local Machine = {
  id = 3,
  name = "grid_slice",
  is_slice = true
}

function Machine.source_items(Item)
  return {
    Item.item("pitch", "P/T", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    Item.item("slice_play_mode", "PLAY", {lockable = true, options = 4}),
    Item.item("slice_index", "SLIC", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
    Item.item("loop_start", "STRT", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
    Item.item("loop_end", "END", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
    Item.item("slice_count", "CNT", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("slice_reverse", "REV", {lockable = true, binary = true, min = 0, max = 1, step = 1})
  }
end

function Machine.source_page2_items(Item)
  return {
    -- WARP algo selector, same as the loop machine's WARP page -- it picks the
    -- per-warp slice voice def. Not p-lockable and not editable during playback
    -- (all slices in a run share one warp).
    Item.item("mode", "WARP", {lockable = false, no_edit_playing = true, options = 6}),
    Item.item("slice_sync", "SYNC", {lockable = false, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_rate", "RATE", {lockable = true, min = 0.125, max = 8, step = 0.01, snaps = {0.125, 0.25, 0.5, 1, 2, 4, 8}})
  }
end

function Machine.machine_items(Item)
  return {
    Item.item("slice_count", "SLIC", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("slice_play_mode", "PLAY", {lockable = true, options = 4}),
    Item.item("slice_reverse", "SREV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_sync", "SYNC", {lockable = false, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_rate", "RATE", {lockable = true, min = 0.125, max = 8, step = 0.01, snaps = {0.125, 0.25, 0.5, 1, 2, 4, 8}})
  }
end

return Machine
