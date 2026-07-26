local Header = {}

Header.HEIGHT = 10
Header.BACKGROUND_LEVEL = 12
Header.SEPARATOR_X = 8
Header.METER_X = 9
Header.METER_Y = 8
Header.METER_WIDTH = 78
Header.METER_ZERO_DB_X = 71

local METER_MIN_DB = -48
local METER_MAX_DB = 12
local METER_BRIGHT_DB = -12

-- Tiny ghost silhouette drawn where the track number normally sits, shown while
-- holding a ghost step. Black body with background-colored eyes and feet.
function Header.draw_ghost_icon(cx)
  local x = cx - 2
  local y = 1
  screen.level(0)
  screen.rect(x + 1, y, 3, 1)
  screen.fill()
  screen.rect(x, y + 1, 5, 5)
  screen.fill()
  screen.level(Header.BACKGROUND_LEVEL)
  screen.pixel(x + 1, y + 5)
  screen.pixel(x + 3, y + 5)
  screen.pixel(x + 1, y + 2)
  screen.pixel(x + 3, y + 2)
  screen.fill()
end

local function db_to_length(db)
  local clamped = util.clamp(db, METER_MIN_DB, METER_MAX_DB)
  local fraction = (clamped - METER_MIN_DB) / (METER_MAX_DB - METER_MIN_DB)
  return util.clamp(math.floor((fraction * Header.METER_WIDTH) + 0.5), 0, Header.METER_WIDTH)
end

local function amp_to_length(amp)
  amp = math.max(tonumber(amp) or 0, 0)
  if amp <= 0 then
    return 0
  end
  return db_to_length(20 * (math.log(amp) / math.log(10)))
end

local METER_BRIGHT_LENGTH = db_to_length(METER_BRIGHT_DB)

function Header.draw_page_icon(number)
  local w = 7
  local h = 8
  local x = 120
  local y = 1

  screen.level(15)
  screen.rect(x, y, w, h)
  screen.fill()

  screen.level(Header.BACKGROUND_LEVEL)
  screen.pixel(x, y)
  screen.pixel(x + 1, y)
  screen.pixel(x, y + 1)
  screen.fill()

  screen.level(0)
  screen.move(x + math.floor(w / 2), y + 7)
  screen.text_center(tostring(number or 1))
end

function Header.draw_meter(left, right)
  screen.level(0)
  screen.rect(Header.METER_X, Header.METER_Y, Header.METER_WIDTH, 2)
  screen.fill()

  local rows = {Header.METER_Y, Header.METER_Y + 1}
  local values = {left, right}
  for i = 1, 2 do
    local len = amp_to_length(values[i])
    if len > 0 then
      local dim_len = math.min(len, METER_BRIGHT_LENGTH)
      screen.level(4)
      screen.rect(Header.METER_X, rows[i], dim_len, 1)
      screen.fill()

      if len > METER_BRIGHT_LENGTH then
        screen.level(9)
        screen.rect(Header.METER_X + METER_BRIGHT_LENGTH, rows[i], len - METER_BRIGHT_LENGTH, 1)
        screen.fill()
      end
    end
  end

  screen.level(4)
  screen.rect(Header.METER_ZERO_DB_X, Header.METER_Y, 1, 2)
  screen.fill()
end

function Header.draw(opts)
  opts = opts or {}
  local title = opts.title or "ELASTICAT"
  local message = opts.message or title
  local tempo = opts.tempo

  screen.level(Header.BACKGROUND_LEVEL)
  screen.rect(0, 0, 128, Header.HEIGHT)
  screen.fill()

  screen.level(0)
  screen.rect(Header.SEPARATOR_X, 0, 1, Header.HEIGHT)
  screen.fill()

  if opts.ghost then
    Header.draw_ghost_icon(math.floor(Header.SEPARATOR_X / 2))
  elseif opts.muted then
    -- MUTED: invert the track-number cell (dark block, light number) -- the
    -- standard mixer cue. A muted track is silent at the filter's amp stage,
    -- which is downstream of the meter, so without this the screen looked
    -- completely normal while nothing reached the outputs.
    screen.level(0)
    screen.rect(0, 0, Header.SEPARATOR_X, Header.HEIGHT)
    screen.fill()
    screen.level(Header.BACKGROUND_LEVEL)
    screen.move(math.floor(Header.SEPARATOR_X / 2), 7)
    screen.text_center(tostring(opts.track or 1))
  else
    screen.level(0)
    screen.move(math.floor(Header.SEPARATOR_X / 2), 7)
    screen.text_center(tostring(opts.track or 1))
  end

  -- Explicit level: the ghost icon leaves screen.level at BACKGROUND_LEVEL, so
  -- without this the message/tempo would render invisibly on the same-level bg.
  screen.level(0)
  screen.move(Header.SEPARATOR_X + 2, 7)
  screen.text_trim(message, 76)

  screen.move(117, 7)
  if tempo ~= nil then
    screen.text_right(string.format("%.1f", tempo))
  else
    screen.text_right(opts.state or "")
  end

  Header.draw_meter(opts.amp_l, opts.amp_r)
  Header.draw_page_icon(opts.page or 1)
end

return Header
