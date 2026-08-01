local ModeParamLayout = include("lib/ui/mode_param_layout")

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

-- Arrange the current mode's params into the reusable Mode-Parameter page skeleton
-- (shared with FILTER MIX and the FX pages). Delegates to lib/ui/mode_param_layout;
-- the WARP page passes its RATE param as the item-10 `trailing`.
function Registry.arrange_page(raw, banner, trailing, blank)
  return ModeParamLayout.arrange(raw, banner, trailing, blank)
end

return Registry
