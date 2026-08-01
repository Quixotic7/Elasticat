# Human factors QA — playing elasticat as an Elektron player

Written from the perspective of someone fluent on Digitakt/Octatrack/Rytm, reading
the control surface in `CONTROLS.md` and the Phase 2 multi-track work. Findings are
marked **[verified]** where I confirmed them in code, **[inferred]** where they follow
from the design but need hands on hardware.

## What already reads as Elektron-native

Worth stating, because it sets the bar for the gaps: scoped **copy/clear/paste** on
step / page / pattern, **p-locks** by hold-and-turn, **ghost trigs** (Elektron's
trigless trigs), **trig conditions**, **ratchets**, **swing**, momentary and latched
**fill**, per-page **loop and rate**, **quantized pattern switching**, and A/B
**scenes on a crossfader** (Octatrack). A player from that world will find their
muscle memory mostly intact.

Two things are genuinely *better* than the hardware:

- **Undo.** Elektron boxes have none. A performer who fumbles a crossfade on a
  Digitakt has lost the work; here the NO key restores it, including the fader
  position. This is a real differentiator — it should be advertised, not buried.
- **CUT/PASTE on held STOP.** Faster than FUNC-combos for rearranging a pattern live.

## Gaps, in the order I'd fix them

### 1. Solo — the biggest hole at 8 tracks *[verified: mute exists, solo does not]*

`FN + track` mutes one track at a time. With 8 tracks running there is no way to
audition one in isolation, and muting seven by hand mid-performance is not viable.

Recommend: a **mute/solo mode** — hold a modifier so row 4 becomes eight latching
mute toggles you can slap in any order, with a second gesture for solo (and solo
being non-destructive to the mute state you return to). Elektron's dedicated mute
mode is the reference; the grid makes it better because all 8 states are visible at
once instead of paged.

Also: Digitakt stores mute state **per pattern**, which is how people build
arrangements without a song mode. Worth matching.

### 2. Sound locks — the highest value-per-unit-effort feature here *[inferred]*

On Elektron, p-locking the *sample slot* per step ("sound locks") is what turns one
track into a whole kit. elasticat already has a shared sample pool, `sample_slot` is
already a per-track param, and the p-lock machinery is generic. If `sample_slot`
becomes step-lockable, a single track can juggle eight different sources — for a
loop-mangling instrument this is enormous, and it is mostly wiring rather than new
design.

I would prioritise this above almost anything else on this list.

### 3. Micro-timing *[inferred: not present in CONTROLS.md]*

Per-step nudge, roughly ±1/6 of a step. An Elektron staple and the main tool for
making programmed parts feel human. Swing is global-per-track and is not a
substitute. Natural gesture: hold step + LEFT/RIGHT.

### 4. Poly-metric sequencing is probably already there — surface it *[verified: `pattern_steps` is per-track]*

Because `pattern_steps` is a per-track param, tracks of different lengths should
already run against each other, which is one of the most musical things an Elektron
does. If that works, it is currently invisible: nothing on screen says "track 3 is 12
steps against track 1's 16". The overview page should show each track's length and
its position within it.

### 5. Parameter access with three encoders *[verified: K2/K3 select a pair]*

An Elektron player expects eight knobs live under their hands. Here, four low-profile
cells with K2/K3 selecting a pair is a sensible adaptation, but it costs a button
press before every edit, and in performance that is the difference between riding a
filter and operating a menu.

Worth trying: **hold a category key, then a step key = jump straight to that
parameter.** It reuses gestures that already exist, needs no new hardware, and turns
parameter selection into one motion instead of a hunt.

### 6. Step feedback for locks and conditions *[inferred — verify on hardware]*

Elektron distinguishes, at a glance, a plain trig from a locked trig from a
conditional one. On a 16x8 grid with brightness only, this needs a deliberate scheme
rather than one "on" level. If it is not already there, it should be: without it,
p-locks become invisible state, which is exactly what makes a sequencer feel
untrustworthy live.

### 7. Arrangement *[verified: patterns exist, chaining does not]*

Sixteen patterns with quantized switching, but no chaining or song mode. Pattern
mutes (point 1) plus a simple chain would cover most live use without building a full
arranger.

## What is uniquely Norns here — the identity worth leaning into

This is the part I would not compromise, because it is the thing no Elektron can do.

**Eight independent time-stretching loop manglers with Elektron sequencing.**

- **Per-track warp machine.** Each track can run a *different* algorithm — tape,
  tempo-varispeed, chopped, granular, random-OLA, pitch-corrected. There is no
  Elektron product where track 1 is a granular cloud and track 2 is a tape
  varispeed against the same clock. After Phase 2 this is real, and it is the
  headline.
- **No sample-length ceiling.** A Digitakt's brutal RAM limit is why it is a drum
  machine. Norns can hold minutes, which makes elasticat a *loop deconstruction*
  instrument rather than a drum box. The eight tracks should be pitched as eight
  loops being pulled apart simultaneously, not eight drum voices.
- **Live region scrubbing on the grid.** Holding loop keys to move the played region
  in real time is the signature gesture, and it has no Elektron analogue — Elektron
  has no grid. Keeping this live and p-lockable is the design north star.
- **The screen as a waveform canvas.** Region, range and trim shown against the
  actual audio, following modulation at 15Hz. Elektron shows you numbers.

Two directions this opens that would be distinctly Norns:

- **Per-step region locks as the primary composition tool.** Not "which sample plays"
  but "which *slice of this minute-long recording* plays, and how is it stretched" —
  sequencing a sound's internal geometry.
- **Drawable LFO shapes on the grid** (already in the roadmap). Elektron gives you a
  fixed waveform list; drawing a shape and assigning it per track is a Norns-culture
  move.

## Recommended order

1. Mute/solo mode with per-pattern mutes *(unblocks actually playing 8 tracks)*
2. Sound locks — step-lockable `sample_slot` *(largest musical return for the work)*
3. Overview page showing length/position/mute/machine per track *(makes poly-meter usable)*
4. Step LED scheme for locks and conditions *(trust)*
5. Micro-timing
6. Hold-category + step for direct parameter access
7. Pattern chaining

## Caveat

None of this is hardware-tested — it is a reading of the control surface and code.
Ordering assumes the Phase 2 per-track work lands first, since several items (solo,
overview, poly-meter display) only matter once tracks are genuinely independent.
