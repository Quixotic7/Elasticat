// Language-side wrapper for the ElasticatGrains particle granular UGen. The playhead
// (0..1, MUST be audio-rate) is a silent emitter; grains read the sample as particles
// and WRAP at the trim bounds, so moving the loop/range points (which only relocate
// the emitter) never clicks. baseRate = playheadRate * grainSpeed * pitchRatio
// (frames/sample, signed); the UGen applies per-grain speed randomness + direction.
// density, cycleMs, spread(0..1), speedRand(0..1), dirBalance(0..1) may be control-rate.
// dirBalance: 0 = all backward, 0.5 = 50/50, 1 = all forward. Returns [L, R].
ElasticatGrains : MultiOutUGen {
	*ar { |bufL, bufR, playhead = 0, density = 8, cycleMs = 80, spread = 0, baseRate = 1, speedRand = 0, dirBalance = 1|
		^this.multiNew('audio', bufL, bufR, playhead, density, cycleMs, spread, baseRate, speedRand, dirBalance)
	}
	init { |... theInputs|
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}
	checkInputs { ^this.checkValidInputs }
}
