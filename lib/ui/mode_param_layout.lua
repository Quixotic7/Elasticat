-- Shared "Mode Parameter" page layout (owner redesign, used by the WARP, FILTER
-- MIX and FX slot pages). Arranges a machine/mode's raw param list into the
-- 10-slot skeleton the renderer (page_render:draw_mode_param_page) expects:
--   items 1-8  two low-profile rows of 4 -- the machine's own params
--   item 9     the mode `banner` (K2/B2 side) -- the machine/mode selector
--   item 10    a `trailing` param (K3/B3 side) -- e.g. WARP's RATE; pass a blank
--              item when the page has none (FILTER MIX, FX)
-- Envelope params (env_role "attack"/"release") are forced onto the second row --
-- Attack to item 5 (first cell), Release to item 6 -- so every envelope reads the
-- same regardless of the machine's declared order. The machine's own padding
-- blanks are dropped and the skeleton re-pads to fixed positions. `blank` is a
-- 0-arg blank-item factory. Up to 8 params fit (two full rows); an extra param
-- past the sixth non-envelope one would be dropped.
local ModeParamLayout = {}

function ModeParamLayout.arrange(raw, banner, trailing, blank)
  local attack, release
  local rest = {}
  for _, it in ipairs(raw or {}) do
    if it.blank then                      -- drop the machine's own padding
    elseif it.env_role == "attack" then
      attack = it
    elseif it.env_role == "release" then
      release = it
    else
      rest[#rest + 1] = it
    end
  end

  local items = {}
  for i = 1, 4 do                         -- top row: first four non-env params
    items[i] = rest[i] or blank()
  end
  if attack ~= nil or release ~= nil then -- envelope: Attack, Release, then params
    items[5] = attack or blank()
    items[6] = release or blank()
    items[7] = rest[5] or blank()
    items[8] = rest[6] or blank()
  else                                    -- no envelope: params flow in naturally
    items[5] = rest[5] or blank()
    items[6] = rest[6] or blank()
    items[7] = rest[7] or blank()
    items[8] = rest[8] or blank()
  end
  items[9] = banner
  items[10] = trailing
  return items
end

return ModeParamLayout
