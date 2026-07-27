-- MIX: the 8-track overview page (master category, page 2).
--
-- The one screen that answers "what is my kit doing" without switching tracks:
-- all 8 tracks legible at once -- which is selected, which are muted, which are
-- beyond the active-track count, each one's machine, sample slot, volume, live
-- level and sequencer position.
--
-- Layout. The screen is 128px wide and 8 tracks divide it exactly, so the
-- column grid is the same "cell + 1px gutter" idiom as lib/ui/low_profile.lua
-- (which is 31 wide on a 32 pitch): here 15 wide on a 16 pitch, column t at
-- x = (t-1)*16. Vertical bands reuse the geometry the other pages already
-- established -- the chip band is LowProfile.CELL_H tall, and the bar band
-- starts at y=23 like page_render.lua's filter/envelope renders.
--
--   y11..y21  track chip   number; inverted when selected, dim when muted
--   y23..y29  machine code + sample slot
--   y31..y53  vertical bars   VOL (base value) | LIVE (metered level)
--   y55       sequencer position tick
--   y57..y63  param strip  the page's own K2/K3 items for the SELECTED track,
--                          so E2/E3 have a visible target (without it the page
--                          would edit values it never displays)
--
-- Brightness is taken from the existing vocabulary rather than invented:
-- LowProfile's value-bar levels (track 1, fill 6 unselected / 15 selected,
-- "modulated/live" 12) and its inverted-chip treatment (fill 15, content 0).
--
-- PERFORMANCE LAW (see page_render.lua's header and the freeze this script has
-- had before): screen.level() is set once per PASS, never per track. Every
-- draw op is bucketed by level first, then flushed -- so the cost is a fixed
-- ~10 level calls regardless of how many tracks are active.
--
-- Pure rendering: the caller resolves the 8 track descriptors, this module
-- never touches params, the engine, or the sequencer.

local LowProfile = include("lib/ui/low_profile")

local MixerPage = {}

local TRACKS = 8
local COL_PITCH = 16
local COL_W = 15
local CHIP_Y = 11
local CHIP_H = LowProfile.CELL_H          -- 11, same chip height as a param cell
local CODE_Y = 29                          -- text baseline for machine + slot
local BAR_Y = 31
local BAR_H = 23
local BAR_BOTTOM = BAR_Y + BAR_H - 1       -- 53
local BAR_W = 4
local VOL_X = 2                            -- inset within the column
local LIVE_X = 8
local TICK_Y = 55
local STRIP_Y = 56                         -- param strip band top (glyph tops)
local STRIP_BASELINE = 63

local floor = math.floor
local max = math.max

MixerPage.COL_PITCH = COL_PITCH
MixerPage.COL_W = COL_W
MixerPage.TRACKS = TRACKS

-- 2-character machine codes (lib/machines/registry.lua order): Loop,
-- Loop Trig, Grid Slice, Razor Slice. Two characters is what fits a 15px
-- column at the default font size.
MixerPage.MACHINE_CODES = {"LP", "LT", "GS", "RS"}

function MixerPage.column_x(track)
  return (track - 1) * COL_PITCH
end

-- Bucketed draw list: ops are collected per level and flushed in one pass each,
-- so screen.level() is called once per distinct level used, not once per track.
local function new_batch()
  return {order = {}, byLevel = {}}
end

local function push(batch, level, op)
  local bucket = batch.byLevel[level]
  if bucket == nil then
    bucket = {}
    batch.byLevel[level] = bucket
    batch.order[#batch.order + 1] = level
  end
  bucket[#bucket + 1] = op
end

local function rect(batch, level, x, y, w, h)
  if w >= 1 and h >= 1 then
    push(batch, level, {x = x, y = y, w = w, h = h})
  end
end

-- align: nil/"left" | "center" | "right"
local function text(batch, level, x, y, str, align)
  push(batch, level, {x = x, y = y, text = tostring(str), align = align})
end

local function flush(batch)
  for _, level in ipairs(batch.order) do
    screen.level(level)
    local has_rect = false
    for _, op in ipairs(batch.byLevel[level]) do
      if op.text ~= nil then
        screen.move(op.x, op.y)
        if op.align == "center" then
          screen.text_center(op.text)
        elseif op.align == "right" then
          screen.text_right(op.text)
        else
          screen.text(op.text)
        end
      else
        screen.rect(op.x, op.y, op.w, op.h)
        has_rect = true
      end
    end
    if has_rect then
      screen.fill()
    end
  end
end

-- Height in pixels of a bar filling `frac` (0..1) of the bar band. A non-zero
-- fraction always draws at least 1px, so a quiet-but-audible track is never
-- indistinguishable from a silent one.
local function bar_h(frac)
  frac = frac or 0
  if frac <= 0 then
    return 0
  end
  if frac > 1 then
    frac = 1
  end
  return max(1, floor(frac * BAR_H + 0.5))
end

-- The bottom strip: the page's own param items for the SELECTED track, laid out
-- evenly across the screen with the active K2/K3 pair inverted (the same
-- selected-chip language as LowProfile). `strip` is a list of
-- {label, value, selected}; an empty/absent list simply draws nothing.
local function draw_param_strip(batch, strip)
  local n = #strip
  if n == 0 then
    return
  end
  local slot_w = floor(128 / n)
  for i, entry in ipairs(strip) do
    local x = (i - 1) * slot_w
    local label_level, value_level = 3, 10
    if entry.selected then
      rect(batch, 15, x, STRIP_Y, slot_w - 1, STRIP_BASELINE - STRIP_Y + 1)
      label_level, value_level = 0, 0
    end
    text(batch, label_level, x + 2, STRIP_BASELINE - 1, entry.label or "")
    text(batch, value_level, x + slot_w - 3, STRIP_BASELINE - 1,
      tostring(entry.value or ""), "right")
  end
end

-- tracks: an array of 8 descriptors, each
--   {active, selected, muted, machine, slot, vol_frac, level_frac, has_content,
--    position_frac}
-- level_frac / position_frac are nil when unknown (a track the engine is not
-- reporting, or one with no pattern) and simply do not render -- the page never
-- substitutes another track's reading.
-- strip: optional list of {label, value, selected} for the bottom param row.
function MixerPage.draw(tracks, strip)
  tracks = tracks or {}
  local batch = new_batch()

  for t = 1, TRACKS do
    local info = tracks[t] or {}
    local x = MixerPage.column_x(t)
    local active = info.active ~= false
    local selected = info.selected == true
    local muted = info.muted == true

    -- ---- track chip -------------------------------------------------------
    -- Selected reads as LowProfile's inverted "locked chip": solid fill with
    -- dark content. Muted keeps the number but drops it to the dim level, the
    -- same cue the header uses for a silent track.
    local number_level
    if not active then
      number_level = 1
    elseif selected then
      rect(batch, 15, x, CHIP_Y, COL_W, CHIP_H)
      number_level = 0
    elseif muted then
      number_level = 3
    else
      number_level = 10
    end
    text(batch, number_level, x + floor(COL_W / 2), CHIP_Y + 8, t, "center")

    -- A muted track gets a strike-through so mute is readable at a glance even
    -- on the selected (inverted) column, where dimming the number is not
    -- available. It matches the number's own level so the strike never reads
    -- brighter than the digit it is crossing out.
    if active and muted then
      rect(batch, selected and 0 or 3, x + 2, CHIP_Y + 5, COL_W - 4, 1)
    end

    -- ---- machine ----------------------------------------------------------
    -- Centred, and dimmed to the "inactive" level when the track has no sample
    -- bound (slot 0) -- so an unloaded track is obvious without a second row.
    --
    -- The numeric sample slot deliberately is NOT shown here: a 3-digit slot
    -- (the pool goes to 128) plus the 2-char machine code is 18px of glyphs in
    -- a 15px column, and they collided. The machine is the identity that makes
    -- the column readable at a glance; the slot lives one keypress away on
    -- SOURCE, where it has room to be edited rather than just read.
    if active then
      local code = MixerPage.MACHINE_CODES[info.machine or 1] or "??"
      local has_sample = (info.slot == nil) or (info.slot >= 1)
      local code_level = 6
      if not has_sample then
        code_level = 2
      elseif muted then
        code_level = 3
      end
      text(batch, code_level, x + floor(COL_W / 2), CODE_Y, code, "center")
    end

    -- ---- bars -------------------------------------------------------------
    if active then
      -- VOL: dim full-height track + the filled portion (LowProfile levels).
      rect(batch, 1, x + VOL_X, BAR_Y, BAR_W, BAR_H)
      local vh = bar_h(info.vol_frac)
      if vh > 0 then
        rect(batch, muted and 3 or (selected and 15 or 6),
          x + VOL_X, BAR_BOTTOM - vh + 1, BAR_W, vh)
      end

      -- LIVE level: drawn only when this track is actually reporting. A track
      -- with no data leaves the column empty instead of borrowing a level.
      rect(batch, 1, x + LIVE_X, BAR_Y, BAR_W, BAR_H)
      local lh = bar_h(info.level_frac)
      if lh > 0 then
        rect(batch, 12, x + LIVE_X, BAR_BOTTOM - lh + 1, BAR_W, lh)
      end
    end

    -- ---- sequencer position tick -----------------------------------------
    -- A 2px mark travelling the column width shows each track running at its
    -- own pattern length. Tracks with no trigs show a dim baseline instead, so
    -- "has a pattern" is visible without reading the step row.
    if active and info.has_content then
      rect(batch, 2, x, TICK_Y, COL_W, 1)
      local pos = info.position_frac
      if pos ~= nil then
        local px = floor(pos * (COL_W - 2) + 0.5)
        rect(batch, selected and 15 or 9, x + px, TICK_Y, 2, 1)
      end
    end
  end

  draw_param_strip(batch, strip or {})
  flush(batch)
end

return MixerPage
