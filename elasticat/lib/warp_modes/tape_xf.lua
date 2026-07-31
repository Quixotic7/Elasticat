-- Tape XF (warp mode 11 / engine mode 10). A straight tape reader like `tape`,
-- but a position JUMP ping-pongs between TWO reader voices and equal-power
-- crossfades between them (softcut-style), so region-change-on-jump no longer
-- clicks. Fade time = the source-page "loop xfade" param. No extra warp params
-- (it plays like tape) -- an empty warp page, same as tape / tempo_varispeed.
local Mode = {id = 11, name = "tape_xf"}

function Mode.source_items(_)
  return {}
end

return Mode
