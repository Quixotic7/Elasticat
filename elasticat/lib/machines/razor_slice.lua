local GridSlice = include("lib/machines/grid_slice")

local Machine = {}
for key, value in pairs(GridSlice) do
  Machine[key] = value
end

Machine.id = 4
Machine.name = "razor_slice"

function Machine.source_items(Item)
  return {
    Item.item("pitch", "P/T", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
    Item.item("slice_play_mode", "PLAY", {lockable = true, options = 6}),
    Item.item("slice_index", "SLIC", {lockable = true, min = 1, max = 32, step = 1, snaps = {1, 2, 4, 8, 16, 32}}),
    Item.item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
    -- CHOK: per-slice choke group (MPC mute group, None = off), a pseudo that
    -- edits the held/selected slice -- not a track param.
    Item.item("slice_choke", "CHOK", {pseudo = "slice_choke", lockable = false, min = 0, max = 8, step = 1}),
    Item.blank(),
    Item.blank(),
    Item.item("slice_reverse", "REV", {lockable = true, binary = true, min = 0, max = 1, step = 1})
  }
end

return Machine
