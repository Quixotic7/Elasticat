-- Trig conditions (PRD docs/PRD.md §6.5). Shared by the param definition (which
-- uses the labels) and the evaluator in lib/grid_sequencer.lua (which reads the
-- kind/a/b), so the option index and its meaning can never drift apart.
--
-- Order IS the trig_condition option index (1-based). A trig fires only if its
-- condition passes AND its chance roll passes -- see GridSequencer:condition_passes.
--   ab    : fires on the A-th of every B pattern passes (Elektron A:B).
--   fill  : fires while Fill is engaged; nfill = while it isn't.
--   pre   : fires if the previous CONDITIONAL trig on this track passed; npre = if not.
--   nei   : neighbor track's previous conditional -- multitrack only, so nei/nnei
--           both evaluate always-true until the neighbor machine exists.
--   first : only on the first pattern pass after (re)entering the pattern.
return {
  { label = "--",    kind = "none" },
  { label = "1:2",   kind = "ab", a = 1, b = 2 },
  { label = "2:2",   kind = "ab", a = 2, b = 2 },
  { label = "1:3",   kind = "ab", a = 1, b = 3 },
  { label = "2:3",   kind = "ab", a = 2, b = 3 },
  { label = "3:3",   kind = "ab", a = 3, b = 3 },
  { label = "1:4",   kind = "ab", a = 1, b = 4 },
  { label = "2:4",   kind = "ab", a = 2, b = 4 },
  { label = "3:4",   kind = "ab", a = 3, b = 4 },
  { label = "4:4",   kind = "ab", a = 4, b = 4 },
  { label = "FILL",  kind = "fill" },
  { label = "!FILL", kind = "nfill" },
  { label = "PRE",   kind = "pre" },
  { label = "!PRE",  kind = "npre" },
  { label = "NEI",   kind = "nei" },
  { label = "!NEI",  kind = "nnei" },
  { label = "1ST",   kind = "first" },
}
