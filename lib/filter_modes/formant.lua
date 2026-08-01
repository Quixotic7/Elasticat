-- Formant (#5): a vowel-morphing bandpass bank (engine \elasticatFilterFormant,
-- stereo). VOWEL morphs A->E->I->O->U, CUT transposes the formants (the filter env
-- rides it), RES sharpens the bands, MIX the dry/wet blend. Reuses the shared filter
-- param ids (VOWEL=morph, CUT=cutoff, RES=res, MIX=mix). All p-lockable.
local Mode = {id = 5, name = "formant"}

function Mode.source_items(Item)
  return {
    Item.item("filter_morph", "VOWEL", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
    Item.item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
    Item.item("filter_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
  }
end

return Mode
