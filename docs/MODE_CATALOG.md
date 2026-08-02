# Elasticat Mode Catalog

The one-page reference for every selectable "machine" in the script: track
machines, warp modes, filter machines, and FX machines. Registries in code:
`lib/machines/registry.lua`, `elasticat.modes` in `lib/elasticat.lua` (engine
`modeNames`), `lib/filter_modes/registry.lua`, `lib/fx_modes/registry.lua`.
Each Lua list is in positional lockstep with a SynthDef-name list in
`lib/Engine_Elasticat.sc`; `bin/test-elasticat-contract` enforces the pairing.

Shared rules:

- A **machine choice is a setting, not a p-lock**. Warp mode and filter
  machine additionally only change with playback **stopped** and **FN held**.
  The FX machine can be swapped **during playback** (FN still guards the
  turn) — the engine respawns the effect without stopping the transport.
- Machine *parameters* are p-lockable unless noted.

## Track machines (SOURCE settings)

| # | Name | What it is |
|---:|---|---|
| 1 | `loop` | Continuous region playback; trigs restart it; loop keys scrub/lock the region live. |
| 2 | `loop_trig` | Same engine, silent except during a triggered step; each step can lock its own region. |
| 3 | `grid_slice` | Region divided into up to 32 **equal** slices; grid rows y2/y3 are pads 1–16 / 17–32. Mono voicing. |
| 4 | `razor_slice` | Slices with **individually placed** start/end pairs (the razor editor: snap modes, zoom, transient auto-chop). Mono voicing. |
| 5 | `slice_poly` | `grid_slice` with polyphonic voicing (per-track cap 8 voices, global cap 24). |
| 6 | `razor_poly` | `razor_slice` with polyphonic voicing (same caps). |
| 7 | `neighbor` | **Tracks 2–6 only.** The LEFT track's output is the source, fully rerouted (the left track is audible only through this one) — serial-stack two tracks' filters/inserts. Playing-independent; warp/pitch inactive. |
| 8 | `input` | The norns audio input is the source (external gear through the track chain). Norns' input monitoring is auto-muted while in use, restored after. Playing-independent. |

**Bus pseudo-tracks** (row 4, x14–16): SEND 1 / SEND 2 / MASTER select as
screen-only "tracks" — sends expose their FX page, MASTER exposes the MIX
overview (SOURCE) and the master insert (FX). The track cap is **6**.

Slice machines: per-slice p-locks (hold a pad + edit), choke groups,
play modes (one-shot / hold / **loop** / ping-pong / continue), ratchets,
velocity as a mod source, copy/paste pads, mute pads.

## Warp modes (loop machines; WARP page banner)

How the region is read back. Most are compiled UGens (`ElasticatReader` /
`ElasticatGrains`, built on-device — see `lib/ugens/`); `spectral_freeze` and
`formant` are an FFT `PV_*` chain.

| # | Name | Identity | Pitch behavior |
|---:|---|---|---|
| 1 | `tape` | Native-rate varispeed, tape-deck style | pitch = speed (coupled) |
| 2 | `tempo_varispeed` | Region force-fit to the step length/BPM, always lands on the loop boundary | pitch is a varispeed offset on top of the fit |
| 3 | `domino` | Rhythmic chunk player (chop steps, forward-stop / loop / ping-pong per chunk) | reader pitch per chunk |
| 4 | `granular` | Overlapping grains; size/density/jitter shape the texture | independent grain pitch |
| 5 | `random_ola` | Shuffled overlap-add stretch, wander around the playhead | independent grain pitch |
| 6 | `pitch_corrected` | Tempo-fit reader + pitch-shifter correction (robotic/formant character) | corrected independently |
| 7 | `harmonizer` | Up to 3 pitch intervals stacked on the reader (0 = off) | per-interval |
| 8 | `wavetable` | Playhead-independent oscillator scanning the sample as a wavetable (slice count, interpolated morph, scan LFO) | oscillator pitch |
| 9 | `spectral_freeze` | FFT freeze/smear of the playing region | spectral pitch |
| 10 | `formant` | FFT formant processing (stereo) with pitch | formant-preserving |
| 11 | `gstretch` | Paulstretch-style extreme stretch, flavor 1 | independent |
| 12 | `gstretch2` | Paulstretch-style extreme stretch, flavor 2 | independent |
| 13 | `chopped` | Digitakt-style chop sync (ramp restarts on step start) | reader pitch |

Notes:

- **Naming history**: `domino` is the mode formerly named `chopped`; today's
  `chopped` (#13) is the newer Digitakt-style chop-sync engine. `tape_xf`,
  `tape_ugen` and the RubberBand experiment were removed 2026-07-31.
- **FFT budget**: `spectral_freeze` and `formant` run their FFT chain on
  **track 1 only** — on any other track the engine silently falls back to
  `tape` (one FFT chain is affordable on the Pi3, eight are not).
- Every mode carries the p-lockable synced **RATE** multiplier in param
  slot 8 of the WARP page.

## Filter machines (FILTER settings; FILTER MIX banner)

One post-mix filter per track (after voice summing; the track's amp/pan also
live on this synth). All machines run in stereo with a stereo-or-mid-side
balance (MSBL) spreading the channel cutoffs; CUT is always cell 1, RES
cell 2, envelope DEPTH cell 4, so the core controls never move.

| # | Name | Identity |
|---:|---|---|
| 1 | `CLASSIC` | LP/HP/BP/notch, switchable type |
| 2 | `MORPHING` | Continuous LP → notch → HP morph |
| 3 | `LADDER` | Moog-style ladder, self-oscillating |
| 4 | `COMB` | Tuned feedback comb |
| 5 | `FORMANT` | A–E–I–O–U vowel bank |

## FX machines (Insert 1 / Send 1 / Send 2 / Master)

All four slots pick from the same 18-machine list; each slot's params are
namespaced (`send1_`/`send2_`/`master_` prefixes) and p-lockable. Slot
behavior for **NONE** differs by role: an *insert/master* None is a clean
passthrough, but a *send return* None spawns **no synth at all** (the bus is
simply unread — a passthrough would double the sent signal).

**MIX rule**: machines with a wet/dry sense carry **MIX** as the page's
trailing (bottom-right) param. The machines marked *always wet* below have no
MIX **by design** — they reshape the whole signal (dynamics, EQ, stereo
field), so a parallel-dry blend would be misleading. The blank trailing cell
on those pages is intentional.

**Units**: params are Elektron-style 0–127 except the dynamics machines
(COMP / DUCK / LIMIT), which display real dB/ms because thresholds and times
are meaningless without units. FN-snap targets are clean real-world values.

| # | Name | Params | Identity |
|---:|---|---|---|
| 1 | `NONE` | — | Passthrough (insert/master) or silent (send). |
| 2 | `DELAY` | TIME, FBK, TONE, MIX | **Clean digital** tempo-synced delay. TIME covers the full 15-division list (1/32 … 2 BAR incl. dotted + triplet); time changes glide (no clicks). |
| 3 | `REVERB` | SIZE, DAMP, MIX | Algorithmic (FreeVerb family). |
| 4 | `LOFI` | BITS, RATE, MIX | Bit-depth + sample-rate reduction. |
| 5 | `COMP` | THRS, RATO, ATK, REL, MKUP, MIX | Compressor with IN/GR metering on-page. dB/ms units. |
| 6 | `DESTROY` | CRSH, SRR, WARB, DRIV, FOLD, SAT, TONE, LEVL | Kitchen-sink destruction: bitcrush + sample-rate reduction lead. *Always wet.* |
| 7 | `ECHO` | TIME, OFST, FBK, MODE, TONE, WOBL, MIX | **Colored stereo echo**: L/R offset ratio, tone-in-loop, wobble. Same 15-division TIME as DELAY. |
| 8 | `BLACKHOLE` | SIZE, GRAV, MOD, LOW, HI, PRE, MIX | Huge modulated reverb. |
| 9 | `CHORUS` | RATE, DPTH, WDTH, TONE, MIX | Modulated short-delay chorus. |
| 10 | `FLANGER` | RATE, DPTH, FBK, TONE, MIX | Swept comb flanger. |
| 11 | `PHASER` | RATE, DPTH, CNTR, STGS, FBK, MIX | 1–8 stage allpass phaser (steps of 1). |
| 12 | `DJ EQ` | LOW, MID, HIGH, XLOW, XHI | 3-band kill EQ + crossover trims. *Always wet.* |
| 13 | `DUCK` | AMNT, SENS, ATK, REL | Sidechain-style ducking keyed from the master bus, with metering. dB/ms units. *Always wet.* |
| 14 | `TAPE ECHO` | TIME, FBK, WOW, FLUT, SAT, TONE, MIX | **Dirty tape delay**: wow/flutter + saturation in the loop. Same 15-division TIME. |
| 15 | `CASSETTE` | WOW, FLUT, NOIS, CRKL, DROP, TONE, MIX | Cassette degradation: noise, crackle, dropouts. |
| 16 | `MOTION` | WDTH, RATE, TREM, PAN, SHPE | Stereo motion: width (up to +6 dB side at max), autopan, tremolo; RATE spans the full division list up to 4 BAR. *Always wet.* |
| 17 | `RINGS` | MODE, FREQ, FINE, FBK, TONE, MIX | Ring-mod / frequency-shift family. |
| 18 | `LIMIT` | GAIN, CEIL, REL | Brickwall-style limiter, ceiling −12..0 dB, IN/GR metered. *Always wet.* |

**DRIVE was removed 2026-08-01** (the filter stage already carries drive):
machine indices above it shifted down one, so older projects that used a
machine above DRIVE load one machine off and need a one-time re-pick.

**The three delays** at a glance: `DELAY` = clean and surgical; `ECHO` =
character echo with stereo offset and tone shaping; `TAPE ECHO` = the same
family soaked in wow/flutter/saturation. All three share the tempo-synced
15-division TIME list.
