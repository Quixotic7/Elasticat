# Benchmark Results

Not yet measured on target hardware.

Required target measurements:

- baseline CPU by mode
- active-mode-only CPU confirmation
- crossfade peak CPU
- memory behavior across sample loads
- 200-switch node lifecycle result
- 30-minute clock drift result

The engine now reports the counters needed for these measurements, but actual norns hardware results still need to be captured.

## Phase 2 — per-track chain cost (2026-07-26)

Measured by `bin/test-elasticat-engine-runtime`, which boots real scsynth,
raises `activeTrackCount`, and reads the server's own node/UGen counters.

| state | synths | groups | UGens | avgCPU (Mac) |
|---|---|---|---|---|
| 1 track | 26 | 15 | 599 | 1.5% |
| 8 tracks | 68 | 29 | 4043 | 12.4% |
| back to 1 | 26 | 15 | 599 | 1.6% |
| 8 again | 68 | 29 | 4043 | 8.1% |

**Per added track: ~6 synths, ~492 UGens.** The 6 are mod, transport, reader,
filter, send tap and mix — insert FX at "None" correctly spawns nothing.

Freeing returns *exactly* to 599 UGens and re-raising returns *exactly* to
4043, so chains neither leak nor come back degraded.

**The absolute CPU is this Mac's, not the norns'.** What transfers is the UGen
count and its shape.

### The optimisation this exposes

~492 UGens/track is dominated by the filter. `filterChannelClassic` computes
RLPF **and** RHPF **and** BPF and then `Select.ar`s between them — and
`Select.ar` evaluates every input, so three filters run to hear one. The
morphing machines are worse. Per stereo track that is ~6 filter instances where
2 would do.

Making the filter machines compute only the selected type would cut a large
fraction of per-track cost, and is plausibly the difference between 4 and 8
comfortable tracks on real hardware. Worth doing before deciding the final
shipped track count.

### Post-integration (all three worktrees merged)

| state | synths | groups | UGens |
|---|---|---|---|
| 1 track | 25 | 14 | 351 |
| 8 tracks | 60 | 28 | 1996 |

**~5 synths, ~235 UGens per added track — down from 492 (-52%).**

The saving is NOT where I predicted. I assumed the filter dominated; measurement
said `\elasticatMod` did (257 of 492 UGens/track, ~35% of engine DSP) versus the
filter's 95. So the mod synth now follows the same "None spawns no synth" pattern
the insert FX uses: with every depth at 0 its five outputs are identically zero,
so omitting it is *provably* free. With modulation active on all 8 tracks the
graph is byte-identical to before (4052 UGens, matching the pre-change baseline
exactly) — this is a saving on idle tracks, not a change to modulated ones.

### The Select.ar prize, and why it was left

Isolated: 8x `Select.ar` over 3 biquads + notch costs +1.82%; 8x a single RLPF
costs +0.55%. So ~1.3% absolute is available, and post-optimisation the filter is
now the largest per-track cost.

It was deliberately not taken. SC has no lazy `Select`, so removing it means one
SynthDef per filter type — which makes `filterType` (p-lockable, live) a synth
*respawn*, and the filter envelope's gate/trig state lives on that synth. That is
an audible mid-note change, not a pure cost reduction. `filterChannelMorph`
genuinely needs all three outputs since it crossfades between them, so the morph
machines are not waste at all.

The additive route — dedicated single-type Classic machines in
`filterSynthNames` — gets the same tone with no respawn on p-lock, because type
is then fixed per machine and machine changes already respawn by design. It grows
the machine index space the params and UI layers enumerate, so it is a contract
change and is deferred rather than slipped in.

## Real norns CPU (owner hardware, 2026-07-26)

Two measurements, all tracks playing audio:

| tracks | CPU |
|---|---|
| 4 | 42% |
| 8 | 72-74% |

Fits **base 11% + 7.75% per track** almost exactly. Interpolating: 1 track ~19%,
2 ~27%, 6 ~58%.

Scaling is slightly BETTER than the local UGen extrapolation predicted (that
said ~79% at 8). UGen count is a good relative predictor but mildly pessimistic
in absolute terms, so prefer these numbers.

**8 tracks is viable, with ~27% headroom.**

### What was actually running (corrected)

I first assumed this was measured with everything bypassed. It was not. The
owner patch at 72-74% was:

- **Send 1: delay**
- **Send 2: reverb**
- **Track 1: lofi insert**
- Tracks 2-8: insert None (no synth spawned -- see `trackPostInsertBus`)

So the figure already includes both global send FX and one per-track insert.
That is a realistic working patch, not a floor, which makes the ~27% headroom
considerably more meaningful than a bypassed measurement would have been.

What is still NOT in it: inserts on tracks 2-8. Seven more inserts is the open
question. A lofi or drive insert is cheap; seven reverbs would not be. Worth
measuring with the heaviest insert on every track before fixing the shipped
track count, since that is the genuine worst case.

### Where the headroom is, if it is needed

The filter is ~95 of the ~235 UGens per track (~40% of a track's cost, so
~3.1% CPU/track). `filterChannelClassic` computes RLPF **and** RHPF **and** BPF
and then `Select.ar`s between them -- and `Select.ar` evaluates every input, so
three filters run to hear one. Dedicated single-type Classic machines would put
8 tracks near **56%**.

Deliberately NOT done: removing `Select.ar` naively means one SynthDef per
filter type, which makes `filterType` (p-lockable, live) a synth respawn -- and
the filter envelope's gate state lives on that synth, so it would restart
mid-note. The additive route (new single-type machines alongside the existing
ones) is safe but grows the machine index space the params and UI layers
enumerate, so it is a contract change.

Note also that the pattern-switch burst (~1116 param sets in one tick) is a Lua
and OSC cost, NOT DSP -- it will not appear on this meter. It shows up as a
stutter at the moment a pattern changes.

### Decomposition (three hardware points)

| patch | CPU |
|---|---|
| 8 tracks, no inserts, no sends | 67% |
| 8 tracks + send delay + send reverb + track-1 lofi | 72-74% |
| 4 tracks + the same FX | 42% |

All three fit one model exactly:

```
CPU = 5%  fixed base (bare: transport, master chain)
    + 7.75% per track
    + 6%  for that FX chain (2 send FX + 1 insert)
```

Check: 8 bare = 5 + 8x7.75 = **67**. 4+FX = 11 + 4x7.75 = **42**.
8+FX = 11 + 8x7.75 = **73**. All measured.

### What this says about where to optimise

**The tracks are 93% of the cost** (62 of the 67% bare). FX are cheap: two send
effects plus an insert cost 6%, i.e. less than one track. So per-track FX are
not the thing to fear -- adding a cheap insert to all 8 would cost roughly one
track's worth.

Optimisation must therefore target the per-track chain, and within it the
filter: ~40% of a track, which is **~25 percentage points across 8 tracks**.
Single-type filter machines would put 8 bare tracks near **51%** and the
FX-loaded patch near **57%**.

Nothing else in the per-track chain is close to that. Do not spend effort on
the base or the FX busses.
