// Elasticat v2 foundation.
//
// Every track is an instance of ONE class, ElasticatTrack (defined at the
// bottom of this file; see docs/PHASE2_CONTRACT.md). Track 1 is not special:
// it owns a chain built by exactly the same code as tracks 2-8, so changing
// how a track works is a one-place change, never 8x.
//
// The engine owns only what is genuinely global: the 2 send busses and their
// FX, the master bus + master FX, transport tempo / clock sync, the shared
// sample pool, the SynthDefs, and OSC routing.
//
// Existing mode families are preserved under technically accurate names:
//   0 tape              former basic
//   1 tempo_varispeed   former classic
//   2 chopped
//   3 granular
//   4 random_ola        former wsola-style random overlap grains
//   5 pitch_corrected   former pv/PitchShift color
Engine_Elasticat : CroneEngine {

	// --- Tracks --------------------------------------------------------------
	// tracks[1..8]; slot 0 is unused so the array indexes by track NUMBER.
	// State instances are created lazily by `track`; the CHAIN (synths/busses)
	// is allocated by \activeTrackCount. Track 1's chain is always allocated
	// -- it is the clock reference -- but it is otherwise an ordinary track.
	var <tracks;
	var activeTrackCount = 1;
	var <tracksGroup;   // holds all 8 track chains; runs before sendGroup
	var levelDecim;     // per-track 30Hz -> 15Hz counter for the meter feed

	// --- Global send busses / master bus (PRD SS3/SS8) -----------------------
	// Group order: tracksGroup -> sendGroup -> masterGroup.
	// Each track's send tap writes sendBus1/2 and its mix synth writes
	// masterBus, all from tracksGroup. sendGroup's two FX synths read the send
	// busses and add back into masterBus. masterGroup's master insert reads
	// masterBus (tracks + both send returns, all written by then) and is the
	// only thing writing context.out_b.
	var <sendGroup;
	var <masterGroup;
	var <masterBus;
	var <sendBus1;
	var <sendBus2;
	var send1Synth;
	var send2Synth;
	var masterSynth;
	var send1Machine = 0;   // index into fxInsertNames
	var send2Machine = 0;
	var masterFxMachine = 0;
	// Per-slot FX params, indexed [send1, send2, master] -- three independent
	// slots sharing one machine set, so arrays rather than scalars.
	var sendFxDrive;
	var sendFxMix;
	var sendFxDelayBeats;
	var sendFxDelayFeedback;
	var sendFxDelayTone;
	var sendFxReverbSize;
	var sendFxReverbDamp;
	var sendFxLofiBits;
	var sendFxLofiRate;

	// --- SynthDef name registries (a machine is one row here + one SynthDef) -
	var <modeSynthNames;
	var <modeNames;
	var <filterSynthNames;
	var <fxInsertNames;

	// --- Shared SynthDef graph functions -------------------------------------
	var readerAmpEnv;         // shared amp-envelope graph for readers/filter env
	var filterPrep;           // shared drive + env-modulated cutoff/res prep
	var filterChannelClassic; // shared per-channel Classic (multimode) filter
	var filterChannelMorph;   // shared per-channel Morphing filter
	var filterBalanceCutoffs; // shared balance law: cutoff + balance -> [fcA, fcB]
	var filterModOut;         // shared pan/amp output stage with pan/amp mod input
	var fxMixBlend;           // shared dry/wet crossfade for insert FX machines
	var fxDriveShape;         // shared drive/clip curve for the insert FX chain

	// --- Global transport / clock -------------------------------------------
	// Tempo is a MASTER-scope setting; every track's transport follows it.
	// Clock sync uses track 1 as the phase reference (one loop can be the
	// reference, and the transport correction it derives is pushed to ALL
	// tracks) -- that is an engine-level role, not per-track behavior.
	var <targetBpm = 120;
	var <modeSwitchFade = 0.05;
	var <correction = 0;
	var loopXfade = 0.005;
	var maxCorrection = 0.02;
	var hardThreshold = 0.125;
	var modeSwitchCount = 0;
	var failedModeSwitchCount = 0;
	var hardRealignCount = 0;
	var staleClockCount = 0;
	var lastClockSeq = -1;
	var lastPhase = 0;
	var lastExpectedPhase = 0;
	var lastPhaseError = 0;
	var lastErrorMs = 0;
	var loadGeneration = 0;
	var debugLevel = 1;
	// Which track's per-instance mod / filter-env stream reaches the script.
	// Eight copies of each now run; forwarding all of them would flood OSC and
	// paint another track's modulation onto this track's page. Defaults to 1.
	var uiTrack = 1;

	// --- Shared sample pool --------------------------------------------------
	// One buffer set per slot, shared by every track (no duplication).
	var <poolSize = 128;
	var <poolBufL;
	var <poolBufR;
	var poolPaths;
	var <poolLoaded;
	var <poolFrames;
	var <poolRates;
	var poolGenerations;
	var <defaultBufL;
	var <defaultBufR;
	var previewSynth;

	// --- Slice voices --------------------------------------------------------
	// Articulation settings are engine-wide; the VOICES live on their track
	// (spawned into that track's sourceGroup so they pass through that track's
	// filter). sliceVoiceOrder is the oldest-first list across ALL tracks that
	// enforces maxSliceVoices -- 8 tracks x 8 voices would cliff the CPU, so
	// the oldest voice is stolen when the cap is hit. The per-track limit
	// (the 32-slot voice map plus slice polyphony/mono) is unchanged.
	var <sliceAttack = 0.002;
	var <sliceRelease = 0.02;
	var <sliceMono = 0;
	var <sliceSyncToClock = 1;
	var <sliceRate = 1;
	var sliceVoiceOrder;
	var maxSliceVoices = 16;

	// --- OSC -----------------------------------------------------------------
	var scriptAddress;
	var statusResponder;
	var modResponder;       // live mod-bus values -> script (~15Hz UI feed)
	var filterEnvResponder; // filter-env cutoff contribution -> script (15Hz)
	var transportResponder;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// Lazy per-track state. Every track index 1..8 is equal; nothing here
	// branches on the number.
	track { arg n;
		var t;
		t = n.asInteger;
		if((t < 1) or: { t > 8 }, { ^nil });
		if(tracks[t].isNil, { tracks[t] = ElasticatTrack(this, t); });
		^tracks[t];
	}

	// Every track that currently owns a chain, in index order.
	activeTracks {
		^(1..8).collect({ arg t; tracks[t] }).select({ arg tr;
			tr.notNil and: { tr.isAllocated }
		});
	}

	alloc {
		var server;
		server = context.server;
		scriptAddress = NetAddr("localhost", 10111);
		modeSynthNames = [
			\elasticatTape,
			\elasticatTempoVarispeed,
			\elasticatChopped,
			\elasticatGranular,
			\elasticatRandomOla,
			\elasticatPitchCorrected
		];
		modeNames = [
			"tape",
			"tempo_varispeed",
			"chopped",
			"granular",
			"random_ola",
			"pitch_corrected"
		];
		filterSynthNames = [
			\elasticatFilterClassic,
			\elasticatFilterMorph,
			\elasticatFilterClassicStereo,
			\elasticatFilterMorphStereo,
			\elasticatFilterClassicMS,
			\elasticatFilterMorphMS
		];
		fxInsertNames = [
			\elasticatFxNone,
			\elasticatFxDrive,
			\elasticatFxDelay,
			\elasticatFxReverb,
			\elasticatFxLofi
		];

		sendFxDrive = [0, 0, 0];
		sendFxMix = [0.5, 0.5, 0.5];
		sendFxDelayBeats = [1, 1, 1];
		sendFxDelayFeedback = [0.3, 0.3, 0.3];
		sendFxDelayTone = [1, 1, 1];
		sendFxReverbSize = [0.5, 0.5, 0.5];
		sendFxReverbDamp = [0.5, 0.5, 0.5];
		sendFxLofiBits = [24, 24, 24];
		sendFxLofiRate = [48000, 48000, 48000];

		masterBus = Bus.audio(server, 2);
		sendBus1 = Bus.audio(server, 2);
		sendBus2 = Bus.audio(server, 2);

		defaultBufL = Buffer.alloc(server, 4, 1);
		defaultBufR = defaultBufL;
		poolBufL = Array.fill(poolSize, { nil });
		poolBufR = Array.fill(poolSize, { nil });
		poolPaths = Array.fill(poolSize, { "" });
		poolLoaded = Array.fill(poolSize, { 0 });
		poolFrames = Array.fill(poolSize, { 4 });
		poolRates = Array.fill(poolSize, { 48000 });
		poolGenerations = Array.fill(poolSize, { 0 });

		tracks = Array.fill(9, { nil });
		levelDecim = Array.fill(9, { 0 });
		sliceVoiceOrder = [];

		this.addSynthDefs;
		server.sync;

		// --- OSC responders --------------------------------------------------
		// Every per-instance SendReply carries its 1-based track index as
		// replyID, so one responder per stream serves all 8 tracks.
		transportResponder = OSCFunc({
			arg msg;
			var t, tr;
			t = msg[2].asInteger;
			tr = if((t >= 1) and: { t <= 8 }, { tracks[t] }, { nil });
			if(tr.notNil, { tr.reportPhase(msg[3].asFloat); });
			// Track 1 is the clock-sync phase reference (an engine-level role).
			if(t == 1, {
				lastPhase = msg[3].asFloat;
				correction = msg[4].asFloat;
				if(debugLevel >= 3, {
					scriptAddress.sendBundle(0, [
						"/elasticat/transport",
						lastPhase,
						correction,
						msg[5].asFloat
					]);
				});
			});
			// UNCONDITIONAL, for every track including 1 -- one code path, no
			// track-1 branch. This is the only phase the script gets for a
			// BACKGROUND track: without it trig_release "return" (which needs a
			// past playhead position to dead-reckon from) degrades to "reset" on
			// every track that is not selected. Track 1 also appears in the
			// legacy 30 Hz /elasticat/status stream, but that stream is track 1's
			// alone and must not be relied on for the others.
			//
			// Cost: one small bundle per track per second (the SendReply above is
			// Impulse.kr(1)), so 8 msg/s at 8 tracks. Deliberately far below the
			// 30 Hz reader streams -- the script dead-reckons between reports, it
			// does not need a fast feed. Do not raise this rate.
			scriptAddress.sendBundle(0, [
				"/elasticat/track/position",
				t,
				msg[3].asFloat
			]);
		}, path: '/elasticat/transportRaw', srcID: server.addr);

		statusResponder = OSCFunc({
			arg msg;
			var t, tr, ui;
			// Every reader fires this at 30Hz; the message has already arrived,
			// so use it to keep EVERY track's phase current (a machine swap
			// re-anchors on it). Only the reference track's FULL status stream
			// is forwarded -- 8 x 30Hz of that would flood OSC.
			t = msg[2].asInteger;
			tr = if((t >= 1) and: { t <= 8 }, { tracks[t] }, { nil });
			if(tr.notNil, {
				tr.reportPhase(msg[4].asFloat);
				// Per-track meter feed, for every track including 1 (one code
				// path; track 1 is not special). Decimated 30Hz -> 15Hz, the
				// norns screen refresh rate the mod feed already uses:
				// forwarding all 8 readers undecimated would be 240 msg/s of
				// meters alone.
				levelDecim[t] = levelDecim[t] + 1;
				if(levelDecim[t] >= 2, {
					levelDecim[t] = 0;
					scriptAddress.sendBundle(0, [
						"/elasticat/track/level", t, msg[6].asFloat, msg[7].asFloat
					]);
				});
			});
			if(t == 1, {
				lastPhase = msg[4].asFloat;
				ui = this.uiTrackObj;
				scriptAddress.sendBundle(0, [
					"/elasticat/status",
					ui.loaded,
					ui.playing,
					modeNames.wrapAt(ui.machine),
					msg[3].asFloat,
					msg[4].asFloat,
					msg[5].asFloat,
					msg[6].asFloat,
					msg[7].asFloat,
					targetBpm,
					ui.derivedSourceBpm,
					correction,
					lastExpectedPhase,
					lastPhaseError,
					lastErrorMs,
					modeSwitchCount,
					failedModeSwitchCount,
					hardRealignCount,
					staleClockCount,
					loadGeneration
				]);
			});
		}, path: '/elasticat/statusRaw', srcID: server.addr);

		// Live modulation feed for the UI: the five mod-bus sums, so the
		// low-profile "actual value" bars and the filter render follow LFOs /
		// mod-env / macros during playback. Fired at 15Hz by each track's
		// \elasticatMod; only the UI-selected track's stream is forwarded.
		// The track index rides along as a trailing value (appending keeps the
		// existing positional handler working unchanged).
		modResponder = OSCFunc({
			arg msg;
			if(msg[2].asInteger == uiTrack, {
				scriptAddress.sendBundle(0, [
					"/elasticat/mod",
					msg[3].asFloat, msg[4].asFloat, msg[5].asFloat,
					msg[6].asFloat, msg[7].asFloat,
					msg[2].asInteger
				]);
			});
		}, path: '/elasticat/modRaw', srcID: server.addr);

		// Filter-envelope cutoff contribution (semitones) -> script, so the UI
		// can show the filter's own envelope sweeping the render.
		filterEnvResponder = OSCFunc({
			arg msg;
			if(msg[2].asInteger == uiTrack, {
				scriptAddress.sendBundle(0, [
					"/elasticat/filterEnv", msg[3].asFloat, msg[2].asInteger
				]);
			});
		}, path: '/elasticat/filterEnvRaw', srcID: server.addr);

		// --- Node graph: tracksGroup -> sendGroup -> masterGroup -------------
		tracksGroup = Group.head(context.xg);
		sendGroup = Group.after(tracksGroup);
		masterGroup = Group.after(sendGroup);

		this.spawnSend1;
		this.spawnSend2;
		this.spawnMasterFx;

		// Allocate every active chain through the ONE code path. Track 1 is
		// included here, not spawned separately.
		this.setActiveTrackCount(activeTrackCount);

		this.installCommands;
	}

	addSynthDefs {
		// Shared amp-envelope graph for the continuous mode readers. Retriggered
		// per step via the envTrig counter; portamento suppresses re-attack on an
		// overlapping (still-sounding) note. Huge envHold/envRelease act as INF.
		readerAmpEnv = { arg envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig;
			var rawTrig, releaseTrig, timedWindow, holdGate, holdIndefinite, window, reEdge, adsrGate, ahrTrig, adsr, ahr, port;
			port = portamento.clip(0, 1);
			rawTrig = Changed.kr(envTrig);
			// --- Task 1 (PRD S8): engine noteOff ---------------------------------
			// envGateSeconds <= 0 is the "indefinite hold" sentinel a live-held note
			// (grid key held, unknown duration) sends via noteOn instead of a fixed
			// seconds value: the ADSR gate opens on the note-on trig and stays open
			// -- the timed window is bypassed entirely -- until an explicit noteOff
			// bumps envReleaseTrig, which is what actually gates the release. Finite
			// notes (envGateSeconds > 0, every existing call site) are untouched:
			// holdIndefinite reads 0 there, so `window` resolves to the very same
			// `timedWindow` Trig.kr as before -- byte-identical to prior behavior.
			holdIndefinite = envGateSeconds <= 0;
			timedWindow = Trig.kr(rawTrig, envGateSeconds.max(0.001));
			releaseTrig = Changed.kr(envReleaseTrig);
			holdGate = SetResetFF.kr(rawTrig, releaseTrig);
			window = Select.kr(holdIndefinite, [timedWindow, holdGate]);
			// --- end Task 1 block -------------------------------------------------
			reEdge = 1 - Trig.kr(rawTrig, ControlDur.ir * 1.5);
			adsrGate = window * Select.kr(port, [reEdge, DC.kr(1)]);
			ahrTrig = Select.kr(port, [rawTrig, Trig.kr(window, 0)]);
			adsr = EnvGen.kr(
				Env.adsr(envAttack.max(0.0001), envDecay.max(0.0001), envSustain.clip(0, 1), envRelease.max(0.0001), 1, -4),
				adsrGate, doneAction: 0);
			ahr = EnvGen.kr(
				Env([0, 1, 1, 0], [envAttack.max(0.0001), envHold.max(0.0001), envRelease.max(0.0001)], [-4, 0, -4]),
				ahrTrig, doneAction: 0);
			Select.kr(envMode.clip(0, 1), [adsr, ahr]);
		};

		// Shared filter-machine DSP graphs, mirroring the readerAmpEnv pattern
		// above: plain Functions assigned to instance vars, inlined wherever a
		// SynthDef calls them. This is what lets the stereo/mid-side machines
		// parameterize the mono DSP (two filter instances + a balance law)
		// instead of hand-copying SynthDefs (PRD SS4.2 / ARCHITECTURE "To add a
		// filter machine").
		//
		// Drive + env-modulated cutoff + resonance prep, shared by every filter
		// machine. Returns [drivenStereoSignal, baseCutoffHz, rq].
		// envReleaseTrig (Task 1, PRD S8) threads noteOff through to the filter
		// envelope, which shares the amp env's trigger counter/gate window.
		filterPrep = { arg sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex=1, slew=0.09;
			var driven, fenv, fc, rq, resMod;
			driven = (sig * (1 + (drive.clip(0, 1) * 12))).tanh;
			sig = XFade2.ar(sig, driven, (drive.clip(0, 1) * 2) - 1);
			fenv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, 0, envReleaseTrig);
			// Depth is +/-6 octaves (72 semitones) of cutoff modulation; the mod
			// bus (LFO/mod-env CUTOFF destination, -1..1) adds up to +/-3 octaves
			// (36 semitones) on top -- both exponential, summed in semitones.
			fc = (Lag.kr(cutoff.clip(20, 20000), slew)
				* ((envDepth.clip(-1, 1) * fenv * 72) + (In.kr(cutoffModBus, 1).clip(-1, 1) * 36)).midiratio).clip(20, 20000);
			// Report the FILTER ENVELOPE's own cutoff contribution (in semitones)
			// to the script at 15Hz. It is applied here rather than on a mod bus,
			// so the UI's filter render/actual-value bars could not see it
			// otherwise. Phase 2: one filter synth PER TRACK, so this carries the
			// track index as replyID and the script keeps only the selected
			// track's stream.
			SendReply.kr(Impulse.kr(15), '/elasticat/filterEnvRaw',
				[envDepth.clip(-1, 1) * fenv * 72], replyID: trackIndex);
			// RES destination: -1..1 mod adds +/-0.5 to the 0..1 resonance.
			resMod = (res.clip(0, 1) + (In.kr(resModBus, 1).clip(-1, 1) * 0.5)).clip(0, 1);
			rq = Lag.kr((1 - (resMod * 0.98)).clip(0.02, 1), slew);
			[sig, fc, rq];
		};

		// Classic per-channel filter: Type selects LP/HP/BP/notch at (fc, rq).
		filterChannelClassic = { arg s, fc, rq, filterType;
			var lp, hp, bp;
			lp = RLPF.ar(s, fc, rq);
			hp = RHPF.ar(s, fc, rq);
			bp = BPF.ar(s, fc, rq);
			Select.ar(filterType.clip(0, 3), [lp, hp, bp, s - bp]);
		};

		// Morphing per-channel filter: Morph sweeps LP -> notch -> HP at (fc, rq).
		// morph is lagged here (matches the original single-channel synth); called
		// once per channel this duplicates a trivial control-rate Lag, not audio DSP.
		filterChannelMorph = { arg s, fc, rq, morph, slew=0.09;
			var lp, hp, bp, notch, lowHalf, highHalf, m;
			m = Lag.kr(morph.clip(0, 1), slew);
			lp = RLPF.ar(s, fc, rq);
			hp = RHPF.ar(s, fc, rq);
			bp = BPF.ar(s, fc, rq);
			notch = s - bp;
			lowHalf = XFade2.ar(lp, notch, m.linlin(0, 0.5, -1, 1).clip(-1, 1));
			highHalf = XFade2.ar(notch, hp, m.linlin(0.5, 1, -1, 1).clip(-1, 1));
			Select.ar(m >= 0.5, [lowHalf, highHalf]);
		};

		// Balance law (PRD SS4.2): balance is -1..1 (engine-side; the Lua param
		// maps its 0-128 centered UI value via (x-64)/64). At balance = +1,
		// channel B's cutoff is pushed up an octave spread and channel A's is
		// pushed down by the same amount; balance = -1 mirrors that (A up, B
		// down); balance = 0 leaves both at the base cutoff. Octave spread is a
		// fixed musical choice (2 octaves at full deflection), not derived from
		// any other param. Stereo machines call this with A=left, B=right;
		// mid/side machines reuse it verbatim with A=mid, B=side.
		filterBalanceCutoffs = { arg fc, balance, spreadSemitones=24;
			var bal, ratioA, ratioB;
			bal = balance.clip(-1, 1);
			ratioA = (bal.neg * spreadSemitones).midiratio;
			ratioB = (bal * spreadSemitones).midiratio;
			[(fc * ratioA).clip(20, 20000), (fc * ratioB).clip(20, 20000)];
		};

		// Shared filter output stage: the master pan + track volume Balance2 every
		// filter machine ends with, now with the AMP/PAN modulation destinations
		// folded in. AMP is a tremolo on the output gain -- amp * (1 + mod),
		// clipped >= 0 -- and PAN adds -1..1 to the pan position, clipped.
		// pan/amp were applied RAW here -- no smoothing at all -- so a stepped
		// control (an encoder detent, or a 12Hz morph tick) landed as a jump.
		// Lagged at `slew` like the rest of the filter stage.
		filterModOut = { arg sigL, sigR, pan, amp, panModBus, ampModBus, slew=0.09;
			Balance2.ar(sigL, sigR,
				(Lag.kr(pan, slew) + In.kr(panModBus, 1).clip(-1, 1)).clip(-1, 1),
				(Lag.kr(amp, slew) * (1 + In.kr(ampModBus, 1).clip(-1, 1))).max(0));
		};

		// trackIndex feeds SendReply's replyID so the responders can tell which
		// track's chain is reporting (Phase 1 multitrack; default 1 = track 1,
		// whose spawns never pass it -- behavior unchanged).
		SynthDef(\elasticatTransport, {
			arg out=0, playing=0, targetBpm=120, loopBeats=4, resetTrig=0,
			resetPos=0, correction=0, trackIndex=1;
			var cyclesPerSecond, phase, run;

			run = Lag.kr(playing.clip(0, 1), 0.01);
			cyclesPerSecond = (targetBpm.max(1) / 60) / loopBeats.max(0.03125);
			phase = Phasor.ar(
				Changed.kr(resetTrig),  // resetTrig is a monotonic counter; edge-detect it so every set resets
				(cyclesPerSecond * (1 + correction.clip(-0.1, 0.1)) * run) / SampleRate.ir,
				0,
				1,
				resetPos.clip(0, 0.999999)
			);
			Out.ar(out, phase);
			SendReply.kr(Impulse.kr(1), cmdName: '/elasticat/transportRaw', values: [
				phase,
				correction,
				targetBpm
			], replyID: trackIndex);
		}).add;

		// Sample preview: plays a slot's trim window at native rate, looping, with
		// no timestretch / pitch / warp -- the File-page audition. Independent of
		// the transport and mode synths.
		SynthDef(\elasticatPreview, {
			arg out=0, bufL=0, bufR=0, startFrac=0, endFrac=1, gain=1, gate=1;
			var frames, span, phase, pos, sig, env;
			frames = BufFrames.kr(bufL).max(4);
			span = (endFrac - startFrac).clip(0.0001, 1);
			phase = Phasor.ar(0, BufRateScale.kr(bufL) / (frames * span), 0, 1);
			pos = (startFrac + (phase * span)) * (frames - 1);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			env = EnvGen.kr(Env.asr(0.005, 1, 0.02), gate, doneAction: 2);
			sig = sig * gain.max(0) * env;
			Out.ar(out, LeakDC.ar(sig));
		}).add;

		this.addDirectReaderDef(\elasticatTape, 0);
		this.addDirectReaderDef(\elasticatTempoVarispeed, 1);

		SynthDef(\elasticatChopped, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, chopBeats=0.25, chopMode=0, chopAttack=0.002, chopHold=0.04, chopRelease=0.01,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, trackIndex=1;
			var ampEnv;
			var phase, frames, pos, trig, beatDur, duty, env, sig, modeGain, playGate, startNorm, range, readPhase;
			var pitchSmooth, sliceWidth, sliceStart, localPhase, forwardStop, loopForward, pingPong, pingPongPhase, stepRate, stopGate;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			beatDur = 60 / targetBpm.max(1);
			trig = Impulse.ar(((targetBpm.max(1) / 60) / chopBeats.max(0.03125)).max(0.1));
			pitchSmooth = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12));
			sliceWidth = (range * (chopBeats.max(0.03125) / loopBeats.max(0.03125))).clip(0.0001, 1);
			sliceStart = Latch.ar(readPhase, trig);
			stepRate = (SampleRate.ir * BufRateScale.kr(bufL) * pitchSmooth.midiratio) / (frames * sliceWidth).max(1);
			localPhase = Sweep.ar(trig, stepRate) * playing.clip(0, 1);
			forwardStop = (sliceStart + (localPhase.clip(0, 1) * sliceWidth)).clip(0, 0.999999);
			loopForward = (sliceStart + (localPhase.wrap(0, 1) * sliceWidth)).clip(0, 0.999999);
			pingPongPhase = localPhase.wrap(0, 2).fold(0, 1);
			pingPong = (sliceStart + (pingPongPhase * sliceWidth)).clip(0, 0.999999);
			stopGate = (localPhase < 1);
			duty = (1 - (macro.clip(0, 1) * 0.85)).clip(0.05, 1);
			pos = Select.ar(chopMode.clip(0, 2), [forwardStop, loopForward, pingPong]) * (frames - 1);
			env = EnvGen.ar(Env.linen(
				chopAttack.max(0.0001),
				((chopBeats.max(0.03125) * beatDur * duty) - chopAttack - chopRelease).max(0.001),
				chopRelease.max(0.0001)
			), trig);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			] * env * Select.ar(chopMode.clip(0, 2), [stopGate, DC.ar(1), DC.ar(1)]);
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			// Track pan + volume moved downstream to the filter output stage; the
			// voice applies only its articulation gain (mode xfade, play gate, env).
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				2, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatGranular, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.08, grainOverlap=8, grainJitter=0.0, grainSpray=0.0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, trackIndex=1;
			var ampEnv;
			var phase, frames, pos, dur, randomness, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlap, overlapControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			pos = readPhase * (frames - 1);
			dur = Lag.kr(grainSize.clip(0.02, 0.5), 0.05);
			stepDur = 15 / targetBpm.max(1);
			overlapControl = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			overlap = ((overlapControl * dur) / stepDur).clip(2, 32);
			randomness = Lag.kr((grainJitter + grainSpray + (macro * 0.03)).clip(0, 0.25), 0.05);
			direct = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			wet = [
				Warp1.ar(1, bufL, readPhase, (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio, dur, -1, overlap, randomness, 4),
				Warp1.ar(1, bufR, readPhase, (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio, dur, -1, overlap, randomness, 4)
			];
			sig = XFade2.ar(direct, wet, macro.linlin(0, 1, -0.75, 0.25));
			gainNorm = overlap.sqrt.reciprocal * 2.5 * (1 + (macro.clip(0, 1) * 0.25));
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * gainNorm * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				3, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatRandomOla, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.1, grainOverlap=6, wander=0.03, timingJitter=0.0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, trackIndex=1;
			var ampEnv;
			var phase, frames, trig, dur, rate, chaos, pos, offset, direct, wet, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, stepDur, overlapControl, wanderControl;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			dur = Lag.kr(grainSize.clip(0.03, 0.6), 0.05);
			stepDur = 15 / targetBpm.max(1);
			overlapControl = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			rate = (overlapControl / stepDur).clip(1, 240);
			trig = Impulse.ar(rate);
			chaos = macro.clip(0, 1);
			wanderControl = Lag.kr(wander.clip(0, 0.25), 0.05);
			offset = TRand.ar(wanderControl.neg, wanderControl, trig) * (0.25 + chaos);
			pos = ((readPhase * BufDur.kr(bufL)) + offset + (TRand.ar(timingJitter.neg, timingJitter, trig) * chaos)).wrap(0, BufDur.kr(bufL).max(0.001));
			direct = [
				BufRd.ar(1, bufL, readPhase * (frames - 1), loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, readPhase * (frames - 1), loop: 1, interpolation: 4)
			];
			wet = [
				TGrains.ar(1, trig, bufL, (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio, pos, dur, 0, 1, 4),
				TGrains.ar(1, trig, bufR, (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio, pos, dur, 0, 1, 4)
			];
			sig = XFade2.ar(direct, wet, macro.linlin(0, 1, -0.75, 0.25));
			gainNorm = overlapControl.sqrt.reciprocal * 2.5;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * gainNorm * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				4, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatPitchCorrected, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, derivedSourceBpm=120, loopBeats=4,
			startPoint=0, endPoint=128, pvWindow=0.2, pvDispersion=0, pvTimeDispersion=0, macro=0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, trackIndex=1;
			var ampEnv;
			var phase, frames, pos, raw, shifted, ratio, sig, modeGain, playGate, window, startNorm, range, readPhase;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			pos = readPhase * (frames - 1);
			raw = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			ratio = (derivedSourceBpm.max(1) / targetBpm.max(1) * (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio).clip(0.5, 2);
			window = Lag.kr(pvWindow.clip(0.005, 2), 0.05) * (1 + macro.clip(0, 1));
			shifted = PitchShift.ar(raw, window, ratio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvTimeDispersion.clip(0, 1), 0.05));
			sig = shifted;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				5, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		SynthDef(\elasticatSliceVoice, {
			arg out=0, bufL=0, bufR=0,
			startPoint=0, endPoint=8, playMode=0, reverse=0,
			amp=0.8, pan=0, pitch=0, velocity=1, gate=1,
			sliceAttack=0.002, sliceRelease=0.02,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			lengthSeconds=0, syncToClock=1, sliceRate=1, warpMode=0,
			targetBpm=120, macro=0, grainSize=0.08, grainOverlap=8,
			grainJitter=0, wsolaWindow=0.1, wsolaSearch=0.03,
			pvWindow=0.2, pvDispersion=0, pitchModBus=0, steal=0;
			var frames, startFrame, endFrame, loFrame, hiFrame, continueMode, readLo, readHi, loopMode;
			var directionSign, resetFrame, rangeFrames, duration, pitchRatio, freePitchRatio, freeRate, fitRate, readRate;
			var pos, loopPos, sweepFrames, sweepForwardPos, sweepReversePos, sweepPos, readPhase, env, adsrEnv, ahrEnv, raw, grain, ola, pc, sig, playAmp;
			var grainDur, grainCount, grainRandom, olaTrig, olaPos, pcRatio, stealFade;

			frames = BufFrames.kr(bufL).max(4);
			startFrame = (startPoint.clip(0, 127.99) / 128) * (frames - 1);
			endFrame = (endPoint.clip(0.01, 128) / 128) * (frames - 1);
			loFrame = startFrame.min(endFrame).clip(0, frames - 2);
			hiFrame = startFrame.max(endFrame).clip(loFrame + 1, frames - 1);
			continueMode = (playMode >= 3);
			loopMode = ((playMode >= 2) * (playMode < 3)).clip(0, 1);
			readLo = loFrame * (1 - continueMode);
			readHi = (hiFrame * (1 - continueMode)) + ((frames - 1) * continueMode);
			directionSign = 1 - (reverse.clip(0, 1) * 2);
			resetFrame = (startFrame * (1 - reverse.clip(0, 1))) + (endFrame * reverse.clip(0, 1));
			resetFrame = resetFrame.clip(readLo, readHi);
			rangeFrames = (readHi - readLo).max(1);
			duration = lengthSeconds.max(0.005);
			pitchRatio = (Lag.kr(pitch, 0.01) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.03125, 32);
			freePitchRatio = Select.kr(warpMode >= 3, [pitchRatio, DC.kr(1)]);
			freeRate = BufRateScale.kr(bufL) * sliceRate.max(0.03125) * freePitchRatio;
			fitRate = rangeFrames / (duration * SampleRate.ir).max(1);
			readRate = Select.kr(syncToClock.clip(0, 1), [freeRate, fitRate]) * directionSign;
			loopPos = Phasor.ar(
				0,
				readRate,
				readLo,
				readHi.max(readLo + 1),
				resetFrame
			);
			sweepFrames = Sweep.ar(0, readRate.abs * SampleRate.ir);
			sweepForwardPos = resetFrame + sweepFrames;
			sweepReversePos = resetFrame - sweepFrames;
			sweepPos = Select.ar(reverse.clip(0, 1), [sweepForwardPos, sweepReversePos]);
			pos = Select.ar(loopMode, [sweepPos.clip(readLo, readHi), loopPos]);
			readPhase = (pos / (frames - 1)).clip(0, 0.999999);
			// Amp envelope (shared with the readers). ADSR sustains while the slice
			// gate is held and releases on gate-off; AHR is a fixed attack/hold/
			// release burst (Hold matters, same as the loop reader). Hold/release are
			// capped so an INF setting can't strand a polyphonic voice. Both run at
			// doneAction 0; FreeSelf frees on gate-release+decay (ADSR) or when the
			// burst completes (AHR).
			adsrEnv = EnvGen.kr(
				Env.adsr(envAttack.max(0.0001), envDecay.max(0.0001), envSustain.clip(0, 1), envRelease.clip(0.0001, 30), 1, -4),
				gate, doneAction: 0);
			ahrEnv = EnvGen.kr(
				Env([0, 1, 1, 0], [envAttack.max(0.0001), envHold.clip(0.0001, 30), envRelease.clip(0.0001, 30)], [-4, 0, -4]),
				gate, doneAction: 0);
			env = Select.kr(envMode.clip(0, 1), [adsrEnv, ahrEnv]);
			FreeSelf.kr(Select.kr(envMode.clip(0, 1), [(gate < 0.5) * (adsrEnv < 0.0004), Done.kr(ahrEnv)]));
			raw = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			grainDur = Lag.kr(grainSize.clip(0.002, 0.5), 0.05);
			grainCount = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			grainRandom = Lag.kr((grainJitter + (macro * 0.03)).clip(0, 0.25), 0.05);
			grain = [
				Warp1.ar(1, bufL, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4),
				Warp1.ar(1, bufR, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4)
			];
			olaTrig = Impulse.ar((grainCount / Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05)).clip(1, 240));
			olaPos = ((readPhase * BufDur.kr(bufL)) + TRand.ar(wsolaSearch.neg, wsolaSearch, olaTrig)).wrap(0, BufDur.kr(bufL).max(0.001));
			ola = [
				TGrains.ar(1, olaTrig, bufL, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4),
				TGrains.ar(1, olaTrig, bufR, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4)
			];
			pcRatio = pitchRatio;
			pc = PitchShift.ar(raw, Lag.kr(pvWindow.clip(0.005, 2), 0.05), pcRatio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvDispersion.clip(0, 1), 0.05));
			sig = [
				Select.ar(warpMode.clip(0, 5), [raw[0], raw[0], raw[0], grain[0], ola[0], pc[0]]),
				Select.ar(warpMode.clip(0, 5), [raw[1], raw[1], raw[1], grain[1], ola[1], pc[1]])
			];
			// Voice stealing (global concurrent-voice cap, Phase 2). \gate alone
			// cannot end an AHR voice -- that envelope ignores gate-off -- so a
			// stolen voice needs its own exit: a 20 ms fade to silence that frees
			// the synth outright. Idle at 1 until \steal is set, so an unstolen
			// voice is bit-identical to before.
			stealFade = EnvGen.kr(Env([1, 0], [0.02]), steal, doneAction: 2);
			// Track pan + volume are applied downstream at the filter output stage;
			// the voice keeps only velocity and its per-note envelope.
			playAmp = velocity.clip(0, 1) * env * stealFade;
			sig = [sig[0], sig[1]] * playAmp;
			sig = LeakDC.ar(sig);
			Out.ar(out, sig);
		}).add;

		// --- Filter machines (global, post-mix) --------------------------------
		// Each reads the summed voices off fxBus, applies pre-filter drive, an
		// env-modulated cutoff (filter env reuses the shared readerAmpEnv graph
		// with its own independent params/mode), then the master pan + track vol
		// at the very end of the chain -> master out. New machines are added by
		// appending a SynthDef here and its name to filterSynthNames. All six
		// machines below share their DSP via filterPrep / filterChannelClassic /
		// filterChannelMorph / filterBalanceCutoffs (defined above, mirroring the
		// readerAmpEnv pattern) -- the stereo/mid-side variants are the mono
		// machines run twice with a balance-derived cutoff spread, not
		// hand-copied SynthDefs.
		//
		// Classic: Type morphs LP/HP/BP/notch by index (p-lockable Type).
		SynthDef(\elasticatFilterClassic, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			filtered = [
				filterChannelClassic.value(sig[0], fc, rq, filterType),
				filterChannelClassic.value(sig[1], fc, rq, filterType)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing: one Morph knob sweeps LP -> notch -> HP (p-lockable Morph).
		SynthDef(\elasticatFilterMorph, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			filtered = [
				filterChannelMorph.value(sig[0], fc, rq, morph, slew),
				filterChannelMorph.value(sig[1], fc, rq, morph, slew)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Classic Stereo (#3): two independent Classic filter instances (L/R),
		// cutoff spread by Balance -- balance = +1 pushes R cutoff up / L down;
		// balance = -1 mirrors (L up / R down); balance = 0 is identical to mono
		// Classic on both channels.
		SynthDef(\elasticatFilterClassicStereo, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, fcL, fcR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# fcL, fcR = filterBalanceCutoffs.value(fc, balance);
			filtered = [
				filterChannelClassic.value(sig[0], fcL, rq, filterType),
				filterChannelClassic.value(sig[1], fcR, rq, filterType)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing Stereo (#4): same balance law as Classic Stereo, applied to two
		// independent Morphing filter instances.
		SynthDef(\elasticatFilterMorphStereo, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, fcL, fcR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# fcL, fcR = filterBalanceCutoffs.value(fc, balance);
			filtered = [
				filterChannelMorph.value(sig[0], fcL, rq, morph, slew),
				filterChannelMorph.value(sig[1], fcR, rq, morph, slew)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Classic Mid/Side (#5): decode L/R -> mid/side (equal-weight sum/diff, a
		// lossless matrix on re-encode), run independent Classic filters on each
		// with the same balance law as the stereo variants (A=mid, B=side: balance
		// = +1 pushes Side cutoff up / Mid down), then re-encode to L/R.
		SynthDef(\elasticatFilterClassicMS, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, fcM, fcS, mid, side, filteredMid, filteredSide, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			mid = (sig[0] + sig[1]) * 0.5;
			side = (sig[0] - sig[1]) * 0.5;
			# fcM, fcS = filterBalanceCutoffs.value(fc, balance);
			filteredMid = filterChannelClassic.value(mid, fcM, rq, filterType);
			filteredSide = filterChannelClassic.value(side, fcS, rq, filterType);
			filtered = [filteredMid + filteredSide, filteredMid - filteredSide];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing Mid/Side (#6): same M/S decode/encode and balance law as
		// Classic Mid/Side, applied to two independent Morphing filter instances.
		SynthDef(\elasticatFilterMorphMS, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, fcM, fcS, mid, side, filteredMid, filteredSide, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			mid = (sig[0] + sig[1]) * 0.5;
			side = (sig[0] - sig[1]) * 0.5;
			# fcM, fcS = filterBalanceCutoffs.value(fc, balance);
			filteredMid = filterChannelMorph.value(mid, fcM, rq, morph, slew);
			filteredSide = filterChannelMorph.value(side, fcS, rq, morph, slew);
			filtered = [filteredMid + filteredSide, filteredMid - filteredSide];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// --- Insert 1 FX machines (global, post-filter) ------------------------
		// Each reads insertBus (the filter's output), applies its own DSP, then
		// writes the master out. Every machine below shares an identical arg
		// list -- unused args are simply ignored by the running synth -- so
		// `insertSynth.set(key, value)` always succeeds regardless of which
		// machine is active, the same trick filterArgs/spawnFilter rely on.
		// Index 0 (\elasticatFxNone) is a bare passthrough: the insert chain
		// graph must never leave insertBus unread, or the track goes silent
		// when the slot is set to "none".
		//
		// Shared dry/wet crossfade, used by every wet machine below (independent
		// of filterPrep -- FX DSP is not shared with the filter machines).
		fxMixBlend = { arg dry, wet, mix; XFade2.ar(dry, wet, (mix.clip(0, 1) * 2) - 1); };
		// Shared drive/clip curve for the insert chain (deliberately mirrors
		// filterPrep's pre-filter drive shape for a consistent character, but
		// kept as its own graph function since filterPrep also carries the
		// filter envelope machinery this chain doesn't need).
		fxDriveShape = { arg sig, drive; (sig * (1 + (drive.clip(0, 1) * 12))).tanh; };

		SynthDef(\elasticatFxNone, {
			arg out=0, in=0, mix=0.5, drive=0,
			delayBeats=1, delayFeedback=0.3, delayTone=1,
			reverbSize=0.5, reverbDamp=0.5,
			lofiBits=24, lofiRate=48000, targetBpm=120;
			Out.ar(out, In.ar(in, 2));
		}).add;

		// Drive: pre-insert clip/distortion (tanh saturation), the cheapest
		// machine here and the one that validates the insert infrastructure.
		SynthDef(\elasticatFxDrive, {
			arg out=0, in=0, mix=0.5, drive=0,
			delayBeats=1, delayFeedback=0.3, delayTone=1,
			reverbSize=0.5, reverbDamp=0.5,
			lofiBits=24, lofiRate=48000, targetBpm=120;
			var sig, dry, wet;
			sig = In.ar(in, 2);
			dry = sig;
			wet = fxDriveShape.value(sig, drive);
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Delay: tempo-synced (beat-division delayBeats, quarter note = 1,
		// recomputed from targetBpm every block so it stays in sync across
		// tempo changes) with a one-pole lowpass in the feedback loop (delayTone
		// -- 0 = dark/damped repeats, 1 = fully open). maxDelayTime is a fixed
		// DelayC buffer size (compile-time constant, cannot be a control-rate
		// arg); long beat divisions at slow tempos clip to this ceiling.
		SynthDef(\elasticatFxDelay, {
			arg out=0, in=0, mix=0.5, drive=0,
			delayBeats=1, delayFeedback=0.3, delayTone=1,
			reverbSize=0.5, reverbDamp=0.5,
			lofiBits=24, lofiRate=48000, targetBpm=120;
			var maxDelayTime = 2.0;
			var sig, dry, wet, fb, delaySeconds, toneHz, recirc;
			sig = In.ar(in, 2);
			dry = sig;
			delaySeconds = ((delayBeats.max(0.03125) * 60) / targetBpm.max(1)).clip(0.001, maxDelayTime);
			toneHz = delayTone.clip(0, 1).linexp(0.001, 1, 220, 18000);
			fb = LocalIn.ar(2);
			recirc = DelayC.ar(sig + (fb * delayFeedback.clip(0, 0.95)), maxDelayTime, delaySeconds);
			recirc = LPF.ar(recirc, toneHz).softclip;
			LocalOut.ar(recirc);
			wet = recirc;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Reverb: FreeVerb2 (see PRD SS4.3 -- FreeVerb2 or JPverb; FreeVerb2
		// chosen for Tier-1 cost). Its own mix arg is pinned to fully wet so the
		// shared fxMixBlend crossfade stays the one dry/wet control across every
		// machine.
		SynthDef(\elasticatFxReverb, {
			arg out=0, in=0, mix=0.5, drive=0,
			delayBeats=1, delayFeedback=0.3, delayTone=1,
			reverbSize=0.5, reverbDamp=0.5,
			lofiBits=24, lofiRate=48000, targetBpm=120;
			var sig, dry, wet;
			sig = In.ar(in, 2);
			dry = sig;
			wet = FreeVerb2.ar(sig[0], sig[1], 1, reverbSize.clip(0, 1), reverbDamp.clip(0, 1));
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Lofi: bit-depth + sample-rate reduction built from core UGens only
		// (Latch for sample-and-hold rate reduction, a round-to-step quantizer
		// for bit reduction) -- NOT SC's `Decimator`, which is a sc3-plugins
		// UGen not present in a stock SuperCollider install (confirmed absent
		// from this project's SCClassLibrary/Extensions search path; PRD SS4.3
		// mentions Decimator/Latch as options, this picks the one guaranteed to
		// be available). lofiBits/lofiRate are the literal output bit depth /
		// sample rate (higher = cleaner); the script converts the 0-127 knobs to
		// real units before sending, same as filter cutoff.
		SynthDef(\elasticatFxLofi, {
			arg out=0, in=0, mix=0.5, drive=0,
			delayBeats=1, delayFeedback=0.3, delayTone=1,
			reverbSize=0.5, reverbDamp=0.5,
			lofiBits=24, lofiRate=48000, targetBpm=120;
			var sig, dry, wet, held, step;
			sig = In.ar(in, 2);
			dry = sig;
			held = Latch.ar(sig, Impulse.ar(lofiRate.clip(500, 48000)));
			step = 2.0.pow(1 - lofiBits.clip(1, 24));
			wet = held.round(step);
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// --- Send tap (global; PRD SS3/SS8) -------------------------------------
		// Reads both the pre-insert (insertBus, post-filter) and post-insert-1
		// (masterBus, read here before any send FX has written back to it this
		// block) signals, selects one per the sendTap setting, then feeds
		// sendBus1/2 at their independent continuous levels. One instance per
		// track, at the head of sendGroup so send1Synth/send2Synth (below) read
		// a fully-formed send bus in the same block.
		SynthDef(\elasticatSendTap, {
			arg preIn=0, postIn=0, tap=0, level1=0, level2=0, sendOut1=0, sendOut2=0;
			var pre, post, sig;
			pre = In.ar(preIn, 2);
			post = In.ar(postIn, 2);
			sig = Select.ar(tap.clip(0, 1), [pre, post]);
			Out.ar(sendOut1, sig * Lag.kr(level1.clip(0, 1), 0.02));
			Out.ar(sendOut2, sig * Lag.kr(level2.clip(0, 1), 0.02));
		}).add;

		// --- Track mix stage (Phase 1 multitrack, tracks 2-8 only) --------------
		// The tail synth of each track 2-8 chain: reads that track's private mix
		// bus, applies track volume + pan (the job track 1's filter output stage
		// does) and the mute gate, and sums into masterBus. `alive` is the
		// click-free teardown gain: \activeTrackCount fades it to 0 (~30 ms Lag)
		// before freeing the chain. Track 1 never uses this synth.
		SynthDef(\elasticatTrackMix, {
			arg out=0, in=0, amp=0.8, pan=0, mute=0, alive=1;
			var sig, gain;
			sig = In.ar(in, 2);
			gain = Lag.kr(
				amp.max(0) * (1 - mute.clip(0, 1)) * alive.clip(0, 1),
				0.03
			);
			Out.ar(out, Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), gain));
		}).add;

		// --- Modulation synth (2 LFOs + mod envelope; MOD category) -------------
		// ONE control-rate synth computes every mod source and routes each source's
		// depth * value onto its selected destination bus (sources picking the same
		// destination sum here, in-synth, before the single Out.kr per bus). LFO
		// speeds are musical divisions: lfoBeats = beats per cycle, so the rate
		// tracks targetBpm (updateTransport pushes tempo changes). Retrigger uses
		// the amp env's counter idiom: the script bumps lfoTrig/menvTrig counters
		// and Changed.kr edge-detects them.
		// LFO modes: 0 FREE (never resets), 1 TRIG (phase resets on note trig),
		// 2 ONE (a single cycle per trig, then parks at phase 1), 3 HOLD (the
		// free-running wave is sampled & held at each trig).
		SynthDef(\elasticatMod, {
			arg pitchOut=0, cutoffOut=0, resOut=0, ampOut=0, panOut=0, targetBpm=120,
			lfo1Dest=0, lfo1Wave=0, lfo1Beats=4, lfo1Depth=0, lfo1Mode=0, lfoTrig1=0,
			lfo2Dest=0, lfo2Wave=0, lfo2Beats=4, lfo2Depth=0, lfo2Mode=0, lfoTrig2=0,
			menvDest=0, menvAttack=0.01, menvDecay=0.15, menvSustain=0.8, menvRelease=0.15,
			menvDepth=0, menvTrig=0, menvGateSeconds=0.5, menvReleaseTrig=0, trackIndex=1,
			macro1Base=0, macro1PitchDepth=0, macro1CutoffDepth=0, macro1ResDepth=0, macro1AmpDepth=0, macro1PanDepth=0,
			macro2Base=0, macro2PitchDepth=0, macro2CutoffDepth=0, macro2ResDepth=0, macro2AmpDepth=0, macro2PanDepth=0,
			macro3Base=0, macro3PitchDepth=0, macro3CutoffDepth=0, macro3ResDepth=0, macro3AmpDepth=0, macro3PanDepth=0,
			macro4Base=0, macro4PitchDepth=0, macro4CutoffDepth=0, macro4ResDepth=0, macro4AmpDepth=0, macro4PanDepth=0;
			var lfoValue, routed, lfo1, lfo2, menv, macroVal, mv1, mv2, mv3, mv4;
			var pitchSum, cutoffSum, resSum, ampSum, panSum;

			// One LFO source: -1..1 wave value honoring wave/mode/trig.
			lfoValue = { arg wave, beats, mode, trigCount;
				var trig, freq, resetTrig, phasor, oneshot, phase;
				var sine, tri, saw, rsaw, sqr, rand, val;
				trig = Changed.kr(trigCount);
				freq = ((targetBpm.max(1) / 60) / beats.max(0.0625)).clip(0.001, 40);
				// Only TRIG mode (1) resets the free phasor's phase on a note trig.
				resetTrig = trig * ((mode > 0.5) * (mode < 1.5));
				phasor = Phasor.kr(resetTrig, freq / ControlRate.ir, 0, 1);
				// ONE mode: a single cycle per trig, then hold at the cycle end.
				oneshot = Sweep.kr(trig, freq).clip(0, 1);
				phase = Select.kr((mode > 1.5) * (mode < 2.5), [phasor, oneshot]);
				sine = (phase * 2pi).sin;
				tri = 1 - ((phase * 2 - 1).abs * 2);
				saw = (phase * 2) - 1;
				rsaw = 1 - (phase * 2);
				sqr = ((phase < 0.5) * 2) - 1;
				rand = LFNoise0.kr(freq);  // S&H noise stepping at the LFO rate
				val = Select.kr(wave.clip(0, 5), [sine, tri, saw, rsaw, sqr, rand]);
				// HOLD mode: sample & hold the running wave at each trig.
				Select.kr(mode > 2.5, [val, Latch.kr(val, trig)]);
			};

			// A source contributes to a destination bus only when its dest selector
			// matches that bus's index (1 pitch, 2 cutoff, 3 res, 4 amp, 5 pan;
			// 6..9 = macro 1..4 as a modulation target).
			routed = { arg sig, dest, idx; sig * ((dest - idx).abs < 0.5); };

			lfo1 = lfoValue.value(lfo1Wave, lfo1Beats, lfo1Mode, lfoTrig1) * lfo1Depth.clip(-1, 1);
			lfo2 = lfoValue.value(lfo2Wave, lfo2Beats, lfo2Mode, lfoTrig2) * lfo2Depth.clip(-1, 1);
			// Mod envelope: a full ADSR (was a one-shot AD burst), reusing the shared
			// readerAmpEnv graph so it sustains and releases exactly like the amp and
			// filter envelopes. Retriggered per note where the step's env_reset
			// resolves ON; its gate follows the note length / noteOff, same as the
			// amp env. envMode 0 = ADSR.
			menv = readerAmpEnv.value(0, menvAttack, menvDecay, menvSustain, menvRelease,
				0, menvTrig, menvGateSeconds, 0, menvReleaseTrig) * menvDepth.clip(-1, 1);

			// Stage 1: each macro's effective value = its base knob plus any
			// LFO/mod-env whose dest points at it (indices 6..9), clipped 0..1.
			macroVal = { arg base, macroIdx;
				(base
					+ routed.value(lfo1, lfo1Dest, 5 + macroIdx)
					+ routed.value(lfo2, lfo2Dest, 5 + macroIdx)
					+ routed.value(menv, menvDest, 5 + macroIdx)).clip(0, 1);
			};
			mv1 = macroVal.value(macro1Base, 1);
			mv2 = macroVal.value(macro2Base, 2);
			mv3 = macroVal.value(macro3Base, 3);
			mv4 = macroVal.value(macro4Base, 4);

			// Stage 2: each destination bus sums the direct LFO/env contributions
			// plus every macro's value * that macro's depth to THIS destination
			// (the mod matrix). A zero matrix depth contributes nothing.
			pitchSum = routed.value(lfo1, lfo1Dest, 1) + routed.value(lfo2, lfo2Dest, 1) + routed.value(menv, menvDest, 1)
				+ (mv1 * macro1PitchDepth) + (mv2 * macro2PitchDepth) + (mv3 * macro3PitchDepth) + (mv4 * macro4PitchDepth);
			cutoffSum = routed.value(lfo1, lfo1Dest, 2) + routed.value(lfo2, lfo2Dest, 2) + routed.value(menv, menvDest, 2)
				+ (mv1 * macro1CutoffDepth) + (mv2 * macro2CutoffDepth) + (mv3 * macro3CutoffDepth) + (mv4 * macro4CutoffDepth);
			resSum = routed.value(lfo1, lfo1Dest, 3) + routed.value(lfo2, lfo2Dest, 3) + routed.value(menv, menvDest, 3)
				+ (mv1 * macro1ResDepth) + (mv2 * macro2ResDepth) + (mv3 * macro3ResDepth) + (mv4 * macro4ResDepth);
			ampSum = routed.value(lfo1, lfo1Dest, 4) + routed.value(lfo2, lfo2Dest, 4) + routed.value(menv, menvDest, 4)
				+ (mv1 * macro1AmpDepth) + (mv2 * macro2AmpDepth) + (mv3 * macro3AmpDepth) + (mv4 * macro4AmpDepth);
			panSum = routed.value(lfo1, lfo1Dest, 5) + routed.value(lfo2, lfo2Dest, 5) + routed.value(menv, menvDest, 5)
				+ (mv1 * macro1PanDepth) + (mv2 * macro2PanDepth) + (mv3 * macro3PanDepth) + (mv4 * macro4PanDepth);

			Out.kr(pitchOut, pitchSum);
			Out.kr(cutoffOut, cutoffSum);
			Out.kr(resOut, resSum);
			Out.kr(ampOut, ampSum);
			Out.kr(panOut, panSum);

			// Report the live modulation to the script at ~15Hz -- the norns
			// screen's own refresh rate, so the UI's "actual value" bars and the
			// filter render can follow the modulation without oversampling it.
			// Phase 2: every track runs its own mod synth, so the replyID says
			// WHICH track is reporting and the script keeps only the selected
			// track's stream (8 undifferentiated streams would both flood OSC
			// and paint another track's modulation onto this track's page).
			SendReply.kr(Impulse.kr(15), '/elasticat/modRaw',
				[pitchSum, cutoffSum, resSum, ampSum, panSum], replyID: trackIndex);
		}).add;
	}

	addDirectReaderDef { arg synthName, modeId;
		SynthDef(synthName, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, speed=1, direction=1,
			targetBpm=120, derivedSourceBpm=120, loopBeats=4, startPoint=0, endPoint=128,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, trackIndex=1;
			var phase, frames, sourcePhase, pos, sig, modeGain, playGate, pitchRatio, startNorm, range, nativeIncrement;
			var ampEnv;
			// --- Task 2 (PRD S8): tempo_varispeed pitch -- extra vars for the
			// modeId==1 branch below.
			var varispeedCyclesPerSecond, pitchDrift;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.03125, 32);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			if(modeId == 0, {
				nativeIncrement = (BufRateScale.kr(bufL) * speed.max(0.03125) * pitchRatio) / (frames * range).max(1);
				phase = Phasor.ar(Changed.kr(resetTrig), nativeIncrement * playing.clip(0, 1), 0, 1, resetPos.clip(0, 0.999999));
			}, {
				phase = In.ar(phaseBus, 1);
				// --- Task 2 (PRD S8): tempo_varispeed pitch -------------------------
				// modeId 1 (tempo_varispeed) used to ignore `pitch` entirely -- it just
				// read the shared transport phase bus verbatim. Varispeed couples pitch
				// and speed by nature, so `pitch` now adds a rate *offset* on top of the
				// tempo-following bus rate (same cyclesPerSecond formula elasticatTransport
				// uses), scaled by (pitchRatio - 1) so pitch==0 contributes exactly zero
				// drift -- this mode is unchanged at its default. The loop still resets on
				// the shared clock's reset points (resetTrig/resetPos, same as the bus), so
				// a pitched loop still starts each cycle in the right place; only its rate
				// through the buffer, once running, is nudged by pitch -- the same
				// principle as nudging a tape deck's speed control while it's synced to a
				// clock. Because this only offsets from the bus phase (rather than
				// replacing it with an independent Phasor), it also keeps the bus's own
				// drift `correction` term for free.
				if(modeId == 1, {
					varispeedCyclesPerSecond = (targetBpm.max(1) / 60) / loopBeats.max(0.03125);
					pitchDrift = Sweep.ar(
						Changed.kr(resetTrig),
						varispeedCyclesPerSecond * (pitchRatio - 1) * playing.clip(0, 1)
					);
					phase = (phase + pitchDrift).wrap(0, 1);
				});
				// --- end Task 2 block ------------------------------------------------
			});
			sourcePhase = Select.ar(direction >= 0, [1 - phase, phase]);
			if(modeId == 0, {
				sourcePhase = sourcePhase.wrap(0, 1);
			}, {
				sourcePhase = sourcePhase.wrap(0, 1);
			});
			sourcePhase = (startNorm + (sourcePhase * range)).clip(0, 0.999999);
			pos = sourcePhase * (frames - 1);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(30), cmdName: '/elasticat/statusRaw', values: [
				modeId, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;
	}

	// =======================================================================
	// Command surface
	// =======================================================================
	// EVERY per-track command takes the 1-based track index as its first
	// argument (docs/PHASE2_CONTRACT.md). There are NO un-prefixed aliases:
	// anything still calling a global parameter command is a bug, not a
	// fallback. Only genuinely global things (send FX, master FX, tempo,
	// sample pool, active track count) keep un-prefixed commands.
	//
	// The ~50 plain value setters are NOT hand-written: they are generated
	// from ElasticatTrack.setSpec, so adding a per-track parameter is one
	// spec row and nothing else.
	installCommands {
		var aliases;

		// --- Generated: \tr<UpperCamelField> (track, value) per spec row ----
		ElasticatTrack.setSpec.keysDo({ arg field;
			var spec, name, format;
			spec = ElasticatTrack.setSpec[field];
			name = this.trCommandName(field);
			format = if(spec[\int] == true, { "ii" }, { "if" });
			this.addCommand(name, format, { arg msg;
				var tr;
				tr = this.track(msg[1]);
				if(tr.notNil, { tr.set(field, msg[2]); });
			});
		});

		// Legacy spellings the script still derives mechanically from its own
		// param spec ("grainDensity" -> \trGrainDensity). One table; each row
		// forwards to the same spec field as the generated command above.
		aliases = [
			[\trGrainDensity, \grainOverlap],
			[\trDelayTime, \delayBeats],
			[\trLfo1Speed, \lfo1Beats],
			[\trLfo2Speed, \lfo2Beats],
			[\trChopLoopMode, \chopMode],
			[\trModeMacro, \macro],
			[\trSetEnvMode, \envMode],
			[\trSetPortamento, \portamento],
			[\trSetSpeed, \speed],
			[\trSetSendTap, \sendTap]
		];
		aliases.do({ arg pair;
			var name, field, spec, format;
			name = pair[0];
			field = pair[1];
			spec = ElasticatTrack.setSpec[field];
			format = if(spec[\int] == true, { "ii" }, { "if" });
			this.addCommand(name, format, { arg msg;
				var tr;
				tr = this.track(msg[1]);
				if(tr.notNil, { tr.set(field, msg[2]); });
			});
		});

		// --- Per-track commands whose logic is genuinely non-trivial --------
		// amp is mute-gated at the filter stage; mute gates both stages.
		this.addCommand(\trAmp, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setAmp(msg[2]); });
		});
		this.addCommand(\trMute, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setMute(msg[2]); });
		});
		// Machine selects respawn a synth.
		this.addCommand(\trFilterMachine, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setFilterMachine(msg[2]); });
		});
		this.addCommand(\trSetFilterMachine, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setFilterMachine(msg[2]); });
		});
		this.addCommand(\trFxInsertMachine, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setInsertMachine(msg[2]); });
		});
		this.addCommand(\trSetInsertMachine, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setInsertMachine(msg[2]); });
		});
		this.addCommand(\trSetMachine, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { this.setTrackMachine(tr, msg[2]); });
		});
		this.addCommand(\trSetMode, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { this.setTrackMachine(tr, msg[2]); });
		});
		// Indexed mod-matrix forms.
		this.addCommand(\trMacroBase, "iif", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setMacroBase(msg[2], msg[3]); });
		});
		this.addCommand(\trMacroDepth, "iiif", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, { tr.setMacroDepth(msg[2], msg[3], msg[4]); });
		});
		this.addCommand(\trModTrig, "iii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.modTrig(msg[2], msg[3]); });
		});
		// Transport.
		this.addCommand(\trPlay, "ii", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, {
				tr.setPlay(msg[2]);
				if(tr.index == 1, {
					scriptAddress.sendBundle(0, ["/elasticat/play", tr.playing]);
				});
			});
		});
		this.addCommand(\trPlayhead, "if", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, {
				tr.setPlayhead(msg[2]);
				if(tr.index == 1, {
					lastPhase = tr.lastPhase;
					scriptAddress.sendBundle(0, ["/elasticat/reset", tr.lastPhase]);
				});
			});
		});
		this.addCommand(\trReverse, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setReverse(msg[2]); });
		});
		this.addCommand(\trSetReverse, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setReverse(msg[2]); });
		});
		this.addCommand(\trLoopStart, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setLoopStart(msg[2]); });
		});
		this.addCommand(\trLoopEnd, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setLoopEnd(msg[2]); });
		});
		this.addCommand(\trLoopRegionPlayhead, "ifff", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, {
				tr.setLoopRegionPlayhead(msg[2], msg[3], msg[4]);
				if(tr.index == 1, {
					lastPhase = tr.lastPhase;
					scriptAddress.sendBundle(0, ["/elasticat/reset", tr.lastPhase]);
				});
			});
		});
		this.addCommand(\trSampleSteps, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setSampleSteps(msg[2]); });
		});
		this.addCommand(\trSetSampleSteps, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setSampleSteps(msg[2]); });
		});
		this.addCommand(\trLoopBeats, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setSampleSteps(msg[2] * 4); });
		});
		this.addCommand(\trSourceBpm, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.setSourceBpm(msg[2]); });
		});
		// chop steps -> beats (/4), the one unit conversion the script relies on.
		this.addCommand(\trChopSteps, "if", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, { tr.set(\chopBeats, msg[2].max(0.03125) / 4); });
		});
		// Sample pool binding (the pool itself is shared and global).
		this.addCommand(\trSampleSlot, "ii", { arg msg; this.setTrackSampleSlot(msg[1], msg[2]); });
		this.addCommand(\trSetSampleSlot, "ii", { arg msg; this.setTrackSampleSlot(msg[1], msg[2]); });
		this.addCommand(\trLoadPoolSlot, "iis", { arg msg; this.loadPoolSlot(msg[2], msg[3]); });
		// Notes.
		this.addCommand(\trNoteOn, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.noteOn(msg[2]); });
		});
		this.addCommand(\trNoteOff, "i", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.noteOff; });
		});
		this.addCommand(\trRetrigNote, "if", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.retrigNote(msg[2]); });
		});
		// Slice voices. \trSliceTrigger is the contract name; \trTriggerSlice
		// is what the script's mechanical tr-name derivation produces from its
		// "triggerSlice" spec entry -- both land on the same method.
		this.addCommand(\trSliceTrigger, "iiffiifff", { arg msg;
			this.trackTriggerSlice(msg);
		});
		this.addCommand(\trTriggerSlice, "iiffiifff", { arg msg;
			this.trackTriggerSlice(msg);
		});
		this.addCommand(\trReleaseSlice, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.releaseSlice(msg[2]); });
		});
		this.addCommand(\trReleaseAllSlices, "i", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.releaseAllSlices; });
		});
		// Generic warp-param escape hatch (live set only, same as before).
		this.addCommand(\trModeParam, "isf", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, { tr.setReader(msg[2].asSymbol, msg[3]); });
		});
		// Engine-wide slice/loop settings the script still addresses per track.
		// They apply globally; accepting the index keeps the script's uniform
		// tr_call path working instead of forcing a special case up there.
		this.addCommand(\trSliceAttack, "if", { arg msg; sliceAttack = msg[2].clip(0.0001, 0.2); });
		this.addCommand(\trSliceRelease, "if", { arg msg; sliceRelease = msg[2].clip(0.0001, 0.5); });
		this.addCommand(\trSetSliceMono, "ii", { arg msg; sliceMono = msg[2].asInteger.clip(0, 1); });
		this.addCommand(\trSetSliceSyncToClock, "ii", { arg msg; sliceSyncToClock = msg[2].asInteger.clip(0, 1); });
		this.addCommand(\trSetSliceRate, "if", { arg msg; sliceRate = msg[2].clip(0.03125, 16); });
		this.addCommand(\trXfade, "if", { arg msg; loopXfade = msg[2].clip(0, 0.25); });

		// --- Genuinely global commands --------------------------------------
		this.addCommand(\activeTrackCount, "i", { arg msg; this.setActiveTrackCount(msg[1]); });
		// Which track's mod / filter-env stream the script receives.
		this.addCommand(\uiTrack, "i", { arg msg; uiTrack = msg[1].asInteger.clip(1, 8); });
		this.addCommand(\maxSliceVoices, "i", { arg msg;
			maxSliceVoices = msg[1].asInteger.clip(1, 64);
		});

		// Sample pool (shared by every track).
		this.addCommand(\loadSample, "s", { arg msg; this.loadSample(msg[1]); });
		this.addCommand(\loadPoolSlot, "is", { arg msg; this.loadPoolSlot(msg[1], msg[2]); });
		this.addCommand(\clearPoolSlot, "i", { arg msg; this.clearPoolSlot(msg[1]); });
		this.addCommand(\previewSlot, "iffff", { arg msg;
			this.previewSlot(msg[1], msg[2], msg[3], msg[4], msg[5]);
		});

		// Whole-engine transport.
		this.addCommand(\stopAndReset, "", { this.stopAndReset; });
		this.addCommand(\stop, "", { this.stopAndReset; });
		this.addCommand(\reset, "", { this.resetAll; });
		this.addCommand(\syncClock, "ffi", { arg msg; this.syncClock(msg[1], msg[2], msg[3]); });
		this.addCommand(\targetBpm, "f", { arg msg;
			targetBpm = msg[1].max(1);
			this.updateTransport;
		});

		// Script-side echoes / engine settings.
		this.addCommand(\setModeProfile, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/profile", msg[1].asInteger]);
		});
		this.addCommand(\setModeSwitchFade, "f", { arg msg; modeSwitchFade = msg[1].clip(0.001, 0.25); });
		this.addCommand(\setModeSwitchQuantization, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/switchQuantization", msg[1].asInteger]);
		});
		this.addCommand(\setLoopPreview, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/loopPreview", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\commitLoop, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/commitLoopPending", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\xfade, "f", { arg msg; loopXfade = msg[1].clip(0, 0.25); });
		this.addCommand(\requestStatus, "", { this.sendStatus; });
		this.addCommand(\setDebug, "i", { arg msg; debugLevel = msg[1].asInteger.clip(0, 3); });
		this.addCommand(\sliceAttack, "f", { arg msg; sliceAttack = msg[1].clip(0.0001, 0.2); });
		this.addCommand(\sliceRelease, "f", { arg msg; sliceRelease = msg[1].clip(0.0001, 0.5); });
		this.addCommand(\setSliceMono, "i", { arg msg; sliceMono = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceSyncToClock, "i", { arg msg; sliceSyncToClock = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceRate, "f", { arg msg; sliceRate = msg[1].clip(0.03125, 16); });

		// Send 1/2 + master insert FX (global; PRD SS3/SS8).
		this.addCommand(\setSendTap, "i", { arg msg;
			// Legacy no-track spelling of a now per-track setting: apply to the
			// UI-selected track so an un-migrated caller still does something
			// sane rather than silently vanishing.
			this.uiTrackObj.set(\sendTap, msg[1]);
		});
		this.addCommand(\setSend1Machine, "i", { arg msg; this.setSend1Machine(msg[1]); });
		this.addCommand(\send1FxDrive, "f", { arg msg; sendFxDrive[0] = msg[1].clip(0, 1); this.setSend1(\drive, sendFxDrive[0]); });
		this.addCommand(\send1FxMix, "f", { arg msg; sendFxMix[0] = msg[1].clip(0, 1); this.setSend1(\mix, sendFxMix[0]); });
		this.addCommand(\send1DelayTime, "f", { arg msg; sendFxDelayBeats[0] = msg[1].clip(0.03125, 8); this.setSend1(\delayBeats, sendFxDelayBeats[0]); });
		this.addCommand(\send1DelayFeedback, "f", { arg msg; sendFxDelayFeedback[0] = msg[1].clip(0, 1); this.setSend1(\delayFeedback, sendFxDelayFeedback[0]); });
		this.addCommand(\send1DelayTone, "f", { arg msg; sendFxDelayTone[0] = msg[1].clip(0, 1); this.setSend1(\delayTone, sendFxDelayTone[0]); });
		this.addCommand(\send1ReverbSize, "f", { arg msg; sendFxReverbSize[0] = msg[1].clip(0, 1); this.setSend1(\reverbSize, sendFxReverbSize[0]); });
		this.addCommand(\send1ReverbDamp, "f", { arg msg; sendFxReverbDamp[0] = msg[1].clip(0, 1); this.setSend1(\reverbDamp, sendFxReverbDamp[0]); });
		this.addCommand(\send1LofiBits, "f", { arg msg; sendFxLofiBits[0] = msg[1].clip(1, 24); this.setSend1(\lofiBits, sendFxLofiBits[0]); });
		this.addCommand(\send1LofiRate, "f", { arg msg; sendFxLofiRate[0] = msg[1].clip(500, 48000); this.setSend1(\lofiRate, sendFxLofiRate[0]); });

		this.addCommand(\setSend2Machine, "i", { arg msg; this.setSend2Machine(msg[1]); });
		this.addCommand(\send2FxDrive, "f", { arg msg; sendFxDrive[1] = msg[1].clip(0, 1); this.setSend2(\drive, sendFxDrive[1]); });
		this.addCommand(\send2FxMix, "f", { arg msg; sendFxMix[1] = msg[1].clip(0, 1); this.setSend2(\mix, sendFxMix[1]); });
		this.addCommand(\send2DelayTime, "f", { arg msg; sendFxDelayBeats[1] = msg[1].clip(0.03125, 8); this.setSend2(\delayBeats, sendFxDelayBeats[1]); });
		this.addCommand(\send2DelayFeedback, "f", { arg msg; sendFxDelayFeedback[1] = msg[1].clip(0, 1); this.setSend2(\delayFeedback, sendFxDelayFeedback[1]); });
		this.addCommand(\send2DelayTone, "f", { arg msg; sendFxDelayTone[1] = msg[1].clip(0, 1); this.setSend2(\delayTone, sendFxDelayTone[1]); });
		this.addCommand(\send2ReverbSize, "f", { arg msg; sendFxReverbSize[1] = msg[1].clip(0, 1); this.setSend2(\reverbSize, sendFxReverbSize[1]); });
		this.addCommand(\send2ReverbDamp, "f", { arg msg; sendFxReverbDamp[1] = msg[1].clip(0, 1); this.setSend2(\reverbDamp, sendFxReverbDamp[1]); });
		this.addCommand(\send2LofiBits, "f", { arg msg; sendFxLofiBits[1] = msg[1].clip(1, 24); this.setSend2(\lofiBits, sendFxLofiBits[1]); });
		this.addCommand(\send2LofiRate, "f", { arg msg; sendFxLofiRate[1] = msg[1].clip(500, 48000); this.setSend2(\lofiRate, sendFxLofiRate[1]); });

		this.addCommand(\setMasterMachine, "i", { arg msg; this.setMasterMachine(msg[1]); });
		this.addCommand(\masterFxDrive, "f", { arg msg; sendFxDrive[2] = msg[1].clip(0, 1); this.setMasterFx(\drive, sendFxDrive[2]); });
		this.addCommand(\masterFxMix, "f", { arg msg; sendFxMix[2] = msg[1].clip(0, 1); this.setMasterFx(\mix, sendFxMix[2]); });
		this.addCommand(\masterDelayTime, "f", { arg msg; sendFxDelayBeats[2] = msg[1].clip(0.03125, 8); this.setMasterFx(\delayBeats, sendFxDelayBeats[2]); });
		this.addCommand(\masterDelayFeedback, "f", { arg msg; sendFxDelayFeedback[2] = msg[1].clip(0, 1); this.setMasterFx(\delayFeedback, sendFxDelayFeedback[2]); });
		this.addCommand(\masterDelayTone, "f", { arg msg; sendFxDelayTone[2] = msg[1].clip(0, 1); this.setMasterFx(\delayTone, sendFxDelayTone[2]); });
		this.addCommand(\masterReverbSize, "f", { arg msg; sendFxReverbSize[2] = msg[1].clip(0, 1); this.setMasterFx(\reverbSize, sendFxReverbSize[2]); });
		this.addCommand(\masterReverbDamp, "f", { arg msg; sendFxReverbDamp[2] = msg[1].clip(0, 1); this.setMasterFx(\reverbDamp, sendFxReverbDamp[2]); });
		this.addCommand(\masterLofiBits, "f", { arg msg; sendFxLofiBits[2] = msg[1].clip(1, 24); this.setMasterFx(\lofiBits, sendFxLofiBits[2]); });
		this.addCommand(\masterLofiRate, "f", { arg msg; sendFxLofiRate[2] = msg[1].clip(500, 48000); this.setMasterFx(\lofiRate, sendFxLofiRate[2]); });
	}

	// field -> \tr<UpperCamelField>, the contract's mechanical naming rule.
	trCommandName { arg field;
		var s;
		s = field.asString;
		^("tr" ++ s.copyRange(0, 0).toUpper ++ s.copyToEnd(1)).asSymbol;
	}

	// The track whose single-track OSC streams (status, mod, filter env, file
	// page) reach the script. Defaults to 1, so an un-migrated script sees
	// exactly what it saw before.
	uiTrackObj { ^this.track(uiTrack) }

	// =======================================================================
	// Track lifecycle + fan-out
	// =======================================================================
	// \activeTrackCount: allocate chains for 1..count, free the rest. The clip
	// guarantees count >= 1, so track 1's chain is never freed -- it is the
	// clock reference -- but it goes through the SAME alloc as every other
	// track. There is no track-1 branch anywhere below.
	setActiveTrackCount { arg count;
		activeTrackCount = count.asInteger.clip(1, 8);
		(1..8).do({ arg t;
			var tr;
			tr = this.track(t);
			if(t <= activeTrackCount, { tr.alloc; }, { tr.free; });
		});
	}

	setTrackMachine { arg tr, modeIndex;
		tr.setMachine(modeIndex);
		if(tr.index == uiTrack, {
			modeSwitchCount = modeSwitchCount + 1;
			scriptAddress.sendBundle(0, [
				"/elasticat/mode", modeNames.wrapAt(tr.machine), tr.machine, modeSwitchCount
			]);
		});
	}

	setTrackSampleSlot { arg track, slot;
		var tr;
		tr = this.track(track);
		if(tr.isNil, { ^nil });
		tr.bindSampleSlot(slot);
		this.reportTrackSlot(tr);
	}

	reportTrackSlot { arg tr;
		scriptAddress.sendBundle(0, [
			"/elasticat/track/slot",
			tr.index,
			tr.sampleSlot,
			tr.loaded,
			tr.sourceFrames,
			tr.sourceRate
		]);
		// The script's file page still listens on the single-track pool
		// stream; feed it from whichever track the UI is showing.
		if(tr.index == uiTrack, {
			if(tr.sampleSlot < 1, {
				scriptAddress.sendBundle(0, ["/elasticat/pool/slot/active", 0, 0, 0, ""]);
			}, {
				if(tr.loaded == 1, {
					scriptAddress.sendBundle(0, [
						"/elasticat/pool/slot/active",
						tr.sampleSlot, tr.sourceFrames, tr.sourceRate,
						poolPaths[tr.sampleSlot - 1]
					]);
				}, {
					scriptAddress.sendBundle(0, ["/elasticat/pool/slot/missing", tr.sampleSlot]);
				});
			});
		});
	}

	// A track whose modulation has just been switched off stops running a mod
	// synth, so its 15Hz /elasticat/mod stream stops too. Send one final all-
	// zero frame so the UI's live "actual value" bars fall back to the base
	// value instead of freezing on the last modulated one.
	reportIdleMod { arg tr;
		if(tr.index == uiTrack, {
			scriptAddress.sendBundle(0, ["/elasticat/mod", 0, 0, 0, 0, 0, tr.index]);
		});
	}

	trackTriggerSlice { arg msg;
		var tr;
		tr = this.track(msg[1]);
		if(tr.isNil, { ^nil });
		tr.triggerSlice(msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8], msg[9]);
	}

	// =======================================================================
	// Global slice voice cap
	// =======================================================================
	// Voices live in their own track's sourceGroup; this list is the only
	// engine-wide bookkeeping -- oldest first, across ALL tracks. 8 tracks x 8
	// voices would cliff the CPU, so hitting the cap steals the oldest voice.
	// The per-track limit (the 32-slot map + slice mono) is untouched.
	registerSliceVoice { arg tr, slot, synth;
		var oldest;
		while({ sliceVoiceOrder.size >= maxSliceVoices }, {
			oldest = sliceVoiceOrder[0];
			sliceVoiceOrder = sliceVoiceOrder.drop(1);
			oldest[\track].stealSlice(oldest[\slot], oldest[\synth]);
		});
		sliceVoiceOrder = sliceVoiceOrder.add((track: tr, slot: slot, synth: synth));
	}

	forgetSliceVoice { arg synth;
		if(synth.isNil, { ^nil });
		sliceVoiceOrder = sliceVoiceOrder.reject({ arg e; e[\synth] === synth });
	}

	forgetSliceVoicesOf { arg tr;
		if(sliceVoiceOrder.isNil, { ^nil });
		sliceVoiceOrder = sliceVoiceOrder.reject({ arg e; e[\track] === tr });
	}

	releaseAllSlices {
		this.activeTracks.do({ arg tr; tr.releaseAllSlices; });
	}

	// =======================================================================
	// Send 1/2 + master insert FX (global; PRD SS3/SS8)
	// =======================================================================
	// Shared arg list for any send/master FX slot -- slotIdx indexes the
	// sendFx* arrays (0 = Send 1, 1 = Send 2, 2 = Master).
	sendFxArgs { arg slotIdx, inBusIndex, outBusIndex;
		^[
			\out, outBusIndex,
			\in, inBusIndex,
			\mix, sendFxMix[slotIdx],
			\drive, sendFxDrive[slotIdx],
			\delayBeats, sendFxDelayBeats[slotIdx],
			\delayFeedback, sendFxDelayFeedback[slotIdx],
			\delayTone, sendFxDelayTone[slotIdx],
			\reverbSize, sendFxReverbSize[slotIdx],
			\reverbDamp, sendFxReverbDamp[slotIdx],
			\lofiBits, sendFxLofiBits[slotIdx],
			\lofiRate, sendFxLofiRate[slotIdx],
			\targetBpm, targetBpm
		];
	}

	spawnSend1 {
		if(send1Synth.notNil, { send1Synth.free; });
		send1Synth = Synth.tail(sendGroup, fxInsertNames.wrapAt(send1Machine.asInteger),
			this.sendFxArgs(0, sendBus1.index, masterBus.index));
		^send1Synth;
	}

	setSend1Machine { arg idx;
		send1Machine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnSend1;
	}

	setSend1 { arg key, value;
		if(send1Synth.notNil, { send1Synth.set(key, value); });
	}

	spawnSend2 {
		if(send2Synth.notNil, { send2Synth.free; });
		send2Synth = Synth.tail(sendGroup, fxInsertNames.wrapAt(send2Machine.asInteger),
			this.sendFxArgs(1, sendBus2.index, masterBus.index));
		^send2Synth;
	}

	setSend2Machine { arg idx;
		send2Machine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnSend2;
	}

	setSend2 { arg key, value;
		if(send2Synth.notNil, { send2Synth.set(key, value); });
	}

	// Master insert: reads masterBus (every track's mix + both send returns,
	// all written by the time masterGroup runs) and is the only thing writing
	// context.out_b.
	spawnMasterFx {
		if(masterSynth.notNil, { masterSynth.free; });
		masterSynth = Synth.tail(masterGroup, fxInsertNames.wrapAt(masterFxMachine.asInteger),
			this.sendFxArgs(2, masterBus.index, context.out_b.index));
		^masterSynth;
	}

	setMasterMachine { arg idx;
		masterFxMachine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnMasterFx;
	}

	setMasterFx { arg key, value;
		if(masterSynth.notNil, { masterSynth.set(key, value); });
	}

	// =======================================================================
	// Global transport / clock
	// =======================================================================
	// The one choke point every tempo change (direct set, clock sync, reset)
	// routes through: push tempo + clock correction to every allocated track,
	// then to the tempo-reading global FX slots.
	updateTransport {
		this.activeTracks.do({ arg tr; tr.pushTempo; });
		this.setSend1(\targetBpm, targetBpm);
		this.setSend2(\targetBpm, targetBpm);
		this.setMasterFx(\targetBpm, targetBpm);
	}

	stopAndReset {
		this.activeTracks.do({ arg tr; tr.setPlay(0); });
		this.updateTransport;
		this.resetAll;
		scriptAddress.sendBundle(0, ["/elasticat/play", 0]);
	}

	resetAll {
		this.activeTracks.do({ arg tr; tr.setPlayhead(0); });
		lastPhase = 0;
		scriptAddress.sendBundle(0, ["/elasticat/reset", 0]);
	}

	// Track 1's loop is the clock reference: one loop has to be, and the
	// transport `correction` derived from it is pushed to EVERY track by
	// updateTransport. This is an engine-level role, not per-track behavior.
	syncClock { arg expectedPhase, tempo, sequence;
		var err, absMs, loopSeconds, reference;
		if(sequence <= lastClockSeq, {
			staleClockCount = staleClockCount + 1;
			^nil;
		});
		reference = this.track(1);
		lastClockSeq = sequence;
		targetBpm = tempo.max(1);
		lastExpectedPhase = expectedPhase.wrap(0, 1);
		err = lastExpectedPhase - lastPhase;
		if(err > 0.5, { err = err - 1; });
		if(err < -0.5, { err = err + 1; });
		loopSeconds = reference.loopBeats * 60 / targetBpm;
		absMs = err.abs * loopSeconds * 1000;
		lastPhaseError = err;
		lastErrorMs = absMs;

		if(err.abs > hardThreshold, {
			correction = 0;
			hardRealignCount = hardRealignCount + 1;
			reference.setPlayhead(lastExpectedPhase);
			lastPhase = reference.lastPhase;
			scriptAddress.sendBundle(0, ["/elasticat/reset", lastPhase]);
		}, {
			if(absMs < 0.5, {
				correction = 0;
			}, {
				correction = (err * 0.5).clip(maxCorrection.neg, maxCorrection);
			});
		});

		this.updateTransport;
	}

	// =======================================================================
	// Shared sample pool
	// =======================================================================
	// The slot the single-track file-page stream reports on.
	activeSampleSlot { ^this.uiTrackObj.sampleSlot }

	loadSample { arg path;
		this.loadPoolSlot(this.activeSampleSlot, path);
	}

	loadPoolSlot { arg slot, path;
		var sf, channels, frames, rate, generation, idx, activeSlot;
		if(path.isNil, { ^nil; });
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		path = path.asString;
		activeSlot = this.activeSampleSlot;
		loadGeneration = loadGeneration + 1;
		generation = loadGeneration;
		poolGenerations[idx] = generation;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/request", slot, path, generation]);
		if(slot == activeSlot, {
			scriptAddress.sendBundle(0, ["/elasticat/load/request", path, generation]);
		});

		sf = SoundFile.openRead(path);
		if(sf.isNil, {
			scriptAddress.sendBundle(0, ["/elasticat/pool/load/failed", slot, path, generation]);
			if(slot == activeSlot, {
				scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
			});
			^nil;
		});
		channels = sf.numChannels;
		frames = sf.numFrames;
		rate = sf.sampleRate;
		sf.close;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/opened", slot, path, channels, frames, rate, generation]);
		if(slot == activeSlot, {
			scriptAddress.sendBundle(0, ["/elasticat/load/opened", path, channels, frames, rate, generation]);
		});

		Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [0], action: {
			arg newL;
			if(generation != poolGenerations[idx], {
				newL.free;
				staleClockCount = staleClockCount + 1;
			}, {
				if(newL.numFrames <= 0, {
					newL.free;
					scriptAddress.sendBundle(0, ["/elasticat/pool/load/failed", slot, path, generation]);
					if(slot == activeSlot, {
						scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
					});
				}, {
					scriptAddress.sendBundle(0, ["/elasticat/pool/load/readDone", slot, 0, newL.numFrames, newL.numChannels, generation]);
					if(slot == activeSlot, {
						scriptAddress.sendBundle(0, ["/elasticat/load/readDone", 0, newL.numFrames, newL.numChannels, generation]);
					});
					if(channels > 1, {
						Buffer.readChannel(server: context.server, path: path, startFrame: 0, numFrames: -1, channels: [1], action: {
							arg newR;
							if(generation != poolGenerations[idx], {
								newL.free;
								newR.free;
							}, {
								scriptAddress.sendBundle(0, ["/elasticat/pool/load/readDone", slot, 1, newR.numFrames, newR.numChannels, generation]);
								if(slot == activeSlot, {
									scriptAddress.sendBundle(0, ["/elasticat/load/readDone", 1, newR.numFrames, newR.numChannels, generation]);
								});
								this.installPoolBuffers(slot, newL, newR, path, frames, rate, generation);
							});
						});
					}, {
						this.installPoolBuffers(slot, newL, newL, path, frames, rate, generation);
					});
				});
			});
		});
	}

	installPoolBuffers { arg slot, newL, newR, path, frames, rate, generation;
		var idx, oldL, oldR, ui;
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		if(generation != poolGenerations[idx], {
			newL.free;
			if(newR != newL, { newR.free; });
			^nil;
		});

		oldL = poolBufL[idx];
		oldR = poolBufR[idx];
		poolBufL[idx] = newL;
		poolBufR[idx] = newR;
		poolPaths[idx] = path;
		poolLoaded[idx] = 1;
		poolFrames[idx] = frames;
		poolRates[idx] = rate;

		// Repoint EVERY track sitting on this slot at the freshly installed
		// buffers, BEFORE the old ones are freed below. Downstream of the
		// generation check, so all tracks obey the same stale-load protection.
		(1..8).do({ arg t;
			var tr;
			tr = tracks[t];
			if(tr.notNil and: { tr.sampleSlot == slot }, {
				this.setTrackSampleSlot(t, slot);
			});
		});

		ui = this.uiTrackObj;
		if(slot == ui.sampleSlot, {
			scriptAddress.sendBundle(0, [
				"/elasticat/load/installed",
				newL.bufnum,
				newR.bufnum,
				newL.numFrames,
				newL.sampleRate,
				ui.derivedSourceBpm,
				generation
			]);
		});

		scriptAddress.sendBundle(0, [
			"/elasticat/pool/load/installed",
			slot,
			newL.bufnum,
			newR.bufnum,
			newL.numFrames,
			newL.sampleRate,
			generation
		]);

		if(oldL.notNil, { oldL.free; });
		if(oldR.notNil and: { oldR != oldL }, { oldR.free; });
	}

	// Unload a pool slot's buffer entirely (New Project / a project load that
	// omits this slot). Without this the server kept the last-loaded buffer, so
	// an emptied ACTIVE slot kept looping the previous sample on play. Bumps the
	// slot's generation so any in-flight async load lands stale (freed by
	// installPoolBuffers' generation check) instead of resurrecting the slot.
	clearPoolSlot { arg slot;
		var idx, oldL, oldR;
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		loadGeneration = loadGeneration + 1;
		poolGenerations[idx] = loadGeneration;
		oldL = poolBufL[idx];
		oldR = poolBufR[idx];
		poolBufL[idx] = nil;
		poolBufR[idx] = nil;
		poolPaths[idx] = "";
		poolLoaded[idx] = 0;
		poolFrames[idx] = 4;
		poolRates[idx] = 48000;
		// Every track on this slot must let go of the buffers BEFORE they are
		// freed below (bindSampleSlot sees poolLoaded == 0 and swaps in the
		// default silent buffers).
		(1..8).do({ arg t;
			var tr;
			tr = tracks[t];
			if(tr.notNil and: { tr.sampleSlot == slot }, {
				this.setTrackSampleSlot(t, slot);
			});
		});
		if(oldL.notNil, { oldL.free; });
		if(oldR.notNil and: { oldR != oldL }, { oldR.free; });
	}

	previewSlot { arg slot, startFrac, endFrac, gain, on;
		var idx;
		if(previewSynth.notNil, {
			previewSynth.set(\gate, 0);
			previewSynth = nil;
		});
		slot = slot.asInteger;
		idx = slot.clip(1, poolSize) - 1;
		if(on > 0.5 and: { slot >= 1 } and: { poolLoaded[idx] == 1 } and: { poolBufL[idx].notNil }, {
			previewSynth = Synth.tail(context.xg, \elasticatPreview, [
				\out, context.out_b.index,
				\bufL, poolBufL[idx].bufnum,
				\bufR, (poolBufR[idx] ? poolBufL[idx]).bufnum,
				\startFrac, startFrac.clip(0, 0.999),
				\endFrac, endFrac.clip(0.001, 1),
				\gain, gain.max(0)
			]);
		});
	}

	sendStatus {
		var ui;
		ui = this.uiTrackObj;
		scriptAddress.sendBundle(0, [
			"/elasticat/requestedStatus",
			ui.loaded,
			ui.playing,
			modeNames.wrapAt(ui.machine),
			ui.lastPhase,
			ui.sourceFrames,
			ui.sourceRate,
			targetBpm,
			ui.derivedSourceBpm,
			correction,
			lastPhaseError,
			lastErrorMs,
			modeSwitchCount,
			failedModeSwitchCount,
			hardRealignCount,
			staleClockCount,
			loadGeneration
		]);
	}

	free {
		this.releaseAllSlices;
		if(statusResponder.notNil, { statusResponder.free; });
		if(modResponder.notNil, { modResponder.free; });
		if(filterEnvResponder.notNil, { filterEnvResponder.free; });
		if(transportResponder.notNil, { transportResponder.free; });
		if(previewSynth.notNil, { previewSynth.free; });
		if(send1Synth.notNil, { send1Synth.free; });
		if(send2Synth.notNil, { send2Synth.free; });
		if(masterSynth.notNil, { masterSynth.free; });
		// One teardown path for all 8 tracks; freeing a track's group frees
		// every synth in its chain, and freeNow releases all nine of its busses.
		if(tracks.notNil, {
			(1..8).do({ arg t;
				if(tracks[t].notNil, { tracks[t].freeNow; });
			});
		});
		if(tracksGroup.notNil, { tracksGroup.free; });
		if(masterGroup.notNil, { masterGroup.free; });
		if(sendGroup.notNil, { sendGroup.free; });
		if(poolBufL.notNil, {
			poolBufL.do({ arg buffer, i;
				if(buffer.notNil, { buffer.free; });
				if(poolBufR[i].notNil and: { poolBufR[i] != buffer }, { poolBufR[i].free; });
			});
		});
		if(defaultBufL.notNil, { defaultBufL.free; });
		if(defaultBufR.notNil and: { defaultBufR != defaultBufL }, { defaultBufR.free; });
		if(masterBus.notNil, { masterBus.free; });
		if(sendBus1.notNil, { sendBus1.free; });
		if(sendBus2.notNil, { sendBus2.free; });
	}
}

// ============================================================================
// ElasticatTrack -- one class, one instance per track, no bespoke per-track
// behavior anywhere (docs/PHASE2_CONTRACT.md).
//
// Defined in THIS file on purpose: the norns crone loader only discovers one
// Engine_* class file, and companion class files have never been verified on
// the device -- a companion that fails to load takes the whole class library
// (and therefore the script) down. SuperCollider is happy with several class
// definitions per file, so this costs nothing.
//
// Node graph, identical for all 8 tracks:
//
//   group
//     sourceGroup { mod (kr) -> transport -> reader -> slice voices } -> fxBus
//     filter     fxBus     -> insertBus   (ALSO the amp/pan/mod output stage)
//     insert FX  insertBus -> mixBus      (NO synth at all when machine None)
//     sendTap    insertBus | mixBus       -> sendBus1 / sendBus2 (global)
//     trackMix   insertBus | mixBus       -> masterBus (mute + teardown fade)
//
// Two invariants that are easy to get wrong:
//   1. amp/pan live on the FILTER synth, never the mix synth -- filterModOut
//      applies the AMP/PAN mod destinations there, so a track's own LFO can
//      only reach them at the filter. The mix synth stays at unity; applying
//      amp in both places would square the gain.
//   2. Insert machine None spawns NO synth; postInsertBus re-points the send
//      tap and the mix synth at insertBus instead. Re-point on every change.
// ============================================================================
ElasticatTrack {
	// One spec table drives every plain value setter: field -> which synth arg
	// it maps to, on which synth, and its range. Adding a per-track parameter
	// is one row here plus one addCommand line -- never eight copies of
	// anything. Bespoke methods exist ONLY where the logic is genuinely
	// non-trivial (machine respawns, mute gating, indexed macros).
	classvar <setSpec;
	classvar <macroDestNames;

	var <engine;     // back-reference: server, groups, global busses, defs, tempo
	var <index;      // 1-based track number; also every SendReply's replyID

	// --- transport / reader state -------------------------------------------
	var <machine = 0, <playing = 0, <muted = 0;
	var <sampleSlot = 1, <loaded = 0, <bufL, <bufR;
	var <sourceFrames = 4, <sourceRate = 48000, <derivedSourceBpm = 120;
	var <sampleSteps = 16, <loopStart = 0, <loopEnd = 128;
	var <pitch = 0, <speed = 1, <direction = 1, <amp = 0.8, <pan = 0, <macro = 0;
	var <envMode = 1, <envAttack = 0.0001, <envDecay = 0.15, <envSustain = 0.8;
	var <envRelease = 0.0001, <envHold = 1000000;
	// Crossfade duration used when this track swaps warp machine. Per-track
	// (the script registers it per track), and state-only: there is no synth
	// arg to push, spawnMode reads it at swap time.
	var <modeSwitchFade = 0.05;
	// Smoothing time for the filter stage (cutoff / res / morph / pan / amp).
	//
	// 0.09s is deliberately just OVER the script send interval (1/12 s =
	// 0.083s). Every one of these params is `queue = true`, so its value
	// arrives on the 12Hz coalescing queue whether it came from a crossfader
	// morph or a deliberate encoder turn. With the old 0.01-0.02s lag the
	// value settled in 10-20ms and then sat still for ~70ms: a STAIRCASE,
	// which is worse than either a zipper or smooth motion. Smoothing must be
	// at least the send interval for the motion to be continuous.
	//
	// There is no "snappy manual vs smooth morph" trade-off to make here --
	// both paths are already rate-limited by the same queue, so one value
	// serves both. \trFilterSlew exists to override it per track if a future
	// path ever sends faster.
	var <filterSlew = 0.09;
	var <envTrigCount = 0, <envNoteSeconds = 0.5, <noteOffTrigCount = 0, <portamento = 0;
	var <resetCount = 0, <lastPhase = 0;

	// --- warp machine params (seeded on every reader respawn) ---------------
	var <chopBeats = 0.25, <chopMode = 0;
	var <chopAttack = 0.002, <chopHold = 0.04, <chopRelease = 0.01;
	var <grainSize = 0.08, <grainOverlap = 8, <grainJitter = 0;
	var <wsolaWindow = 0.1, <wsolaSearch = 0.03;
	var <pvWindow = 0.2, <pvDispersion = 0;

	// --- filter + filter envelope -------------------------------------------
	var <filterMachine = 0, <filterType = 0, <filterCutoff = 20000;
	var <filterRes = 0, <filterDrive = 0, <filterMorph = 0, <filterBalance = 0;
	var <filterEnvMode = 1, <filterEnvAttack = 0.0001, <filterEnvDecay = 0.15;
	var <filterEnvSustain = 0.8, <filterEnvRelease = 0.0001, <filterEnvHold = 1000000;
	var <filterEnvDepth = 0;

	// --- insert FX -----------------------------------------------------------
	var <fxInsertMachine = 0, <fxDrive = 0, <fxMix = 0.5;
	var <delayBeats = 1, <delayFeedback = 0.3, <delayTone = 1;
	var <reverbSize = 0.5, <reverbDamp = 0.5, <lofiBits = 24, <lofiRate = 48000;

	// --- send levels into the two GLOBAL send busses ------------------------
	var <sendTap = 0, <sendLevel1 = 0, <sendLevel2 = 0;

	// --- mod: 2 LFOs + mod env + 4 macros (base + 4x5 depth matrix) ---------
	var <lfo1Dest = 0, <lfo1Wave = 0, <lfo1Beats = 4, <lfo1Depth = 0, <lfo1Mode = 0;
	var <lfo2Dest = 0, <lfo2Wave = 0, <lfo2Beats = 4, <lfo2Depth = 0, <lfo2Mode = 0;
	var <menvDest = 0, <menvAttack = 0.01, <menvDecay = 0.15;
	var <menvSustain = 0.8, <menvRelease = 0.15, <menvDepth = 0;
	var <lfoTrigCount = 0, <menvTrigCount = 0;
	var <macroBase, <macroMatrix;
	var badIndexedWarned;   // warn-once set for malformed indexed commands

	// --- nodes / busses (nil while the chain is not allocated) --------------
	var <group, <sourceGroup;
	var <phaseBus, <fxBus, <insertBus, <mixBus;
	var <modBusPitch, <modBusCutoff, <modBusRes, <modBusAmp, <modBusPan;
	var <transportSynth, <modSynth, <activeSynth;
	var <filterSynth, <insertSynth, <sendTapSynth, <mixSynth;
	var <sliceVoices;

	*initClass {
		macroDestNames = [\Pitch, \Cutoff, \Res, \Amp, \Pan];
		// field -> (arg: synth-arg name(s), synth: which synth, lo:, hi:, int:)
		// `synth` is resolved by synthFor below. `arg` may be an Array when one
		// field drives several synth args.
		setSpec = IdentityDictionary[
			// reader / voice
			\pitch        -> (arg: \pitch,        synth: \reader, lo: -24, hi: 24),
			\speed        -> (arg: \speed,        synth: \reader, lo: 0.03125, hi: 8),
			\macro        -> (arg: \macro,        synth: \reader, lo: 0, hi: 1),
			\portamento   -> (arg: \portamento,   synth: \reader, lo: 0, hi: 1, int: true),
			\envMode      -> (arg: \envMode,      synth: \reader, lo: 0, hi: 1, int: true),
			\envAttack    -> (arg: \envAttack,    synth: \reader, lo: 0),
			\envDecay     -> (arg: \envDecay,     synth: \reader, lo: 0),
			\envSustain   -> (arg: \envSustain,   synth: \reader, lo: 0, hi: 1),
			\envRelease   -> (arg: \envRelease,   synth: \reader, lo: 0),
			\envHold      -> (arg: \envHold,      synth: \reader, lo: 0),
			// State-only: synthFor(\state) is nil, so set() stores the value and
			// pushes nothing. spawnMode reads it when this track swaps machine.
			// The script registers mode_switch_fade per track, so without this
			// row every edit derived \trModeSwitchFade, found no command, and
			// was silently dropped.
			\modeSwitchFade -> (arg: \fadeTime, synth: \state, lo: 0.001, hi: 0.25),
			\filterSlew   -> (arg: \slew,     synth: \filter, lo: 0.001, hi: 0.5),
			// warp machine params. wsola* deliberately alias the RandomOla
			// reader's \grainSize / \wander args (see warpArgs).
			\chopBeats    -> (arg: \chopBeats,    synth: \reader, lo: 0.03125),
			\chopMode     -> (arg: \chopMode,     synth: \reader, lo: 0, hi: 2, int: true),
			\chopAttack   -> (arg: \chopAttack,   synth: \reader, lo: 0.0001),
			\chopHold     -> (arg: \chopHold,     synth: \reader, lo: 0),
			\chopRelease  -> (arg: \chopRelease,  synth: \reader, lo: 0.0001),
			\grainSize    -> (arg: \grainSize,    synth: \reader, lo: 0.002, hi: 0.5),
			\grainOverlap -> (arg: \grainOverlap, synth: \reader, lo: 1, hi: 64),
			\grainJitter  -> (arg: [\grainJitter, \grainSpray], synth: \reader, lo: 0, hi: 0.25),
			\wsolaWindow  -> (arg: \grainSize,    synth: \reader, lo: 0.005, hi: 0.5),
			\wsolaSearch  -> (arg: \wander,       synth: \reader, lo: 0, hi: 0.1),
			\pvWindow     -> (arg: \pvWindow,     synth: \reader, lo: 0.005, hi: 2),
			\pvDispersion -> (arg: \pvDispersion, synth: \reader, lo: 0, hi: 1),
			// filter stage (also the amp/pan output stage -- see setAmp)
			\pan              -> (arg: \pan,        synth: \filter, lo: -1, hi: 1),
			\filterType       -> (arg: \filterType, synth: \filter, lo: 0, hi: 3, int: true),
			\filterCutoff     -> (arg: \cutoff,     synth: \filter, lo: 20, hi: 20000),
			\filterRes        -> (arg: \res,        synth: \filter, lo: 0, hi: 1),
			\filterDrive      -> (arg: \drive,      synth: \filter, lo: 0, hi: 1),
			\filterMorph      -> (arg: \morph,      synth: \filter, lo: 0, hi: 1),
			\filterBalance    -> (arg: \balance,    synth: \filter, lo: -1, hi: 1),
			\filterEnvMode    -> (arg: \envMode,    synth: \filter, lo: 0, hi: 1, int: true),
			\filterEnvAttack  -> (arg: \envAttack,  synth: \filter, lo: 0),
			\filterEnvDecay   -> (arg: \envDecay,   synth: \filter, lo: 0),
			\filterEnvSustain -> (arg: \envSustain, synth: \filter, lo: 0, hi: 1),
			\filterEnvRelease -> (arg: \envRelease, synth: \filter, lo: 0),
			\filterEnvHold    -> (arg: \envHold,    synth: \filter, lo: 0),
			\filterEnvDepth   -> (arg: \envDepth,   synth: \filter, lo: -1, hi: 1),
			// insert FX
			\fxDrive       -> (arg: \drive,         synth: \insert, lo: 0, hi: 1),
			\fxMix         -> (arg: \mix,           synth: \insert, lo: 0, hi: 1),
			\delayBeats    -> (arg: \delayBeats,    synth: \insert, lo: 0.03125, hi: 8),
			\delayFeedback -> (arg: \delayFeedback, synth: \insert, lo: 0, hi: 1),
			\delayTone     -> (arg: \delayTone,     synth: \insert, lo: 0, hi: 1),
			\reverbSize    -> (arg: \reverbSize,    synth: \insert, lo: 0, hi: 1),
			\reverbDamp    -> (arg: \reverbDamp,    synth: \insert, lo: 0, hi: 1),
			\lofiBits      -> (arg: \lofiBits,      synth: \insert, lo: 1, hi: 24),
			\lofiRate      -> (arg: \lofiRate,      synth: \insert, lo: 500, hi: 48000),
			// send tap
			\sendTap    -> (arg: \tap,    synth: \sendTap, lo: 0, hi: 1, int: true),
			\sendLevel1 -> (arg: \level1, synth: \sendTap, lo: 0, hi: 1),
			\sendLevel2 -> (arg: \level2, synth: \sendTap, lo: 0, hi: 1),
			// modulation. dest 0 off, 1..5 pitch/cutoff/res/amp/pan, 6..9 macro 1..4
			\lfo1Dest  -> (arg: \lfo1Dest,  synth: \mod, lo: 0, hi: 9, int: true),
			\lfo1Wave  -> (arg: \lfo1Wave,  synth: \mod, lo: 0, hi: 5, int: true),
			\lfo1Beats -> (arg: \lfo1Beats, synth: \mod, lo: 0.0625, hi: 128),
			\lfo1Depth -> (arg: \lfo1Depth, synth: \mod, lo: -1, hi: 1),
			\lfo1Mode  -> (arg: \lfo1Mode,  synth: \mod, lo: 0, hi: 3, int: true),
			\lfo2Dest  -> (arg: \lfo2Dest,  synth: \mod, lo: 0, hi: 9, int: true),
			\lfo2Wave  -> (arg: \lfo2Wave,  synth: \mod, lo: 0, hi: 5, int: true),
			\lfo2Beats -> (arg: \lfo2Beats, synth: \mod, lo: 0.0625, hi: 128),
			\lfo2Depth -> (arg: \lfo2Depth, synth: \mod, lo: -1, hi: 1),
			\lfo2Mode  -> (arg: \lfo2Mode,  synth: \mod, lo: 0, hi: 3, int: true),
			\menvDest    -> (arg: \menvDest,    synth: \mod, lo: 0, hi: 9, int: true),
			\menvAttack  -> (arg: \menvAttack,  synth: \mod, lo: 0.0001),
			\menvDecay   -> (arg: \menvDecay,   synth: \mod, lo: 0.0001),
			\menvSustain -> (arg: \menvSustain, synth: \mod, lo: 0, hi: 1),
			\menvRelease -> (arg: \menvRelease, synth: \mod, lo: 0.0001),
			\menvDepth   -> (arg: \menvDepth,   synth: \mod, lo: -1, hi: 1)
		];
	}

	*new { arg engineArg, indexArg;
		^super.new.init(engineArg, indexArg);
	}

	init { arg engineArg, indexArg;
		engine = engineArg;
		index = indexArg.asInteger;
		macroBase = Array.fill(4, { 0 });
		macroMatrix = Array.fill(4, { Array.fill(5, { 0 }) });
		sliceVoices = Array.fill(32, { nil });
	}

	isAllocated { ^group.notNil }

	// ---- generic parameter dispatch ----------------------------------------
	// The ONE path every plain value setter takes: clip per the spec, store on
	// the instance, push to whichever synth owns it. A nil synth (chain not
	// allocated, or an insert set while the machine is None) is a no-op -- the
	// value is seeded back in by the next spawn.
	set { arg field, value;
		var spec, v;
		spec = setSpec[field];
		if(spec.isNil, { ^nil });
		v = value;
		if(spec[\int] == true, { v = v.asInteger; });
		if(spec[\lo].notNil, { v = v.max(spec[\lo]); });
		if(spec[\hi].notNil, { v = v.min(spec[\hi]); });
		this.instVarPut(field, v);
		this.push(spec, v);
		// A mod field may have just switched this track's modulation on or off.
		if(spec[\synth] == \mod, { this.refreshModSynth; });
		^v;
	}

	push { arg spec, v;
		var synth;
		synth = this.synthFor(spec[\synth]);
		if(synth.isNil, { ^nil });
		spec[\arg].asArray.do({ arg name; synth.set(name, v); });
	}

	synthFor { arg which;
		^switch(which,
			\reader,  { activeSynth },
			\filter,  { filterSynth },
			\insert,  { insertSynth },
			\sendTap, { sendTapSynth },
			\mod,     { modSynth },
			{ nil });
	}

	// Raw live set on the reader: the generic \trModeParam escape hatch for
	// warp params that have no spec row.
	setReader { arg key, value;
		if(activeSynth.notNil, { activeSynth.set(key, value); });
	}

	// ---- bespoke setters (genuinely non-trivial logic only) ----------------

	// amp is gated by mute at the FILTER stage: that is the one place a track's
	// own AMP-destination LFO can reach it (filterModOut). The mix synth stays
	// at unity -- applying amp there too would square the gain.
	setAmp { arg value;
		amp = value.max(0);
		this.pushAmp;
	}

	setMute { arg state;
		muted = state.asInteger.clip(0, 1);
		this.pushAmp;
		if(mixSynth.notNil, { mixSynth.set(\mute, muted); });
	}

	pushAmp {
		if(filterSynth.notNil, {
			filterSynth.set(\amp, if(muted == 1, { 0 }, { amp }));
		});
	}

	// One line per command name, not one per message. If this ever prints, the
	// script and the compiled engine class disagree about a command's argument
	// count -- most often because Engine_Elasticat.sc is a CLASS and only
	// recompiles when sclang restarts, so reloading the script alone can leave
	// a stale class library behind. A full norns restart is the first thing to
	// try.
	warnBadIndexedCommand { arg name;
		badIndexedWarned = badIndexedWarned ? IdentityDictionary.new;
		if(badIndexedWarned[name.asSymbol].isNil, {
			badIndexedWarned[name.asSymbol] = true;
			("elasticat: " ++ name ++ " arrived with missing arguments -- script/engine"
				" disagree on its format. Restart norns fully (the engine is a"
				" SuperCollider class and does not reload with the script).").postln;
		});
	}

	setMacroBase { arg macroIdx, value;
		var k;
		if(macroIdx.isNil or: { value.isNil }, {
			this.warnBadIndexedCommand("trMacroBase");
			^nil;
		});
		k = macroIdx.asInteger.clip(1, 4) - 1;
		macroBase[k] = value.clip(0, 1);
		if(modSynth.notNil, {
			modSynth.set(("macro" ++ (k + 1) ++ "Base").asSymbol, macroBase[k]);
		});
	}

	// nil-guarded: an indexed command that arrives with the wrong argument
	// count (a stale compiled class library disagreeing with the script about
	// this command's format, say) would otherwise hit `nil.asInteger` and throw
	// a DoesNotUnderstand PER MESSAGE -- at param-sync rates that is a log
	// flood that can stall sclang, turning a dropped macro into a dead engine.
	// Drop the message instead; the next correct one still lands.
	setMacroDepth { arg macroIdx, destIdx, value;
		var k, d;
		if(macroIdx.isNil or: { destIdx.isNil } or: { value.isNil }, {
			this.warnBadIndexedCommand("trMacroDepth");
			^nil;
		});
		k = macroIdx.asInteger.clip(1, 4) - 1;
		d = destIdx.asInteger.clip(1, 5) - 1;
		macroMatrix[k][d] = value.clip(-1, 1);
		if(modSynth.notNil, {
			modSynth.set(
				("macro" ++ (k + 1) ++ macroDestNames[d] ++ "Depth").asSymbol,
				macroMatrix[k][d]);
		});
		this.refreshModSynth;
	}

	// ---- modulation on demand ----------------------------------------------
	// \elasticatMod is 257 control-rate UGens -- measured as the single largest
	// per-track cost, ~35% of the engine's DSP at 8 tracks. At default settings
	// it computes identically ZERO: every source is multiplied by its depth
	// (lfo1/lfo2/menv) and every macro contributes value * matrix depth, so
	// with all depths at 0 all five destination sums are exactly 0. Rather than
	// pay for 8 copies of nothing, a track runs a mod synth only once some
	// depth is non-zero -- the same "None spawns no synth" principle the insert
	// FX already uses. Destination selectors are irrelevant here: a zero depth
	// zeroes the contribution whatever it points at.
	needsMod {
		if(lfo1Depth != 0, { ^true });
		if(lfo2Depth != 0, { ^true });
		if(menvDepth != 0, { ^true });
		macroMatrix.do({ arg row;
			row.do({ arg v; if(v != 0, { ^true }); });
		});
		^false;
	}

	// Bring the mod synth in line with the current state. Called from the one
	// generic setter (for any \mod-routed field) and from setMacroDepth, so
	// there is a single place that decides whether a track modulates.
	refreshModSynth {
		if(sourceGroup.isNil, { ^nil });
		if(this.needsMod, {
			if(modSynth.isNil, { this.spawnMod; });
		}, {
			if(modSynth.notNil, {
				modSynth.free;
				modSynth = nil;
				this.zeroModBusses;
				engine.reportIdleMod(this);
			});
		});
	}

	// A control bus keeps whatever was last written to it, and a freed bus can
	// come back with stale contents, so an idle track must park its five mod
	// busses at 0 explicitly -- otherwise the filter/readers would keep reading
	// the last modulation value forever.
	zeroModBusses {
		[modBusPitch, modBusCutoff, modBusRes, modBusAmp, modBusPan].do({ arg b;
			if(b.notNil, { b.set(0); });
		});
	}

	// Machine changes respawn a synth, so they are not spec-table material.
	setFilterMachine { arg idx;
		filterMachine = idx.asInteger.clip(0, engine.filterSynthNames.size - 1);
		this.spawnFilter;
	}

	setInsertMachine { arg idx;
		fxInsertMachine = idx.asInteger.clip(0, engine.fxInsertNames.size - 1);
		this.spawnInsert;
	}

	// Reader machine: crossfade-swap. While the chain is inactive only the
	// state changes -- alloc re-seeds the reader from it.
	setMachine { arg modeIndex;
		var newMode, oldMode, oldSynth, newSynth;
		newMode = modeIndex.asInteger.clip(0, engine.modeSynthNames.size - 1);
		oldMode = machine;
		if((newMode == oldMode) and: { activeSynth.notNil }, { ^nil });
		machine = newMode;
		if(group.isNil, { ^nil });
		// Leaving the free-running tape reader: re-anchor on the shared phase.
		if((oldMode == 0) and: { newMode != 0 }, { this.setPlayhead(lastPhase); });
		oldSynth = activeSynth;
		newSynth = this.spawnMode(0);
		activeSynth = newSynth;
		newSynth.set(\modeAmp, 1, \fadeTime, modeSwitchFade);
		if(oldSynth.notNil, {
			oldSynth.set(\modeAmp, 0, \fadeTime, modeSwitchFade);
			Routine({ modeSwitchFade.wait; oldSynth.free; }).play(SystemClock);
		});
	}

	// ---- derived values -----------------------------------------------------
	loopBeats {
		var region;
		region = ((loopEnd - loopStart).max(0.01) / 128).clip(0.0001, 1);
		^((sampleSteps.max(1) / 4) * region).max(0.03125);
	}

	recalcNativeTempo {
		var duration;
		duration = sourceFrames.max(1) / sourceRate.max(1);
		derivedSourceBpm = ((sampleSteps.max(1) / 4) * 60 / duration).max(1);
		^derivedSourceBpm;
	}

	// ---- transport ----------------------------------------------------------
	setPlay { arg state;
		playing = state.asInteger.clip(0, 1);
		if(playing == 0, { this.releaseAllSlices; });
		if(transportSynth.notNil, { transportSynth.set(\playing, playing); });
		this.setReader(\playing, playing);
	}

	setPlayhead { arg phase;
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(\resetPos, lastPhase, \resetTrig, resetCount);
		});
		if(activeSynth.notNil, {
			activeSynth.set(\resetPos, lastPhase, \resetTrig, resetCount);
		});
	}

	// Phase reported back by this track's own transport/reader SendReply.
	reportPhase { arg phase;
		lastPhase = phase.wrap(0, 1);
	}

	setReverse { arg value;
		direction = if(value.asInteger == 1, { -1 }, { 1 });
		this.setReader(\direction, direction);
	}

	applyLoop {
		if(transportSynth.notNil, { transportSynth.set(\loopBeats, this.loopBeats); });
		if(activeSynth.notNil, {
			activeSynth.set(
				\loopBeats, this.loopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd
			);
		});
	}

	setLoopStart { arg position;
		loopStart = position.clip(0, 127.99);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		this.applyLoop;
	}

	setLoopEnd { arg position;
		loopEnd = position.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopStart = (loopEnd - 0.01).clip(0, 127.99); });
		this.applyLoop;
	}

	// Atomically set the loop region AND reset the phase (live region scrubbing).
	setLoopRegionPlayhead { arg startPosition, endPosition, phase;
		loopStart = startPosition.clip(0, 127.99);
		loopEnd = endPosition.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, engine.targetBpm,
				\loopBeats, this.loopBeats,
				\correction, engine.correction,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
		if(activeSynth.notNil, {
			activeSynth.set(
				\playing, playing,
				\targetBpm, engine.targetBpm,
				\loopBeats, this.loopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
	}

	setSampleSteps { arg steps;
		sampleSteps = steps.clip(1, 512);
		this.recalcNativeTempo;
		if(transportSynth.notNil, { transportSynth.set(\loopBeats, this.loopBeats); });
		if(activeSynth.notNil, {
			activeSynth.set(\loopBeats, this.loopBeats, \derivedSourceBpm, derivedSourceBpm);
		});
	}

	setSourceBpm { arg bpm;
		derivedSourceBpm = bpm.max(1);
		this.setReader(\derivedSourceBpm, derivedSourceBpm);
	}

	// Tempo/clock-correction fan-out. Every global tempo change routes through
	// engine.updateTransport, which calls this on each allocated track.
	pushTempo {
		if(group.isNil, { ^nil });
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, engine.targetBpm,
				\loopBeats, this.loopBeats,
				\correction, engine.correction
			);
		});
		if(activeSynth.notNil, {
			activeSynth.set(
				\playing, playing,
				\targetBpm, engine.targetBpm,
				\loopBeats, this.loopBeats
			);
		});
		// Delay is the only insert FX that reads tempo; LFO rates are musical
		// divisions of it.
		if(insertSynth.notNil, { insertSynth.set(\targetBpm, engine.targetBpm); });
		if(modSynth.notNil, { modSynth.set(\targetBpm, engine.targetBpm); });
	}

	// ---- notes --------------------------------------------------------------
	// seconds <= 0 is the indefinite-hold sentinel: the gate stays open until
	// noteOff. The filter env shares the amp env's trigger counter and gate.
	noteOn { arg seconds;
		envNoteSeconds = if(seconds > 0, { seconds.max(0.005) }, { -1 });
		envTrigCount = envTrigCount + 1;
		if(activeSynth.notNil, {
			activeSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
		});
		if(filterSynth.notNil, {
			filterSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
		});
		if(modSynth.notNil, { modSynth.set(\menvGateSeconds, envNoteSeconds); });
	}

	noteOff {
		noteOffTrigCount = noteOffTrigCount + 1;
		if(activeSynth.notNil, { activeSynth.set(\envReleaseTrig, noteOffTrigCount); });
		if(filterSynth.notNil, { filterSynth.set(\envReleaseTrig, noteOffTrigCount); });
		if(modSynth.notNil, { modSynth.set(\menvReleaseTrig, noteOffTrigCount); });
	}

	// Force a fresh amp/filter re-attack for a stopped step preview. Unlike a
	// plain noteOn this ALWAYS re-attacks, even under portamento (whose legato
	// deliberately swallows a note-on on a still-sounding note): a preview is
	// monitoring, not legato, so it must be heard. Under portamento we mimic a
	// manual re-press -- close the gate now, reopen one block later, since a
	// same-block set/reset on SetResetFF is reset-wins (stuck closed).
	retrigNote { arg seconds;
		var applyNoteOn;
		applyNoteOn = {
			envNoteSeconds = if(seconds > 0, { seconds.max(0.005) }, { -1 });
			envTrigCount = envTrigCount + 1;
			if(activeSynth.notNil, {
				activeSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
			});
			if(filterSynth.notNil, {
				filterSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
			});
		};
		if(portamento > 0, {
			noteOffTrigCount = noteOffTrigCount + 1;
			if(activeSynth.notNil, { activeSynth.set(\envReleaseTrig, noteOffTrigCount); });
			if(filterSynth.notNil, { filterSynth.set(\envReleaseTrig, noteOffTrigCount); });
			SystemClock.sched(0.008, { applyNoteOn.value; nil });
		}, {
			applyNoteOn.value;
		});
	}

	// Per-step modulation retrigger: arg 1 != 0 retriggers both LFOs (their
	// non-FREE modes), arg 2 != 0 retriggers the mod envelope.
	modTrig { arg lfo, env;
		if(lfo.asInteger != 0, {
			lfoTrigCount = lfoTrigCount + 1;
			if(modSynth.notNil, {
				modSynth.set(\lfoTrig1, lfoTrigCount, \lfoTrig2, lfoTrigCount);
			});
		});
		if(env.asInteger != 0, {
			menvTrigCount = menvTrigCount + 1;
			if(modSynth.notNil, { modSynth.set(\menvTrig, menvTrigCount); });
		});
	}

	// ---- sample pool binding ------------------------------------------------
	// Tracks SHARE the pool buffers -- no duplication. Slot 0 / an empty slot
	// points the reader at the default (silent) buffers so the transport keeps
	// running. installPoolBuffers/clearPoolSlot re-call this after an async
	// load lands, downstream of the generation check.
	bindSampleSlot { arg slot;
		var idx;
		slot = slot.asInteger;
		this.releaseAllSlices;
		if(slot < 1, {
			sampleSlot = 0;
			loaded = 0;
			bufL = engine.defaultBufL;
			bufR = engine.defaultBufR;
		}, {
			slot = slot.clip(1, engine.poolSize);
			idx = slot - 1;
			sampleSlot = slot;
			if(engine.poolLoaded[idx] != 1, {
				loaded = 0;
				bufL = engine.defaultBufL;
				bufR = engine.defaultBufR;
			}, {
				loaded = 1;
				bufL = engine.poolBufL[idx];
				bufR = engine.poolBufR[idx];
				sourceFrames = engine.poolFrames[idx].max(1);
				sourceRate = engine.poolRates[idx].max(1);
				this.recalcNativeTempo;
			});
		});
		if(activeSynth.notNil, {
			activeSynth.set(
				\bufL, (bufL ? engine.defaultBufL).bufnum,
				\bufR, (bufR ? engine.defaultBufR).bufnum,
				\derivedSourceBpm, derivedSourceBpm
			);
		});
		^sampleSlot;
	}

	// ---- synth argument lists ----------------------------------------------
	commonArgs { arg startAmp;
		^[
			\out, fxBus.index,
			\phaseBus, phaseBus.index,
			\bufL, (bufL ? engine.defaultBufL).bufnum,
			\bufR, (bufR ? engine.defaultBufR).bufnum,
			\modeAmp, startAmp,
			\fadeTime, modeSwitchFade,
			\playing, playing,
			\resetTrig, resetCount,
			\resetPos, lastPhase,
			\amp, amp,
			\pan, pan,
			\pitch, pitch,
			\speed, speed,
			\direction, direction,
			\targetBpm, engine.targetBpm,
			\derivedSourceBpm, derivedSourceBpm,
			\loopBeats, this.loopBeats,
			\startPoint, loopStart,
			\endPoint, loopEnd,
			\macro, macro,
			\envMode, envMode,
			\envAttack, envAttack,
			\envDecay, envDecay,
			\envSustain, envSustain,
			\envRelease, envRelease,
			\envHold, envHold,
			\envTrig, envTrigCount,
			\envGateSeconds, envNoteSeconds,
			\envReleaseTrig, noteOffTrigCount,
			\portamento, portamento,
			\pitchModBus, modBusPitch.index,
			\trackIndex, index
		] ++ this.warpArgs;
	}

	// Warp params seeded on every reader spawn, so a machine swap no longer
	// drops them. random_ola (machine 4) is the one reader whose window/search
	// controls are named \grainSize / \wander -- the same aliasing the
	// wsolaWindow / wsolaSearch spec rows use.
	warpArgs {
		var out;
		out = [
			\chopBeats, chopBeats,
			\chopMode, chopMode,
			\chopAttack, chopAttack,
			\chopHold, chopHold,
			\chopRelease, chopRelease,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter,
			\grainSpray, grainJitter,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion
		];
		^if(machine.asInteger == 4, {
			out ++ [\grainSize, wsolaWindow, \wander, wsolaSearch];
		}, {
			out ++ [\grainSize, grainSize];
		});
	}

	filterArgs {
		^[
			\out, insertBus.index,
			\in, fxBus.index,
			// Effective amp: 0 while muted, so a muted track stays muted across
			// filter machine respawns. The mix synth gates again for the fade.
			\amp, if(muted == 1, { 0 }, { amp }),
			\pan, pan,
			\filterType, filterType,
			\cutoff, filterCutoff,
			\res, filterRes,
			\drive, filterDrive,
			\morph, filterMorph,
			\balance, filterBalance,
			\envMode, filterEnvMode,
			\envAttack, filterEnvAttack,
			\envDecay, filterEnvDecay,
			\envSustain, filterEnvSustain,
			\envRelease, filterEnvRelease,
			\envHold, filterEnvHold,
			\envDepth, filterEnvDepth,
			\envTrig, envTrigCount,
			\envGateSeconds, envNoteSeconds,
			\envReleaseTrig, noteOffTrigCount,
			\cutoffModBus, modBusCutoff.index,
			\resModBus, modBusRes.index,
			\ampModBus, modBusAmp.index,
			\panModBus, modBusPan.index,
			\trackIndex, index,
			\slew, filterSlew
		];
	}

	fxInsertArgs {
		^[
			\out, mixBus.index,
			\in, insertBus.index,
			\mix, fxMix,
			\drive, fxDrive,
			\delayBeats, delayBeats,
			\delayFeedback, delayFeedback,
			\delayTone, delayTone,
			\reverbSize, reverbSize,
			\reverbDamp, reverbDamp,
			\lofiBits, lofiBits,
			\lofiRate, lofiRate,
			\targetBpm, engine.targetBpm
		];
	}

	// Insert machine None spawns no synth at all, so nothing carries
	// insertBus -> mixBus: the post-insert readers read insertBus directly
	// instead of paying for a passthrough synth.
	postInsertBus {
		^if(fxInsertMachine.asInteger == 0, { insertBus }, { mixBus });
	}

	repointPostInsert {
		var post;
		if(group.isNil, { ^nil });
		post = this.postInsertBus;
		if(sendTapSynth.notNil, { sendTapSynth.set(\postIn, post.index); });
		if(mixSynth.notNil, { mixSynth.set(\in, post.index); });
	}

	sendTapArgs {
		^[
			\preIn, insertBus.index,
			\postIn, this.postInsertBus.index,
			\tap, sendTap,
			\level1, sendLevel1,
			\level2, sendLevel2,
			\sendOut1, engine.sendBus1.index,
			\sendOut2, engine.sendBus2.index
		];
	}

	modArgs {
		^[
			\pitchOut, modBusPitch.index,
			\cutoffOut, modBusCutoff.index,
			\resOut, modBusRes.index,
			\ampOut, modBusAmp.index,
			\panOut, modBusPan.index,
			\targetBpm, engine.targetBpm,
			\lfo1Dest, lfo1Dest,
			\lfo1Wave, lfo1Wave,
			\lfo1Beats, lfo1Beats,
			\lfo1Depth, lfo1Depth,
			\lfo1Mode, lfo1Mode,
			\lfoTrig1, lfoTrigCount,
			\lfo2Dest, lfo2Dest,
			\lfo2Wave, lfo2Wave,
			\lfo2Beats, lfo2Beats,
			\lfo2Depth, lfo2Depth,
			\lfo2Mode, lfo2Mode,
			\lfoTrig2, lfoTrigCount,
			\menvDest, menvDest,
			\menvAttack, menvAttack,
			\menvDecay, menvDecay,
			\menvSustain, menvSustain,
			\menvRelease, menvRelease,
			\menvDepth, menvDepth,
			\menvTrig, menvTrigCount,
			\menvGateSeconds, envNoteSeconds,
			\menvReleaseTrig, noteOffTrigCount,
			\trackIndex, index
		] ++ this.macroArgs;
	}

	// 4 macros x (base + one signed depth per destination), flattened into the
	// \macroNBase / \macroN<Dest>Depth args \elasticatMod declares.
	macroArgs {
		var out = [];
		4.do({ arg m;
			out = out ++ [("macro" ++ (m + 1) ++ "Base").asSymbol, macroBase[m]];
			macroDestNames.do({ arg name, d;
				out = out ++ [
					("macro" ++ (m + 1) ++ name ++ "Depth").asSymbol,
					macroMatrix[m][d]
				];
			});
		});
		^out;
	}

	// ---- spawns -------------------------------------------------------------
	spawnMode { arg startAmp;
		if(group.isNil, { ^nil });
		^Synth.after(transportSynth,
			engine.modeSynthNames.wrapAt(machine.asInteger), this.commonArgs(startAmp));
	}

	spawnMod {
		if(sourceGroup.isNil, { ^nil });
		if(modSynth.notNil, { modSynth.free; });
		modSynth = Synth.head(sourceGroup, \elasticatMod, this.modArgs);
		^modSynth;
	}

	spawnFilter {
		if(group.isNil, { ^nil });
		if(filterSynth.notNil, { filterSynth.free; });
		filterSynth = Synth.after(sourceGroup,
			engine.filterSynthNames.wrapAt(filterMachine.asInteger), this.filterArgs);
		^filterSynth;
	}

	spawnInsert {
		if(group.isNil, { ^nil });
		if(insertSynth.notNil, { insertSynth.free; insertSynth = nil; });
		if(fxInsertMachine.asInteger > 0, {
			insertSynth = Synth.after(filterSynth ? sourceGroup,
				engine.fxInsertNames.wrapAt(fxInsertMachine.asInteger), this.fxInsertArgs);
		});
		this.repointPostInsert;
		^insertSynth;
	}

	spawnSendTap {
		if(group.isNil, { ^nil });
		if(sendTapSynth.notNil, { sendTapSynth.free; });
		sendTapSynth = Synth.before(mixSynth, \elasticatSendTap, this.sendTapArgs);
		^sendTapSynth;
	}

	// ---- lifecycle ----------------------------------------------------------
	alloc {
		var server;
		if(group.notNil, { ^nil });
		server = engine.context.server;
		phaseBus = Bus.audio(server, 1);
		fxBus = Bus.audio(server, 2);
		insertBus = Bus.audio(server, 2);
		mixBus = Bus.audio(server, 2);
		modBusPitch = Bus.control(server, 1);
		modBusCutoff = Bus.control(server, 1);
		modBusRes = Bus.control(server, 1);
		modBusAmp = Bus.control(server, 1);
		modBusPan = Bus.control(server, 1);
		group = Group.tail(engine.tracksGroup);
		sourceGroup = Group.head(group);
		// Fresh busses can carry whatever a previous owner left behind.
		this.zeroModBusses;
		// Only spawns if this track actually modulates something (see needsMod);
		// it lands at the head of sourceGroup whenever it does, so the readers,
		// slice voices and the downstream filter all read this block's values.
		this.refreshModSynth;
		transportSynth = Synth.tail(sourceGroup, \elasticatTransport, [
			\out, phaseBus.index,
			\playing, playing,
			\targetBpm, engine.targetBpm,
			\loopBeats, this.loopBeats,
			\correction, engine.correction,
			\resetTrig, resetCount,
			\resetPos, lastPhase,
			\trackIndex, index
		]);
		activeSynth = this.spawnMode(1);
		// mixSynth first so spawnSendTap has a node to sit before, and the
		// filter/insert have somewhere to land between sourceGroup and it. It
		// stays at UNITY amp/pan: the filter stage carries this track's amp/pan
		// (that is where the AMP/PAN mod destinations apply).
		mixSynth = Synth.tail(group, \elasticatTrackMix, [
			\out, engine.masterBus.index,
			\in, this.postInsertBus.index,
			\amp, 1,
			\pan, 0,
			\mute, muted,
			\alive, 1
		]);
		this.spawnFilter;
		this.spawnInsert;
		this.spawnSendTap;
		// Bind whatever the track's selected pool slot currently holds.
		this.bindSampleSlot(sampleSlot);
		^group;
	}

	// Click-free teardown: fade the mix gain (30 ms Lag on \alive), wait past
	// it, then free the group and ALL NINE busses. The instance survives, so
	// re-raising \activeTrackCount restores the track exactly as it was.
	free {
		var doomedGroup, doomedBusses, doomedMix;
		if(group.isNil, { ^nil });
		doomedGroup = group;
		doomedMix = mixSynth;
		doomedBusses = this.chainBusses;
		this.forgetNodes;
		if(doomedMix.notNil, { doomedMix.set(\alive, 0); });
		Routine({
			0.08.wait;  // > the 30 ms alive Lag: silence before the free
			doomedGroup.free;
			doomedBusses.do({ arg b; if(b.notNil, { b.free; }); });
		}).play(SystemClock);
	}

	// Immediate teardown for engine shutdown (no fade, no Routine).
	freeNow {
		var doomedBusses;
		if(group.isNil, { ^nil });
		doomedBusses = this.chainBusses;
		group.free;
		doomedBusses.do({ arg b; if(b.notNil, { b.free; }); });
		this.forgetNodes;
	}

	// ALL NINE busses a chain owns -- one list, used by both teardown paths so
	// neither can drift and leak.
	chainBusses {
		^[
			phaseBus, fxBus, insertBus, mixBus,
			modBusPitch, modBusCutoff, modBusRes, modBusAmp, modBusPan
		];
	}

	forgetNodes {
		engine.forgetSliceVoicesOf(this);
		sliceVoices = Array.fill(32, { nil });
		group = nil; sourceGroup = nil;
		phaseBus = nil; fxBus = nil; insertBus = nil; mixBus = nil;
		modBusPitch = nil; modBusCutoff = nil; modBusRes = nil;
		modBusAmp = nil; modBusPan = nil;
		transportSynth = nil; modSynth = nil; activeSynth = nil;
		filterSynth = nil; insertSynth = nil; sendTapSynth = nil; mixSynth = nil;
	}

	// ---- slice voices -------------------------------------------------------
	// Voices tail-add inside THIS track's sourceGroup, so they always precede
	// this track's filter -- a slice on track 3 must never play through track
	// 1's filter. The 32 slots are the per-track voice map; engine-side there
	// is also a hard cap on total concurrent voices across all 8 tracks.
	triggerSlice { arg sliceIndex, startPoint, endPoint, playMode, reverse, velocity, lengthSeconds, notePitch;
		var idx, startPos, endPos, mode, rev, pitchValue, pitchRatio, duration, sliceRatio, synth;
		if(group.isNil, { ^nil });
		idx = sliceIndex.asInteger.clip(1, 32);
		startPos = startPoint.asFloat.clip(0, 127.99);
		endPos = endPoint.asFloat.clip(0.01, 128);
		if(endPos <= startPos, { endPos = (startPos + 0.01).clip(0.01, 128); });
		mode = playMode.asInteger.clip(0, 3);
		rev = reverse.asInteger.clip(0, 1);
		pitchValue = notePitch.asFloat.clip(-48, 48);
		pitchRatio = pitchValue.midiratio.max(0.001);
		duration = lengthSeconds.asFloat;
		if(duration <= 0, {
			if(mode >= 2, {
				duration = 60;
			}, {
				sliceRatio = ((endPos - startPos).abs / 128).max(0.0001);
				duration = ((sourceFrames.max(1) * sliceRatio) / sourceRate.max(1)) / pitchRatio;
			});
		});
		duration = duration.clip(0.005, 60);

		if(engine.sliceMono == 1, { this.releaseAllSlices; });
		this.releaseSlice(idx);

		synth = Synth.tail(sourceGroup, \elasticatSliceVoice, [
			\out, fxBus.index,
			\bufL, (bufL ? engine.defaultBufL).bufnum,
			\bufR, (bufR ? engine.defaultBufR).bufnum,
			\startPoint, startPos,
			\endPoint, endPos,
			\playMode, mode,
			\reverse, rev,
			\amp, amp,
			\pan, pan,
			\pitch, pitchValue,
			\velocity, velocity.asFloat.clip(0, 1),
			\sliceAttack, engine.sliceAttack,
			\sliceRelease, engine.sliceRelease,
			\envMode, envMode,
			\envAttack, envAttack,
			\envDecay, envDecay,
			\envSustain, envSustain,
			\envRelease, envRelease,
			\envHold, envHold,
			\lengthSeconds, duration,
			\syncToClock, engine.sliceSyncToClock,
			\sliceRate, engine.sliceRate,
			\warpMode, machine,
			\targetBpm, engine.targetBpm,
			\macro, macro,
			\grainSize, grainSize,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter,
			\wsolaWindow, wsolaWindow,
			\wsolaSearch, wsolaSearch,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion,
			\pitchModBus, modBusPitch.index,
			\gate, 1
		]);
		sliceVoices[idx - 1] = synth;
		engine.registerSliceVoice(this, idx, synth);
		Routine({
			duration.wait;
			// Only close the gate if this voice still owns the slot: a stolen or
			// replaced voice is already gone, and setting a freed node just
			// makes the server log a failure.
			if(sliceVoices[idx - 1] == synth, {
				synth.set(\gate, 0);
				sliceVoices[idx - 1] = nil;
			});
			engine.forgetSliceVoice(synth);
		}).play(SystemClock);
		^synth;
	}

	releaseSlice { arg sliceIndex;
		var idx, synth;
		idx = sliceIndex.asInteger.clip(1, 32);
		synth = sliceVoices[idx - 1];
		if(synth.notNil, {
			synth.set(\gate, 0);
			sliceVoices[idx - 1] = nil;
			engine.forgetSliceVoice(synth);
		});
	}

	// Voice stealing (global cap): the engine has already dropped this entry
	// from its order list, so do NOT call back into forgetSliceVoice here.
	// \steal runs the voice's own 20 ms fade-and-free -- \gate alone would
	// leave an AHR voice sounding, since that envelope ignores gate-off.
	stealSlice { arg slot, synth;
		if(synth.notNil, { synth.set(\steal, 1); });
		if(sliceVoices[slot - 1] == synth, { sliceVoices[slot - 1] = nil; });
	}

	releaseAllSlices {
		sliceVoices.do({ arg synth, i;
			if(synth.notNil, {
				synth.set(\gate, 0);
				sliceVoices[i] = nil;
				engine.forgetSliceVoice(synth);
			});
		});
	}
}
