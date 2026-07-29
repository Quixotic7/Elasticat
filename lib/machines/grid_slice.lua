local Machine = {
  id = 3,
  name = "grid_slice",
  is_slice = true
}

function Machine.source_items(Item)
  return {
    Item.item("pitch", "P/T", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    Item.item("slice_play_mode", "PLAY", {lockable = true, options = 6}),
    Item.item("slice_index", "SLIC", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
    -- Sample START/END (loop_start/end) are HIDDEN for the slice machine: the CNT
    -- slices divide the whole trim window, so those points do nothing here (owner)
    -- -- carve a window with the Range page instead. CNT/REV/CHOK fill the bottom
    -- row. CHOK is the per-slice choke group (MPC mute group, None = off), a
    -- pseudo that edits the held/selected slice -- not a track param.
    Item.item("slice_count", "CNT", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("slice_reverse", "REV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_choke", "CHOK", {pseudo = "slice_choke", lockable = false, min = 0, max = 8, step = 1}),
    Item.blank()
  }
end

-- NOTE: no static source_page2_items. The WARP page is built dynamically by the
-- coordinator (page_items_for, source page 3) so it shows the SAME warp-mode
-- params as the loop machine (grain size/density, OLA window, PC window, ... --
-- WarpRegistry.source_items for the current mode), with the slice machine's SYNC
-- and RATE appended. A static list here could not read the current warp mode.

function Machine.machine_items(Item)
  return {
    Item.item("slice_count", "SLIC", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("slice_play_mode", "PLAY", {lockable = true, options = 6}),
    Item.item("slice_reverse", "SREV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_ratchet", "RTCH", {lockable = true, min = 1, max = 4, step = 1, snaps = {1, 2, 3, 4}}),
    Item.item("slice_sync", "SYNC", {lockable = false, binary = true, min = 0, max = 1, step = 1}),
    Item.item("slice_rate", "RATE", {lockable = true, min = 0.125, max = 8, step = 0.01, snaps = {0.125, 0.25, 0.5, 1, 2, 4, 8}})
  }
end

return Machine
