local ParamItem = include("lib/ui/param_item")
local item = ParamItem.item
local blank = ParamItem.blank

local page_model = {
  master = {
    title = "MASTER",
    pages = {
      {
        title = "MASTER",
        items = {
          item("target_bpm", "BPM", {lockable = false, min = 20, max = 300, step = 1, snaps = {60, 80, 90, 100, 110, 120, 128, 136, 140, 160, 180}}),
          item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 100, 127}}),
          -- A/B scene crossfader position (PRD §6.6 requirements 2-3): global,
          -- not p-lockable -- it must not change per pattern/step, only via the
          -- grid row-5 fader/anchors or this encoder.
          item("crossfade", "XFD", {lockable = false, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
        }
      },
      {
        -- MIX: the 8-track overview (lib/ui/mixer_page.lua). The coordinator
        -- detects `mixer` and renders the column grid under the normal header.
        --
        -- Its items are ordinary per-track params, so K2/K3 + E2/E3 edit the
        -- SELECTED track's mix from this page with no new input handling --
        -- they resolve through elasticat.lua's ui_id funnel like every other
        -- page. MUTE is per-track today (ParamsSpec.SPEC); VOL/PAN become
        -- per-track the moment those suffixes land in SPEC, at which point this
        -- page follows the selection automatically.
        title = "MIX",
        mixer = true,
        items = {
          item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 100, 127}}),
          item("pan", "PAN", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
          item("mute", "MUTE", {lockable = false, binary = true, min = 0, max = 1, step = 1})
        }
      },
      {
        -- Full-screen looping sprite + grid comet sweep, tempo-scaled. The
        -- coordinator detects `animation` and renders it with no header/UI.
        title = "VISUALIZER",
        items = {},
        animation = true
      }
    },
    -- Multi-page settings (in-script Project management, PRD §7.3): master is
    -- the only category with more than one settings page today, so `settings`
    -- here is a list of {title=?, items=...} pages instead of a flat item
    -- list. lib/pages/navigation.lua detects this shape (an item list never
    -- has an `.items` key) and treats a plain flat list -- what every other
    -- category's `settings` still is -- as an implicit single page, so this
    -- is purely additive: no other category needs to change.
    settings = {
      {
        -- Page 1: unchanged from before -- same 6 items, same ids/order.
        items = {
          item("clock_sync", "SYNC", {binary = true, min = 0, max = 1, step = 1}),
          item("global_bpm", "GBPM", {binary = true, min = 0, max = 1, step = 1}),
          item("live_performance_mode", "LPRF", {binary = true, min = 0, max = 1, step = 1}),
          item("step_preview", "PREV", {binary = true, min = 0, max = 1, step = 1}),
          item("live_step_trig", "LTRG", {binary = true, min = 0, max = 1, step = 1}),
          -- How many track chains the engine runs (1-8). The row-4 track keys
          -- report "Track N off" above this count, so it needs to be reachable
          -- without digging into the norns PARAMS menu.
          item("active_track_count", "ACTIVE TRACKS", {min = 1, max = 8, step = 1}),
          item("debug", "DBG", {options = 4})
        }
      },
      {
        -- Page 2: Project management (PRD §7). Scrolling past the last item
        -- of page 1 above lands here (see Navigation:settings_select_delta),
        -- and scrolling up past the first item here goes back to page 1.
        --
        -- The four action rows below are marked with `project_row` instead of
        -- a real param `id` -- they're not norns params, they're buttons that
        -- invoke elasticat.lua's existing do_project_load/save/save_as/new()
        -- (K3 confirms; see key(n,z)'s settings-layer branch and
        -- draw_settings_page()/invoke_project_settings_action() in
        -- elasticat.lua, which special-case `project_row` so these never flow
        -- through the generic ParamValues path that assumes every item has a
        -- real param id). AUTO-NAME is the one real param on this page
        -- (elasticat_project_auto_name, an existing option param) and is
        -- rendered/edited the normal way.
        title = "PROJECT",
        items = {
          {project_row = "status", short = "PROJECT"},
          {project_row = "load", short = "LOAD"},
          {project_row = "save", short = "SAVE"},
          {project_row = "save_as", short = "SAVE AS"},
          {project_row = "new", short = "NEW PROJECT"},
          item("project_auto_name", "AUTO-NAME", {options = 3})
        }
      }
    }
  },
  pattern = {
    title = "PATTERN",
    pages = {
      {
        title = "PATTERN",
        items = {
          item("pattern_steps", "LEN", {lockable = false, min = 1, max = 256, step = 1, snaps = {4, 8, 16, 32, 48, 64, 96, 128, 256}}),
          -- 21 fraction rates (see TrackSequencer.RATE_FRACTIONS); 1x is 13.
          -- NOT an `options` item: it is a pseudo with its own label function,
          -- and `options` suppresses the value bar (item_frac returns nil) as
          -- well as steering some paths at option_value(), which throws on an
          -- unregistered id. With min/max it gets a real bar showing position
          -- in a 21-long list. FN snaps to the musical anchors 1/2, 1, 2.
          item("pattern_rate", "RATE", {pseudo = "pattern_rate", lockable = false, min = 1, max = 21, step = 1, snaps = {7, 13, 21}}),
          item("global_pattern_length", "GLEN", {lockable = false, min = 1, max = 256, step = 1, snaps = {4, 8, 16, 32, 48, 64, 96, 128, 256}})
        }
      }
    },
    settings = {
      item("pattern_rate", "RATE", {pseudo = "pattern_rate", min = 1, max = 21, step = 1, snaps = {7, 13, 21}}),
      item("pattern_quantize", "PATTERN CHANGE", {options = 4}),
      item("global_pattern_length", "GLOBAL LENGTH", {min = 1, max = 256, step = 1, snaps = {4, 8, 16, 32, 64, 128, 256}})
    }
  },
  trig = {
    title = "TRIG",
    pages = {
      {
        -- Page 1: trig params common to every machine.
        title = "TRIG",
        items = {
          item("pitch", "NOTE", {lockable = true, min = -24, max = 24, step = 0.1, snaps = {-24, -12, -7, 0, 7, 12, 24}}),
          item("default_length", "LEN", {lock_id = "length", lockable = true, min = 0.25, max = 16, step = 0.25, snaps = {0.25, 0.5, 1, 2, 4, 8, 16}}),
          item("default_velocity", "VEL", {lock_id = "velocity", lockable = true, min = 0, max = 1, step = 0.01, snaps = {0, 0.25, 0.5, 0.75, 1}}),
          blank(),
          item("env_reset", "ERST", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("lfo_reset", "LRST", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("filter_reset", "FRST", {lockable = true, binary = true, min = 0, max = 1, step = 1})
        }
      },
      {
        -- Page 2: conditional trigs (common to all machines). A trig fires only
        -- if its chance roll AND its condition both pass.
        title = "TRIG COND",
        items = {
          item("trig_chance", "CHNC", {lockable = true, min = 0, max = 100, step = 1, snaps = {0, 25, 50, 75, 100}}),
          item("trig_condition", "COND", {lockable = true, options = 17}),
          item("trig_ratchet", "RTCH", {lockable = true, min = 1, max = 8, step = 1, snaps = {1, 2, 3, 4, 6, 8}})
        }
      },
      {
        -- Page 3: machine trig behaviour. Items are resolved dynamically in
        -- page_items_for (empty for slice machines); this is the fallback.
        title = "MACHINE TRIG",
        items = {
          item("trig_jump", "JUMP", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("trig_release", "RLSE", {lockable = true, options = 3})
        }
      }
    },
    settings = {
      item("swing", "SWING", {min = 50, max = 75, step = 1})
    }
  },
  source = {
    title = "SOURCE",
    pages = {
      {
        title = "SOURCE",
        items = {
          item("sample_slot", "SLOT", {lockable = true, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
          item("loop_start", "STRT", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
          item("loop_end", "END", {lockable = true, min = 0, max = 128, step = 1, fine_step = 0.01, snaps = {0, 8, 16, 32, 64, 96, 120, 128}}),
          item("loop_reverse", "LREV", {lockable = true, binary = true, min = 0, max = 1, step = 1}),
          item("slice_reverse", "SREV", {lockable = true, binary = true, min = 0, max = 1, step = 1})
        }
      },
      {
        title = "MACHINE",
        items = {}
      },
      {
        title = "WARP",
        items = {
          item("mode_macro", "MACR", {lockable = true, min = 0, max = 1, step = 0.001, snaps = {0, 0.25, 0.5, 0.75, 1}}),
          item("chop_steps", "CHOP", {lockable = true, min = 0.25, max = 16, step = 0.25, snaps = {0.25, 0.5, 1, 2, 4, 8, 16}}),
          item("chop_loop_mode", "LOOP", {lockable = true, options = 3}),
          item("grain_size", "GSIZ", {lockable = true, min = 0.002, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
          item("grain_density", "GDEN", {lockable = true, min = 1, max = 64, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64}}),
          item("grain_jitter", "GJIT", {lockable = true, min = 0, max = 0.25, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25}}),
          item("wsola_window", "OWIN", {lockable = true, min = 0.005, max = 0.5, step = 0.001, snaps = {0.005, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32}}),
          item("wsola_search", "OWAN", {lockable = true, min = 0, max = 0.1, step = 0.001, snaps = {0, 0.005, 0.01, 0.02, 0.05, 0.1}})
        }
      },
      {
        title = "RANGE",
        items = {
          item("range_start", "R-ST", {lockable = true, fn_snap_multiple = 8, min = 0, max = 128, step = 1}),
          item("range_end", "R-EN", {lockable = true, fn_snap_multiple = 8, min = 0, max = 128, step = 1}),
          item("range_end_sync", "E-SNC", {lockable = false, binary = true, min = 0, max = 1, step = 1})
        }
      }
    },
    settings = {
      -- All 6 machines: Loop, Trig, Slice, Razor, Slice Poly, Razor Poly. The cap
      -- is the encoder's clamp (param_values option_delta), so 4 hid the two poly
      -- machines even though the param + display formatter already know all six.
      item("machine", "MACH", {options = 6}),
      item("loop_division", "LDIV", {lockable = false, min = 2, max = 32, step = 2, snaps = {2, 4, 8, 16, 32}}),
      item("trig_polyphony", "POLY", {options = 2}),
      item("playhead_return", "PHED", {options = 3})
    }
  },
  file = {
    title = "FILE",
    pages = {
      {
        title = "SAMPLE",
        items = {
          -- fn_to_edit: the sample's detected BPM / step count only change with FN
          -- held, so a stray knob turn can't silently rewrite the warp reference
          -- and force a recalculation (owner). FN also does the trim-zoom here,
          -- but that only triggers on the trim items, so there is no conflict.
          item("sample_bpm", "BPM", {lockable = false, fn_to_edit = true, always_value = true, min = 20, max = 300, step = 1, snaps = {60, 80, 90, 100, 110, 120, 128, 136, 140, 160, 180}}),
          item("sample_steps", "STEP", {lockable = false, fn_to_edit = true, always_value = true, min = 1, max = 512, step = 1, snaps = {4, 8, 16, 32, 48, 64, 96, 128, 256, 512}}),
          item("sample", "FILE", {file = true, lockable = false}),
          item("file_slot", "SLOT", {lockable = false, min = 1, max = 128, step = 1, snaps = {1, 2, 4, 8, 16, 32, 64, 128}}),
          item("trim_start", "T-ST", {lockable = false, trim_scan = true, min = 0, max = 3600, step = 0.01, fine_step = 0.001}),
          item("trim_end", "T-EN", {lockable = false, trim_scan = true, min = 0, max = 3600, step = 0.01, fine_step = 0.001}),
          item("gain", "GAIN", {lockable = false, min = 0, max = 4, step = 0.01, snaps = {0, 0.5, 1, 1.5, 2, 3, 4}}),
          item("sample_preview", "PREV", {lockable = false, binary = true, min = 0, max = 1, step = 1})
        }
      }
    },
    settings = {
      item("bpm_step_mode", "BPM/STEP MODE", {options = 4}),
      item("recalc_bpm_steps", "RECALC BPM/STEP", {options = 2})
    }
  },
  filter = {
    title = "FILTER",
    pages = {
      {
        -- Page 1 (machine macro row) is resolved per filter machine in
        -- page_items_for; this static list is the CLASSIC-default fallback.
        title = "FILTER",
        items = {
          item("filter_type", "TYPE", {lockable = true, options = 4}),
          item("filter_cutoff", "CUT", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("filter_res", "RES", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("filter_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      },
      {
        -- Page 2 (filter envelope) is resolved per env mode in page_items_for;
        -- this static list is the AHR-default fallback. DEPTH modulates cutoff.
        title = "F.ENV",
        items = {
          item("filter_env_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1}),
          item("filter_env_hold", "HOLD", {lockable = true, min = 0, max = 128, step = 1}),
          item("filter_env_release", "REL", {lockable = true, min = 0, max = 128, step = 1}),
          blank(),
          item("filter_env_depth", "DPTH", {lockable = true, min = 0, max = 128, step = 1}),
          blank(),
          blank(),
          blank()
        }
      }
    },
    settings = {
      -- 6 filter machines: Classic, Morphing, Classic/Morphing Stereo,
      -- Classic/Morphing Mid/Side (PRD SS4.2, machines #1-6).
      item("filter_machine", "MACH", {options = 6}),
      item("filter_env_mode", "FENV", {options = 2})
    }
  },
  amp = {
    title = "AMP",
    pages = {
      {
        -- Items are resolved dynamically per envelope mode in page_items_for
        -- (ADSR vs AHR); this static list is the AHR-default fallback.
        title = "AMP",
        items = {
          item("env_attack", "ATK", {lockable = true, min = 0, max = 127, step = 1}),
          item("env_hold", "HOLD", {lockable = true, min = 0, max = 128, step = 1}),
          item("env_release", "REL", {lockable = true, min = 0, max = 128, step = 1}),
          blank(),
          blank(),
          blank(),
          item("pan", "PAN", {lockable = true, min = 0, max = 128, step = 1}),
          item("amp", "VOL", {lockable = true, min = 0, max = 127, step = 1})
        }
      }
    },
    settings = {
      item("env_mode", "ENVELOPE MODE", {options = 2}),
      item("env_range", "ENVELOPE RANGE", {options = 10}),
      item("portamento", "PORTAMENTO", {binary = true, min = 0, max = 1, step = 1}),
      item("slice_hold_to_step", "SLICE HOLD", {binary = true, min = 0, max = 1, step = 1})
      -- SLICE POLY removed: voicing is the MACHINE selector now (Slice/Razor mono,
      -- Slice Poly/Razor Poly poly). The slice_polyphony param stays registered
      -- for old-project compatibility but no longer drives anything.
    }
  },
  fx = {
    title = "FX",
    pages = {
      {
        -- Page 1 (Insert 1 machine macro row) is resolved per fx machine in
        -- page_items_for; this static list is the DRIVE-default fallback (NONE
        -- returns no items, so DRIVE's row is the more useful static preview).
        title = "FX",
        items = {
          item("fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      },
      {
        -- Page 2: SENDS (PRD SS3/SS8). Send 1/2 levels are the continuous,
        -- p-lockable send amounts; each send's own FX knobs get their own page
        -- below (SEND1 FX / SEND2 FX), keeping this page a tight mix row.
        title = "SENDS",
        items = {
          item("send1_level", "SND1", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("send2_level", "SND2", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          blank(),
          blank(),
          blank(),
          blank(),
          blank(),
          blank()
        }
      },
      {
        -- Pages 3-5: Send 1 / Send 2 / Master insert machine rows, resolved per
        -- each slot's machine setting in page_items_for (elasticat.lua's
        -- fx_slot_items) with ids namespaced send1_/send2_/master_. These
        -- static lists are the DRIVE-default fallbacks, same as page 1; a slot
        -- on NONE resolves to no items and draws as the blank "empty" page.
        title = "SEND1 FX",
        items = {
          item("send1_fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("send1_fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      },
      {
        title = "SEND2 FX",
        items = {
          item("send2_fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("send2_fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      },
      {
        title = "MASTER FX",
        items = {
          item("master_fx_drive", "DRIV", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("master_fx_mix", "MIX", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      }
    },
    settings = {
      -- 5 fx machines: None (passthrough/bypass), Drive, Delay, Reverb, Lofi
      -- (PRD SS4.3 Tier 1, plus the always-present None) -- shared by Insert 1,
      -- Send 1/2, and the Master insert. Send tap picks which point in the
      -- chain Send 1/2 pull from (PRD SS3).
      item("fx_insert1_machine", "MACH", {options = 5}),
      item("send_tap", "TAP", {options = 2}),
      item("send1_machine", "SEND1", {options = 5}),
      item("send2_machine", "SEND2", {options = 5}),
      item("master_fx_machine", "MASTER", {options = 5})
    }
  },
  mod = {
    title = "MOD",
    -- 2 LFOs + 1 mod envelope (engine-side; see Engine_Elasticat.sc's
    -- \elasticatMod). DEP is the standard bipolar 0-128 (64 = off/center),
    -- SPD a tempo-synced musical division, DEST routes to the engine's
    -- per-destination mod buses. DEST/WAVE/MODE are not lockable in this
    -- first stab; DEP/SPD/ATK/DEC are.
    pages = {
      {
        title = "LFO 1",
        items = {
          item("lfo1_dest", "DEST", {lockable = false, options = 10}),
          item("lfo1_wave", "WAVE", {lockable = false, options = 6}),
          item("lfo1_speed", "SPD", {lockable = true, options = 10}),
          item("lfo1_depth", "DEP", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
          item("lfo1_mode", "MODE", {lockable = false, options = 4}),
          blank(),
          blank(),
          blank()
        }
      },
      {
        title = "LFO 2",
        items = {
          item("lfo2_dest", "DEST", {lockable = false, options = 10}),
          item("lfo2_wave", "WAVE", {lockable = false, options = 6}),
          item("lfo2_speed", "SPD", {lockable = true, options = 10}),
          item("lfo2_depth", "DEP", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}}),
          item("lfo2_mode", "MODE", {lockable = false, options = 4}),
          blank(),
          blank(),
          blank()
        }
      },
      {
        -- Resolved in page_items_for (elasticat.mod_env_lowprofile_items): a
        -- full ADSR on top, DEST/DEPTH in the bottom row. This static list is
        -- the fallback and keeps the ids discoverable.
        title = "MOD ENV",
        items = {
          item("menv_attack", "ATCK", {lockable = true, min = 0, max = 127, step = 1}),
          item("menv_decay", "DECAY", {lockable = true, min = 0, max = 127, step = 1}),
          item("menv_sustain", "SUST", {lockable = true, min = 0, max = 127, step = 1}),
          item("menv_release", "REL", {lockable = true, min = 0, max = 127, step = 1}),
          item("menv_dest", "DEST", {lockable = false, options = 10}),
          item("menv_depth", "DEPTH", {lockable = true, min = 0, max = 128, step = 1, snaps = {0, 32, 64, 96, 128}})
        }
      },
      -- MACRO page: the 4 macro VALUE knobs (0-127, p-lockable). Each macro's
      -- mod matrix (its signed depth to each destination) is assigned by the
      -- gesture -- hold the macro's grid key (row 4, cols 1-4) and turn a
      -- destination param -- not edited here, so this page is just the drivers.
      {
        title = "MACROS",
        items = {
          item("macro1_value", "M1", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("macro2_value", "M2", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("macro3_value", "M3", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}}),
          item("macro4_value", "M4", {lockable = true, min = 0, max = 127, step = 1, snaps = {0, 32, 64, 96, 127}})
        }
      }
    },
    settings = {}
  }
}

return page_model
