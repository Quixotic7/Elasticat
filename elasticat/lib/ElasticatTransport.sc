// ElasticatTransport responsibility boundary.
//
// The shared transport SynthDef is implemented in Engine_Elasticat.sc as
// \elasticatTransport for deploy safety.
//
// Implemented transport behavior:
// - audio-rate normalized phase bus
// - play/pause without losing phase
// - explicit reset/reposition
// - target BPM and declared loop-beat duration
// - bounded soft correction from Lua clock observations
// - phase/correction diagnostics
