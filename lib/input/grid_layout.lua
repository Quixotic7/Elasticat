-- One source of truth for the grid's PHYSICAL layout (elasticat-input-actions).
-- BOTH the input router (its modal nav bindings -- yes/no/arrows, driving menus/
-- pop-ups) and GridSequencer's base dispatch read their coordinates from here, so
-- moving a key to a different grid button is ONE edit and the two stay in
-- lockstep. Coordinates are 1-based {col, row} on a 16x8 grid; a region is
-- {row, cols = {min, max}}; a bare row number means the whole row.
--
-- The dispatch LOGIC (ordering, key-release semantics, context gates) stays in
-- GridSequencer:key -- only the coordinates live here. A grid-like controller
-- (a MIDI Launchpad, ...) that maps its pads to these coordinates drives the
-- same actions with no code change.
local GridLayout = {
  -- Modal / navigation keys. Also compiled into the router's GRID_KEYS, so these
  -- are the SAME buttons the base surface uses (e.g. yes = confirm AND the
  -- File-page hold-to-preview).
  yes   = {11, 6},   -- confirm / File-page hold-to-preview
  no    = {11, 7},   -- cancel
  up    = {13, 6},
  down  = {13, 7},
  left  = {12, 7},
  right = {14, 7},

  -- Modifier / momentary keys (GridSequencer handles their key-release itself).
  page_toggle = {16, 7},   -- hold = page-step layer over the step row
  fill        = {16, 6},   -- momentary FILL (FN latches)
  pattern     = {8, 5},    -- pattern-load overlay (FN = quantize-mode menu)

  -- Base-dispatch regions.
  category_row = 1,        -- row 1: category-select cols (CATEGORY_KEYS) / controls
  loop_row     = 2,        -- row 2: loop / slice control
  loop_row_hi  = 3,        -- row 3: loop overflow (division > 16) / slice control
  step_row     = 8,        -- row 8: step grid (page-step under page_toggle)
  octave = {row = 5, cols = {1, 2}},
  scene  = {row = 5, cols = {9, 16}},
  macro  = {row = 4, cols = {1, 4}},
  track  = {row = 4, cols = {8, 13}},   -- T1-T6 (track count is capped at 6)
  -- Bus pseudo-track keys (owner 2026-08-02): SEND 1 / SEND 2 / MASTER get the
  -- three keys right of the track row. Selecting one flips the SCREEN to that
  -- bus's pages (FX for sends; SOURCE = the mixer for master) -- the grid's
  -- step/loop surface keeps editing the last real track.
  bus    = {row = 4, cols = {14, 16}},
}

-- "col:row" string key, for the router's GRID_KEYS lookup table.
function GridLayout.key_id(coord)
  return coord[1] .. ":" .. coord[2]
end

-- True if (x, y) is exactly the {col, row} `coord`.
function GridLayout.is_key(coord, x, y)
  return x == coord[1] and y == coord[2]
end

-- True if (x, y) is inside `region`: {row, cols = {min, max}}, or a bare row.
function GridLayout.in_region(region, x, y)
  if type(region) == "number" then
    return y == region
  end
  return y == region.row and x >= region.cols[1] and x <= region.cols[2]
end

return GridLayout
