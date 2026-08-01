// ElasticatKernel responsibility boundary.
//
// The v2 runtime kernel currently lives in Engine_Elasticat.sc so the norns
// crone dynamic engine loader only needs to discover one Engine_* class file.
//
// Kernel responsibilities implemented there:
// - active-mode-only synth lifecycle
// - crossfaded mode switching
// - safe buffer generation activation
// - old synth/buffer deferred free
// - mode/load/sync instrumentation
//
// This file marks the intended extraction boundary for a later static
// SuperCollider test harness once companion class loading is verified on norns.
