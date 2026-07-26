-- Generic modal text-entry dialog (PRD §7.3). Reusable anywhere a string is
-- typed in (project name, pattern rename, ...). Pure logic/rendering: no engine
-- or sequencer calls, owns no grid device (`g` is passed into grid_redraw).
--
-- Public API (unchanged): TextEntry.new(opts); :open{text,title,max_length,
-- confirm_label,on_accept,on_cancel}; :is_open(); :key(n,z); :enc(n,d);
-- :grid_key(x,y,z); :draw(); :grid_redraw(g). :key/:enc/:grid_key return true
-- iff the (open) dialog consumed the event, so the coordinator swallows it.
--
-- ==== NORNS CONTROLS ========================================================
-- A caret sits BETWEEN characters (insert point). Focus is either the LETTER
-- picker or one of five FUNCTION buttons (X / RND / CLEAR / DEL / Confirm);
-- E2 moves focus across them. RND fills in a namesizer-generated name.
--   Letter focus:  E3 scrolls the character picker; K3 inserts it at the caret;
--                  E1 moves the caret; K2 deletes left of the caret.
--   Button focus:  K3 activates the button; K2 cancels.
-- K1 is never used (it is the norns FN/menu key). Confirm's label is
-- context-set by whoever opened the dialog (e.g. "SAVE").
--
-- ==== GRID (Deluge-style QWERTY, 16x8) ======================================
-- Escape (1,1); number row y3 (1..0 at x3-12, "-" x13, backspace x14-15);
-- qwerty y4 (x3-12); asdf y5 (x3-11, ";" x12, "'" x13, Return x14-15);
-- shift y6 (x1-2), zxcvbnm (x3-9), "," x10, "." x11, Up x13; space y7 (x5-10),
-- Left x12, Down x13, Right x14. Hold Shift for capitals + shifted symbols.
-- Left/Right move the caret; Backspace deletes; Return confirms; Escape cancels;
-- Up/Down are inert (single-line).
local TextEntry = {}
TextEntry.__index = TextEntry

TextEntry.DEFAULT_CHARSET = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.,;:'"
TextEntry.DEFAULT_MAX_LENGTH = 32
TextEntry.PICKER_WINDOW_RADIUS = 3
-- Focus values (E2 walks these): letters, then the function buttons.
local FOCUS_LETTERS, FOCUS_CANCEL, FOCUS_RND, FOCUS_CLEAR, FOCUS_DEL, FOCUS_CONFIRM = 0, 1, 2, 3, 4, 5

-- Build the grid cell table once: cells[y][x] = {kind, lower, shift, level}.
-- kind: char | shift | backspace | return | escape | left | right | up | down | space
local GRID_CELLS
local function build_grid_cells()
  local cells = {}
  local function put(x, y, cell)
    cells[y] = cells[y] or {}
    cells[y][x] = cell
  end
  local function char(x, y, lower, shift, level)
    put(x, y, {kind = "char", lower = lower, shift = shift, level = level})
  end

  put(1, 1, {kind = "escape", level = 14})

  local nums = {"1", "2", "3", "4", "5", "6", "7", "8", "9", "0"}
  local num_shift = {"!", "@", "#", "$", "%", "^", "&", "*", "(", ")"}
  for i = 1, 10 do char(2 + i, 3, nums[i], num_shift[i], 10) end
  char(13, 3, "-", "_", 6)
  put(14, 3, {kind = "backspace", level = 14})
  put(15, 3, {kind = "backspace", level = 14})

  local r4 = {"q", "w", "e", "r", "t", "y", "u", "i", "o", "p"}
  for i = 1, 10 do char(2 + i, 4, r4[i], r4[i]:upper(), 6) end

  local r5 = {"a", "s", "d", "f", "g", "h", "j", "k", "l"}
  for i = 1, 9 do char(2 + i, 5, r5[i], r5[i]:upper(), 6) end
  -- Punctuation keys sit a notch dimmer (4) than letters (6) so the letter
  -- field reads as the primary surface.
  char(12, 5, ";", ":", 4)
  char(13, 5, "'", '"', 4)
  put(14, 5, {kind = "return", level = 15})
  put(15, 5, {kind = "return", level = 15})

  put(1, 6, {kind = "shift", level = 12})
  put(2, 6, {kind = "shift", level = 12})
  local r6 = {"z", "x", "c", "v", "b", "n", "m"}
  for i = 1, 7 do char(2 + i, 6, r6[i], r6[i]:upper(), 6) end
  char(10, 6, ",", "<", 4)
  char(11, 6, ".", ">", 4)
  put(13, 6, {kind = "up", level = 13})

  for x = 5, 10 do put(x, 7, {kind = "space", level = 12}) end
  put(12, 7, {kind = "left", level = 13})
  put(13, 7, {kind = "down", level = 13})
  put(14, 7, {kind = "right", level = 13})
  return cells
end
GRID_CELLS = build_grid_cells()

function TextEntry.new(opts)
  opts = opts or {}
  return setmetatable({
    charset = opts.charset or TextEntry.DEFAULT_CHARSET,
    default_max_length = opts.max_length or TextEntry.DEFAULT_MAX_LENGTH,
    is_open_flag = false,
    text = "",
    title = "",
    confirm_label = "OK",
    max_length = opts.max_length or TextEntry.DEFAULT_MAX_LENGTH,
    cursor = 0,           -- caret position: 0..#text (insert point)
    focus = FOCUS_LETTERS,
    picker_index = 1,
    shift = false,
    on_accept = nil,
    on_cancel = nil,
    _grid_pressed = {},
    _frame = 0
  }, TextEntry)
end

function TextEntry:open(opts)
  opts = opts or {}
  self.text = opts.text or ""
  self.title = opts.title or ""
  self.confirm_label = opts.confirm_label or "OK"
  self.max_length = opts.max_length or self.default_max_length
  self.on_accept = opts.on_accept
  self.on_cancel = opts.on_cancel
  self.cursor = #self.text
  self.focus = FOCUS_LETTERS
  self.picker_index = 1
  self.shift = false
  self._grid_pressed = {}
  self._frame = 0
  self.is_open_flag = true
end

function TextEntry:is_open()
  return self.is_open_flag == true
end

-- ---- text ops (all caret-relative) ----------------------------------------

function TextEntry:_insert(ch)
  if ch == nil or ch == "" or #self.text >= self.max_length then
    return
  end
  self.text = self.text:sub(1, self.cursor) .. ch .. self.text:sub(self.cursor + 1)
  self.cursor = self.cursor + 1
end

function TextEntry:_backspace()
  if self.cursor <= 0 then
    return
  end
  self.text = self.text:sub(1, self.cursor - 1) .. self.text:sub(self.cursor + 1)
  self.cursor = self.cursor - 1
end

function TextEntry:_clear()
  self.text = ""
  self.cursor = 0
end

-- RND button: replace the text with a namesizer-generated name (bundled
-- lib/namesizer, hyphen-joined so it's filename-safe). Loaded lazily and
-- pcall-guarded; a missing/broken library makes RND a silent no-op rather
-- than crashing a modal that has swallowed all input.
function TextEntry:_randomize()
  local ok, NameSizer = pcall(function() return include("lib/namesizer/namesizer") end)
  if not ok or type(NameSizer) ~= "table" or type(NameSizer.rnd) ~= "function" then
    return
  end
  local ok2, name = pcall(NameSizer.rnd, "-")
  if ok2 and type(name) == "string" and name ~= "" then
    self.text = name:sub(1, self.max_length)
    self.cursor = #self.text
  end
end

function TextEntry:_move_cursor(delta)
  self.cursor = math.max(0, math.min(#self.text, self.cursor + delta))
end

function TextEntry:_accept()
  local text, callback = self.text, self.on_accept
  self.is_open_flag = false
  if callback ~= nil then callback(text) end
end

function TextEntry:_cancel()
  local callback = self.on_cancel
  self.is_open_flag = false
  if callback ~= nil then callback() end
end

function TextEntry:_move_picker(delta)
  local len = #self.charset
  if len > 0 and delta ~= 0 then
    self.picker_index = ((self.picker_index - 1 + delta) % len) + 1
  end
end

function TextEntry:_picker_char()
  return self.charset:sub(self.picker_index, self.picker_index)
end

function TextEntry:_activate_focus()
  if self.focus == FOCUS_CANCEL then
    self:_cancel()
  elseif self.focus == FOCUS_RND then
    self:_randomize()
  elseif self.focus == FOCUS_CLEAR then
    self:_clear()
  elseif self.focus == FOCUS_DEL then
    self:_backspace()
  elseif self.focus == FOCUS_CONFIRM then
    self:_accept()
  end
end

-- ---- norns input ----------------------------------------------------------

function TextEntry:key(n, z)
  if not self:is_open() then
    return false
  end
  if z ~= 1 then
    return true  -- swallow key-up
  end
  if n == 2 then
    -- K2: backspace on the letter picker, cancel on a function button.
    if self.focus == FOCUS_LETTERS then
      self:_backspace()
    else
      self:_cancel()
    end
  elseif n == 3 then
    -- K3: insert the picked character, or activate the focused button.
    if self.focus == FOCUS_LETTERS then
      self:_insert(self:_picker_char())
    else
      self:_activate_focus()
    end
  end
  -- n == 1 (K1) is swallowed but does nothing: reserved as the FN/menu key.
  return true
end

function TextEntry:enc(n, d)
  if not self:is_open() then
    return false
  end
  if n == 1 then
    if self.focus == FOCUS_LETTERS then
      self:_move_cursor(d)
    end
  elseif n == 2 then
    -- Focus moves across [letters, Cancel, DEL, Confirm] (clamped, full delta).
    self.focus = math.max(FOCUS_LETTERS, math.min(FOCUS_CONFIRM, self.focus + d))
  elseif n == 3 then
    if self.focus == FOCUS_LETTERS then
      self:_move_picker(d)
    end
  end
  return true
end

-- ---- grid input -----------------------------------------------------------

function TextEntry:grid_key(x, y, z)
  if not self:is_open() then
    return false
  end
  local cell = GRID_CELLS[y] and GRID_CELLS[y][x]
  if cell == nil then
    return true  -- inside the modal, unmapped keys are inert (still swallowed)
  end

  local key = x .. "_" .. y
  local was_down = self._grid_pressed[key] == true
  self._grid_pressed[key] = z == 1 or nil

  if cell.kind == "shift" then
    self.shift = z == 1
    return true
  end
  if z ~= 1 then
    return true  -- everything else acts on press only
  end
  -- Debounce: one character per discrete press. A repeated key-down without an
  -- intervening key-up (grid bounce, or a held key auto-repeating) is ignored.
  if was_down then
    return true
  end

  if cell.kind == "char" then
    self:_insert(self.shift and cell.shift or cell.lower)
  elseif cell.kind == "space" then
    self:_insert(" ")
  elseif cell.kind == "backspace" then
    self:_backspace()
  elseif cell.kind == "return" then
    self:_accept()
  elseif cell.kind == "escape" then
    self:_cancel()
  elseif cell.kind == "left" then
    self:_move_cursor(-1)
  elseif cell.kind == "right" then
    self:_move_cursor(1)
  end
  -- up/down: inert (single-line).
  return true
end

-- ---- render ----------------------------------------------------------------

function TextEntry:_picker_window(radius)
  radius = radius or TextEntry.PICKER_WINDOW_RADIUS
  local len = #self.charset
  local out = {}
  for i = -radius, radius do
    local idx = ((self.picker_index - 1 + i) % len) + 1
    out[#out + 1] = self.charset:sub(idx, idx)
  end
  return out
end

function TextEntry:draw()
  if not self:is_open() then
    return
  end
  self._frame = (self._frame + 1) % 1000000

  screen.level(0)
  screen.rect(0, 0, 128, 64)
  screen.fill()

  -- Context-sensitive header.
  screen.level(3)
  screen.rect(0, 0, 128, 11)
  screen.fill()
  screen.level(15)
  screen.move(64, 8)
  screen.text_center(self.title ~= "" and self.title or "ENTER TEXT")

  -- Text box with the caret drawn BETWEEN characters at self.cursor.
  local box_x, box_y = 4, 17
  screen.level(1)
  screen.rect(box_x, box_y, 120, 14)
  screen.fill()
  screen.level(15)
  screen.rect(box_x, box_y, 120, 14)
  screen.stroke()

  local text_x, text_y = box_x + 4, box_y + 10
  screen.level(15)
  screen.move(text_x, text_y)
  screen.text(self.text)
  -- Caret: width of the text left of the cursor, INCLUDING trailing spaces
  -- (screen.text_extents drops trailing whitespace). Append a marker so any
  -- trailing space is measured mid-string, then subtract the marker's own
  -- width. Clamped inside the box so it can never vanish off an edge.
  if self.focus == FOCUS_LETTERS or math.floor(self._frame / 8) % 2 == 0 then
    local before = self.text:sub(1, self.cursor)
    local caret_x = text_x
    if before ~= "" then
      caret_x = text_x + screen.text_extents(before .. "|") - screen.text_extents("|")
    end
    caret_x = math.max(text_x, math.min(caret_x, box_x + 116))
    screen.level(15)
    screen.rect(caret_x + 1, box_y + 2, 1, 10)
    screen.fill()
  end

  -- Character picker strip (bright when it has focus).
  local chars = self:_picker_window()
  local center = TextEntry.PICKER_WINDOW_RADIUS + 1
  local step = 13
  local start_x = 64 - ((center - 1) * step)
  local letters_focused = self.focus == FOCUS_LETTERS
  for i, ch in ipairs(chars) do
    local cx = start_x + (i - 1) * step
    local label = ch == " " and "_" or ch
    if i == center then
      screen.level(letters_focused and 15 or 6)
      screen.rect(cx - 5, 36, 10, 11)
      if letters_focused then screen.fill() else screen.stroke() end
      screen.level(letters_focused and 0 or 12)
    else
      screen.level(letters_focused and 5 or 3)
    end
    screen.move(cx, 44)
    screen.text_center(label)
  end

  -- Function buttons: X / RND / CLEAR / DEL / Confirm. Five even 25px cells
  -- with 1px gaps. No borders -- just the label, highlighted (filled box,
  -- inverted text) when focused. RND replaces the text with a namesizer name.
  local labels = {"X", "RND", "CLEAR", "DEL", self.confirm_label}
  local focus_map = {FOCUS_CANCEL, FOCUS_RND, FOCUS_CLEAR, FOCUS_DEL, FOCUS_CONFIRM}
  local cell_w = 25
  for i = 1, 5 do
    local bx = (i - 1) * (cell_w + 1)
    if self.focus == focus_map[i] then
      screen.level(15)
      screen.rect(bx, 54, cell_w, 10)
      screen.fill()
      screen.level(0)
    else
      screen.level(9)
    end
    screen.move(bx + cell_w / 2, 62)
    screen.text_center(labels[i])
  end
end

function TextEntry:grid_redraw(g)
  if g == nil or not self:is_open() then
    return
  end
  g:all(0)
  for y, row in pairs(GRID_CELLS) do
    for x, cell in pairs(row) do
      local level = cell.level
      if cell.kind == "shift" and self.shift then
        level = 15
      elseif self._grid_pressed[x .. "_" .. y] then
        level = 15
      end
      g:led(x, y, level)
    end
  end
  g:refresh()
end

return TextEntry
