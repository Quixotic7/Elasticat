-- None: dry passthrough. Selecting this machine bypasses whichever slot has it
-- (Insert 1, Send 1/2, or the Master insert) -- the engine still runs a
-- trivial `\elasticatFxNone` synth (Out.ar(out, In.ar(in, 2))) so the chain
-- graph is always present and switching machines is a real respawn, not a
-- special-cased silence. No p-lockable params.
local Mode = {id = 0, name = "none"}

function Mode.source_items(Item, prefix)
  return {}
end

return Mode
