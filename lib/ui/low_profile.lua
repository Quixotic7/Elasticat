-- Generic "low-profile" parameter cell (owner spec + pixel mockups in
-- elasticat-design-images/lowprofile_param_{sel,notsel}.png). A 31x11 box:
--   y1-5  parameter NAME (or, while editing, the live value), left at x+1
--   y7-8  VALUE bar (2px) -- the base track value; filled + a dim track
--   y9    ACTUAL bar (1px) -- the value after crossfade / modulation / macro
--          preview; brighter when something is moving or p-locking it
-- A row divides into 4 cells at x = index*32 + 1 (1px gap between). The cell
-- is pure rendering: the caller resolves value_frac / actual_frac (0..1) and
-- the state flags. Bipolar params fill from the centre.
--
-- Brightness (decoded from the mockups, norns levels 0-15):
--   name       unselected 3   selected 15
--   value fill unselected 6   selected 15     track (unfilled) 1
--   actual     unselected 3   selected 6      +bump when modulated/locked
-- INVERTED (a step / mod key / crossfader is p-locking this param, or it's
-- assigned as a mod target): the cell fills bright and draws its content dark,
-- the same "locked chip" language used elsewhere.
local LowProfile = {}

local CELL_W = 31
local CELL_H = 11
local BAR_X = 1              -- bars/name inset 1px inside the cell
local BAR_W = 29            -- inner width (x+1 .. x+29)
local floor = math.floor
local max = math.max
local min = math.min

-- Left edge of cell `index` (0-3) in a 4-up row.
function LowProfile.cell_x(index)
  return index * 32 + 1
end

LowProfile.CELL_W = CELL_W
LowProfile.CELL_H = CELL_H

local function bar_len(frac)
  frac = frac or 0
  if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
  return floor(frac * BAR_W + 0.5)
end

-- opts:
--   x, y            cell top-left
--   label           parameter name (shown unless editing)
--   display_value   string shown in the name row while editing
--   editing         show display_value instead of label
--   value_frac      0..1 base value (the VALUE bar)
--   actual_frac     0..1 post-mod value (the ACTUAL bar); defaults to value
--   centered        bipolar: both bars fill from the centre
--   selected        brighter palette
--   modulated       actual bar is brighter (something is moving/locking it)
--   inverted        p-lock / mod-target: fill bright, draw content dark
function LowProfile.draw(opts)
  local x, y = opts.x, opts.y
  local value_frac = opts.value_frac or 0
  local actual_frac = opts.actual_frac or value_frac
  local sel = opts.selected == true
  local inv = opts.inverted == true

  local name_level = inv and 0 or (sel and 15 or 3)
  local fill_level = inv and 0 or (sel and 15 or 6)
  local actual_level
  if inv then
    actual_level = 0
  else
    local base = sel and 6 or 3
    actual_level = opts.modulated and (sel and 15 or 12) or base
  end

  -- Inverted background chip.
  if inv then
    screen.level(15)
    screen.rect(x, y, CELL_W, CELL_H)
    screen.fill()
  end

  -- Name (or the live value while editing), row y+1..y+5. The VALUE is hard-capped
  -- to 5 chars (owner) -- the cell is too narrow for more; the header keeps the
  -- full value. The label is already a short (<=4 char) name, so it is left as-is.
  local text = opts.label or ""
  if opts.editing and opts.display_value ~= nil then
    text = string.sub(tostring(opts.display_value), 1, 5)
  end
  screen.level(name_level)
  screen.move(x + BAR_X, y + 6)
  screen.text(tostring(text))

  -- VALUE bar (2px, y+7..y+8): dim full-width track, then the filled portion.
  screen.level(inv and 6 or 1)
  screen.rect(x + BAR_X, y + 7, BAR_W, 2)
  screen.fill()
  local len = bar_len(value_frac)
  if opts.centered then
    local half = floor(BAR_W / 2)
    local mid = x + BAR_X + half
    local d = floor((value_frac - 0.5) * BAR_W + 0.5)
    screen.level(fill_level)
    if d >= 0 then screen.rect(mid, y + 7, max(d, 1), 2)
    else screen.rect(mid + d, y + 7, -d, 2) end
    screen.fill()
  else
    -- Clamp to >= 1px: a param morphed to 0 still reads as "present, at zero"
    -- instead of an empty cell (owner spec, #46).
    screen.level(fill_level)
    screen.rect(x + BAR_X, y + 7, max(len, 1), 2)
    screen.fill()
  end

  -- ACTUAL bar (1px, y+9): filled only, no track.
  local alen = bar_len(actual_frac)
  screen.level(actual_level)
  if opts.centered then
    local half = floor(BAR_W / 2)
    local mid = x + BAR_X + half
    local d = floor((actual_frac - 0.5) * BAR_W + 0.5)
    if d >= 0 then screen.rect(mid, y + 9, max(d, 1), 1)
    else screen.rect(mid + d, y + 9, -d, 1) end
    screen.fill()
  else
    -- Clamp to >= 1px, same reasoning as the VALUE bar above.
    screen.rect(x + BAR_X, y + 9, max(alen, 1), 1)
    screen.fill()
  end
end

-- One 3-pixel selection corner bracket at a cell corner (#46). `kind` is "tl"
-- (top-left) or "br" (bottom-right). The bracket is an L of 3 pixels: the
-- corner pixel plus one along each edge. Top-left shifts 1px LEFT into the
-- black border so it never overdraws the label text. The caller sets the level
-- and batches the fill -- these only add rects, so a whole group's brackets
-- stay in one level pass (redraw-metro safety). Drawn at the GROUP edges (the
-- leftmost/rightmost selected cell), not per cell, so a K2/K3 pair reads as one
-- bracket, not a box around each param.
function LowProfile.corner_rects(x, y, kind)
  if kind == "tl" then
    screen.rect(x - 1, y, 2, 1)          -- corner + one right (top edge)
    screen.rect(x - 1, y, 1, 2)          -- corner + one down (left edge)
  else
    local bx = x + CELL_W - 1
    local by = y + CELL_H - 1
    screen.rect(bx - 1, by, 2, 1)        -- corner + one left (bottom edge)
    screen.rect(bx, by - 1, 1, 2)        -- corner + one up (right edge)
  end
end

return LowProfile
