// Language-side wrapper for the ElasticatSlicer UGen. A slice player: the region
// [startFrac,endFrac] is cut into numSlices slices; slicePhase (0..1 over the region,
// MUST be audio-rate; run it backward for track-reverse) selects the current slice and
// a 2-head crossfade hands off on each change (no click even with long attack/gate).
// attackSamp/releaseSamp are in SAMPLES; gate is 0..1 of the slice duration (sliceDurSamp
// = slice length in samples, for the gate timing); loopMode 0 chop / 1 loop / 2 pingpong
// / 3 runaway; sliceReverse 0/1 (slice plays backward); pitchRate = frames/sample
// (magnitude). Returns [L, R].
ElasticatSlicer : MultiOutUGen {
	*ar { |bufL, bufR, slicePhase = 0, startFrac = 0, endFrac = 1, numSlices = 8, attackSamp = 96, releaseSamp = 480, gate = 1, sliceDurSamp = 4800, loopMode = 0, sliceReverse = 0, pitchRate = 1|
		^this.multiNew('audio', bufL, bufR, slicePhase, startFrac, endFrac, numSlices, attackSamp, releaseSamp, gate, sliceDurSamp, loopMode, sliceReverse, pitchRate)
	}
	init { |... theInputs|
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}
	checkInputs { ^this.checkValidInputs }
}
