-- Tape UGEN (warp mode 12 / engine mode 11). Same tape playback as tape_xf, but
-- the read + sub-head crossfade run in the COMPILED ElasticatReader UGen (ugens/):
-- a softcut-style head pool that crossfades BOTH position jumps AND the loop seam,
-- sample-accurately at audio rate. Fade time = the source-page "loop xfade" param.
-- No extra warp params (an empty warp page, like tape / tape_xf).
--
-- Requires the plugin built + installed: run `./ugens/build-ugens.sh` and restart
-- the norns audio, or selecting this mode errors "UGen 'ElasticatReader' not found".
local Mode = {id = 12, name = "tape_ugen"}

function Mode.source_items(_)
  return {}
end

return Mode
