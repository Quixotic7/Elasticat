// ElasticatModes responsibility boundary.
//
// Mode SynthDefs are registered from Engine_Elasticat.sc so the engine remains
// self-contained for norns. The current first-class mode IDs are:
//
// 0 tape
// 1 tempo_varispeed
// 2 chopped
// 3 granular
// 4 random_ola
// 5 pitch_corrected
//
// Each mode reads the same shared phase bus and only the active mode synth runs
// during normal playback. A second mode synth may exist only during a bounded
// crossfade.
