-- NEIGHBOR source machine (owner 2026-08-02): the track's sound source is the
-- OUTPUT of the track one index to the LEFT (track N-1), rerouted in full --
-- the left track is audible only THROUGH this one (Elektron-style neighbor).
-- Stacks two tracks for a longer serial chain: left's filter+insert feed into
-- this track's filter+insert. Tracks 2-6 only (track 1 has no left neighbor;
-- the source_machine action rejects it there).
--
-- The reader is playing-independent (audio flows regardless of this track's
-- transport) and ignores warp/pitch -- everything audible here is the left
-- track plus THIS track's filter / amp / insert FX / sends.
local Machine = {
  id = 7,
  name = "neighbor",
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
