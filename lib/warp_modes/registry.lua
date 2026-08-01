local Registry = {}

local modes = {
  [1] = include("lib/warp_modes/tape"),
  [2] = include("lib/warp_modes/tempo_varispeed"),
  [3] = include("lib/warp_modes/domino"),
  [4] = include("lib/warp_modes/granular"),
  [5] = include("lib/warp_modes/random_ola"),
  [6] = include("lib/warp_modes/pitch_corrected"),
  [7] = include("lib/warp_modes/harmonizer"),
  [8] = include("lib/warp_modes/wavetable"),
  [9] = include("lib/warp_modes/spectral_freeze"),
  [10] = include("lib/warp_modes/formant"),
  -- tape_xf / tape_ugen / rubberband removed 2026-07-31 (tape is the breadwinner);
  -- the survivors compacted down, so their ids shifted (see each mode file).
  [11] = include("lib/warp_modes/gstretch"),
  [12] = include("lib/warp_modes/gstretch2"),
  [13] = include("lib/warp_modes/chopped")
}

function Registry.get(mode_id)
  return modes[math.floor((tonumber(mode_id) or 1) + 0.5)] or modes[1]
end

function Registry.source_items(mode_id, Item)
  local mode = Registry.get(mode_id)
  return mode.source_items ~= nil and mode.source_items(Item) or {}
end

-- Arrange a mode's raw params into the reusable Mode-Parameter page skeleton
-- (owner, mirrors FILTER MIX): two low-profile rows of 4 (items 1-8) fully for the
-- mode's own params, then the last pair along the bottom -- the mode `banner` at
-- item 9 (K2 side) and a constant `trailing` param (RATE) at item 10 (K3 side),
-- rendered to the banner's right. Envelope params (env_role "attack"/"release")
-- are forced to the second row -- Attack to item 5 (first cell), Release to item 6
-- -- so every envelope reads the same regardless of the mode's own order; the
-- mode's own padding blanks are dropped and the skeleton re-pads to fixed
-- positions. `blank` is a 0-arg blank-item factory. Modes carry <= 8 params today
-- (two full rows), so nothing overflows -- an extra param past the sixth non-env
-- one would be dropped.
function Registry.arrange_page(raw, banner, trailing, blank)
  local attack, release
  local rest = {}
  for _, it in ipairs(raw or {}) do
    if it.blank then                      -- drop the mode's own padding
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

return Registry
