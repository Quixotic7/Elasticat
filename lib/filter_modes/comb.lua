-- Comb (#4): a tuned feedback comb (engine \elasticatFilterComb, stereo). TUNE sets
-- the comb frequency (the filter env transposes it), FB the feedback resonance, DAMP
-- a low-pass in the feedback path (each echo duller), MIX the dry/wet blend. Reuses
-- the shared filter param ids (TUNE=cutoff, FB=res, DAMP=drive, MIX=mix). All p-lockable.
local Mode = {id = 4, name = "comb"}

function Mode.source_items(Item)
  return {
    Item.item("filter_cutoff", "TUNE", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "FB", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_drive", "DAMP", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
