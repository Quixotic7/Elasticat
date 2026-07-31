# Elasticat Workstreams — parallel agents in worktrees

How the work in `docs/PRD.md` §6 (1-track MVP) divides across agents, each in
its own git worktree, and the rules that keep them from stepping on each other.
The first bugfixes+filter merge (2bd8108) conflicted in exactly one place —
`elasticat.lua`'s `page_items_for` — and that lesson shapes these rules.

## Workstreams (MVP)

### A. Core / Sequencer / Playback — worktree `bugfixes`
The playback-correctness owner. Continues hardware-feedback iteration.

- **Trig conditions + ratchets + swing + Fill key (X16,Y6)** — PRD §6.5
- **Pattern system** (PRD §6.1-6.4): in-memory pattern store (16 slots,
  per-pattern scope incl. per-pattern BPM w/ global override), pattern-load
  grid mode (X8,Y5 key + bottom-row slots + momentary hold), quantized
  switching (sequential / direct jump / direct start / temp jump), per-track
  vs global lengths
- **A/B crossfader morph, 1-track** (PRD §6.6) — scene snapshots + param
  interpolation; resolve the row-5 layout question first
- Engine `noteOff` for live-held notes; `tempo_varispeed` pitch (or hide it)
- Region/anchor/release machinery, grid interactions, bug intake from testing
- Owns: `lib/grid_sequencer.lua`, `lib/sequencer/*`, `lib/machines/*`,
  playhead/transport parts of `Engine_Elasticat.sc`, the sim harness

### B. Filter + FX — worktree `filter-fx`
The DSP-catalog owner.

- Filter machines 3-6 (Classic/Morphing Stereo + Mid/Side), then Comb/Ladder/
  Formant per PRD §4.2 priority
- FX infrastructure: insert slot + 2 sends + master bus, send-tap setting,
  Tier-1 FX (drive, delay, reverb, lofi) per PRD §4.3
- Owns: `lib/filter_modes/*`, future `lib/fx_modes/*`, filter/FX sections of
  `Engine_Elasticat.sc`, FILTER/FX pages

### C. Projects + Release — worktree `projects` (new)
The "ship it" owner. PRD §7 is its spec.

- **Projects system** (MVP blocker): full serialization (all 16 patterns,
  locks, settings, pool refs) via `lib/script_state.lua`'s `tab.save`
  pattern; load/save/save-as; temp work project + autosave-while-stopped +
  reload-loads-temp; memorize/recall RAM snapshot (FN+octave keys)
- **Text-entry dialog** (`lib/ui/text_entry.lua`): modal popup + grid QWERTY
  (Deluge-style); norns E2/E3 + K1/K2/K3 mapping per PRD §7.3. Ships early —
  A's pattern-rename depends on it
- Auto-name modes (None / Date / Namesizer runtime detection)
- Release hygiene: README for strangers, sane defaults, `.DS_Store` purge +
  `.gitignore`, stray-worktree cleanup
- CPU measurement harness: fill in `docs/BENCHMARK_RESULTS.md` per PRD §10

**Cross-stream dependencies**: A owns the in-memory pattern store; C owns its
serialization — agree the pattern-table shape early (write it into this doc
when settled). C's text dialog blocks A's pattern rename (rename can land
behind a stub until then).

Multitrack Phases 1+ (per-track params, track-aware sequencer, engine
multi-instantiation) start **only after MVP ships**, and Phase 1's three
pieces map naturally onto A (sequencer), B (engine chains), C (params/persistence).

## File ownership & contention rules

Hotspot files every workstream touches. Rules, learned from merge 2bd8108:

| File | Owner | Others may... |
|---|---|---|
| `lib/grid_sequencer.lua` | A | not touch without coordination |
| `lib/Engine_Elasticat.sc` | split: A = transport/readers/voices, B = filterGroup onward | add self-contained sections only; never reorder existing blocks |
| `elasticat.lua` | shared | add **one dispatch branch + one `*_items()` helper** per feature, nothing else; keep additions in separate hunks (top of `page_items_for` chain) |
| `lib/pages/model.lua` | shared | add items/pages only within your own category block |
| `lib/elasticat.lua` | shared | append-only: new ids in your namespace (`filter_*`, `fx_*`, `seq_*`), new params in your own contiguous block |
| `lib/ui/param_values.lua` | shared | one-line adds: `ID_FORMATTERS` entries, exclusion-list ids, `format_item_value` branches |
| `lib/filter_modes/*`, `lib/fx_modes/*` | B | — |
| `lib/script_state.lua` | C | — |
| `docs/*` | anyone | PRD changes need the user's sign-off |

Principles:
- **Registry pattern always**: new machines/modes/FX are new module files +
  a registry line, never new conditionals in shared files. This is what makes
  parallel work mergeable.
- **Namespace param ids** by domain so `ids` table and param blocks never
  collide.
- **Shared-file edits are append-shaped**: new helper above `page_items_for`,
  new branch at the top of the chain, new param block at the end of your
  section — so concurrent edits land in different hunks.

## Integration protocol

1. **Merge to `main` after every hardware-verified milestone** — small, tested
   increments; don't sit on a branch for a week. The 2bd8108 flow is the
   template: merge one worktree into the other, resolve, verify, then
   fast-forward `main` and the remaining worktrees.
2. **Fast-forward your worktree from `main` before starting new work** and
   after any other stream merges.
3. **Tests before every merge**: `bin/test-elasticat-lua`,
   `bin/test-elasticat-sclang`, `git diff --check`, plus workstream sims
   (A: the grid-level simulation suite).
4. **Deploy coordination**: `deploy-elasticat.sh` rsyncs to the single
   physical norns — one deployer at a time, announced. Hardware test time is
   the scarcest resource; batch verification requests for the user.
5. **Commit messages** describe behavior change + verification performed, so
   other streams can assess merge risk from `git log` alone.

## Working agreements

- PRD §5 parameter conventions are law; don't relitigate ranges.
- Every p-lockable candidate defaults to lockable (PRD §1); settings are the
  exception and need a reason.
- Protect the signature feature: nothing may make live scrubbing feel worse.
- CPU: check the norns CPU meter after adding any synth; stay inside the PRD
  §8 per-stage budgets; a feature that busts budget ships behind a bypass.
- Anything ambiguous in the PRD: ask the user, then **update the PRD** so the
  next agent doesn't re-ask.
