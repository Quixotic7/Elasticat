// Language-side wrapper for the ElasticatPassthru server UGen. Lives in the
// Extensions dir so sclang knows ElasticatPassthru.ar; the .so registers the
// matching server unit. Toolchain-validation UGen -- out = in * gain.
ElasticatPassthru : UGen {
	*ar { |in, gain = 1.0|
		^this.multiNew('audio', in, gain)
	}
	checkInputs { ^this.checkValidInputs }
}
