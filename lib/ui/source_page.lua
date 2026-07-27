local SOURCE_CELL_X = {1, 33, 65, 97}
local SOURCE_CELL_WIDTH = 31
local SOURCE_CELL_HEIGHT = 11
local SOURCE_TOP_Y = 11
local SOURCE_WAVEFORM_Y = 23
local SOURCE_WAVEFORM_HEIGHT = 27
local SOURCE_BOTTOM_Y = 53

local SourcePage = {}
SourcePage.__index = SourcePage

-- Renders the Source category's pages: the main 4x2 param grid + waveform,
-- and the sample-edit/trim sub-page. Pure rendering, like param_renderer.lua --
-- value lookups (param_values) and navigation state (nav) are handed in as
-- objects, and coordinator-only helpers (draw_page_header, active_waveform,
-- active_region, display_phase, visual_param_value) as callbacks, so this
-- module never touches engine/param state directly.
function SourcePage.new(opts)
  opts = opts or {}
  return setmetatable({
    elasticat = opts.elasticat,
    MachineRegistry = opts.MachineRegistry,
    ParamRenderer = opts.ParamRenderer,
    param_values = opts.param_values,
    nav = opts.nav,
    param_value_or = opts.param_value_or,
    sample_name = opts.sample_name,
    draw_page_header = opts.draw_page_header,
    active_waveform = opts.active_waveform,
    active_region = opts.active_region,
    active_range = opts.active_range,
    get_playing = opts.get_playing,
    display_phase = opts.display_phase,
    visual_param_value = opts.visual_param_value,
    id = opts.id,
    get_alt = opts.get_alt,
    get_last_trim_focus = opts.get_last_trim_focus
  }, SourcePage)
end

function SourcePage:cell_geometry(index)
  local column = (index - 1) % 4
  local row = math.floor((index - 1) / 4)
  return SOURCE_CELL_X[column + 1], row == 0 and SOURCE_TOP_Y or SOURCE_BOTTOM_Y
end

function SourcePage:draw_box(x, y, inverted)
  if inverted then
    screen.level(15)
    screen.rect(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT)
    screen.fill()
  end
end

function SourcePage:draw_text(text, x, y, inverted)
  screen.level(inverted and 0 or 15)
  screen.move(x + math.floor(SOURCE_CELL_WIDTH / 2), y + 8)
  screen.text_center(tostring(text or ""))
end

function SourcePage:draw_pitch_ruler(param_item, x, y, inverted)
  local pitch = self.param_values:item_raw_value(param_item) or 0
  local dot_spacing = 3
  local octave_px = dot_spacing * 5
  local center_x = x + math.floor(SOURCE_CELL_WIDTH / 2)
  local text_y = y + 7
  local dot_y = y + SOURCE_CELL_HEIGHT - 2
  local level = inverted and 0 or 15

  -- Round the pitch offset once so every dot/label spacing below is pure
  -- integer arithmetic; rounding each element separately made neighboring
  -- gaps drift between 2 and 3 blank pixels as pitch changed continuously.
  local zero_x = math.floor(center_x - (pitch / 12 * octave_px) + 0.5)

  screen.level(level)
  for octave = -4, 4 do
    local octave_x = zero_x + (octave * octave_px)
    for dot = 1, 4 do
      local dot_x = octave_x + (dot * dot_spacing)
      if dot_x > x + 1 and dot_x < x + SOURCE_CELL_WIDTH - 1 then
        screen.pixel(dot_x, dot_y)
      end
    end
  end
  screen.fill()

  screen.level(level)
  for octave = -4, 4 do
    local label = tostring(octave)
    local octave_x = zero_x + (octave * octave_px)
    local half_width = math.ceil(screen.text_extents(label) / 2)
    if octave_x - half_width >= x + 1 and octave_x + half_width <= x + SOURCE_CELL_WIDTH - 1 then
      screen.move(octave_x, text_y)
      screen.text_center(label)
    end
  end
end

function SourcePage:draw_sample_slot_tab(param_item, x, y, inverted)
  local slot = math.floor((self.param_values:item_raw_value(param_item) or 1) + 0.5)
  local text = slot < 1 and "off" or tostring(slot)
  local fg = inverted and 0 or 15
  local bg = inverted and 15 or 0

  screen.level(fg)
  screen.rect(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT)
  screen.fill()

  screen.level(bg)
  screen.rect(x + 7, y + 1, 23, 9)
  screen.fill()

  screen.level(bg)
  screen.pixel(x, y)
  screen.pixel(x, y + SOURCE_CELL_HEIGHT - 1)
  screen.fill()

  screen.level(fg)
  screen.move(x + 18, y + 8)
  screen.text_center(text)
end

function SourcePage:draw_main_cell(param_item, index, corner)
  local x, y = self:cell_geometry(index)
  local locked = self.param_values:item_locked(param_item)

  self:draw_box(x, y, locked)

  if corner ~= nil then
    self.ParamRenderer.draw_selection_corner(x, y, SOURCE_CELL_WIDTH, SOURCE_CELL_HEIGHT, corner)
  end

  if param_item == nil or param_item.blank then
    return
  elseif param_item.id == "pitch" then
    self:draw_pitch_ruler(param_item, x, y, locked)
  elseif param_item.id == "sample_slot" or param_item.id == "file_slot" then
    self:draw_sample_slot_tab(param_item, x, y, locked)
  else
    -- Show the value when flashing/locked, when the item asks to always show it
    -- (BPM/STEP), or while FN is held (peek all values); otherwise the label.
    local fn_held = self.get_alt ~= nil and self.get_alt()
    local show_value = self.param_values:item_value_flashing(param_item) or locked
      or param_item.always_value == true or fn_held
    local text = show_value and self.param_values:item_display_value(param_item) or (param_item.short or param_item.id)
    self:draw_text(text, x, y, locked)
  end
end

function SourcePage:draw_waveform_marker(position, x0, y0, width, height, kind)
  local x = x0 + math.floor(((width - 1) * util.clamp(position, 0, 128) / 128) + 0.5)
  self:draw_marker_at_px(x, y0, height, kind)
end

function SourcePage:draw_marker_at_px(x, y0, height, kind)
  screen.rect(x, y0, 1, height)
  screen.fill()

  if kind == "start" then
    screen.move(x, y0 + 2)
    screen.line(x + 3, y0)
    screen.move(x, y0 + 2)
    screen.line(x + 3, y0 + 4)
    screen.stroke()
  elseif kind == "end" then
    screen.move(x, y0 + 2)
    screen.line(x - 3, y0)
    screen.move(x, y0 + 2)
    screen.line(x - 3, y0 + 4)
    screen.stroke()
  end
end

function SourcePage:group_has_trim_items()
  local left, right = self.nav:current_group_items()
  return (left ~= nil and (left.id == "trim_start" or left.id == "trim_end"))
    or (right ~= nil and (right.id == "trim_start" or right.id == "trim_end"))
end

function SourcePage:group_has_range_items()
  local left, right = self.nav:current_group_items()
  return (left ~= nil and (left.id == "range_start" or left.id == "range_end"))
    or (right ~= nil and (right.id == "range_start" or right.id == "range_end"))
end

-- Draws a start/end marker pair given their positions as fractions of the whole
-- sample, mapped through the current view window. The end marker's rounding is
-- anchored to the start's so the pixel gap between them stays constant while a
-- linked start/end scrubs (avoids 1px jitter). Markers outside the view are
-- skipped.
function SourcePage:draw_marker_pair(start_frac, end_frac, view_lo, view_hi, x0, y0, width, height)
  if view_hi <= view_lo then
    return
  end
  local span = view_hi - view_lo
  local start_exact = (width - 1) * ((util.clamp(start_frac, 0, 1) - view_lo) / span)
  local end_exact = (width - 1) * ((util.clamp(end_frac, 0, 1) - view_lo) / span)
  local start_px = math.floor(start_exact + 0.5)
  local end_px = start_px + math.floor((end_exact - start_exact) + 0.5)
  if start_frac >= view_lo and start_frac <= view_hi then
    self:draw_marker_at_px(x0 + util.clamp(start_px, 0, width - 1), y0, height, "start")
  end
  if end_frac >= view_lo and end_frac <= view_hi then
    self:draw_marker_at_px(x0 + util.clamp(end_px, 0, width - 1), y0, height, "end")
  end
end

function SourcePage:draw_waveform(opts)
  opts = opts or {}
  local x0 = opts.x or 3
  local y0 = opts.y or 24
  local width = opts.width or 122
  local height = opts.height or 22
  local center = y0 + math.floor(height / 2)
  -- opts.slot lets the File page render its own (file-edit) slot; otherwise the
  -- SELECTED TRACK's slot (Phase 2 -- `sample_slot` is a per-track suffix, so
  -- ui_sample_slot is just the id funnel; on track 1 it is the same slot the
  -- facade's active_pool_slot returns, leaving single-track rendering
  -- unchanged). Slot 0 means the track has no sample: draw the empty box.
  local slot = opts.slot or (self.elasticat.ui_sample_slot ~= nil and self.elasticat.ui_sample_slot())
    or (self.elasticat.active_pool_slot ~= nil and self.elasticat.active_pool_slot()) or 1
  local waveform = slot >= 1 and self.active_waveform(slot) or nil
  local meta = (slot >= 1 and self.elasticat.pool_meta ~= nil and self.elasticat.pool_meta(slot)) or {}
  local duration = meta.duration or 0
  local trim_start = meta.trim_start or 0
  local trim_end = meta.trim_end or duration
  local trim_lo = 0
  local trim_hi = 1
  if duration > 0 then
    trim_lo = util.clamp(trim_start / duration, 0, 1)
    trim_hi = util.clamp(trim_end / duration, trim_lo, 1)
  end

  -- Range (0-128) nested inside the trim window, expressed as fractions of the
  -- whole sample. Two distinct ranges:
  --   marker range -- the Track (or held-step) values the range markers draw.
  --     Stable so they stay editable during playback (they don't sweep).
  --   actual range -- what's actually playing (Step Range sweeps included). Used
  --     for the Main-page view window and for shading the waveform bright/dim.
  local trim_span = trim_hi - trim_lo
  local function range_to_frac(v)
    return util.clamp(trim_lo + (trim_span * (util.clamp(v, 0, 128) / 128)), 0, 1)
  end

  local marker_range_lo = range_to_frac(self.visual_param_value("range_start", 0))
  local marker_range_hi = range_to_frac(self.visual_param_value("range_end", 128))
  if marker_range_hi <= marker_range_lo then
    marker_range_hi = math.min(1, marker_range_lo + 0.001)
  end

  local actual_range_start, actual_range_end =
    self.visual_param_value("range_start", 0), self.visual_param_value("range_end", 128)
  if self.get_playing ~= nil and self.get_playing() and self.active_range ~= nil then
    actual_range_start, actual_range_end = self.active_range()
  end
  local active_lo = range_to_frac(actual_range_start)
  local active_hi = range_to_frac(actual_range_end)
  if active_hi <= active_lo then
    active_hi = math.min(1, active_lo + 0.001)
  end

  local view_lo, view_hi
  if opts.sample_edit then
    view_lo, view_hi = 0, 1
  elseif opts.range_edit then
    view_lo, view_hi = trim_lo, trim_hi
  else
    -- Main view follows the Actual Range so the shown slice re-renders with a
    -- sequenced sweep.
    view_lo, view_hi = active_lo, active_hi
  end

  -- FN zoom is the Sample (file trim) page only. The Range page does not zoom
  -- under FN -- there FN snaps the values to multiples of 8 instead.
  if opts.sample_edit and self.get_alt() and duration > 0 and self:group_has_trim_items() then
    local zoom_span = util.clamp(4.0 / duration, 0.04, 0.4)
    local focus = self.get_last_trim_focus() == "trim_end" and trim_end or trim_start
    local focus_fraction = util.clamp(focus / duration, 0, 1)
    view_lo = util.clamp(focus_fraction - (zoom_span / 2), 0, math.max(0, 1 - zoom_span))
    view_hi = util.clamp(view_lo + zoom_span, view_lo + 0.001, 1)
  end

  screen.level(2)
  screen.rect(x0, y0, width, 1)
  screen.fill()
  screen.rect(x0, y0 + height - 1, width, 1)
  screen.fill()
  screen.rect(x0, y0, 1, height)
  screen.fill()
  screen.rect(x0 + width - 1, y0, 1, height)
  screen.fill()

  if waveform == nil then
    screen.level(5)
    screen.move(x0 + math.floor(width / 2), y0 + math.floor(height / 2) + 3)
    screen.text_center("NO SAMPLE")
    return
  end

  local gain = meta.gain or 1
  -- Bright where the Actual Range is playing, dim elsewhere. screen.level is set
  -- only when the shade actually changes (at the range boundaries), NOT once per
  -- column -- 127 screen.level calls per frame floods the norns screen command
  -- buffer and stalls the redraw metro (froze screen+grid together previously).
  -- Which span renders bright. The SAMPLE EDITOR (File page) is deliberately
  -- detached from the track: it shades the TRIM window (start..end) only, so
  -- the editor never reflects the track's Range page. Every other view shades
  -- the Actual Range that's playing.
  local shade_lo, shade_hi = active_lo, active_hi
  if opts.sample_edit then
    shade_lo, shade_hi = trim_lo, trim_hi
  end

  local current_level = nil
  for column = 0, width - 1 do
    local fraction = view_lo + ((view_hi - view_lo) * (column / math.max(1, width - 1)))
    local index = math.floor(fraction * (#waveform - 1)) + 1
    local peak = util.clamp((waveform[index] or 0) * gain, 0, 1)
    local amp = math.max(1, math.floor((height / 2) * peak))
    local top = util.clamp(center - amp, y0, y0 + height - 1)
    local bottom = util.clamp(center + amp, y0, y0 + height - 1)
    local level = (fraction >= shade_lo and fraction <= shade_hi) and 6 or 2
    if level ~= current_level then
      screen.level(level)
      current_level = level
    end
    screen.rect(x0 + column, top, 1, bottom - top + 1)
    screen.fill()
  end

  if opts.show_slices then
    local slice_count = util.clamp(math.floor((params:get(self.id("slice_count")) or 1) + 0.5), 1, 32)
    screen.level(3)
    for slice = 1, slice_count - 1 do
      local x = x0 + math.floor((width * slice / slice_count) + 0.5)
      screen.move(x, y0 + 1)
      screen.line(x, y0 + height - 1)
    end
    screen.stroke()
  end

  local start_point, end_point = self.active_region()
  local phase = util.clamp(self.display_phase(), 0, 1)
  local position = util.clamp(start_point + ((end_point - start_point) * phase), 0, 128)
  local visual_start = self.visual_param_value("loop_start", 0)
  local visual_end = self.visual_param_value("loop_end", 128)
  local function draw_fraction_marker(fraction, kind)
    if view_hi <= view_lo or fraction < view_lo or fraction > view_hi then
      return
    end
    self:draw_waveform_marker(((fraction - view_lo) / (view_hi - view_lo)) * 128, x0, y0, width, height, kind)
  end

  if opts.sample_edit then
    screen.level(9)
    if duration > 0 then
      self:draw_marker_pair(trim_start / duration, trim_end / duration, view_lo, view_hi, x0, y0, width, height)
    else
      draw_fraction_marker(0, "start")
      draw_fraction_marker(1, "end")
    end
  elseif opts.range_edit then
    screen.level(9)
    self:draw_marker_pair(marker_range_lo, marker_range_hi, view_lo, view_hi, x0, y0, width, height)
  else
    screen.level(9)
    self:draw_waveform_marker(visual_start, x0, y0, width, height, "start")
    self:draw_waveform_marker(visual_end, x0, y0, width, height, "end")

    -- Only show the playhead while the transport is actually playing. While
    -- stopped (incl. a held-step preview) it would sit static and misleading.
    if self.get_playing == nil or self.get_playing() then
      screen.level(15)
      self:draw_waveform_marker(position, x0, y0, width, height, nil)
    end
  end

  -- Stereo / mono badge (top-left of the waveform box).
  if meta.channels ~= nil then
    screen.level(0)
    screen.rect(x0 + 1, y0 + 1, 11, 7)
    screen.fill()
    screen.level(9)
    screen.move(x0 + 2, y0 + 7)
    screen.text(meta.channels >= 2 and "ST" or "MO")
  end
end

-- Draws param cells for the K2/K3 group model, rendered at cell positions
-- offset by cell_offset (Range's items live at list indices 1-3 -- so K2/K3
-- default to them -- but render on the bottom row via cell_offset 4).
function SourcePage:draw_editor_cells(items, cell_offset)
  cell_offset = cell_offset or 0
  local selected_start = ((self.nav:clamp_current_group() - 1) * 2) + 1
  for i = 1, 8 do
    local param_item = items[i]
    if param_item ~= nil then
      local corner = nil
      if i == selected_start then
        corner = "tl"
      elseif i == selected_start + 1 then
        corner = "br"
      end
      self:draw_main_cell(param_item, i + cell_offset, corner)
    end
  end
end

-- Shared renderer for every sample-style page (Source main, File editor, Range)
-- so they read as one uniform layout: header + full-width waveform + the 4x2
-- cell grid, differing only in waveform view mode and where the cells sit.
function SourcePage:draw_editor(opts)
  self.draw_page_header(opts.title or "", opts.page_number or 1)
  self:draw_waveform({
    x = 1,
    y = SOURCE_WAVEFORM_Y,
    width = 127,
    height = SOURCE_WAVEFORM_HEIGHT,
    show_slices = opts.show_slices,
    sample_edit = opts.sample_edit,
    range_edit = opts.range_edit,
    slot = opts.slot
  })
  self:draw_editor_cells(opts.items, opts.cell_offset)
end

function SourcePage:draw_main_page(items, page_number)
  local machine = self.param_value_or("machine", 1)
  self:draw_editor({
    items = items,
    page_number = page_number,
    title = "",
    show_slices = self.MachineRegistry.is_slice(machine)
  })
end

function SourcePage:draw_file_page(page, items)
  -- The File page edits its own file-edit slot, independent of playback.
  local slot = self.elasticat.file_edit_slot ~= nil and self.elasticat.file_edit_slot() or self.param_value_or("file_slot", 1)
  local name = self.elasticat.pool_label ~= nil and self.elasticat.pool_label(slot) or self.sample_name()
  self:draw_editor({
    items = items,
    page_number = self.nav.page_index_by_category.file or 1,
    title = string.format("%03d %s", slot, name),
    sample_edit = true,
    slot = slot
  })
end

function SourcePage:draw_sample_page(page, items)
  local page_index = self.nav.page_index_by_category.source or 1
  if page_index == 1 then
    self:draw_main_page(items, page_index)
    return
  end

  -- Range page (4): edit params live on the bottom row (cell_offset 4) so they
  -- line up with the trim params on the File page.
  self:draw_editor({
    items = items,
    page_number = page_index,
    title = "RANGE",
    range_edit = true,
    cell_offset = 4
  })
end

return SourcePage
