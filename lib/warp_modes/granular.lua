local Mode = {id = 4, name = "granular"}

-- Particle granular engine (ElasticatGrains): the playhead is a silent emitter; grains
-- read the sample as particles that wrap at the trim bounds. No dry/wet -- grains ARE
-- the output. GDEN density, GSIZ grain cycle length, SPRD emit-position spread, GSPD
-- grain speed (x playhead scan), RAND speed randomness, DIR forward<->backward morph.
function Mode.source_items(Item)
  return {
    Item.item("grain_density", "GDEN", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64}}),
    Item.item("grain_size", "GSIZ", {lockable = true, min = 0.002, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
    Item.item("grain_jitter", "SPRD", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}}),
    Item.item("grain_speed", "GSPD", {lockable = true, min = 0, max = 4, step = 0.01, snaps = {0, 0.25, 0.5, 1, 2, 4}}),
    Item.item("grain_speed_rand", "RAND", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.1, 0.25, 0.5, 1}}),
    Item.item("grain_direction", "DIR", {lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.5, 1}})
  }
end

return Mode
