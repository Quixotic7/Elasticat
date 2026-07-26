# Elasticat controls cheat sheet

One-page reference. See `README.md` for explanations; this is table form
only. Coordinates are grid `(x,y)`, `x`=1-16 left-right, `y`=1-8 top-bottom.

## Grid map (loop-machine layout)

```
y\x     1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
y1     FN    -  REC PLAY STOP    -  MST FILE  PAT    - TRIG  SRC FILT  AMP   FX  MOD
y2      1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
y3     17   18   19   20   21   22   23   24   25   26   27   28   29   30   31   32
y4    MC1  MC2  MC3  MC4    -    -    -   T1   T2   T3   T4   T5   T6   T7   T8    -
y5   OCT- OCT+    -    -    -    -    - PATN SC-A  xf1  xf2  xf3  xf4  xf5  xf6 SC-B
y6      -   C#   D#    -   F#   G#   A#    -    -    -  YES    -   UP    -    - FILL
y7      C    D    E    F    G    A    B  C+1    -    -   NO LEFT DOWN RGHT    - PAGE
y8      1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
```

`y2`/`y3`: slice machines show slice triggers 1-16 / 17-32 instead of loop
keys. `-` = unused/reserved.

## Grid: row 1 — transport & categories

| x,y | Key | Action |
|---|---|---|
| 1,1 | FN | Hold = modifier (= norns K1). |
| 3,1 | REC | Toggle record-armed indicator. With a scope held (below): COPY. |
| 4,1 | PLAY | Toggle play/pause, no reset. With a scope held: CLEAR. |
| 5,1 | STOP | Tap = stop + reset to step 1 (fires on release). **Hold = CUT/PASTE mode** (below). With a step held: PASTE. |
| 7,1 | MST | MASTER category. |
| 8,1 | FILE | FILE category. |
| 9,1 | PAT | PATTERN category. |
| 11,1 | TRIG | TRIG category. |
| 12,1 | SRC | SOURCE category. |
| 13,1 | FILT | FILTER category. |
| 14,1 | AMP | AMP category. |
| 15,1 | FX | FX category. |
| 16,1 | MOD | MOD category. |

Category keys: press = switch category; press same one again = cycle its
pages; FN+press = open its settings page; FN+press again while in settings =
leave settings, land on that category's main page; press a *different*
category while in settings = jump straight to that category's settings.

## Grid: rows 2-3 — loop/slice keys

| Row | Loop machines | Slice machines |
|---|---|---|
| y=2 | Loop keys 1-16 (hold to jump live region) | Slice triggers 1-16 |
| y=3 | Loop keys 17-32 (only if SOURCE settings LDIV > 16) | Slice triggers 17-32 |

Hold a step first, then press loop keys, to lock that step's region instead
of moving the live one. One key: the first tap locks start+end; tap the same
key again for start-only (end follows the track). Two or more keys held at
once: start+end from their span.

## Grid: row 4 — macros & tracks

| x,y | Key | Action |
|---|---|---|
| 1,4-4,4 | MC1-MC4 | Macro keys (mod matrix). Hold + turn a destination param's encoder = dial that macro's signed depth to it. LED brightness tracks the macro's value. |
| 8,4-15,4 | T1-T8 | Track select (up to ACTIVE TRACKS). Press = select; FN+press = mute. |

## Grid: row 5 — octave, pattern load, scenes

| x,y | Key | Action |
|---|---|---|
| 1,5 | OCT- | Mini keyboard octave down (-2..+2). **FN+OCT-** = Recall the RAM project snapshot. |
| 2,5 | OCT+ | Mini keyboard octave up. **FN+OCT+** = Memorize the whole project state to RAM (playback-safe). |
| 3,5-7,5 | — | Unused. |
| 8,5 | PATN | Tap = latch pattern-load overlay open (tap again to close); hold = momentary. FN+press = pattern-quantize menu (screen). |
| 9,5 | SC-A | Scene A anchor: hold + `E2`/`E3` = lock that param into A; FN+press = capture all morphable params into A. |
| 10,5-15,5 | xf1-xf6 | Crossfade glide keys, A (10,5) → B (15,5). Hold to ease the crossfader toward that position. |
| 16,5 | SC-B | Scene B anchor: same as Scene A. |

## Grid: rows 6-7 — mini keyboard, YES/NO, arrows, FILL, PAGE

| x,y | Key | Action |
|---|---|---|
| 2,6 / 3,6 / 5,6 / 6,6 / 7,6 | C# D# F# G# A# | Black keys. |
| 11,6 | YES | Confirm (= K3). Hold on FILE page = preview sample (stopped only). |
| 13,6 | UP | Settings nav up; with PAGE held = Page-Select mode. |
| 16,6 | FILL | Hold = momentary Fill. FN+press = latch Fill on/off. |
| 1,7-8,7 | C D E F G A B C+1 | White keys (one octave + root above). |
| 11,7 | NO | Cancel in menus/dialogs (= K2). **Outside menus: quick UNDO** — see below. |
| 12,7 | LEFT | Settings nav left/value-; with PAGE held = Pattern-Rate mode. |
| 13,7 | DOWN | Settings nav down; with PAGE held = Page-Loop mode. |
| 14,7 | RIGHT | Settings nav right/value+/confirm-on-action-row; with PAGE held = back to Page-Select. **Also**: while the pattern-load overlay is open, renames the current pattern. |
| 16,7 | PAGE | Hold: step row becomes Page-Select / Page-Loop / Rate overlay (pick mode with UP/LEFT/DOWN above). |

## Grid: row 8 — steps

| Gesture | Action |
|---|---|
| Quick tap | Toggle trig on/off. |
| FN + quick tap | Toggle ghost trig (carries state forward, no re-trigger). |
| Hold + turn `E2`/`E3` | Parameter-lock that step. |
| Hold + press loop/pitch/slice key | Lock that value to the step. |
| Hold + `K2`/`K3` | Clear one param's lock on that step. |
| While PATN overlay open | Press a slot (1-16) to load that pattern. |
| While PAGE (16,7) held | Pick page / toggle page-loop / pick rate, per the active overlay mode. |

## Quick undo (NO key)

Outside menus and dialogs the **NO** key (`11,7`) undoes the last value
change — press it again to keep stepping back (16 deep).

| Undoes | Restores |
|---|---|
| A crossfader move | every morphed parameter *and* the fader position, as they were before the move |
| A parameter edit (encoder, any page, incl. settings) | that parameter's value before you started turning |
| A step tapped on/off | the whole step record, parameter locks included |
| A parameter lock (hold step + encoder / loop / pitch key) | the step's locks as they were |
| CUT/PASTE, and copy-paste-clear of steps / pages | the affected steps |

Undo works per **gesture**, not per detent: turning cutoff from 20 to 90 in
one motion undoes straight back to 20, and a whole fader glide is a single
step. Pausing for about a second starts a new gesture.

This is the safety net for the crossfader: with scenes mapped, brushing the
fader overwrites the values you had dialed in — NO puts them back.

## CUT / PASTE mode (hold STOP)

Hold **STOP** and tap steps to shuffle them around quickly. The header shows
`CUT/PASTE` and whether the next tap will cut or paste.

| Tap a step that… | Does |
|---|---|
| has a trig | **cuts** it — copied to the buffer, then cleared |
| is empty | **pastes** the buffer there (the buffer stays, so you can keep dropping it) |

Tapping another step that has a trig cuts that one instead, replacing the
buffer. STOP's own transport action fires on **release**, and is skipped if the
hold was used to shuffle — so a tap still stops, but shuffling never kills
playback. NO undoes each cut and paste.

## Copy / Clear / Paste (Elektron-style)

REC/PLAY/STOP double as COPY/CLEAR/PASTE while a scope modifier is held.
Each scope keeps its own buffer, so a copied step never overwrites a copied
pattern.

| Scope | Copy | Clear | Paste |
|---|---|---|---|
| Step(s) | hold step(s) + REC | hold step + PLAY (removes p-locks, keeps the trig) | hold step + STOP |
| Sequencer page | hold PAGE + REC (selected page) | hold PAGE + PLAY | hold PAGE + STOP |
| Pattern | FN + REC | FN + PLAY (confirm popup; wipes trigs only) | FN + STOP |

Multi-step copy: hold several steps and press REC — pasting onto a held step
places the copies in the same relation to each other (steps that would land
past the page edge are dropped).

## Norns panel

| Control | Action |
|---|---|
| `K1` hold | FN modifier (quick tap reserved by norns for its system menu). |
| `K1`+`E1` CW / CCW | Open / leave the current category's settings. |
| `K1`+`E2`/`E3` (turn) | Snap the edited parameter to a preset value. |
| `E1` | Cycle parameter pages (rolls across categories). |
| `E2` / `E3` | Edit the left / right parameter of the selected pair. |
| `K2` / `K3` | Previous / next parameter pair. |
| Hold step + `E2`/`E3` | Parameter-lock that step's value. |
| Hold step + `K2`/`K3` | Clear that step's lock (left/right param). |
| `K1`+`K2`/`K3` | Clear that param's locks across the whole pattern. |
| **Settings layer:** `K3`/YES | Confirm / invoke selected action row. |
| `K2`/NO | Cancel / close settings. |
| grid up/down or `E2` | Move settings selection (crosses pages). |
| grid left/right or `E3` | Adjust selected row's value (or confirm on action rows). |

## Text-entry dialog (project name / pattern rename)

| Control | Action |
|---|---|
| `E2` | Scroll the character picker. |
| `E3` | Commit the highlighted character (appends; multi-detent = multiple copies). |
| `K2` | Backspace. |
| `K3` | Accept. |
| `K1` | Cancel. |
| Grid y=2 | Q W E R T Y U I O P (x=1-10). |
| Grid y=3 | A S D F G H J K L (x=1-9). |
| Grid y=4 | Z X C V B N M (x=1-7). |
| Grid y=5 | Space (x=1-8), Shift hold (x=10-11), Backspace (x=13-14), OK (x=16). |

## Trig conditions (17 options)

`--`, `1:2` `2:2`, `1:3` `2:3` `3:3`, `1:4` `2:4` `3:4` `4:4`, `FILL` `!FILL`,
`PRE` `!PRE`, `NEI` `!NEI` (always-true until multitrack), `1ST`.

## Trig Release / Trig Jump

| Value | Trig Release (on override end) | 
|---|---|
| 1 (default) | Return — snaps back to where the main loop naturally would be. |
| 2 | Boomerang — plays the override region backwards on the way out. |
| 3 | Reset — restarts the main loop from its own start. |

Trig Jump ON (default) = new region snaps playhead to its start every trig.
Trig Jump OFF = playhead keeps its absolute position, only warping to the
region start if it would otherwise fall outside the new region.

## Filter machines (FILTER settings > MACH)

| # | Name | Params |
|---|---|---|
| 1 | Classic | TYPE (LP/HP/BP/notch), CUT, RES, DRIV |
| 2 | Morphing | MRPH, CUT, RES, DRIV |
| 3 | Classic Stereo | BAL, TYPE, CUT, RES, DRIV |
| 4 | Morphing Stereo | BAL, MRPH, CUT, RES, DRIV |
| 5 | Classic Mid/Side | MSBL, TYPE, CUT, RES, DRIV |
| 6 | Morphing Mid/Side | MSBL, MRPH, CUT, RES, DRIV |

## FX slots

| Slot | Where | Machine setting | Knobs |
|------|-------|-----------------|-------|
| Insert 1 | filter output -> master bus | FX settings > MACH | FX page 1 |
| Send 1 / Send 2 | fed by the send tap (FX settings > SEND TAP: pre- or post-Insert-1); levels on FX page 2 (SEND1/SEND2, p-lockable) | FX settings > SEND1/SEND2 MACH | FX pages 3/4 (SEND1 FX / SEND2 FX) |
| Master | master bus -> output (colors everything, send returns included) | FX settings > MASTER MACH | FX page 5 (MASTER FX) |

All four slots pick from the same machine list below (None = passthrough,
free). Each slot's page shows its active machine's knobs (a slot on None shows
an empty page); all knobs are p-lockable and scene-morphable.

## FX machines (any slot)

| # | Name | Params |
|---|---|---|
| 1 | None | — (passthrough, default) |
| 2 | Drive | DRIV, MIX |
| 3 | Delay | TIME (beat division), FBK, TONE, MIX |
| 4 | Reverb | SIZE, DAMP, MIX |
| 5 | Lofi | BITS, RATE, MIX |

## MOD pages (2 LFOs + mod envelope + 4 macros)

| Page | Params |
|---|---|
| LFO 1 / LFO 2 | DEST (off/pitch/cutoff/res/amp/pan/**macro 1-4**), WAVE (sine/tri/saw/rsaw/sqr/rand), SPD (8 bar ... 1/64, tempo-synced), DEP (bipolar, 64 = off), MODE (free/trig/one/hold) |
| MOD ENV | DEST (same list, incl. macros), ATK, DEC, DEP (bipolar) -- an AD burst per note |
| MACROS | the 4 macro VALUE knobs (0-127, p-lockable). Each macro's mod matrix is assigned by the grid gesture below, not on this page. |

DEP/SPD/ATK/DEC and every macro VAL/DEP are p-lockable. TRIG/ONE/HOLD LFO
modes retrigger per step when the step's `LRST` (lfo_reset) resolves on; the
mod envelope retriggers per step when `ERST` (env_reset) resolves on. Ghost
steps retrigger nothing -- they ride the running modulation.

### Macros (a per-macro mod matrix)

Each of the 4 macros is its own **mod matrix**: a VALUE knob (0-127) times a
signed depth to any of the modulation destinations (pitch, filter cutoff,
filter res, amp/vol, pan). The macro contributes VALUE x depth to each
destination it's assigned to, summing with the LFOs/mod-env. An LFO or the mod
envelope can also **target a macro** (set its DEST to MACRO 1-4) to move the
macro's VALUE -- so one macro can push many params at once, itself driven by a
knob, an LFO, or a p-lock.

**Assign a macro (the matrix):** hold its grid key (row 4, cols 1-4), then turn
a **destination param's encoder** on its page -- `E2` for the selected pair's
left param, `E3` for the right. That dials the macro's signed depth to that
destination (turn up = positive, down = negative; center = off). Repeat on
different params to build the matrix. Turning a non-modulatable param while a
macro is held does nothing (it never edits the value).

**Drive a macro (the VALUE):** on the MACROS page (p-lockable per step), or by
pointing an LFO/mod-env's DEST at MACRO 1-4. The grid-key LED brightness tracks
the value.

## Pattern change quantization (PATTERN settings)

| Value | Behavior |
|---|---|
| Sequential (default) | New pattern starts at the next global-length boundary. |
| Direct Jump | Switches immediately, keeps current step position. |
| Direct Start | Switches immediately, restarts from step 1. |
| Temp Jump | Switches immediately, auto-returns after one full pass. |
