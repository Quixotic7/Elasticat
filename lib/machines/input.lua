-- INPUT source machine (owner 2026-08-02): the norns audio INPUT is the
-- track's sound source, so external gear runs through the track's filter /
-- amp / insert FX / sends. Playing-independent (audio flows regardless of
-- the transport), ignores warp/pitch.
--
-- While ANY active track uses this machine, the coordinator disables norns'
-- built-in input monitoring (audio.level_monitor(0)) -- otherwise the raw
-- input reaches the output twice -- and restores the saved monitor level as
-- soon as no track uses it (and at script cleanup).
local Machine = {
  id = 8,
  name = "input",
  is_slice = false
}

function Machine.source_items(Item)
  return {
    Item.blank(), Item.blank(), Item.blank(), Item.blank(),
    Item.blank(), Item.blank(), Item.blank(), Item.blank()
  }
end

function Machine.machine_items(Item)
  return {}
end

return Machine
