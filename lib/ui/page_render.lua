-- Elektron-style (Digitakt/Digitone) parameter page renderer for the generic
-- K2/K3-pair param pages (master/pattern/trig/source-machine/warp/filter/amp/
-- fx/mod). Replaces the old bare label+value cells with a structured 2x4 cell
-- grid -- label on top (small/dim), value below (bright), a position bar under
-- each numeric value -- plus per-category widgets in the unused cell space:
--   FILTER p1  filter response curve (type/morph, cutoff, res, balance)
--   FILTER p2  filter envelope sketch (AHR/ADSR, height scaled by DEPTH)
--   AMP p1     amp envelope sketch (AHR/ADSR)
--   FX p1      Insert 1 identity banner (active machine name, big type)
--   FX p2      Send 1/2 identity rows (machine names + level bars)
--
-- Pure rendering: values are read through the injected param_values object
-- (which already resolves held-step p-locks / scene locks / step-lock bases)
-- and the `value` callback (param_value_or) for settings that aren't page
-- items (env modes, machine selectors). No engine calls, no param writes.
--
-- PERFORMANCE LAW (this script has frozen before -- see draw_waveform's
-- comment in source_page.lua): screen.level() is set once per *pass*, never
-- per cell or per pixel. Cells are drawn in level-batched passes (all dim
-- labels, then all bright labels, ...), and curves are short polylines
-- (<= N_CURVE+1 points) drawn with move/line + one stroke.
local LowProfile = include("lib/ui/low_profile")

local PageRender = {}
PageRender.__index = PageRender

local CELL_W = 32
local CELL_H = 25
local ROW_Y = {12, 39}

-- Filter page (owner redesign, elasticat-design-images/filterDesign.png): a
-- low-profile param row (CUT/RES/MORPH-or-TYPE/DEPTH) over a 42-bar render.
local FILTER_ROW_Y = 11        -- low-profile cells sit at y=11
local FILTER_REND_Y = 23       -- bar render region top
local FILTER_REND_H = 41       -- ... to y=63
local FILTER_BARS = 42
local FILTER_BAR_STEP = 3      -- 2px bar + 1px gap; bar i (1..42) at x = 3*i
-- FILTER ENV page: low-profile params top AND bottom, envelope bars between,
-- same bar grid/width as the filter render but shorter (y23..y51).
local FENV_ROW_TOP_Y = 11
local FENV_ROW_BOTTOM_Y = 53
local FENV_REND_Y = 23
local FENV_REND_H = 29

-- FX slot pages (fx category pages 1/3/4/5): identity-banner label + the
-- machine-selector param each page's widget reads. Page 2 (SENDS) has its own
-- widget. Keep in sync with lib/pages/model.lua's fx pages / page_items_for.
local FX_SLOT_PAGES = {
  [1] = {label = "INSERT 1", machine = "fx_insert1_machine"},
  [3] = {label = "SEND 1", machine = "send1_machine"},
  [4] = {label = "SEND 2", machine = "send2_machine"},
  [5] = {label = "MASTER", machine = "master_fx_machine"}
}
local BAR_W = 28
local N_CURVE = 22

local floor = math.floor
local exp = math.exp
local abs = math.abs
local max = math.max
local min = math.min

-- Bipolar 0-128 params (64 = center): their position bar fills from the
-- middle outward instead of from the left.
local CENTERED = {
  pan = true,
  crossfade = true,
  filter_morph = true,
  filter_balance = true,
  filter_env_depth = true,
  lfo1_depth = true,
  lfo2_depth = true,
  menv_depth = true
}

function PageRender.new(opts)
  opts = opts or {}
  return setmetatable({
    param_values = opts.param_values,
    value = opts.value, -- param_value_or(id, default)
    -- display_values(item, raw) -> base_raw, actual_raw, modulated. Splits the
    -- low-profile cell's two bars (track value vs post-crossfade/macro/mod
    -- value); defaults to "actual == base" when not injected.
    display_values = opts.display_values,
    -- mod_offsets() -> cutoff_offset, res_offset (in param units) from the
    -- engine's live modulation feed; drives the filter render during playback.
    mod_offsets = opts.mod_offsets,
    filter_names = opts.filter_names or {},
    fx_names = opts.fx_names or {}
  }, PageRender)
end

-- Cell index -> top-left corner. Indices past 8 clamp onto the bottom row,
-- matching the old renderer's behavior for over-long item lists.
local function cell_pos(i)
  local col = (i - 1) % 4
  local row = floor((i - 1) / 4)
  if row > 1 then
    row = 1
  end
  return col * CELL_W, ROW_Y[row + 1]
end

local function last_non_blank(items)
  local last = 0
  for i = 1, #items do
    if not items[i].blank then
      last = i
    end
  end
  return last
end

-- Which trailing bottom-row cells a category widget occupies, if any.
-- Returns first cell, last cell, method name.
function PageRender:widget_span(category, page_index, items)
  if category == "amp" and page_index == 1 then
    -- The envelope IS the interface (owner spec): the env param cells are
    -- hidden and the whole top row draws the shape, with the selected pair's
    -- stage points marked for direct E2/E3 editing. PAN/VOL keep cells 7-8.
    return 1, 4, "draw_amp_env"
  elseif category == "filter" then
    if page_index == 2 then
      -- Same direct-editing treatment for the filter envelope; DPTH stays a
      -- real cell in the bottom row.
      return 1, 4, "draw_filter_env"
    end
    local start = max(last_non_blank(items) + 1, 5)
    if start > 8 then
      return nil
    end
    if page_index == 1 then
      return start, 8, "draw_filter_curve"
    end
    return nil
  elseif category == "fx" and FX_SLOT_PAGES[page_index] ~= nil then
    -- Insert 1 / Send 1 / Send 2 / Master slot pages (fx pages 1/3/4/5) all
    -- share the identity-banner widget, keyed per page below.
    local start = max(last_non_blank(items) + 1, 5)
    if start > 8 then
      return nil
    end
    return start, 8, "draw_fx_slot"
  elseif category == "fx" and page_index == 2 then
    return 5, 8, "draw_fx_sends"
  end
  return nil
end

local function in_widget(i, wstart, wend)
  return wstart ~= nil and i >= wstart and i <= wend
end

-- A cell is drawn when it has a real item and isn't covered by the widget.
local function cell_visible(i, item, wstart, wend)
  return item ~= nil and not item.blank and not in_widget(i, wstart, wend)
end

-- 0..1 position of an item's raw value inside its min/max range, or nil when
-- the item has no numeric range to show (options/file items).
local function item_frac(item, raw)
  if type(raw) ~= "number" or item.min == nil or item.max == nil
    or item.options ~= nil or item.max <= item.min then
    return nil
  end
  local frac = (raw - item.min) / (item.max - item.min)
  if frac < 0 then
    return 0
  elseif frac > 1 then
    return 1
  end
  return frac
end

-- Resolve a param value for a widget: prefer the matching page item (so held
-- p-locks / scene locks show live in the widget geometry), else fall back to
-- the plain param value.
function PageRender:item_value(items, id, default)
  for i = 1, #items do
    local it = items[i]
    if it.id == id then
      local raw = self.param_values:item_raw_value(it)
      if type(raw) == "number" then
        return raw
      end
      return default
    end
  end
  return self.value(id, default)
end

-- Faint Elektron-style cell frame: one horizontal divider between the rows,
-- vertical dividers between columns. Bottom-row dividers inside the widget
-- region are skipped so the widget gets an unbroken canvas.
function PageRender:draw_cells(items, wstart, wend, sel_lo, sel_hi)
  local pv = self.param_values

  -- Pass 1: labels, unselected (dim).
  screen.level(3)
  for i = 1, #items do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) and (i < sel_lo or i > sel_hi) then
      local x, y = cell_pos(i)
      screen.move(x + 2, y + 7)
      screen.text(string.sub(it.short or it.id or "", 1, 6))
    end
  end

  -- Pass 2: labels, selected pair (bright).
  screen.level(10)
  for i = sel_lo, sel_hi do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) then
      local x, y = cell_pos(i)
      screen.move(x + 2, y + 7)
      screen.text(string.sub(it.short or it.id or "", 1, 6))
    end
  end

  -- Pass 3: values, unselected (mid).
  screen.level(8)
  for i = 1, #items do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) and (i < sel_lo or i > sel_hi) then
      local x, y = cell_pos(i)
      screen.move(x + 2, y + 17)
      screen.text_trim(tostring(pv:item_display_value(it) or ""), BAR_W)
    end
  end

  -- Pass 4: values, selected pair (full bright).
  screen.level(15)
  for i = sel_lo, sel_hi do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) then
      local x, y = cell_pos(i)
      screen.move(x + 2, y + 17)
      screen.text_trim(tostring(pv:item_display_value(it) or ""), BAR_W)
    end
  end

  -- Pass 5: position-bar tracks for every ranged item.
  screen.level(1)
  for i = 1, #items do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) and it.min ~= nil and it.max ~= nil
      and it.options == nil and not it.file then
      local x, y = cell_pos(i)
      screen.rect(x + 2, y + 21, BAR_W, 2)
    end
  end
  screen.fill()

  -- Passes 6/7: bar fills (unselected mid, selected bright). Centered params
  -- fill from the middle outward, everything else from the left.
  for pass = 1, 2 do
    screen.level(pass == 1 and 6 or 15)
    for i = 1, #items do
      local it = items[i]
      local selected = i >= sel_lo and i <= sel_hi
      if cell_visible(i, it, wstart, wend)
        and ((pass == 1 and not selected) or (pass == 2 and selected)) then
        local frac = item_frac(it, pv:item_raw_value(it))
        if frac ~= nil then
          local x, y = cell_pos(i)
          if CENTERED[it.id] then
            local xc = x + 2 + floor(BAR_W / 2)
            local len = floor((frac - 0.5) * BAR_W + 0.5)
            if len >= 0 then
              screen.rect(xc, y + 21, max(len, 1), 2)
            else
              screen.rect(xc + len, y + 21, -len, 2)
            end
          elseif frac > 0 then
            screen.rect(x + 2, y + 21, max(1, floor(frac * BAR_W + 0.5)), 2)
          end
        end
      end
    end
    screen.fill()
  end

  -- Pass 8: held p-lock / scene-lock: invert the label chip (the same "this
  -- param is locked" cue the old cells gave via a brighter label).
  screen.level(12)
  local any_locked = false
  for i = 1, #items do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) and pv:item_locked(it) then
      local x, y = cell_pos(i)
      screen.rect(x, y, CELL_W - 1, 9)
      any_locked = true
    end
  end
  if any_locked then
    screen.fill()
    screen.level(0)
    for i = 1, #items do
      local it = items[i]
      if cell_visible(i, it, wstart, wend) and pv:item_locked(it) then
        local x, y = cell_pos(i)
        screen.move(x + 2, y + 7)
        screen.text(string.sub(it.short or it.id or "", 1, 6))
      end
    end
  end

  -- Pass 9: momentary edit flash -- invert the value chip of the item that
  -- just changed (refines the old flash, which only source pages surfaced).
  screen.level(15)
  local any_flash = false
  for i = 1, #items do
    local it = items[i]
    if cell_visible(i, it, wstart, wend) and pv:item_value_flashing(it) then
      local x, y = cell_pos(i)
      screen.rect(x, y + 10, CELL_W - 1, 9)
      any_flash = true
    end
  end
  if any_flash then
    screen.fill()
    screen.level(0)
    for i = 1, #items do
      local it = items[i]
      if cell_visible(i, it, wstart, wend) and pv:item_value_flashing(it) then
        local x, y = cell_pos(i)
        screen.move(x + 2, y + 17)
        screen.text_trim(tostring(pv:item_display_value(it) or ""), BAR_W)
      end
    end
  end
end

-- Mark the selected K2/K3 pair with upper-left and lower-right corner
-- brackets (the original selection language of the script -- owner spec; no
-- boxes). Dimmed when the pair holds nothing editable so the cursor position
-- is still visible without shouting. A pair fully inside a widget draws no
-- corners at all: the widget shows its own selection (envelope stage markers).
function PageRender:draw_selection(items, sel_lo, wstart, wend)
  local first = items[sel_lo]
  local second = items[sel_lo + 1]
  if first == nil and second == nil then
    return
  end
  if in_widget(sel_lo, wstart, wend) and in_widget(sel_lo + 1, wstart, wend) then
    return
  end
  local x, y = cell_pos(sel_lo)
  local span = 1
  if second ~= nil and not (in_widget(sel_lo + 1, wstart, wend) and not in_widget(sel_lo, wstart, wend)) then
    span = 2
  end
  local editable = (first ~= nil and not first.blank and not in_widget(sel_lo, wstart, wend))
    or (second ~= nil and not second.blank and not in_widget(sel_lo + 1, wstart, wend))
  screen.level(editable and 10 or 3)
  local x2 = x + (span * CELL_W) - 2
  local y2 = y + CELL_H - 3
  -- upper-left corner
  screen.rect(x, y - 1, 4, 1)
  screen.rect(x, y - 1, 1, 4)
  -- lower-right corner
  screen.rect(x2 - 3, y2, 4, 1)
  screen.rect(x2, y2 - 3, 1, 4)
  screen.fill()
end

-- ---- Widgets ---------------------------------------------------------------

-- Shared envelope polyline. `ybase`/`ytop` may be inverted (ytop below ybase)
-- to draw a negative-depth filter envelope hanging downward. AHR treats
-- hold/release >= 128 as INF (flat to the end of the widget), matching the
-- "INF" the value cells display. Returns a table of stage vertex positions
-- ({attack/decay/sustain/hold/release} -> {x, y}) so the caller can mark the
-- stage(s) the selected K2/K3 pair is editing (direct envelope editing).
function PageRender:draw_env_shape(x0, w, mode, a, d, s, hd, r, ybase, ytop)
  local xl = x0 + 3
  local xr = x0 + w - 3
  local span = xr - xl
  local pts = {}
  screen.level(10)
  screen.move(xl, ybase)
  if mode == 1 then -- ADSR
    local wa = 2 + (a / 127) * span * 0.22
    local wd = 2 + (d / 127) * span * 0.22
    local ws = span * 0.2
    local ys = ybase + (ytop - ybase) * (s / 127)
    local x1 = xl + wa
    screen.line(x1, ytop)
    pts.attack = {x1, ytop}
    -- one midpoint eases the decay/release into an exp-ish curve
    screen.line(min(x1 + wd * 0.4, xr), ytop + (ys - ytop) * 0.7)
    screen.line(min(x1 + wd, xr), ys)
    pts.decay = {min(x1 + wd, xr), ys}
    local x2 = min(x1 + wd + ws, xr - 2)
    screen.line(x2, ys)
    pts.sustain = {x2, ys}
    if r >= 128 then
      screen.line(xr, ys)
      pts.release = {xr, ys}
    else
      local wr = 2 + (r / 127) * span * 0.22
      screen.line(min(x2 + wr * 0.4, xr), ys + (ybase - ys) * 0.7)
      screen.line(min(x2 + wr, xr), ybase)
      pts.release = {min(x2 + wr, xr), ybase}
      screen.line(xr, ybase)
    end
  else -- AHR
    local wa = 2 + (a / 127) * span * 0.3
    local x1 = xl + wa
    screen.line(x1, ytop)
    pts.attack = {x1, ytop}
    if hd >= 128 then
      screen.line(xr, ytop)
      pts.hold = {xr, ytop}
      pts.release = {xr, ytop}
    else
      local x2 = min(x1 + 1 + (hd / 128) * span * 0.3, xr - 1)
      screen.line(x2, ytop)
      pts.hold = {x2, ytop}
      if r >= 128 then
        screen.line(xr, ytop)
        pts.release = {xr, ytop}
      else
        local wr = 2 + (r / 128) * span * 0.34
        screen.line(min(x2 + wr * 0.4, xr), ytop + (ybase - ytop) * 0.75)
        screen.line(min(x2 + wr, xr), ybase)
        pts.release = {min(x2 + wr, xr), ybase}
        screen.line(xr, ybase)
      end
    end
  end
  screen.stroke()
  return pts
end

-- Direct envelope editing (owner spec): the env param cells are hidden -- the
-- envelope drawing IS the page. Mark the stage vertex each selected param is
-- editing: a dim vertical hairline down to the baseline plus a bright 3x3
-- handle on the vertex. `id_to_stage` strips the param family prefix so one
-- mapper serves both the amp env (env_*) and the filter env (filter_env_*).
local ENV_STAGE = {attack = true, decay = true, sustain = true, hold = true, release = true}
local function id_to_stage(id)
  if id == nil then
    return nil
  end
  local stage = id:gsub("^filter_env_", ""):gsub("^env_", "")
  return ENV_STAGE[stage] and stage or nil
end

function PageRender:draw_env_stage_markers(pts, items, sel_lo, y0, h)
  -- Dim handles on every stage vertex, so the grabbable points read as such.
  screen.level(4)
  for _, p in pairs(pts) do
    screen.rect(p[1] - 1, p[2] - 1, 2, 2)
  end
  screen.fill()
  -- Bright handles + hairlines on the stage(s) the selected pair edits.
  for i = sel_lo, sel_lo + 1 do
    local it = items[i]
    local stage = it ~= nil and id_to_stage(it.id) or nil
    local p = stage ~= nil and pts[stage] or nil
    if p ~= nil then
      screen.level(4)
      screen.rect(p[1], y0 + 2, 1, h - 4)
      screen.fill()
      screen.level(15)
      screen.rect(p[1] - 1, p[2] - 1, 3, 3)
      screen.fill()
    end
  end
end

function PageRender:draw_amp_env(x0, y0, w, h, items, page_index, sel_lo)
  local mode = floor(self.value("env_mode", 2) + 0.5)
  local pts = self:draw_env_shape(x0, w, mode,
    self:item_value(items, "env_attack", 0),
    self:item_value(items, "env_decay", 0),
    self:item_value(items, "env_sustain", 127),
    self:item_value(items, "env_hold", 0),
    self:item_value(items, "env_release", 0),
    y0 + h - 3, y0 + 4)
  self:draw_env_stage_markers(pts, items, sel_lo or 1, y0, h)
  screen.level(3)
  screen.move(x0 + w - 2, y0 + 7)
  screen.text_right(mode == 1 and "ADSR" or "AHR")
end

function PageRender:draw_filter_env(x0, y0, w, h, items, page_index, sel_lo)
  local mode = floor(self.value("filter_env_mode", 2) + 0.5)
  local depth = (self:item_value(items, "filter_env_depth", 64) - 64) / 64
  local amp = max(3, abs(depth) * (h - 9))
  local ybase, ytop
  if depth >= 0 then
    ybase = y0 + h - 3
    ytop = ybase - amp
  else
    -- negative depth: envelope hangs downward from a top baseline
    ybase = y0 + 9
    ytop = min(ybase + amp, y0 + h - 2)
  end
  local pts = self:draw_env_shape(x0, w, mode,
    self:item_value(items, "filter_env_attack", 0),
    self:item_value(items, "filter_env_decay", 0),
    self:item_value(items, "filter_env_sustain", 127),
    self:item_value(items, "filter_env_hold", 0),
    self:item_value(items, "filter_env_release", 0),
    ybase, ytop)
  self:draw_env_stage_markers(pts, items, sel_lo or 1, y0, h)
  screen.level(3)
  screen.move(x0 + w - 2, y0 + 7)
  screen.text_right((depth < 0 and "-" or "") .. (mode == 1 and "ADSR" or "AHR"))
end

-- Filter magnitude-response shapes (sketches, not measurements): unity band,
-- rolloff past cutoff, resonance as a gaussian bump at the cutoff.
local function resp_lp(u, fc, q)
  local d = u - fc
  local base = d <= 0 and 1 or (1 - d * 3.5)
  if base < 0 then
    base = 0
  end
  return base + q * 1.05 * exp(-(d * d) / 0.005)
end

local function resp_notch(u, fc, q)
  local d = u - fc
  local nw = 0.11 - 0.06 * q
  return 1 - 0.95 * exp(-(d * d) / (nw * nw))
end

local function resp_bp(u, fc, q)
  local d = u - fc
  local bw = 0.20 - 0.13 * q
  return (0.75 + 0.45 * q) * exp(-(d * d) / (bw * bw))
end

-- Classic machines: arg = filter_type 1..4 (LP/HP/BP/NOTCH). Morphing
-- machines: arg = morph 0..1 (LP -> notch -> HP, 0.5 = notch).
local function response(u, fc, q, morphing, arg)
  if morphing then
    if arg < 0.5 then
      local t = arg * 2
      return resp_lp(u, fc, q) * (1 - t) + resp_notch(u, fc, q) * t
    end
    local t = (arg - 0.5) * 2
    return resp_notch(u, fc, q) * (1 - t) + resp_lp(1 - u, 1 - fc, q) * t
  end
  if arg == 2 then
    return resp_lp(1 - u, 1 - fc, q) -- HP = mirrored LP
  elseif arg == 3 then
    return resp_bp(u, fc, q)
  elseif arg == 4 then
    return resp_notch(u, fc, q)
  end
  return resp_lp(u, fc, q)
end

function PageRender:plot_response(x0, y0, w, h, fc, q, morphing, arg, level)
  local xl = x0 + 2
  local xr = x0 + w - 2
  local ybase = y0 + h - 2
  local scale = (h - 5) / 1.5
  screen.level(level)
  for k = 0, N_CURVE do
    local u = k / N_CURVE
    local g = response(u, fc, q, morphing, arg)
    if g < 0 then
      g = 0
    elseif g > 1.5 then
      g = 1.5
    end
    local x = xl + u * (xr - xl)
    local y = ybase - g * scale
    if k == 0 then
      screen.move(x, y)
    else
      screen.line(x, y)
    end
  end
  screen.stroke()
end

function PageRender:draw_filter_curve(x0, y0, w, h, items)
  local machine = floor(self.value("filter_machine", 1) + 0.5)
  local morphing = machine % 2 == 0 -- 2/4/6 = morphing family
  local cut = self:item_value(items, "filter_cutoff", 64)
  local res = self:item_value(items, "filter_res", 0) / 127
  if res < 0 then
    res = 0
  elseif res > 1 then
    res = 1
  end
  local fc = 0.06 + min(max(cut / 127, 0), 1) * 0.88

  local arg
  if morphing then
    arg = min(max(self:item_value(items, "filter_morph", 64) / 128, 0), 1)
  else
    arg = floor(min(max(self:item_value(items, "filter_type", 1), 1), 4) + 0.5)
  end

  -- Stereo / mid-side machines: Balance spreads the two channel cutoffs; the
  -- second channel draws as a dim ghost curve.
  local bal = 0
  if machine >= 3 then
    bal = (self:item_value(items, "filter_balance", 64) - 64) / 64
  end
  if abs(bal) > 0.03 then
    self:plot_response(x0, y0, w, h, min(max(fc - bal * 0.12, 0.02), 0.98), res, morphing, arg, 3)
    fc = min(max(fc + bal * 0.12, 0.02), 0.98)
  end
  self:plot_response(x0, y0, w, h, fc, res, morphing, arg, 12)

  -- cutoff tick on the baseline
  screen.level(4)
  screen.rect(x0 + 2 + floor(fc * (w - 4) + 0.5), y0 + h - 3, 1, 2)
  screen.fill()

  screen.level(3)
  screen.move(x0 + w - 2, y0 + 7)
  screen.text_right(self.filter_names[machine] or "")
end

-- One low-profile param cell (owner redesign). `index` 0-3 places it in the
-- 4-up row at y = FILTER_ROW_Y.
function PageRender:draw_low_profile_cell(item, index, selected, row_y)
  if item == nil or item.blank then
    return
  end
  local pv = self.param_values
  local raw = pv:item_raw_value(item)
  local base_raw, actual_raw, modulated = raw, raw, false
  if self.display_values ~= nil then
    base_raw, actual_raw, modulated = self.display_values(item, raw)
  end
  local locked = pv:item_locked(item)
  LowProfile.draw({
    x = LowProfile.cell_x(index),
    y = row_y or FILTER_ROW_Y,
    label = item.short or item.id,
    display_value = tostring(pv:item_display_value(item) or ""),
    editing = pv:item_value_flashing(item),
    -- Base bar = the track value (holds still under the crossfader); actual
    -- bar = after crossfade morph / macro-assign preview / modulation.
    value_frac = item_frac(item, base_raw) or 0,
    actual_frac = item_frac(item, actual_raw) or 0,
    centered = CENTERED[item.id] == true,
    selected = selected,
    modulated = modulated or locked,
    inverted = locked
  })
end

-- The 42-bar filter magnitude render (owner redesign). Bars grow from the
-- bottom; the cutoff (+/- envelope-depth band while stopped, single bar while
-- playing) is drawn brighter. Two level-batched passes (performance law).
function PageRender:draw_filter_bars(items, playing)
  local machine = floor(self.value("filter_machine", 1) + 0.5)
  local morphing = machine % 2 == 0
  local cut = self:item_value(items, "filter_cutoff", 64)
  local res_raw = self:item_value(items, "filter_res", 0)
  -- During playback the render follows the ACTUAL (modulated) filter, so LFOs /
  -- the filter env / macros visibly sweep the bars. mod_offsets is injected by
  -- the coordinator and reads the engine's 15Hz mod feed.
  if playing and self.mod_offsets ~= nil then
    local d_cut, d_res = self.mod_offsets()
    cut = cut + (d_cut or 0)
    res_raw = res_raw + (d_res or 0)
  end
  local res = min(max(res_raw / 127, 0), 1)
  local fc = 0.06 + min(max(cut / 127, 0), 1) * 0.88
  local arg
  if morphing then
    arg = min(max(self:item_value(items, "filter_morph", 64) / 128, 0), 1)
  else
    arg = floor(min(max(self:item_value(items, "filter_type", 1), 1), 4) + 0.5)
  end
  -- Envelope-depth band (stopped only). DIRECTIONAL: the envelope only pushes
  -- the cutoff ONE way, so the highlight runs from the cutoff toward where the
  -- envelope takes it -- up for positive depth, down for negative. (Drawing it
  -- both ways read as if the cutoff swung symmetrically, which it doesn't.)
  local depth = (self:item_value(items, "filter_env_depth", 64) - 64) / 64
  local reach = playing and 0 or (depth * 0.42)
  local lo_u, hi_u
  if reach >= 0 then
    lo_u, hi_u = fc, fc + reach
  else
    lo_u, hi_u = fc + reach, fc
  end
  local band = abs(reach)
  local nearest = floor(fc * (FILTER_BARS - 1) + 0.5)  -- cutoff bar index (0-based)
  local scale = (FILTER_REND_H - 1) / 1.5

  -- Precompute each bar's height + brightness.
  local dim, bright = {}, {}
  for i = 1, FILTER_BARS do
    local u = (i - 1) / (FILTER_BARS - 1)
    local g = min(max(response(u, fc, res, morphing, arg), 0), 1.5)
    local bh = floor(g * scale + 0.5)
    if bh >= 1 then
      local bx = FILTER_BAR_STEP * i
      local is_bright
      if band > 0 then
        is_bright = u >= lo_u and u <= hi_u
      else
        is_bright = (i - 1) == nearest  -- depth 0 (or playing): the cutoff bar
      end
      local dest = is_bright and bright or dim
      dest[#dest + 1] = {x = bx, top = 64 - bh, h = bh}
    end
  end

  screen.level(6)
  for _, b in ipairs(dim) do screen.rect(b.x, b.top, 2, b.h) end
  screen.fill()
  screen.level(12)
  for _, b in ipairs(bright) do screen.rect(b.x, b.top, 2, b.h) end
  screen.fill()
end

-- Envelope amplitude (0..1) at normalized time u (0..1), for the bar render.
-- Stage widths mirror draw_env_shape's proportions so the bars read like the
-- old polyline. Returns amp, stage -- the stage name lets the caller brighten
-- the region the selected K2/K3 pair is editing.
-- AHR treats hold/release >= 128 as INF (holds to the end of the window).
-- Envelope as an explicit list of BARS ({amp, stage} per bar). Allocating bar
-- counts directly -- rather than normalizing stage times -- is what lets the
-- render honour hard visual rules that proportional scaling cannot:
--   * ATTACK is never narrower than 1 bar, so a 0 attack still shows the
--     instant jump to peak instead of rendering nothing.
--   * ATTACK+DECAY together never exceed half the width, and RELEASE never
--     exceeds the other half, so a long release stops squeezing the attack.
--   * SUSTAIN keeps at least 1 bar (it is a level; it needs somewhere to sit).
--   * A stage set to 0 gets 0 bars = a genuine cliff. With every AHR stage at
--     0 only the single attack bar renders -- no phantom release slope.
local function env_bars(mode, a, d, s, hd, r, n)
  local half = floor(n / 2)
  local sus = min(max(s / 127, 0), 1)
  local function span(v, maxv)
    return floor((v / maxv) * half + 0.5)
  end

  local out = {}
  -- Sample each stage at k = i/count, so a stage ENDS exactly on its target
  -- and never repeats the value the previous stage already drew. A 1-bar
  -- attack therefore lands straight on the peak (k = 1), and a decay/release
  -- starts descending immediately instead of echoing the peak for a bar.
  local function push(count, from, to, stage)
    for i = 1, count do
      local k = i / count
      out[#out + 1] = {amp = from + ((to - from) * k), stage = stage}
    end
  end

  if mode == 1 then  -- ADSR
    local a_b, d_b = span(a, 127), span(d, 127)
    if a_b + d_b > half then           -- keep attack+decay inside the left half
      local scale = half / (a_b + d_b)
      a_b, d_b = floor(a_b * scale), floor(d_b * scale)
    end
    a_b = max(1, a_b)                  -- attack always visible
    local r_b = (r >= 128) and 0 or min(span(r, 127), half)
    local s_b = n - a_b - d_b - r_b
    if s_b < 1 then                    -- sustain keeps at least one bar
      local need = 1 - s_b
      local take = min(need, r_b); r_b = r_b - take; need = need - take
      if need > 0 then
        take = min(need, d_b); d_b = d_b - take; need = need - take
      end
      if need > 0 then a_b = max(1, a_b - need) end
      s_b = n - a_b - d_b - r_b
    end
    push(a_b, 0, 1, "attack")
    push(d_b, 1, sus, "decay")
    push(s_b, sus, sus, "sustain")
    push(r_b, sus, 0, "release")
  else  -- AHR
    local a_b = max(1, min(span(a, 127), half))
    if hd >= 128 then                  -- INF hold: stays open to the end
      push(a_b, 0, 1, "attack")
      push(n - a_b, 1, 1, "hold")
    elseif r >= 128 then               -- INF release: holds after the hold
      local h_b = min(span(hd, 128), n - a_b)
      push(a_b, 0, 1, "attack")
      push(h_b, 1, 1, "hold")
      push(n - a_b - h_b, 1, 1, "release")
    else
      local h_b = min(span(hd, 128), half)
      local r_b = min(span(r, 128), half)
      push(a_b, 0, 1, "attack")
      push(h_b, 1, 1, "hold")
      push(r_b, 1, 0, "release")
      -- Anything left is past the end of the envelope: silence, not a slope.
    end
  end

  while #out > n do
    out[#out] = nil
  end
  return out
end

-- FILTER ENV page: the envelope drawn on the same 2px-bar grid as the filter
-- render, between a top and bottom low-profile param row. Bars covering the
-- stage(s) the selected pair edits are brightened (the direct-editing cue that
-- replaced the old polyline handles).
function PageRender:draw_filter_env_bars(items, sel_lo)
  local mode = floor(self.value("filter_env_mode", 2) + 0.5)
  local a = self:item_value(items, "filter_env_attack", 0)
  local d = self:item_value(items, "filter_env_decay", 0)
  local s = self:item_value(items, "filter_env_sustain", 127)
  local hd = self:item_value(items, "filter_env_hold", 0)
  local r = self:item_value(items, "filter_env_release", 0)

  -- Which stages the selected pair is editing (id -> stage name).
  local hot = {}
  for i = sel_lo, sel_lo + 1 do
    local it = items[i]
    local stage = it ~= nil and id_to_stage(it.id) or nil
    if stage ~= nil then
      hot[stage] = true
    end
  end

  local base = FENV_REND_Y + FENV_REND_H - 1
  local bars = env_bars(mode, a, d, s, hd, r, FILTER_BARS)
  local dim, bright = {}, {}
  for i = 1, #bars do
    local bar = bars[i]
    local bh = floor(min(max(bar.amp, 0), 1) * (FENV_REND_H - 1) + 0.5)
    if bh >= 1 then
      local dest = hot[bar.stage] and bright or dim
      dest[#dest + 1] = {x = FILTER_BAR_STEP * i, top = base - bh + 1, h = bh}
    end
  end

  screen.level(6)
  for _, b in ipairs(dim) do screen.rect(b.x, b.top, 2, b.h) end
  screen.fill()
  screen.level(12)
  for _, b in ipairs(bright) do screen.rect(b.x, b.top, 2, b.h) end
  screen.fill()

  -- No ADSR/AHR label here: it overlapped the bars and the shape already says
  -- which envelope type is active.
end

-- Full FILTER page 2. items 1-4 fill the TOP low-profile row (the env stages;
-- AHR leaves the 4th blank), items 5-6 the BOTTOM row's cells 3 and 4
-- (DRIVE, DEPTH) -- kept adjacent in the list so K2/K3 never lands on an
-- all-blank pair.
function PageRender:draw_filter_env_page(items, group)
  local sel_lo = ((group or 1) - 1) * 2 + 1
  for i = 1, 4 do
    self:draw_low_profile_cell(items[i], i - 1, i == sel_lo or i == sel_lo + 1, FENV_ROW_TOP_Y)
  end
  for i = 5, 6 do
    -- item 5 -> bottom cell index 2, item 6 -> 3 (positions 3 and 4).
    self:draw_low_profile_cell(items[i], i - 3, i == sel_lo or i == sel_lo + 1, FENV_ROW_BOTTOM_Y)
  end
  self:draw_filter_env_bars(items, sel_lo)
end

-- Full FILTER page 1: low-profile param row + bar render. The coordinator has
-- already drawn the page header. `items` is the curated [cutoff, res,
-- morph|type, env_depth] set; `group` is the K2/K3 pair index.
function PageRender:draw_filter_page(items, group, playing)
  local sel_lo = ((group or 1) - 1) * 2 + 1
  for i = 1, 4 do
    self:draw_low_profile_cell(items[i], i - 1, i == sel_lo or i == sel_lo + 1)
  end
  self:draw_filter_bars(items, playing == true)
end

function PageRender:draw_fx_slot(x0, y0, w, h, items, page_index)
  local slot = FX_SLOT_PAGES[page_index] or FX_SLOT_PAGES[1]
  local machine = floor(self.value(slot.machine, 1) + 0.5)
  screen.level(3)
  screen.move(x0 + 2, y0 + 7)
  screen.text(slot.label)
  screen.level(15)
  screen.font_size(16)
  screen.move(x0 + 2, y0 + 22)
  screen.text(self.fx_names[machine] or "?")
  screen.font_size(8)
  if machine == 1 then
    screen.level(4)
    screen.move(x0 + w - 2, y0 + 22)
    screen.text_right("BYPASS")
  end
end

function PageRender:draw_fx_sends(x0, y0, w, h, items)
  local b1 = y0 + 10
  local b2 = y0 + 21
  local m1 = floor(self.value("send1_machine", 1) + 0.5)
  local m2 = floor(self.value("send2_machine", 1) + 0.5)

  screen.level(3)
  screen.move(x0 + 2, b1)
  screen.text("S1")
  screen.move(x0 + 2, b2)
  screen.text("S2")

  screen.level(m1 == 1 and 4 or 12)
  screen.move(x0 + 14, b1)
  screen.text(self.fx_names[m1] or "")
  screen.level(m2 == 1 and 4 or 12)
  screen.move(x0 + 14, b2)
  screen.text(self.fx_names[m2] or "")

  -- send level bars (read through the page items so p-locks show live)
  local bx = x0 + 62
  local bw = w - 66
  local l1 = min(max(self:item_value(items, "send1_level", 0) / 127, 0), 1)
  local l2 = min(max(self:item_value(items, "send2_level", 0) / 127, 0), 1)
  screen.level(1)
  screen.rect(bx, b1 - 5, bw, 3)
  screen.rect(bx, b2 - 5, bw, 3)
  screen.fill()
  screen.level(9)
  if l1 > 0 then
    screen.rect(bx, b1 - 5, max(1, floor(l1 * bw + 0.5)), 3)
  end
  if l2 > 0 then
    screen.rect(bx, b2 - 5, max(1, floor(l2 * bw + 0.5)), 3)
  end
  screen.fill()
end

-- ---- Entry point -----------------------------------------------------------

-- category/page_index locate the page; items is its resolved item list
-- (page_items_for); group is the clamped K2/K3 pair index.
function PageRender:draw(category, page_index, items, group)
  local wstart, wend, wname = self:widget_span(category, page_index, items)

  if #items == 0 and wname == nil then
    screen.level(4)
    screen.move(0, 34)
    screen.text("empty")
    return
  end

  local sel_lo = ((group or 1) - 1) * 2 + 1
  self:draw_cells(items, wstart, wend, sel_lo, sel_lo + 1)
  self:draw_selection(items, sel_lo, wstart, wend)

  if wname ~= nil then
    -- Widgets occupy one row: indices 1-4 = top row, 5-8 = bottom row.
    local top = wend <= 4
    local x0 = ((wstart - 1) % 4) * CELL_W
    local ww = (wend - wstart + 1) * CELL_W
    self[wname](self, x0, top and ROW_Y[1] or ROW_Y[2], ww, CELL_H, items, page_index, sel_lo)
  end
end

return PageRender
