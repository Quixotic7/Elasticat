// Language-side wrapper for the ElasticatReader server UGen. Click-free stereo
// buffer reader ported from softcut (absolute-frame reads + one queued 2-head
// crossfade). loopStart/loopEnd/resetPos are in FRAMES; rate is frames/sample
// (signed for reverse). Returns [L, R, phase01] -- phase01 (0..1 over the region)
// is the active head's, for the UI playhead.
ElasticatReader : MultiOutUGen {
	*ar { |bufL, bufR, loopStart = 0, loopEnd = 0, rate = 0, resetTrig = 0, resetPos = 0, fadeTime = 0.01, loopFlag = 1|
		^this.multiNew('audio', bufL, bufR, loopStart, loopEnd, rate, resetTrig, resetPos, fadeTime, loopFlag)
	}
	init { |... theInputs|
		inputs = theInputs;
		^this.initOutputs(3, rate);
	}
	checkInputs { ^this.checkValidInputs }
}
