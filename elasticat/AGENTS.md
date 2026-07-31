# Elasticat Development Rules

Read `docs/ARCHITECTURE.md` before making structural changes.
Read `docs/MULTITRACK_ARCHITECTURE.md` before working on multitrack features (filters, sends, mod matrix, scenes, neighbor routing, projects) — it has the target design and the phase this is currently at.

- Keep `elasticat.lua` as a coordinator. Do not add new machine or warp-mode conditionals there.
- Add machine-specific behavior in `lib/machines/`.
- Add warp-mode-specific behavior in `lib/warp_modes/`.
- Use `lib/ui/header.lua` for every page header.
- Use `lib/ui/param_item.lua`, `lib/ui/param_bank.lua`, and `lib/ui/param_renderer.lua` for parameter UI work.
- Use `lib/ui/param_values.lua` for parameter value/formatting logic (raw value, display formatting, snap/adjust, apply, step-lock). Add new numeric-display formatters to its `ID_FORMATTERS` table rather than inline in `elasticat.lua`.
- Use `lib/ui/source_page.lua` for Source-category rendering (pitch ruler, sample-slot tab, waveform box, cell renderers).
- Use `lib/pages/model.lua` for category/page/item definitions, and `lib/pages/navigation.lua` for category/page/settings selection state.
- Use `lib/script_state.lua` for `dust/data` persistence (browser folder, sample pool state) and `lib/wav_reader.lua` for WAV parsing.
- Use `lib/sequencer/step.lua` for step-record creation and content checks.
- Keep engine/sample-pool communication in `lib/elasticat.lua`.
- Run `bin/test-elasticat-lua`, `bin/test-elasticat-sclang`, and `git diff --check` before committing.
