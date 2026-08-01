# Elasticat v2 Mode Catalog

| ID | Name | Former name | Purpose | Pitch behavior |
|---:|---|---|---|---|
| 0 | `tape` | `basic` | Direct varispeed loop playback | pitch and speed coupled |
| 1 | `tempo_varispeed` | `classic` | Clock-fit tape-style tempo matching | pitch follows tempo, user offset allowed |
| 2 | `chopped` | `chopped` | Rhythmic retrigger, gate, and stutter | per-mode reader pitch |
| 3 | `granular` | `granular` | Granular stretch and texture | independent grain pitch |
| 4 | `random_ola` | `wsola` | Bounded random overlap-grain texture | independent grain pitch |
| 5 | `pitch_corrected` | `pv` | Tempo-fit reader plus `PitchShift` pitch restoration | lightweight pitch correction |

The current milestone preserves current sound families while changing lifecycle and timing architecture. `random_ola` is not true WSOLA. `pitch_corrected` is not a phase vocoder.
