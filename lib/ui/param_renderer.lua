local ParamRenderer = {}

function ParamRenderer.draw_cell_value(text, width)
  -- Hard 5-character cap on any value shown in a param BOX (owner) -- a slot is
  -- too narrow for longer strings. Does NOT touch the header/show_message path,
  -- which uses item_display_value directly.
  text = string.sub(tostring(text or ""), 1, 5)
  if #text <= 3 then
    screen.text(text)
  else
    screen.text_trim(text, width)
  end
end

function ParamRenderer.draw_selection_corner(x, y, width, height, corner)
  screen.level(12)
  if corner == "tl" then
    screen.pixel(x, y)
    screen.pixel(x + 1, y)
    screen.pixel(x, y + 1)
  elseif corner == "br" then
    screen.pixel(x + width - 1, y + height - 1)
    screen.pixel(x + width - 2, y + height - 1)
    screen.pixel(x + width - 1, y + height - 2)
  end
  screen.fill()
end

function ParamRenderer.draw_param_cell(param_item, x, y, corner, item_locked, item_display_value)
  local width = 30
  local height = 21
  if param_item == nil then
    return
  end

  if corner ~= nil then
    ParamRenderer.draw_selection_corner(x, y - 2, width, height, corner)
  end

  if param_item.blank then
    return
  end

  screen.level(item_locked(param_item) and 12 or 5)
  screen.move(x + 2, y + 5)
  screen.text(string.sub(param_item.short or param_item.id, 1, 4))

  screen.level(corner ~= nil and 15 or 11)
  screen.move(x + 2, y + 17)
  ParamRenderer.draw_cell_value(item_display_value(param_item), width - 4)
end

return ParamRenderer
