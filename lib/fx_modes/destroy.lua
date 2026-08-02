-- Destroy (#7). Tonverk-style multi-FX distortion stack: one slot, a serial chain
-- of warble -> overdrive -> wavefold -> saturation -> bitcrush, each stage on its
-- own amount knob (0 = that stage bypasses). Reuses the shared fx_drive (DRIV
-- overdrive) and fx_mix (MIX); WARB/FOLD/SAT/CRSH/TONE/LEVL are new (CRSH is its
-- own crush so the knob reads up = more crush, unlike the LOFI machine's bit knob).
-- All p-lockable.
local Mode = {id = 7, name = "destroy"}

function Mode.source_items(Item, prefix)
  prefix = prefix or ""
  local q = {0, 32, 64, 96, 127}
  -- Page order (owner): the two digital-degradation knobs LEAD -- bitcrush then
  -- sample-rate reduction -- then the rest. This is DISPLAY order; the signal
  -- chain in the SynthDef stays warble -> drive -> fold -> sat -> crush -> SRR ->
  -- tone -> level (degradation after the shapers, which is the musical order).
  -- Fills all 8 cells.
  return {
    Item.item(prefix .. "destroy_crush", "CRSH", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_srr", "SRR", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_warble", "WARB", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_fold", "FOLD", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_sat", "SAT", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_tone", "TONE", {lockable = true, min = 0, max = 127, step = 1, snaps = q}),
    Item.item(prefix .. "destroy_level", "LEVL", {lockable = true, min = 0, max = 127, step = 1, snaps = q})
    -- No MIX: Destroy is always fully wet (owner). Its SynthDef ignores the mix arg.
  }
end

return Mode
