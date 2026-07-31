// Language-side wrapper for the ElasticatWavetable UGen. A wavetable-scanning
// oscillator over the region [startFrac,endFrac] (0..1): the region is a bank of
// numSlices single-cycle frames (cycleLen buffer-samples each); morph scans the
// bank (0..1), freq sets the pitch (Hz). An internal per-sample LFO (lfoRate Hz,
// lfoShape 0 sin/1 tri/2 saw/3 s&h/4 rand, unipolar * lfoDepth added to morph)
// reaches audio rates. Loop start/end changes are declicked by a queued equal-
// power crossfade over xfadeSamp samples (softcut model). Returns [L, R].
ElasticatWavetable : MultiOutUGen {
	*ar { |bufL, bufR, startFrac = 0, endFrac = 1, numSlices = 8, cycleLen = 600, morph = 0, freq = 130.81, lfoRate = 0, lfoDepth = 0, lfoShape = 0, xfadeSamp = 480|
		^this.multiNew('audio', bufL, bufR, startFrac, endFrac, numSlices, cycleLen, morph, freq, lfoRate, lfoDepth, lfoShape, xfadeSamp)
	}
	init { |... theInputs|
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}
	checkInputs { ^this.checkValidInputs }
}
