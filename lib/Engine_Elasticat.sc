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
	var sendFxExtra;   // per-slot dict of the new machines' send/master params

	// --- SynthDef name registries (a machine is one row here + one SynthDef) -
	var <modeSynthNames;
	var <modeNames;
	var <filterSynthNames;
	var <fxInsertNames;

	// --- Shared SynthDef graph functions -------------------------------------
	var readerAmpEnv;         // shared amp-envelope graph for readers/filter env
	var readerDeclick;        // shared amp dip masking a playhead-JUMP discontinuity
	var filterPrep;           // shared drive + env-modulated cutoff/res prep
	var filterChannelClassic; // shared per-channel Classic (multimode) filter
	var filterChannelMorph;   // shared per-channel Morphing filter
	var filterChannelLadder;  // #8 Moog-ladder LP (MoogFF)
	var filterChannelFormant; // #9 vowel BPF bank
	var filterDecodeMS, filterEncodeMS; // stereo<->mid/side matrix for the mix mode
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
	// The on-screen SELECTED track (pushed from Lua on every track switch). Drives
	// the per-track UI feeds -- the FAST 15Hz phase + meter (smooth playhead) AND
	// the live mod-bus / filter-env streams (so the actual-value bars and filter
	// render follow the SELECTED track's LFOs, not always track 1's). Separate from
	// uiTrack, which is a track-1-assuming legacy handle kept only for the
	// /elasticat/status stream (uiTrack is never pushed, so it stays 1).
	var viewTrack = 1;
	var meterAll = 0;   // 1 = the mixer view is up: forward EVERY track's meter

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
	var <>sliceMono = 1;   // default MONO (owner): one slice voice at a time
	var <sliceSyncToClock = 1;
	var <sliceRate = 1;
	var sliceVoiceOrder;
	// Slice voice budget (owner). Per TRACK: at most maxSliceVoicesPerTrack (the
	// "poly 8" option), so one track cannot hog the pool. GLOBAL: at most
	// maxSliceVoices across ALL 8 tracks -- 8x8 = 64 would cliff the CPU, so a
	// SHARED 24-voice pool is stolen oldest-first (per-track cap first, then the
	// global pool). With the bounded slice envelope above, these are backstops,
	// not the primary limit.
	var maxSliceVoicesPerTrack = 8;
	var maxSliceVoices = 24;

	// --- OSC -----------------------------------------------------------------
	var scriptAddress;
	var statusResponder;
	var modResponder;       // live mod-bus values -> script (~15Hz UI feed)
	var filterEnvResponder; // filter-env cutoff contribution -> script (15Hz)
	var fxMeterResponder;   // comp/duck gain-reduction + level meter -> script (20Hz)
	var transportResponder;
	// --- Idle pause + CPU telemetry (Pi3 xrun mitigation) --------------------
	// A stopped, silent, un-viewed track's whole node group is paused
	// (group.run(false)) so 8 mostly-idle tracks stop burning warp/filter DSP.
	// Silence is measured POST-everything (\elasticatTrackMix output, 2Hz), so
	// a ringing insert tail keeps its track awake until it has decayed.
	var idleResponder;      // /elasticat/idleRaw -> track.reportOutLevel
	var idleScanRoutine;    // 2s tick: pause eligible tracks + CPU report
	var <idlePauseEnabled = 1;
	var <idlePausedCount = 0;
	var <idleGraceSeconds = 4.0;   // settable: test seam + live tuning

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
			\elasticatTape,           // 1  tape
			\elasticatTempoVarispeed, // 2  tempo_varispeed
			\elasticatChopped,        // 3  domino
			\elasticatGranular,       // 4  granular
			\elasticatRandomOla,      // 5  random_ola
			\elasticatPitchCorrected, // 6  pitch_corrected
			\elasticatHarmonizer,     // 7  harmonizer
			\elasticatWavetable,      // 8  wavetable
			\elasticatSpectral,       // 9  spectral_freeze
			\elasticatSpectral,       // 10 formant (shares the Spectral def)
			\elasticatGStretch,       // 11 gstretch  (was 13)
			\elasticatGStretch2,      // 12 gstretch2 (was 14)
			\elasticatChopSync        // 13 chopped   (Digitakt ramp-on-start; was 16)
		];
		modeNames = [
			"tape",
			"tempo_varispeed",
			"domino",
			"granular",
			"random_ola",
			"pitch_corrected",
			"harmonizer",
			"wavetable",
			"spectral_freeze",
			"formant",
			"gstretch",
			"gstretch2",
			"chopped"
		];
		filterSynthNames = [
			\elasticatFilterClassic,
			\elasticatFilterMorph,
			\elasticatFilterLadder,
			\elasticatFilterComb,
			\elasticatFilterFormant
		];
		fxInsertNames = [
			\elasticatFxNone,
			\elasticatFxDrive,
			\elasticatFxDelay,
			\elasticatFxReverb,
			\elasticatFxLofi,
			\elasticatFxComp,
			\elasticatFxDestroy,
			\elasticatFxEcho,
			\elasticatFxBlackhole,
			\elasticatFxChorus,
			\elasticatFxFlanger,
			\elasticatFxPhaser,
			\elasticatFxDjEq,
			\elasticatFxDuck,
			\elasticatFxTapeEcho,
			\elasticatFxCassette,
			\elasticatFxMotion,
			\elasticatFxRings,
			\elasticatFxLimit
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
		// New FX machines (Comp/Destroy/Echo/Blackhole) route their send/master
		// params through one generated command block instead of a hand-written
		// command + array per param. sendFxExtra[slotIdx] is a per-slot dict of
		// arg -> last value, seeded here to the SynthDef defaults and reapplied on
		// respawn via sendFxArgs. See sendFxExtraSpec + installCommands.
		sendFxExtra = [Dictionary.new, Dictionary.new, Dictionary.new];
		this.sendFxExtraSpec.do({ arg row;
			(0..2).do({ arg s; sendFxExtra[s][row[1]] = row[4]; });
		});

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
				// Meter feed (15Hz = screen rate): only the SELECTED (UI) track is on
				// screen on most pages, so forward only its meter -- UNLESS the mixer
				// view is up (meterAll), which shows all 8. A background track meter is
				// out of view, so flooding OSC with it is waste (owner). Track 1 also
				// rides /elasticat/status.
				if((t == viewTrack) or: { meterAll == 1 }, {
					scriptAddress.sendBundle(0, [
						"/elasticat/track/level", t, msg[6].asFloat, msg[7].asFloat
					]);
				});
				// FAST playhead for the SELECTED (UI) track, whichever it is: forward
				// its phase at the reader's 15Hz so a loop on a track above 1 has a
				// SMOOTH playhead. Without this it fell back to the 1Hz
				// /track/position re-anchor and dead-reckoned (visibly snapping)
				// between reports. Track 1 already gets its phase via /elasticat/
				// status below, so skip the redundant send there. (Owner.)
				if((t == viewTrack) and: { t != 1 }, {
					scriptAddress.sendBundle(0, [
						"/elasticat/track/position", t, msg[4].asFloat
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
			if(msg[2].asInteger == viewTrack, {
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
			if(msg[2].asInteger == viewTrack, {
				scriptAddress.sendBundle(0, [
					"/elasticat/filterEnv", msg[3].asFloat, msg[2].asInteger
				]);
			});
		}, path: '/elasticat/filterEnvRaw', srcID: server.addr);

		// Comp/Duck gain-reduction + level meter (owner). The insert synth of the
		// VIEWED track reports [grDb, keyDb, threshDb], forwarded when its id
		// matches viewTrack; the GLOBAL slots report as 101/102/103 (Send 1/2 /
		// Master -- see sendFxArgs) and are forwarded unconditionally, so the send
		// and master FX pages can meter their own Comp/Duck. The script matches the
		// id against the page it is showing, so the streams never mix on screen.
		fxMeterResponder = OSCFunc({
			arg msg;
			var mid = msg[2].asInteger;
			if((mid == viewTrack) or: { mid > 100 }, {
				scriptAddress.sendBundle(0, [
					"/elasticat/fxMeter", msg[3].asFloat, msg[4].asFloat, msg[5].asFloat, mid
				]);
			});
		}, path: '/elasticat/fxMeterRaw', srcID: server.addr);

		// Idle detector: each track's post-gain output level (2Hz, from its
		// \elasticatTrackMix). A paused track's mix synth stops reporting --
		// deliberately fine, since paused implies silent and waking is driven
		// by commands (play/trig/view), never by level.
		idleResponder = OSCFunc({
			arg msg;
			var t, tr;
			t = msg[2].asInteger;
			tr = if((t >= 1) and: { t <= 8 }, { tracks[t] }, { nil });
			if(tr.notNil, { tr.reportOutLevel(msg[3].asFloat); });
		}, path: '/elasticat/idleRaw', srcID: server.addr);

		// One 2s housekeeping tick: pause idle-eligible tracks, then report CPU
		// + pause telemetry to the script. A plain sclang Routine (not a synth):
		// server CPU stats only exist client-side, and 0.5Hz costs nothing.
		idleScanRoutine = Routine({
			loop {
				2.0.wait;
				this.idleScan;
				scriptAddress.sendBundle(0, [
					"/elasticat/cpu",
					context.server.avgCPU ? 0,
					context.server.peakCPU ? 0,
					idlePausedCount,
					context.server.numSynths ? 0
				]);
			}
		}).play(SystemClock);

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

		// A playhead JUMP resets the read phasor -> waveform discontinuity ->
		// click. Dip the reader amp to 0 across the jump; the phasor reset is
		// DELAYED by the 3ms down-time (below) so the phase jumps while this is
		// already at 0 -- the discontinuity is silent. 2ms flat-zero absorbs the
		// reader<->bus latency. A normal loop WRAP is not a resetTrig edge, so it
		// is never dipped.
		readerDeclick = { arg resetTrig;
			EnvGen.ar(Env.new([1, 0, 0, 1], [0.003, 0.002, 0.003], \sin), Changed.kr(resetTrig));
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
			// Depth is +/-6 octaves (72 semitones) of filter-ENV cutoff modulation.
			// The mod bus (LFO/mod-env/macros/VELOCITY -> CUTOFF, -1..1) is scaled
			// here to the FULL cutoff range (+/-10 octaves, 120 semitones). The mod
			// synth pre-scales the LFO/env/macro cutoff terms by 0.3 to preserve
			// their old +/-3 octaves, while VELOCITY is summed at full weight -- so
			// a max-depth velocity mod sweeps the cutoff across its whole range.
			// Base cutoff Lag is SHORT (0.02s, was 0.09): per-slice filter p-locks want
			// a near-instant cutoff per hit (owner "bloop"); seq_apply_locks already
			// flushes the value before the trigger. LFO/env->cutoff ride the separate
			// mod bus above (feel unchanged); only manual cutoff sweeps get a touch
			// steppier. res/pan/amp/morph keep the longer `slew` (avoid clicks).
			fc = (Lag.kr(cutoff.clip(20, 20000), 0.02)
				* ((envDepth.clip(-1, 1) * fenv * 72) + (In.kr(cutoffModBus, 1).clip(-1, 1) * 120)).midiratio).clip(20, 20000);
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

		// Ladder (#8): a Moog-style ladder low-pass. filterPrep gives (fc, rq)
		// where LOW rq = HIGH resonance; MoogFF wants resonance as 0..4 (self-
		// oscillates near 4), so (1 - rq) maps into that range. Drive is the pre-
		// filter tanh shape filterPrep already applied. Called once per channel.
		filterChannelLadder = { arg s, fc, rq;
			var reso = (1 - rq).linlin(0, 0.98, 0, 4.0).clip(0, 4.0);
			MoogFF.ar(s, fc.clip(20, 18000), reso);
		};

		// Formant (#9): a 3-band bandpass VOWEL bank, per channel. `vowel` 0..1 morphs
		// A->E->I->O->U (linear-interpolated formant freqs + amps); `shiftRatio` scales
		// all three formants (from CUT, so the filter env transposes the vowel); `q` is
		// the BPF reciprocal-Q (from RES, sharper = more vowel-like).
		filterChannelFormant = { arg s, shiftRatio, q, vowel;
			var fmt1 = [ 700, 400, 250, 400, 350 ];
			var fmt2 = [1220, 2000, 2100, 750, 600 ];
			var fmt3 = [2600, 2600, 2900, 2400, 2400 ];
			var amp2t = [0.5, 0.45, 0.35, 0.28, 0.12];
			var amp3t = [0.28, 0.22, 0.22, 0.2, 0.1];
			var vp = (vowel.clip(0, 1) * 4);
			var viA = vp.floor.clip(0, 4);
			var viB = (viA + 1).clip(0, 4);
			var vf = vp - vp.floor;
			var lerp = { arg tbl; (Select.kr(viA, tbl) * (1 - vf)) + (Select.kr(viB, tbl) * vf) };
			var f1 = (lerp.value(fmt1) * shiftRatio).clip(60, 18000);
			var f2 = (lerp.value(fmt2) * shiftRatio).clip(60, 18000);
			var f3 = (lerp.value(fmt3) * shiftRatio).clip(60, 18000);
			var rqb = q.clip(0.03, 0.5);
			(BPF.ar(s, f1, rqb) + (BPF.ar(s, f2, rqb) * lerp.value(amp2t)) + (BPF.ar(s, f3, rqb) * lerp.value(amp3t))) * 2.0;
		};

		// Filter Mix Mode matrix. mode 0 = Stereo (channels A/B ARE left/right); mode 1 =
		// Mid/Side (A = mid = (L+R)/2, B = side = (L-R)/2, re-encoded L=M+S, R=M-S). Every
		// filter machine decodes -> filters the two channels (with the balance-spread
		// cutoffs) -> encodes, so Stereo/Mid-Side is one shared law across all machines.
		filterDecodeMS = { arg sig, mode;
			var mid = (sig[0] + sig[1]) * 0.5;
			var side = (sig[0] - sig[1]) * 0.5;
			[Select.ar(mode, [sig[0], mid]), Select.ar(mode, [sig[1], side])];
		};
		filterEncodeMS = { arg a, b, mode;
			[Select.ar(mode, [a, a + b]), Select.ar(mode, [b, a - b])];
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
				(Lag.kr(amp, slew) * (1 + In.kr(ampModBus, 1).clip(-1, 1))).max(0) * 2.63)  // +8.4dB makeup: match the raw preview (which bypasses this chain); NOT the sample-gain param, so the waveform view is unaffected;
		};

		// trackIndex feeds SendReply's replyID so the responders can tell which
		// track's chain is reporting (Phase 1 multitrack; default 1 = track 1,
		// whose spawns never pass it -- behavior unchanged).
		SynthDef(\elasticatTransport, {
			arg out=0, playing=0, targetBpm=120, loopBeats=4, resetTrig=0,
			resetPos=0, correction=0, warpRate=1, trackIndex=1;
			var cyclesPerSecond, phase, run;

			run = Lag.kr(playing.clip(0, 1), 0.01);
			// warpRate multiplies the synced loop speed (owner: BPM stays master; a
			// rate of 0.5 plays the loop at half speed, still grid-locked because the
			// Phasor stays sample-accurate at a constant tempo). Lagged so scrubbing
			// the rate knob / p-locking it glides instead of zippering. Every bus-
			// following reader inherits this scaling for free (they read this phase).
			cyclesPerSecond = ((targetBpm.max(1) / 60) / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			phase = Phasor.ar(
				TDelay.kr(Changed.kr(resetTrig), 0.003),  // delayed 3ms so the declick reaches 0 before the jump; monotonic counter; edge-detect it so every set resets
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
			var frames, sFrac, eFrac, span, phase, pos, sig, env;
			frames = BufFrames.kr(bufL).max(4);
			// Lag the region so live trim scrubbing (setPreviewRegion) GLIDES instead
			// of clicking -- the File-page audition mirrors the loop machine's live
			// region scrubbing (design north star).
			sFrac = Lag.kr(startFrac, 0.05);
			eFrac = Lag.kr(endFrac, 0.05);
			span = (eFrac - sFrac).clip(0.0001, 1);
			phase = Phasor.ar(0, BufRateScale.kr(bufL) / (frames * span), 0, 1);
			pos = (sFrac + (phase * span)) * (frames - 1);
			sig = [
				BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)
			];
			env = EnvGen.kr(Env.asr(0.005, 1, 0.02), gate, doneAction: 2);
			sig = sig * Lag.kr(gain.max(0), 0.03) * env;
			Out.ar(out, LeakDC.ar(sig));
		}).add;

		// The DEFAULT tape mode IS the compiled click-free reader now (softcut model):
		// absolute-frame reads + one queued 2-head crossfade, so a region relock / the
		// trig-release return-jump / the loop seam never pop. Guarded -- falls back to
		// the SC-graph direct reader if the .so is missing. tempo_varispeed (transport-
		// synced) keeps its own XFade2 declick until the phase-following reader lands.
		this.addUGenReaderDef(\elasticatTape, 0);
		// tempo_varispeed is now the click-free ElasticatReader too, at the tempo-synced
		// rate (grid-locked; pitch a byproduct of the stretch). Guarded fallback = the
		// SC-graph tempo direct reader.
		this.addUGenReaderDef(\elasticatTempoVarispeed, 1, true);

		SynthDef(\elasticatChopped, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, chopBeats=16, chopMode=2, chopSliceLen=1, chopAttack=0.002, chopHold=0.9, chopRelease=0.01,
			chopRangeStart=0, chopRangeEnd=128, chopPlayLo=0, chopPlayHi=1,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, direction=1, chopReverse=0, trackIndex=1;
			var ampEnv;
			var phase, frames, sig, modeGain, playGate, pitchRatio, startFrac, endFrac, cps, wr, stepSamples, slotSamples, slicePhase, slicePhaseInc, loopPhase, numSlices, sliceDurSamp, attackSamp, releaseSamp, gate, pitchRate, playLo, playHi;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			// DOMINO MODEL (owner): the RANGE (chopRangeStart/End) is the audio, cut into
			// numSlices slices -- the slice area, INDEPENDENT of the track loop. The TRACK
			// window (chopPlayLo/Hi, 0..1 of the full slice-zone space) bounds the PLAYHEAD,
			// so only the slices under the track fire: track 0-8 (SLCS 16) -> slice 1 only,
			// 0-16 -> slices 1-2, 120-128 -> slice 16. Both are sent as separate args by the
			// facade (raw loop for the window, range for the slice area); startPoint/endPoint
			// (the shared loop-folded region) is no longer used for slicing here.
			startFrac = Lag.kr(chopRangeStart.clip(0, 127.99) / 128, 0.002);
			endFrac = Lag.kr(chopRangeEnd.clip(0.01, 128) / 128, 0.002);
			playLo = Lag.kr(chopPlayLo.clip(0, 1), 0.01);
			playHi = Lag.kr(chopPlayHi.clip(0, 1), 0.01).max(playLo + 0.0001);
			// SLICE PLAYER (ElasticatSlicer): the range is cut into numSlices (SLCS) slices;
			// slicePhase (the playhead) sweeps the TRACK window and idx = floor(sp*numSlices)
			// picks the slice. DIRECTION = TRACK REVERSE (playhead backward = slices in reverse
			// order). A 2-head crossfade on each slice change means a long attack / full gate no
			// longer clicks. Gated by playing; resetTrig re-anchors. chopReverse = each slice
			// plays backward; chopHold = GATE (0..1 of the slice duration); chopMode 0-7 decodes
			// to loopMode floor(m/2) + sliceReverse m%2 (8 modes -- per-slice fill behaviour).
			wr = Lag.kr(warpRate.max(0.001), 0.02);
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * wr;
			numSlices = chopBeats.clip(1, 256).round(1);
			// STEP-LOCKED playhead advance: the playhead crosses one slice zone (1/numSlices of
			// the full 0..1) every chopSliceLen (SLEN) steps -- a step = 0.25 beat / a 16th, so
			// a slot = SLEN * 15 * SR / bpm samples, higher BPM -> faster. slicePhase sweeps only
			// [playLo, playHi] (the track window) and wraps there; resetTrig re-anchors it to the
			// window edge. Inside a slot the slice loops-to-fill (LOOP mode). DECOUPLED: SLCS
			// (chopBeats) cuts the range, SLEN sets playhead speed, TRACK sets which slices fire.
			stepSamples = (15 * SampleRate.ir / (targetBpm.max(1) * wr)).max(1);
			slotSamples = (chopSliceLen.clip(0.05, 64) * stepSamples).max(1);
			slicePhaseInc = (1 / (numSlices.max(1) * slotSamples)) * direction * playing.clip(0, 1);
			slicePhase = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), slicePhaseInc, playLo, playHi, Select.kr(direction > 0, [playHi, playLo]));
			// Separate loop-position phasor for the UI playhead -- slicePhase is now the
			// internal slice cursor, no longer the loop position.
			loopPhase = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), (cps / SampleRate.ir) * direction * playing.clip(0, 1), 0, 1, resetPos.clip(0, 0.999999));
			sliceDurSamp = slotSamples;
			attackSamp = (chopAttack.clip(0.0001, 0.5) * SampleRate.ir).max(1);
			releaseSamp = (chopRelease.clip(0.0001, 0.5) * SampleRate.ir).max(1);
			gate = chopHold.clip(0, 1);
			pitchRate = BufRateScale.kr(bufL) * pitchRatio;
			sig = if(\ElasticatSlicer.asClass.notNil, {
				ElasticatSlicer.ar(bufL, bufR, slicePhase, startFrac, endFrac, numSlices, attackSamp, releaseSamp, gate, sliceDurSamp, (chopMode.clip(0, 7) / 2).floor, chopMode.clip(0, 7) % 2, pitchRate)
			}, {
				// Fallback (plugin absent): a plain region read (no slicing/crossfade).
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), (endFrac - startFrac) * frames * cps / SampleRate.ir * direction * playing.clip(0, 1), startFrac * frames, endFrac * frames, startFrac * frames);
				[BufRd.ar(1, bufL, ph, loop: 1, interpolation: 4), BufRd.ar(1, bufR, ph, loop: 1, interpolation: 4)]
			});
			phase = loopPhase;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				2, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- WARP MODE 16: Chopped (Digitakt-style hacky timestretch) --------------
		// No timestretch UGen: a clock-synced LINEAR RAMP (a Phasor over the loop)
		// sweeps the read START across the region -- the classic trick of an LFO on
		// Sample Start + a trig every step. An internal step clock (Impulse, one grain
		// per SLEN steps) LATCHES the ramp and re-anchors a NATURAL-pitch read there;
		// an AHR grain envelope gates each step. Each grain plays a different slice of
		// the sample; stitched at the main tempo they reconstruct it (native BPM) or
		// stretch it (any other BPM). Cheap -- one Phasor + Impulse + Latch + Sweep +
		// 2 BufRd + one EnvGen -- so it does not lag the UI like the slice bank did.
		SynthDef(\elasticatChopSync, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, chopSliceLen=1, chopAttack=0.002, chopHold=0.9, chopRelease=0.01,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, direction=1, trackIndex=1;
			var ampEnv;
			var frames, startFrac, endFrac, wr, cps, rampPhase, stepFreq, stepTrig, slotDur,
			latchedStart, readStart, readPos, grainEnv, gateFrac, sustainTime, sig, pitchRatio,
			pitchRate, modeGain, playGate, phase;
			frames = BufFrames.kr(bufL).max(4);
			wr = Lag.kr(warpRate.max(0.001), 0.02);
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * wr;
			startFrac = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.01);
			endFrac = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.01);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			pitchRate = BufRateScale.kr(bufL) * pitchRatio;
			// Linear ramp synced to the loop (0->1 over loopBeats); direction = reverse.
			rampPhase = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003),
				(cps / SampleRate.ir) * direction * playing.clip(0, 1), 0, 1, resetPos.clip(0, 0.999999));
			// One grain every SLEN steps (a step = 1/4 beat -> steps/sec = bpm*wr/15).
			stepFreq = ((targetBpm.max(1) * wr / 15) / chopSliceLen.clip(0.05, 64)).max(0.01);
			slotDur = 1 / stepFreq;
			stepTrig = Impulse.ar(stepFreq * playing.clip(0, 1));
			// Latch the ramp at each trig = the grain start (fixed for the grain), mapped
			// through the region; the grain reads forward from there at natural pitch.
			latchedStart = Latch.ar(rampPhase, stepTrig);
			readStart = (startFrac + (latchedStart * (endFrac - startFrac))) * frames;
			readPos = readStart + Sweep.ar(stepTrig, pitchRate * SampleRate.ir);
			sig = [BufRd.ar(1, bufL, readPos, loop: 1, interpolation: 4),
				BufRd.ar(1, bufR, readPos, loop: 1, interpolation: 4)];
			// AHR grain gate (owner: the envelope gates each step). GATE (chopHold 0..1)
			// = the fraction of the slot the grain sounds; ATK/REL taper it (declick).
			gateFrac = chopHold.clip(0.01, 1);
			sustainTime = ((gateFrac * slotDur) - chopAttack - chopRelease).max(0.0005);
			grainEnv = EnvGen.ar(Env.new([0, 1, 1, 0],
				[chopAttack.clip(0.0002, 0.5), sustainTime, chopRelease.clip(0.0002, 0.5)],
				[\sin, \lin, \sin]), gate: stepTrig);
			sig = sig * grainEnv;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			phase = rampPhase;
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				16, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
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
			pitchModBus=0, warpRate=1, loopXfade=0.01, grainSpeed=1, grainSpeedRand=0, grainDirection=1, direction=1, trackIndex=1;
			var ampEnv;
			var phase, frames, sig, modeGain, playGate, gainNorm, startNorm, range, readPhase, pitchRatio, scanCps, emitInc, emitPh, grainRate, density, cycleMs, spread;
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			// PARTICLE GRANULAR (ElasticatGrains) with INDEPENDENT pitch + time.
			// TIME: the emit cursor is a Phasor scanning the range at grainSpeed x the
			// tempo -- 1 = realtime, <1 = time-stretch, 0 = frozen (pitched drone), and
			// DIRECTION reverses the scan (reverse moves the playhead backward). Fenced to
			// the range; resetTrig re-anchors it (loop/step). Gated by playing.
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			scanCps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			emitInc = scanCps * Lag.kr(grainSpeed.clip(0, 4), 0.05) * playing.clip(0, 1) * direction / SampleRate.ir;
			emitPh = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), emitInc, 0, 1, resetPos.clip(0, 0.999999));
			readPhase = (startNorm + (emitPh * range)).clip(0, 0.999999);
			// Report the EMIT scan (0..1 over range) as the playhead so the UI follows the
			// grains -- slowed by grainSpeed and moving BACKWARD on reverse (not the transport).
			phase = emitPh;
			// PITCH: each grain reads at the pitch ratio, native-referenced -- INDEPENDENT
			// of grain speed (that's the decoupling: slowing the scan no longer drops pitch).
			grainRate = BufRateScale.kr(bufL) * pitchRatio;
			density = grainOverlap.clip(1, 64);
			cycleMs = Lag.kr(grainSize.clip(0.002, 0.5), 0.05) * 1000;
			spread = Lag.kr((grainJitter + grainSpray).clip(0, 1), 0.05);
			sig = if(\ElasticatGrains.asClass.notNil, {
				ElasticatGrains.ar(bufL, bufR, readPhase, density, cycleMs, spread, grainRate, grainSpeedRand.clip(0, 1), grainDirection.clip(0, 1))
			}, {
				// Fallback (plugin absent): the old Warp1 cloud around the emit cursor.
				[
					Warp1.ar(1, bufL, readPhase, pitchRatio, Lag.kr(grainSize.clip(0.02, 0.5), 0.05), -1, density.clip(2, 32), spread.clip(0, 0.25), 4),
					Warp1.ar(1, bufR, readPhase, pitchRatio, Lag.kr(grainSize.clip(0.02, 0.5), 0.05), -1, density.clip(2, 32), spread.clip(0, 0.25), 4)
				]
			});
			gainNorm = density.max(1).sqrt.reciprocal * 3;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * gainNorm * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				3, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- GStretch (mode 12): stretch-focused clone of GText ------------------
		// A STANDALONE copy of the GText particle engine so it can be tuned for clean
		// pitch-preserving time-stretch WITHOUT touching the locked GText. Same DSP
		// today; the Lua side exposes a simpler stretch surface (STRETCH/GSIZ/SMTH).
		SynthDef(\elasticatGStretch, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.08, grainOverlap=8, grainJitter=0.0, grainSpray=0.0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, grainSpeed=1, grainSpeedRand=0, grainDirection=1, direction=1, trackIndex=1;
			var ampEnv;
			var phase, frames, sig, src, modeGain, playGate, pitchRatio, strch, loopStartF, loopEndF, readerRate, resetFrame, shiftRatio, win, smth;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			// STRETCH = a VARISPEED read (owner's idea): read the buffer slower to time-
			// stretch (pitched down), then a real-time PITCH-SHIFTER restores the pitch, so
			// pitch is held independent of stretch. The read reuses the click-free
			// ElasticatReader so loop jumps / region scrub / seam stay clean; the shifter
			// runs at time-ratio 1 (no buffering). SC PitchShift now; RubberBand can drop in
			// as the shifter for studio quality.
			strch = Lag.kr(grainSpeed.clip(0.0625, 4), 0.05);
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			readerRate = BufRateScale.kr(bufL) * strch * Lag.kr(warpRate.max(0.001), 0.02) * playing.clip(0, 1) * direction;
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			src = if(\ElasticatReader.asClass.notNil, {
				var rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, readerRate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
				phase = rd[2];
				[rd[0], rd[1]]
			}, {
				// Fallback (plugin absent): plain varispeed Phasor read (not click-free).
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), readerRate, loopStartF, loopEndF, resetFrame);
				phase = ((ph - loopStartF) / (loopEndF - loopStartF).max(1)).clip(0, 1);
				[BufRd.ar(1, bufL, ph, 1, 4), BufRd.ar(1, bufR, ph, 1, 4)]
			});
			// PITCH-CORRECT: the read is pitched by (strch * warpRate); shift by the inverse
			// times the pitch knob so final pitch = pitchRatio, independent of stretch.
			shiftRatio = (pitchRatio / (strch * Lag.kr(warpRate.max(0.001), 0.02))).clip(0.25, 4);
			win = Lag.kr(grainSize.clip(0.02, 0.5), 0.05);
			// SMTH: PitchShift time dispersion (same mapping as GStretch2 -- these two modes
			// are identical apart from GStretch2's clock-lock). Default grain_density 8 keeps
			// dispersion low, ~the fixed value GStretch used before.
			smth = Lag.kr(((grainOverlap.clip(1, 64) - 1) / 63), 0.05);
			sig = PitchShift.ar(src, win, shiftRatio, 0, smth * win);
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				12, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- GStretch2 (mode 13): BPM/clock-synced stretch -----------------------
		// Like GStretch (varispeed reader + pitch-correct) but the read rate is TEMPO-
		// derived: the region traverses once per loop (loopBeats), so a 16-step sample
		// loops every 16 steps at STRCH=warp=1. STRCH + warpRate deviate from the grid;
		// pitch is HELD (the shift corrects the grid-sync speed back to native). SMTH =
		// pitch-shifter time dispersion (higher = smoother / less metallic).
		SynthDef(\elasticatGStretch2, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, grainSize=0.08, grainOverlap=8, grainJitter=0.0, grainSpray=0.0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, grainSpeed=1, grainSpeedRand=0, grainDirection=1, direction=1, trackIndex=1;
			var ampEnv;
			var phase, frames, sig, src, modeGain, playGate, pitchRatio, strch, loopStartF, loopEndF, cps, readerRateBase, readerRate, resetFrame, shiftRatio, win, smth;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			strch = Lag.kr(grainSpeed.clip(0.0625, 4), 0.05);
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			// TEMPO-SYNCED read: region traverses once per loop at STRCH=warp=1 (grid-lock).
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			readerRateBase = (loopEndF - loopStartF) * cps / SampleRate.ir * strch;
			readerRate = readerRateBase * playing.clip(0, 1) * direction;
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			src = if(\ElasticatReader.asClass.notNil, {
				var rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, readerRate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
				phase = rd[2];
				[rd[0], rd[1]]
			}, {
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), readerRate, loopStartF, loopEndF, resetFrame);
				phase = ((ph - loopStartF) / (loopEndF - loopStartF).max(1)).clip(0, 1);
				[BufRd.ar(1, bufL, ph, 1, 4), BufRd.ar(1, bufR, ph, 1, 4)]
			});
			// PITCH-CORRECT to native: shift = native / readBase * pitch knob, so grid-sync
			// (or STRCH) changes SPEED but not pitch. SMTH -> PitchShift time dispersion.
			shiftRatio = (pitchRatio * BufRateScale.kr(bufL) / readerRateBase.max(0.0001)).clip(0.25, 4);
			win = Lag.kr(grainSize.clip(0.02, 0.5), 0.05);
			smth = Lag.kr(((grainOverlap.clip(1, 64) - 1) / 63), 0.05);
			sig = PitchShift.ar(src, win, shiftRatio, 0, smth * win);
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				13, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
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
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var ampEnv;
			var phase, frames, trig, dur, rate, chaos, pos, offset, direct, wet, sig, modeGain, playGate, gainNorm, loopStartF, loopEndF, cps, readerRate, resetFrame, readPhaseBuf, stepDur, overlapControl, wanderControl, pitchRatio;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			// DIRECT read = the click-free tempo-synced ElasticatReader; the TGrains cloud
			// reads around the same playhead (its grains are windowed = already declicked).
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			readerRate = (loopEndF - loopStartF) * cps / SampleRate.ir * playing.clip(0, 1);
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			direct = if(\ElasticatReader.asClass.notNil, {
				var rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, readerRate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
				phase = rd[2];
				[rd[0], rd[1]]
			}, {
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), readerRate, loopStartF, loopEndF, resetFrame);
				phase = ((ph - loopStartF) / (loopEndF - loopStartF).max(1)).clip(0, 1);
				[BufRd.ar(1, bufL, ph, loop: 1, interpolation: 4), BufRd.ar(1, bufR, ph, loop: 1, interpolation: 4)]
			});
			readPhaseBuf = ((loopStartF + (phase * (loopEndF - loopStartF))) / frames).clip(0, 0.999999);
			dur = Lag.kr(grainSize.clip(0.03, 0.6), 0.05);
			stepDur = 15 / targetBpm.max(1);
			overlapControl = Lag.kr(grainOverlap.clip(1, 64), 0.05);
			rate = (overlapControl / stepDur).clip(1, 240);
			trig = Impulse.ar(rate);
			chaos = macro.clip(0, 1);
			wanderControl = Lag.kr(wander.clip(0, 0.25), 0.05);
			offset = TRand.ar(wanderControl.neg, wanderControl, trig) * (0.25 + chaos);
			pos = ((readPhaseBuf * BufDur.kr(bufL)) + offset + (TRand.ar(timingJitter.neg, timingJitter, trig) * chaos)).wrap(0, BufDur.kr(bufL).max(0.001));
			wet = [
				TGrains.ar(1, trig, bufL, pitchRatio, pos, dur, 0, 1, 4),
				TGrains.ar(1, trig, bufR, pitchRatio, pos, dur, 0, 1, 4)
			];
			sig = XFade2.ar(direct, wet, macro.linlin(0, 1, -0.75, 0.25));
			gainNorm = overlapControl.sqrt.reciprocal * 2.5;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * gainNorm * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
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
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var ampEnv;
			var phase, frames, raw, shifted, ratio, sig, modeGain, playGate, window, loopStartF, loopEndF, cps, readerRate, resetFrame, pitchRatio;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio;
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			// Click-free tempo-synced READ (ElasticatReader) -> pitch-CORRECT by
			// derivedSourceBpm/targetBpm so the loop locks to tempo at the source pitch.
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			readerRate = (loopEndF - loopStartF) * cps / SampleRate.ir * playing.clip(0, 1);
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			raw = if(\ElasticatReader.asClass.notNil, {
				var rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, readerRate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
				phase = rd[2];
				[rd[0], rd[1]]
			}, {
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), readerRate, loopStartF, loopEndF, resetFrame);
				phase = ((ph - loopStartF) / (loopEndF - loopStartF).max(1)).clip(0, 1);
				[BufRd.ar(1, bufL, ph, loop: 1, interpolation: 4), BufRd.ar(1, bufR, ph, loop: 1, interpolation: 4)]
			});
			ratio = (derivedSourceBpm.max(1) / targetBpm.max(1) * pitchRatio).clip(0.5, 2);
			window = Lag.kr(pvWindow.clip(0.005, 2), 0.05) * (1 + macro.clip(0, 1));
			shifted = PitchShift.ar(raw, window, ratio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvTimeDispersion.clip(0, 1), 0.05));
			sig = shifted;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				5, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- WARP MODE 6: Harmonizer (loop-only for now; slice falls back to raw) --
		// Dry read at the transport rate PLUS a granular pitch-shifted harmony, so
		// timing stays locked (unlike a varispeed harmony). macro = harmony LEVEL
		// (dry is always present). harmInterval = the interval; pitchMod -> interval.
		SynthDef(\elasticatHarmonizer, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0.5,
			startPoint=0, endPoint=128, harmInterval=7, harmInterval2=0, harmInterval3=0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var ampEnv, phase, frames, loopStartF, loopEndF, cps, readerRate, resetFrame, dry, harmRatio, harmRatio2, harmRatio3, g1, g2, g3, wetL, wetR, sig, modeGain, playGate, mix;
			frames = BufFrames.kr(bufL).max(4);
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			// Click-free tempo-synced dry READ (ElasticatReader); the harmonies shift it.
			cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
			readerRate = (loopEndF - loopStartF) * cps / SampleRate.ir * playing.clip(0, 1);
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			dry = if(\ElasticatReader.asClass.notNil, {
				var rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, readerRate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
				phase = rd[2];
				[rd[0], rd[1]]
			}, {
				var ph = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), readerRate, loopStartF, loopEndF, resetFrame);
				phase = ((ph - loopStartF) / (loopEndF - loopStartF).max(1)).clip(0, 1);
				[BufRd.ar(1, bufL, ph, loop: 1, interpolation: 4), BufRd.ar(1, bufR, ph, loop: 1, interpolation: 4)]
			});
			// Three stacked harmony voices -- an interval of 0 turns that voice OFF
			// (owner); the lagged gate glides a voice in/out of the chord (no click).
			harmRatio = (Lag.kr(harmInterval, 0.05) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.25, 4);
			harmRatio2 = (Lag.kr(harmInterval2, 0.05) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.25, 4);
			harmRatio3 = (Lag.kr(harmInterval3, 0.05) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.25, 4);
			g1 = Lag.kr(harmInterval.abs > 0.5, 0.02);
			g2 = Lag.kr(harmInterval2.abs > 0.5, 0.02);
			g3 = Lag.kr(harmInterval3.abs > 0.5, 0.02);
			wetL = (PitchShift.ar(dry[0], 0.2, harmRatio, 0, 0.004) * g1) + (PitchShift.ar(dry[0], 0.2, harmRatio2, 0, 0.004) * g2) + (PitchShift.ar(dry[0], 0.2, harmRatio3, 0, 0.004) * g3);
			wetR = (PitchShift.ar(dry[1], 0.2, harmRatio, 0, 0.004) * g1) + (PitchShift.ar(dry[1], 0.2, harmRatio2, 0, 0.004) * g2) + (PitchShift.ar(dry[1], 0.2, harmRatio3, 0, 0.004) * g3);
			mix = macro.clip(0, 1);
			sig = [dry[0] + (wetL * mix), dry[1] + (wetR * mix)] * 0.6;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				6, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- WARP MODE 7: Wavetable Scan (loop-only for now) ----------------------
		// The PLAYHEAD has no meaning here (owner). The loop start/end define an
		// audio RANGE; that range is the wavetable BANK. WSIZ (wtWindow) is now a
		// SLICE COUNT: the range is cut into that many equal single-cycle slices.
		// MORF (macro) is the scan position across the bank and CROSSFADES between
		// adjacent slice cycles, so morphing is smooth even with just 2 slices. A
		// built-in LFO (rate/depth/shape) auto-scans MORF. Each cycle is read with
		// two half-window Hann taps so its wrap never clicks. An oscillator (freq
		// from pitch, base C3) plays the interpolated cycle. Changing the range or
		// slice count instantly rebuilds the bank -- a weird wavetable synth.
		SynthDef(\elasticatWavetable, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, wtWindow=8, wtCycle=600,
			wtLfoRate=0, wtLfoDepth=64, wtLfoShape=0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var ampEnv, frames, startFrac, endFrac, slices, cycleLen, morphBase, lfoDepthSigned, freq, xfadeSamp, scanPhase, sig, modeGain, playGate;
			frames = BufFrames.kr(bufL).max(4);
			startFrac = startPoint.clip(0, 127.99) / 128;
			endFrac = endPoint.clip(startPoint + 0.01, 128) / 128;
			slices = wtWindow.round(1).clip(2, 64);
			cycleLen = wtCycle.clip(16, 8192);
			morphBase = Lag.kr(macro.clip(0, 1), 0.02);
			// Depth is a SIGNED 0-128 control (64 = off): the UGen adds unipolar LFO *
			// this to MORF. LFO shape 0 sin / 1 tri / 2 saw / 3 s&h / 4 rand.
			lfoDepthSigned = Lag.kr(((wtLfoDepth - 64) / 64).clip(-1, 1), 0.05);
			freq = (130.81 * ((Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio)).clip(1, 12000);
			xfadeSamp = (loopXfade.clip(0.0005, 0.5) * SampleRate.ir).max(1);
			// UGen wavetable: click-free loop start/end via a queued equal-power REGION
			// crossfade + an internal AUDIO-RATE morph LFO. start/end pass RAW (no Lag)
			// so the UGen sees jumps and declicks them itself (softcut model).
			sig = if(\ElasticatWavetable.asClass.notNil, {
				ElasticatWavetable.ar(bufL, bufR, startFrac, endFrac, slices, cycleLen, morphBase, freq, wtLfoRate.max(0), lfoDepthSigned, wtLfoShape.clip(0, 4), xfadeSamp)
			}, {
				// Fallback (plugin absent): the prior BufRd wavetable -- kr LFO, no region
				// crossfade (clicks on loop start/end), but keeps sound if the .so is gone.
				var startNorm, range, rangeStart, rangeLen, step, lfo, morphPos, sliceF, si, frac, startA, startB, wtPhase, p2, w1, w2, aL, aR, bLx, bRx, cLen;
				startNorm = Lag.kr(startFrac, 0.01);
				range = Lag.kr((endFrac - startFrac).clip(0.0001, 1), 0.01);
				rangeStart = startNorm * (frames - 1);
				rangeLen = (range * frames).max(8);
				cLen = cycleLen.min(rangeLen);
				step = (rangeLen - cLen).max(0) / (slices - 1).max(1);
				lfo = Select.kr(wtLfoShape.clip(0, 4), [
					SinOsc.kr(wtLfoRate.max(0)), LFTri.kr(wtLfoRate.max(0)),
					LFSaw.kr(wtLfoRate.max(0)), LFNoise0.kr(wtLfoRate.max(0)), LFNoise1.kr(wtLfoRate.max(0))
				]);
				lfo = (lfo + 1) * 0.5;
				morphPos = (morphBase + (lfo * lfoDepthSigned)).clip(0, 1);
				sliceF = morphPos * (slices - 1);
				si = sliceF.floor;
				frac = sliceF - si;
				startA = rangeStart + (si * step);
				startB = rangeStart + ((si + 1).min(slices - 1) * step);
				wtPhase = Phasor.ar(0, freq * cLen / SampleRate.ir, 0, cLen);
				p2 = (wtPhase + (cLen * 0.5)).wrap(0, cLen);
				w1 = (sin((wtPhase / cLen) * pi)).squared;
				w2 = (sin((p2 / cLen) * pi)).squared;
				aL = (BufRd.ar(1, bufL, startA + wtPhase, loop: 1, interpolation: 4) * w1) + (BufRd.ar(1, bufL, startA + p2, loop: 1, interpolation: 4) * w2);
				bLx = (BufRd.ar(1, bufL, startB + wtPhase, loop: 1, interpolation: 4) * w1) + (BufRd.ar(1, bufL, startB + p2, loop: 1, interpolation: 4) * w2);
				aR = (BufRd.ar(1, bufR, startA + wtPhase, loop: 1, interpolation: 4) * w1) + (BufRd.ar(1, bufR, startA + p2, loop: 1, interpolation: 4) * w2);
				bRx = (BufRd.ar(1, bufR, startB + wtPhase, loop: 1, interpolation: 4) * w1) + (BufRd.ar(1, bufR, startB + p2, loop: 1, interpolation: 4) * w2);
				[(aL * (1 - frac)) + (bLx * frac), (aR * (1 - frac)) + (bRx * frac)]
			});
			scanPhase = morphBase;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			// No readerDeclick: this mode is playhead-INDEPENDENT (the oscillator scans,
			// it doesn't follow the loop playhead), so resetTrig must not dip the amp every
			// loop; the UGen already declicks region changes with its own crossfade.
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			// Report the SCAN position (not a playhead) so the UI marker shows where
			// in the range the wavetable window sits.
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				7, scanPhase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// --- WARP MODES 9 + 10: Spectral (Freeze + Formant), one shared FFT def ----
		// TRACK-1-ONLY (spawnMode falls back to tape elsewhere): one MONO FFT chain
		// is affordable, 8 are not. Both controls are always live. FREEZE holds the
		// magnitude spectrum at the playhead into a drone; BLUR smears it; FORMANT
		// shifts the spectral envelope (PV_MagShift, pitch-preserving); the track
		// PITCH shifts the bin frequencies independently (PV_BinShift), so the
		// keyboard plays either mode. Input is summed to mono -> centered in both
		// channels. FFT adds ~fftSize/2 samples of latency -- fine for pads. Loop-only.
		SynthDef(\elasticatSpectral, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, targetBpm=120, loopBeats=4, macro=0,
			startPoint=0, endPoint=128, freezeAmount=0, spectralBlur=0, formantShift=0,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var ampEnv, phase, frames, startNorm, range, readPhase, pos, mono, sigMono, freezeGate, blur, fShift, pitchRatio, chain, sig, modeGain, playGate;
			phase = In.ar(phaseBus, 1);
			frames = BufFrames.kr(bufL).max(4);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			readPhase = (startNorm + (phase * range)).clip(0, 0.999999);
			pos = readPhase * (frames - 1);
			// Sum to mono BEFORE the FFT: one chain (half the CPU of two) and, crucially,
			// a centered output in BOTH channels. The old per-channel version dropped to
			// the left only (a stereo LocalBuf/IFFT pairing issue); a frozen / formant
			// drone has no meaningful stereo image anyway, so mono -> centered is right.
			mono = (BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4) + BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)) * 0.5;
			freezeGate = Lag.kr(freezeAmount.clip(0, 1), 0.1);
			blur = Lag.kr(spectralBlur.clip(0, 1), 0.1) * 16;
			// FORMANT: PV_MagShift stretches the MAGNITUDE-bin positions -- a
			// multiplicative (octave-per-doubling) envelope shift, pitch-preserving.
			fShift = Lag.kr(formantShift, 0.1).midiratio.clip(0.25, 4);
			// PITCH: PV_BinShift stretches the bin FREQUENCIES -- an independent pitch
			// shift (formants stay put), driven by the track pitch + pitch mod, so the
			// keyboard plays both Spectral Freeze and Formant.
			pitchRatio = (Lag.kr(pitch, 0.05) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.25, 4);
			chain = FFT(LocalBuf(2048), mono);
			chain = PV_MagFreeze(chain, freezeGate);
			chain = PV_MagSmear(chain, blur);
			chain = PV_MagShift(chain, fShift, 0);
			chain = PV_BinShift(chain, pitchRatio, 0);
			sigMono = IFFT(chain);
			sig = [sigMono, sigMono];
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv * readerDeclick.value(resetTrig));
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				8, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;

		// ONE slice-voice SynthDef per warp mode. The old single def computed raw
		// + Warp1 (grain) + TGrains (ola) + PitchShift (pc) ALL at once and
		// Select'd one -- 145 UGens per voice, which cliffed norns CPU with a few
		// concurrent slices (audio dropped out / the server crashed). Warp mode is
		// a build-time constant here (a `switch` builds only the matching branch's
		// UGens), and a voice is spawned with a FIXED warp (triggerSlice picks the
		// def by the track's warp mode, which cannot change mid-playback), so every
		// live slice runs a lean def -- raw is ~a dozen UGens instead of 145.
		//   warp modes: 0 tape / 1 varispeed / 2 chopped -> raw; 3 granular; 4
		//   random_ola; 5 pitch_corrected. (Matches the old Select order.)
		[\raw, \grain, \ola, \pc].do({ arg warpKind;
			SynthDef(("elasticatSliceVoice_" ++ warpKind).asSymbol, {
				arg out=0, bufL=0, bufR=0,
				startPoint=0, endPoint=8, playMode=0, reverse=0,
				amp=0.8, pan=0, pitch=0, velocity=1, gate=1,
				sliceAttack=0.002, sliceRelease=0.02,
				envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
				lengthSeconds=0, syncToClock=1, sliceRate=1,
				targetBpm=120, derivedSourceBpm=120, macro=0, grainSize=0.08, grainOverlap=8,
				grainJitter=0, wsolaWindow=0.1, wsolaSearch=0.03,
				pvWindow=0.2, pvDispersion=0, pitchModBus=0, steal=0, tempoMode=0;
				var frames, startFrame, endFrame, loFrame, hiFrame, continueMode, readLo, readHi, loopMode;
				var directionSign, resetFrame, rangeFrames, duration, pitchRatio, freePitchRatio, freeRate, syncedRate, readRate;
				var pos, loopPos, sweepFrames, sweepForwardPos, sweepReversePos, sweepPos, readPhase, env, sig, playAmp;
				var grainDur, grainCount, grainRandom, olaTrig, olaPos, stealFade, sweptFrames, oneShotOpen, noteGate;
				var pingPongMode, pingPongPos, posMode;

				frames = BufFrames.kr(bufL).max(4);
				startFrame = (startPoint.clip(0, 127.99) / 128) * (frames - 1);
				endFrame = (endPoint.clip(0.01, 128) / 128) * (frames - 1);
				loFrame = startFrame.min(endFrame).clip(0, frames - 2);
				hiFrame = startFrame.max(endFrame).clip(loFrame + 1, frames - 1);
				// Play modes: 0 One-Shot, 1 Hold, 2 Loop, 3 Continue, 4 Ping-Pong,
				// 5 Continue-Loop. continueMode extends the read to the SAMPLE END
				// (Continue + Continue-Loop). loopMode uses the wrapping Phasor (Loop +
				// Continue-Loop -- the latter loops [0, sample end] starting at the slice,
				// so it plays on past the slice and then keeps looping the whole sample).
				// pingPongMode bounces within the slice range. One-Shot/Hold/Continue
				// read the one-shot sweep.
				// NB: `==` is object identity on UGens, not a signal op -- use the
				// integer-distance form (playMode is an integer control).
				continueMode = (((playMode - 3).abs < 0.5) + ((playMode - 5).abs < 0.5)).clip(0, 1);
				loopMode = (((playMode - 2).abs < 0.5) + ((playMode - 5).abs < 0.5)).clip(0, 1);
				pingPongMode = ((playMode - 4).abs < 0.5);
				readLo = loFrame * (1 - continueMode);
				readHi = (hiFrame * (1 - continueMode)) + ((frames - 1) * continueMode);
				directionSign = 1 - (reverse.clip(0, 1) * 2);
				resetFrame = (startFrame * (1 - reverse.clip(0, 1))) + (endFrame * reverse.clip(0, 1));
				resetFrame = resetFrame.clip(readLo, readHi);
				rangeFrames = (readHi - readLo).max(1);
				duration = lengthSeconds.max(0.005);
				pitchRatio = (Lag.kr(pitch, 0.01) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.03125, 32);
				// raw reads the buffer at the pitched rate; the warp UGens apply pitch
				// themselves, so their read position advances at 1x (build-time choice).
				// RAW voice = tape(0)+chopped(2) [pitch applies] AND tempo_varispeed(1)
				// [pitch IGNORED: it stretches to tempo/RATE, not a pitch control].
				freePitchRatio = if(warpKind == \raw, { Select.kr(tempoMode, [pitchRatio, DC.kr(1)]) }, { DC.kr(1) });
				// Read rate (owner: warp modes must match the loop machine, keyed to the
				// WHOLE sample's tempo, not a per-slice fit). CLOCK SYNC ON -> the slice
				// plays at the same rate the loop reader plays the whole sample when
				// tempo-matched: natural rate x (targetBpm / derivedSourceBpm). Matched
				// (target==source) that is exactly 1.0 (no pitch shift), and changing the
				// BPM scales it -- so a chop sounds like the loop locked to that segment.
				// CLOCK SYNC OFF -> the RATE knob (freeRate) speeds up / slows down the
				// slice directly. `duration` no longer feeds the rate (it was a fit-to-
				// lifetime stretch that made Continue a slow aliased crawl); it is now
				// only the gate/lifetime.
				// SYNC = quantize TIMING, not warp the audio; behaviour keys off the warp
				// mode. ONE rate = BufRateScale x freePitchRatio x (SYNC ? syncScale : RATE).
				// Under SYNC ON: WARP voices always use the tempo ratio; the RAW voice uses
				// 1 (NATIVE) for tape/chopped (tempoMode 0) and the tempo ratio for tempo_
				// varispeed (tempoMode 1). freePitchRatio is already 1 for tempo_varispeed so
				// its pitch is ignored; tape/chopped keep pitch. SYNC OFF = the RATE knob for
				// all. (One product chain -- the raw voice has a hard UGen budget of 120.)
				syncedRate = if(warpKind == \raw, {
					Select.kr(tempoMode, [DC.kr(1), targetBpm / derivedSourceBpm.max(1)]);
				}, {
					targetBpm / derivedSourceBpm.max(1);
				});
				readRate = BufRateScale.kr(bufL) * freePitchRatio * Select.kr(syncToClock.clip(0, 1), [sliceRate.max(0.03125), syncedRate]) * directionSign;
				loopPos = Phasor.ar(
					// Reset to resetFrame (the SLICE start) at voice spawn. Without this the
					// Phasor starts at `start` = readLo, which continue modes force to 0 (the
					// SAMPLE start) -- so Continue-Loop began at the sample start, not the slice.
					Impulse.ar(0),
					readRate,
					readLo,
					readHi.max(readLo + 1),
					resetFrame
				);
				// Sweep is reset at spawn too, so Continue (one-shot) starts at resetFrame.
				sweepFrames = Sweep.ar(Impulse.ar(0), readRate.abs * SampleRate.ir);
				sweepForwardPos = resetFrame + sweepFrames;
				sweepReversePos = resetFrame - sweepFrames;
				sweepPos = Select.ar(reverse.clip(0, 1), [sweepForwardPos, sweepReversePos]);
				// Ping-pong: fold the (abs) sweep into the range so it bounces
				// forward/back between readLo and readHi.
				pingPongPos = readLo + sweepFrames.fold(0, rangeFrames);
				// pos source: 0 = one-shot sweep (Shot/Hold/Continue), 1 = wrapping loop
				// (Loop/Continue-Loop), 2 = ping-pong bounce.
				posMode = ((loopMode * 1) + (pingPongMode * 2)).clip(0, 2);
				pos = Select.ar(posMode, [sweepPos.clip(readLo, readHi), loopPos, pingPongPos]);
				readPhase = (pos / (frames - 1)).clip(0, 0.999999);
				// noteGate: how the voice's release is triggered, per play mode (owner).
				//  * One-Shot (playMode 0) ignores the external gate and releases when
				//    the read reaches the END of the slice range, so the whole slice
				//    plays through regardless of step length.
				//  * Hold / Loop / Continue use the EXTERNAL gate: the step's note length
				//    closes it (the trigger Routine), or a live key release does
				//    (releaseSlice). So releasing a held Continue/Loop actually stops it,
				//    and a longer step gates a longer note.
				sweptFrames = A2K.kr(sweepFrames);
				oneShotOpen = (sweptFrames < rangeFrames);
				noteGate = Select.kr((playMode <= 0), [gate, oneShotOpen]);
				// ONE gate-responsive amp envelope. The "hold" for AHR is the gate-open
				// time (sustain at peak until the gate closes), so gate-off ALWAYS
				// releases the voice -- an AHR one-shot that IGNORED gate-off was the
				// stuck-note bug (Continue with an INF hold played forever). ADSR sustains
				// at S, AHR at 1; releaseNode 2 waits for the gate, doneAction 2 frees on
				// release. RELEASE is bounded to 2s so an INF default can never strand a
				// voice. envMode: 0 = ADSR, 1 = AHR.
				env = EnvGen.kr(
					Env([0, 1, Select.kr(envMode.clip(0, 1), [envSustain.clip(0, 1), 1]), 0],
						[envAttack.max(0.0001),
						 Select.kr(envMode.clip(0, 1), [envDecay.max(0.0001), 0.0001]),
						 envRelease.clip(0.0001, 2)],
						[-4, -4, -4], releaseNode: 2),
					noteGate, doneAction: 2);
				// Only THIS warp's UGens are built (warpKind is a build-time constant).
				sig = switch(warpKind,
					\raw, {
						[BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
						 BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)]
					},
					\grain, {
						grainDur = Lag.kr(grainSize.clip(0.002, 0.5), 0.05);
						grainCount = Lag.kr(grainOverlap.clip(1, 64), 0.05);
						grainRandom = Lag.kr((grainJitter + (macro * 0.03)).clip(0, 0.25), 0.05);
						[Warp1.ar(1, bufL, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4),
						 Warp1.ar(1, bufR, readPhase, pitchRatio, grainDur, -1, grainCount, grainRandom, 4)]
					},
					\ola, {
						grainCount = Lag.kr(grainOverlap.clip(1, 64), 0.05);
						olaTrig = Impulse.ar((grainCount / Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05)).clip(1, 240));
						olaPos = ((readPhase * BufDur.kr(bufL)) + TRand.ar(wsolaSearch.neg, wsolaSearch, olaTrig)).wrap(0, BufDur.kr(bufL).max(0.001));
						[TGrains.ar(1, olaTrig, bufL, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4),
						 TGrains.ar(1, olaTrig, bufR, pitchRatio, olaPos, Lag.kr(wsolaWindow.clip(0.005, 0.5), 0.05), 0, 1, 4)]
					},
					\pc, {
						var pcRaw = [BufRd.ar(1, bufL, pos, loop: 1, interpolation: 4),
							BufRd.ar(1, bufR, pos, loop: 1, interpolation: 4)];
						PitchShift.ar(pcRaw, Lag.kr(pvWindow.clip(0.005, 2), 0.05), pitchRatio, Lag.kr(pvDispersion.clip(0, 1), 0.05), Lag.kr(pvDispersion.clip(0, 1), 0.05))
					}
				);
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
		});

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
		// The five filter machines (PRD SS4.2, reduced set). Each decodes to Stereo or
		// Mid/Side (mixMode), filters the two channels with balance-spread cutoffs, then
		// re-encodes -- so the Filter Mix Mode + Balance are shared across all of them.
		// Classic (#1): Elektron multimode (Type LP/HP/BP/notch).
		SynthDef(\elasticatFilterClassic, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0, mix=1, mixMode=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, a, b, fcA, fcB, fa, fb, outL, outR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# a, b = filterDecodeMS.value(sig, mixMode);
			# fcA, fcB = filterBalanceCutoffs.value(fc, balance);
			fa = filterChannelClassic.value(a, fcA, rq, filterType);
			fb = filterChannelClassic.value(b, fcB, rq, filterType);
			# outL, outR = filterEncodeMS.value(fa, fb, mixMode);
			filtered = filterModOut.value(outL, outR, pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing (#2): Morph sweeps LP -> notch -> HP.
		SynthDef(\elasticatFilterMorph, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0, mix=1, mixMode=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, a, b, fcA, fcB, fa, fb, outL, outR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# a, b = filterDecodeMS.value(sig, mixMode);
			# fcA, fcB = filterBalanceCutoffs.value(fc, balance);
			fa = filterChannelMorph.value(a, fcA, rq, morph, slew);
			fb = filterChannelMorph.value(b, fcB, rq, morph, slew);
			# outL, outR = filterEncodeMS.value(fa, fb, mixMode);
			filtered = filterModOut.value(outL, outR, pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Ladder (#3): Moog-style ladder LP (MoogFF).
		SynthDef(\elasticatFilterLadder, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0, mix=1, mixMode=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, a, b, fcA, fcB, fa, fb, outL, outR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# a, b = filterDecodeMS.value(sig, mixMode);
			# fcA, fcB = filterBalanceCutoffs.value(fc, balance);
			fa = filterChannelLadder.value(a, fcA, rq);
			fb = filterChannelLadder.value(b, fcB, rq);
			# outL, outR = filterEncodeMS.value(fa, fb, mixMode);
			filtered = filterModOut.value(outL, outR, pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Comb (#4): tuned feedback comb. CUT tunes (env transposes), RES = feedback,
		// DRIVE = DAMP (LP in the loop), MIX = dry/wet. Two channels (decoded), per-
		// channel tune from the balance spread; block-delay compensated (tracks to ~1kHz).
		SynthDef(\elasticatFilterComb, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0, mix=1, mixMode=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, a, b, fcA, fcB, tuneA, tuneB, dtA, dtB, fb, dampFreq, loop, yA, yB, m, waL, waR, outL, outR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, 0, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# a, b = filterDecodeMS.value(sig, mixMode);
			# fcA, fcB = filterBalanceCutoffs.value(fc, balance);
			tuneA = fcA.clip(40, 4000); tuneB = fcB.clip(40, 4000);
			dtA = ((1 / tuneA) - ControlDur.ir).clip(SampleDur.ir, 0.05);
			dtB = ((1 / tuneB) - ControlDur.ir).clip(SampleDur.ir, 0.05);
			fb = (1 - rq).clip(0, 0.97);
			dampFreq = drive.clip(0, 1).linexp(0, 1, 16000, 600);
			loop = LocalIn.ar(2);
			yA = a + loop[0]; yB = b + loop[1];
			LocalOut.ar([LPF.ar(DelayC.ar(yA, 0.05, dtA), dampFreq) * fb, LPF.ar(DelayC.ar(yB, 0.05, dtB), dampFreq) * fb]);
			m = (mix.clip(0, 1) * 2) - 1;
			waL = XFade2.ar(a, yA, m); waR = XFade2.ar(b, yB, m);
			# outL, outR = filterEncodeMS.value(waL, waR, mixMode);
			filtered = filterModOut.value(outL, outR, pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Formant (#5): vowel BPF bank. VOWEL = morph, CUT transposes (per-channel via
		// the balance spread), RES sharpens, MIX = dry/wet.
		SynthDef(\elasticatFilterFormant, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0, mix=1, mixMode=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0, trackIndex=1, slew=0.09;
			var sig, fc, rq, a, b, fcA, fcB, vw, waL, waR, m, outL, outR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, 0, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus, trackIndex, slew);
			# a, b = filterDecodeMS.value(sig, mixMode);
			# fcA, fcB = filterBalanceCutoffs.value(fc, balance);
			vw = Lag.kr(morph.clip(0, 1), slew);
			m = (mix.clip(0, 1) * 2) - 1;
			waL = XFade2.ar(a, filterChannelFormant.value(a, (fcA / 1000).clip(0.25, 4), rq, vw), m);
			waR = XFade2.ar(b, filterChannelFormant.value(b, (fcB / 1000).clip(0.25, 4), rq, vw), m);
			# outL, outR = filterEncodeMS.value(waL, waR, mixMode);
			filtered = filterModOut.value(outL, outR, pan.clip(-1, 1), amp, panModBus, ampModBus, slew);
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
			var maxDelayTime = 4.0;   // 2 BAR at slow tempos; was 2.0 (clipped early)
			var sig, dry, wet, fb, delaySeconds, toneHz, recirc;
			sig = In.ar(in, 2);
			dry = sig;
			// Lag the time: an instant jump in DelayC's read position is a hard
			// discontinuity = a CLICK on every TIME/tempo change (owner report; the
			// knob's 12Hz coalesced sends made it a click storm). The lag turns a
			// time change into a short tape-style glide instead.
			delaySeconds = Lag.kr(
				((delayBeats.max(0.03125) * 60) / targetBpm.max(1)).clip(0.001, maxDelayTime), 0.15);
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

		// Comp (#6): Compander dynamics. Detector is the mono sum so the stereo
		// image never wanders; MIX < 1 = parallel (NY) compression. Knobs are
		// 0-1 amounts mapped to real units here (threshold/ratio/attack/release/
		// makeup). No feedback -- cannot blow up.
		SynthDef(\elasticatFxComp, {
			arg out=0, in=0, mix=0.5, meterTrack=0,
			compThresh=0.3, compRatio=0.2, compAttack=0.1, compRelease=0.3, compMakeup=0;
			var sig, dry, ctrl, thresh, slope, atk, rel, gain, comp, wet;
			var inAmp, outAmp, grDb, keyDb;
			sig = In.ar(in, 2);
			dry = sig;
			ctrl = ((sig[0] + sig[1]) * 0.5) ! 2;
			thresh = compThresh.clip(0, 1).linlin(0, 1, 0.02, 1.0);   // up = higher thresh = less comp
			slope  = compRatio.clip(0, 1).linexp(0.001, 1, 1.0, 0.05); // slopeAbove = 1/ratio (1..20:1)
			atk    = compAttack.clip(0, 1).linexp(0.001, 1, 0.0005, 0.1);
			rel    = compRelease.clip(0, 1).linexp(0.001, 1, 0.02, 0.8);
			gain   = compMakeup.clip(0, 1).linlin(0, 1, 1.0, 4.0);     // 0..~+12 dB
			comp = Compander.ar(sig, ctrl, thresh, 1.0, slope, atk, rel);
			wet = comp * gain;
			// Metering feed (owner): gain reduction (pre-makeup out / in, in dB),
			// input/key level, and the threshold, all in dB, at 20Hz keyed by the
			// track index. Gated to the viewed track by the engine responder.
			inAmp  = Amplitude.kr(ctrl[0]);
			outAmp = Amplitude.kr(comp[0]);
			grDb   = (outAmp / (inAmp + 0.0001)).clip(0.0001, 1).ampdb;
			keyDb  = inAmp.clip(0.0001, 4).ampdb;
			SendReply.kr(Impulse.kr(20), '/elasticat/fxMeterRaw', [grDb, keyDb, thresh.ampdb], meterTrack);
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Destroy (#7): serial distortion stack -- warble -> overdrive -> wavefold
		// -> saturation -> bitcrush -> tone -> level. Each stage bypasses at 0
		// (SelectX crossfade), so a stage costs its UGens but not its character
		// until dialled in. drive is the shared fx_drive; the rest are new. Every
		// stage is bounded arithmetic -- no feedback.
		SynthDef(\elasticatFxDestroy, {
			arg out=0, in=0, mix=1.0, drive=0,
			destroyWarble=0, destroyFold=0, destroySat=0, destroyCrush=0, destroySrr=0,
			destroyTone=1, destroyLevel=0.55;
			var sig, dry, x, warb, driv, fold, sat, crush, srr, srrHz, toneHz, lvl, bits, step;
			sig = In.ar(in, 2);
			dry = sig;
			x = sig;
			warb = destroyWarble.clip(0, 1);
			x = DelayC.ar(x, 0.03,
				(0.006 + (LFNoise2.kr((warb.linexp(0.001, 1, 0.5, 9)) ! 2) * warb * 0.005)).clip(0.0003, 0.03));
			driv = drive.clip(0, 1);
			x = SelectX.ar(driv, [x, (((x * (1 + (driv * 24))) + (driv * 0.15)).tanh)]);
			fold = destroyFold.clip(0, 1);
			x = SelectX.ar(fold, [x, (x * (1 + (fold * 6))).fold2(1.0)]);
			sat = destroySat.clip(0, 1);
			x = SelectX.ar(sat, [x, (x * (1 + (sat * 14))).tanh]);
			crush = destroyCrush.clip(0, 1);
			bits = crush.linlin(0, 1, 24, 2);       // up = fewer bits = more crush
			step = 2.0.pow(1 - bits);
			x = SelectX.ar(crush, [x, x.round(step)]);
			// Sample-rate reduction (owner): Latch sample-and-hold, same core-UGen
			// approach as the LOFI machine. Up = lower rate = more aliasing; 0
			// bypasses through the SelectX so it costs UGens but no character.
			srr = destroySrr.clip(0, 1);
			srrHz = srr.linexp(0, 1, 48000, 500);
			x = SelectX.ar(srr, [x, Latch.ar(x, Impulse.ar(srrHz))]);
			toneHz = destroyTone.clip(0, 1).linexp(0, 1, 400, 18000);
			x = LPF.ar(x, toneHz);
			lvl = destroyLevel.clip(0, 1).linlin(0, 1, 0.2, 2.0);
			x = (x * lvl).softclip;
			Out.ar(out, x);   // always fully wet (owner: Destroy has no dry/wet)
		}).add;

		// Echo (#8): Ableton-Echo-style stereo delay. Its OWN tempo-synced time
		// (echoBeats) so the simple DELAY machine's serialized division list is
		// untouched; the right tap is offset by a ratio, the image is stereo or
		// ping-pong (crossed feedback), the loop has a lowpass tone + time wobble.
		// Feedback clipped at 0.95 + softclip in the loop -- bounded.
		SynthDef(\elasticatFxEcho, {
			arg out=0, in=0, mix=0.5, delayFeedback=0.3,
			echoBeats=1, echoOffset=0, echoMode=0, echoTone=1, echoWobble=0, targetBpm=120;
			var maxT = 4.0;
			var sig, dry, lTime, rTime, offRatio, toneHz, wob, lTmod, rTmod;
			var fb, fbG, mSel, fbL, fbR, dl, dr, wet;
			sig = In.ar(in, 2);
			dry = sig;
			// Lagged like DELAY: an instant time jump = a click (see \elasticatFxDelay).
			lTime = Lag.kr(((echoBeats.max(0.03125) * 60) / targetBpm.max(1)).clip(0.001, maxT), 0.15);
			offRatio = Lag.kr(echoOffset.clip(-1, 1).linexp(-1, 1, 0.5, 2.0), 0.15);
			rTime = (lTime * offRatio).clip(0.001, maxT);
			toneHz = echoTone.clip(0, 1).linexp(0, 1, 300, 18000);
			wob = echoWobble.clip(0, 1);
			lTmod = (lTime * (1 + (SinOsc.kr(0.7) * wob * 0.03) + (LFNoise2.kr(9) * wob * 0.01))).clip(0.001, maxT);
			rTmod = (rTime * (1 + (SinOsc.kr(0.73) * wob * 0.03) + (LFNoise2.kr(9.3) * wob * 0.01))).clip(0.001, maxT);
			fb = LocalIn.ar(2);
			fbG = delayFeedback.clip(0, 0.95);
			mSel = echoMode.round(1).clip(0, 1);
			fbL = Select.ar(mSel, [fb[0], fb[1]]);   // ping-pong crosses the channels
			fbR = Select.ar(mSel, [fb[1], fb[0]]);
			dl = DelayC.ar(sig[0] + (fbL * fbG), maxT, lTmod);
			dr = DelayC.ar(sig[1] + (fbR * fbG), maxT, rTmod);
			dl = LPF.ar(dl, toneHz).softclip;
			dr = LPF.ar(dr, toneHz).softclip;
			LocalOut.ar([dl, dr]);
			wet = [dl, dr];
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Blackhole (#9): huge modulated freeze-capable reverb. A modulated
		// AllpassC ring with a feedback gain that GRAV pushes toward 1.0 (freeze).
		// A Limiter in the loop keeps the freeze from blowing up while sustaining.
		// reverbSize scales the allpass times, reverbDamp is HF damping, bhLow is a
		// tail low cut, bhPredelay offsets the onset.
		SynthDef(\elasticatFxBlackhole, {
			arg out=0, in=0, mix=0.5, reverbSize=0.5, reverbDamp=0.5,
			bhGravity=0.5, bhMod=0.2, bhLow=0.1, bhPredelay=0.1, targetBpm=120;
			var sig, dry, preT, sizeScale, fbG, dampHz, lowHz, modAmt, pre, loop, x, wet;
			sig = In.ar(in, 2);
			dry = sig;
			preT = bhPredelay.clip(0, 1).linlin(0, 1, 0, 0.2);
			sizeScale = reverbSize.clip(0, 1).linlin(0, 1, 0.5, 1.6);
			fbG = bhGravity.clip(0, 1).linlin(0, 1, 0.7, 1.0).min(0.9995);
			dampHz = reverbDamp.clip(0, 1).linexp(0, 1, 16000, 700);
			lowHz = bhLow.clip(0, 1).linexp(0, 1, 20, 600);
			modAmt = bhMod.clip(0, 1);
			pre = DelayN.ar(sig, 0.2, preT);
			loop = LocalIn.ar(2);
			x = pre + (loop * fbG);
			[0.013, 0.021, 0.031, 0.043].do({ arg t, i;
				var mt = t * sizeScale * (1 + (LFNoise2.kr((0.2 + (i * 0.13)) ! 2) * modAmt * 0.18));
				x = AllpassC.ar(x, 0.12, mt.clip(0.001, 0.12), 3.5 * sizeScale);
			});
			x = LPF.ar(x, dampHz);
			x = HPF.ar(x, lowHz);
			x = Limiter.ar(LeakDC.ar(x), 0.9);
			LocalOut.ar(x);
			wet = x;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Chorus (#10): dual-voice modulated delay. L/R LFOs offset by chorusWidth
		// (quadrature at full). Shares modfxRate/Depth/Tone with Flanger/Phaser. No
		// feedback -- safe.
		SynthDef(\elasticatFxChorus, {
			arg out=0, in=0, mix=0.5, modfxRate=0.3, modfxDepth=0.3, chorusWidth=0.5, modfxTone=0.8;
			var sig, dry, rateHz, depthS, toneHz, lfoL, lfoR, dL, dR, wet;
			sig = In.ar(in, 2);
			dry = sig;
			rateHz = modfxRate.clip(0, 1).linexp(0.001, 1, 0.05, 8);
			depthS = modfxDepth.clip(0, 1).linlin(0, 1, 0, 0.012);
			toneHz = modfxTone.clip(0, 1).linexp(0, 1, 400, 18000);
			lfoL = SinOsc.kr(rateHz, 0);
			lfoR = SinOsc.kr(rateHz, chorusWidth.clip(0, 1) * pi);
			dL = DelayC.ar(sig[0], 0.05, (0.015 + (depthS * lfoL)).clip(0.001, 0.05));
			dR = DelayC.ar(sig[1], 0.05, (0.015 + (depthS * lfoR)).clip(0.001, 0.05));
			wet = LPF.ar([dL, dR], toneHz);
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Flanger (#11): short modulated delay with feedback. flangerFeedback is
		// BIPOLAR (negative = hollow comb); clipped to +/-0.9 so it can drone but
		// not blow up.
		SynthDef(\elasticatFxFlanger, {
			arg out=0, in=0, mix=0.5, modfxRate=0.3, modfxDepth=0.3, flangerFeedback=0, modfxTone=0.8;
			var sig, dry, rateHz, depthS, fbAmt, toneHz, lfo, dtime, fb, x, d, wet;
			sig = In.ar(in, 2);
			dry = sig;
			rateHz = modfxRate.clip(0, 1).linexp(0.001, 1, 0.02, 4);
			depthS = modfxDepth.clip(0, 1).linlin(0, 1, 0.0002, 0.006);
			fbAmt = flangerFeedback.clip(-1, 1) * 0.9;
			toneHz = modfxTone.clip(0, 1).linexp(0, 1, 400, 18000);
			lfo = SinOsc.kr(rateHz).range(0, 1);
			dtime = (0.0006 + (depthS * lfo)).clip(0.0002, 0.02);
			fb = LocalIn.ar(2);
			x = sig + (fb * fbAmt);
			d = LPF.ar(DelayC.ar(x, 0.02, dtime ! 2), toneHz);
			LocalOut.ar(d);
			wet = d;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Phaser (#12): cascaded first-order allpass (FOS) sweep, 2/4/6/8 stages
		// tapped by phaserStages, resonance via a clipped feedback path. All stages
		// share the swept break frequency (classic phaser). Shares modfxRate/Depth.
		SynthDef(\elasticatFxPhaser, {
			arg out=0, in=0, mix=0.5, modfxRate=0.25, modfxDepth=0.6, phaserCenter=0.5, phaserStages=1, phaserFeedback=0.2;
			var sig, dry, sr, rateHz, depth, centerHz, fbAmt, lfo, lo, hi, fc, t, c;
			var fb, x, a2, a4, a6, a8, tapL, tapR, tapped, wet;
			sig = In.ar(in, 2);
			dry = sig;
			sr = SampleRate.ir;
			rateHz = modfxRate.clip(0, 1).linexp(0.001, 1, 0.02, 4);
			depth = modfxDepth.clip(0, 1);
			centerHz = phaserCenter.clip(0, 1).linexp(0, 1, 100, 4000);
			fbAmt = phaserFeedback.clip(0, 1) * 0.9;
			lo = (centerHz * (1 - (depth * 0.7))).max(40);
			hi = (centerHz * (1 + (depth * 1.5))).min(12000);
			fc = SinOsc.kr(rateHz).range(lo, hi).clip(40, 12000);
			t = ((pi * fc) / sr).tan;
			c = (t - 1) / (t + 1);
			fb = LocalIn.ar(2);
			x = sig + (fb * fbAmt);
			// First-order allpass: y[n] = c*x[n] + x[n-1] - c*y[n-1], i.e. FOS
			// b1 = c.NEG. (Shipped with +c, which is a shelf, not an allpass --
			// no notches, so the phaser barely phased.)
			a2 = x;  2.do { a2 = FOS.ar(a2, c, 1.0, c.neg); };
			a4 = a2; 2.do { a4 = FOS.ar(a4, c, 1.0, c.neg); };
			a6 = a4; 2.do { a6 = FOS.ar(a6, c, 1.0, c.neg); };
			a8 = a6; 2.do { a8 = FOS.ar(a8, c, 1.0, c.neg); };
			tapL = Select.ar(phaserStages.round(1).clip(0, 3), [a2[0], a4[0], a6[0], a8[0]]);
			tapR = Select.ar(phaserStages.round(1).clip(0, 3), [a2[1], a4[1], a6[1], a8[1]]);
			tapped = [tapL, tapR];
			LocalOut.ar(tapped);
			wet = (dry + tapped) * 0.5;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// DJ EQ (#13): 3-band isolator with kills. Gains are BIPOLAR (64 = unity,
		// 0 = full kill, top = boost); bands split by subtraction. No MIX (an EQ at
		// 50% wet is a phase mess) -- writes the sum directly.
		SynthDef(\elasticatFxDjEq, {
			arg out=0, in=0, eqLow=0, eqMid=0, eqHigh=0, eqXlow=0.3, eqXhi=0.7;
			var sig, xlowHz, xhiHz, gLow, gMid, gHigh, low, high, mid, wet;
			sig = In.ar(in, 2);
			xlowHz = eqXlow.clip(0, 1).linexp(0, 1, 80, 500);
			xhiHz = eqXhi.clip(0, 1).linexp(0, 1, 1000, 8000);
			gLow = (1 + eqLow.clip(-1, 1)).clip(0, 2);
			gMid = (1 + eqMid.clip(-1, 1)).clip(0, 2);
			gHigh = (1 + eqHigh.clip(-1, 1)).clip(0, 2);
			low = LPF.ar(sig, xlowHz);
			high = HPF.ar(sig, xhiHz);
			mid = sig - low - high;
			wet = (low * gLow) + (mid * gMid) + (high * gHigh);
			Out.ar(out, wet);
		}).add;

		// Duck (#14): sidechain ducker keyed off keyIn (the master bus -- the dry
		// program). Best on a send return. No MIX; writes the gained signal.
		SynthDef(\elasticatFxDuck, {
			arg out=0, in=0, keyIn=0, meterTrack=0, duckAmount=0.6, duckSens=0.5, duckAttack=0.2, duckRelease=0.4;
			var sig, key, keyMono, amt, sensMult, atk, rel, keyAmp, env, gain;
			sig = In.ar(in, 2);
			key = In.ar(keyIn, 2);
			keyMono = (key[0] + key[1]) * 0.5;
			amt = duckAmount.clip(0, 1);
			sensMult = duckSens.clip(0, 1).linexp(0, 1, 0.5, 8);
			atk = duckAttack.clip(0, 1).linexp(0, 1, 0.001, 0.05);
			rel = duckRelease.clip(0, 1).linexp(0, 1, 0.05, 1.2);
			keyAmp = Amplitude.kr(keyMono, atk, rel);
			env = (keyAmp * sensMult).clip(0, 1);
			gain = Lag.kr((1 - (env * amt)).clip(0, 1), 0.005);
			// Metering: the duck gain (in dB) is the reduction; the key level is the
			// dry program. Duck has no hard threshold, so thresh is sent as -99 (the
			// UI omits the threshold tick for duck). 20Hz, keyed by the track index.
			SendReply.kr(Impulse.kr(20), '/elasticat/fxMeterRaw',
				[gain.clip(0.0001, 1).ampdb, keyAmp.clip(0.0001, 4).ampdb, -99], meterTrack);
			Out.ar(out, sig * gain);
		}).add;

		// Tape Echo (#15): the tempo-synced delay with the tape loop misbehaving --
		// wow (slow) + flutter (fast) modulate the delay time, tanh saturation +
		// band-limit sit inside the recirculation. Reuses echoBeats/echoTone/
		// delayFeedback. Feedback clipped 0.95 + softclip -- bounded.
		SynthDef(\elasticatFxTapeEcho, {
			arg out=0, in=0, mix=0.5, delayFeedback=0.3, echoBeats=1, echoTone=1,
			tapeWow=0.2, tapeFlutter=0.12, tapeSat=0.24, targetBpm=120;
			var maxT = 4.0;
			var sig, dry, t, wowMod, flutMod, tMod, toneHz, fb, fbG, x, rec, driven, wet;
			sig = In.ar(in, 2);
			dry = sig;
			// Lagged like DELAY: an instant time jump = a click (see \elasticatFxDelay).
			t = Lag.kr(((echoBeats.max(0.03125) * 60) / targetBpm.max(1)).clip(0.001, maxT), 0.15);
			wowMod = SinOsc.kr(0.5) * tapeWow.clip(0, 1) * 0.02;
			flutMod = LFNoise2.kr(8) * tapeFlutter.clip(0, 1) * 0.006;
			tMod = (t * (1 + wowMod + flutMod)).clip(0.001, maxT);
			toneHz = echoTone.clip(0, 1).linexp(0, 1, 300, 14000);
			fb = LocalIn.ar(2);
			fbG = delayFeedback.clip(0, 0.95);
			x = sig + (fb * fbG);
			rec = DelayC.ar(x, maxT, tMod ! 2);
			rec = LPF.ar(HPF.ar(rec, 70), toneHz);
			driven = ((rec * (1 + (tapeSat.clip(0, 1) * 5))).tanh) * (0.9 / (1 + (tapeSat.clip(0, 1) * 1.2)));
			rec = SelectX.ar(tapeSat.clip(0, 1), [rec, driven]).softclip;
			LocalOut.ar(rec);
			wet = rec;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Cassette (#16): degraded-media character -- pitch wobble (shared tapeWow/
		// tapeFlutter), hiss bed, Dust crackle, random dropouts, band-limit. All
		// bounded arithmetic, no feedback.
		SynthDef(\elasticatFxCassette, {
			arg out=0, in=0, mix=1.0,
			tapeWow=0.2, tapeFlutter=0.12, cassNoise=0.08, cassCrackle=0, cassDrop=0, cassTone=0.63;
			var sig, dry, wob, dropMod, toneHz, band, hiss, crackle, wet;
			sig = In.ar(in, 2);
			dry = sig;
			wob = DelayC.ar(sig, 0.03,
				(0.012 + (SinOsc.kr(0.6) * tapeWow.clip(0, 1) * 0.004)
					+ (LFNoise2.kr(6) * tapeFlutter.clip(0, 1) * 0.002)).clip(0.001, 0.03));
			dropMod = (1 - (cassDrop.clip(0, 1) * LFNoise1.kr(3).range(0, 1).pow(3))).clip(0, 1);
			toneHz = cassTone.clip(0, 1).linexp(0, 1, 1200, 16000);
			band = LPF.ar(HPF.ar(wob * dropMod, 60), toneHz);
			hiss = HPF.ar(PinkNoise.ar(cassNoise.clip(0, 1) * 0.02 ! 2), 800);
			crackle = BPF.ar(Decay.ar(Dust2.ar(cassCrackle.clip(0, 1) * 40 ! 2), 0.002), 2500, 1.5) * 0.4;
			wet = band + hiss + crackle;
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Motion (#17): M/S stereo width + one tempo-synced LFO driving tremolo
		// (in-phase) and autopan (opposite-phase). Depths at 0 = exact unity, so
		// there is no mix arg. motionWidth -1..1: -1 mono, 0 unity, +1 wide.
		SynthDef(\elasticatFxMotion, {
			arg out=0, in=0, motionWidth=0, motionBeats=1, motionTrem=0, motionPan=0, motionShape=0, targetBpm=120;
			var sig, mid, side, sideGain, l2, r2, hz, lfoU, trem, panL, panR;
			sig = In.ar(in, 2);
			mid = (sig[0] + sig[1]) * 0.5;
			side = (sig[0] - sig[1]) * 0.5;
			sideGain = (1 + motionWidth.clip(-1, 1)).clip(0, 2);
			l2 = mid + (side * sideGain);
			r2 = mid - (side * sideGain);
			hz = ((targetBpm.max(1) / 60) / motionBeats.max(0.0625)).clip(0.01, 40);
			lfoU = Select.kr(motionShape.round(1).clip(0, 2), [
				SinOsc.kr(hz).range(0, 1), LFTri.kr(hz).range(0, 1), LFPulse.kr(hz)
			]);
			trem = 1 - (motionTrem.clip(0, 1) * lfoU);
			panL = 1 - (motionPan.clip(0, 1) * lfoU);
			panR = 1 - (motionPan.clip(0, 1) * (1 - lfoU));
			Out.ar(out, [l2 * trem * panL, r2 * trem * panR]);
		}).add;

		// Rings (#18): RING = sig * SinOsc (freq magnitude), SHIFT = FreqShift
		// (bipolar direction) with feedback for barberpole recirculation. Reuses
		// modfxTone as the wet lowpass. Feedback clipped 0.85 -- bounded.
		SynthDef(\elasticatFxRings, {
			arg out=0, in=0, mix=0.5, ringsMode=0, ringsFreq=0.5, ringsFine=0, ringsFeedback=0, modfxTone=0.8;
			var sig, dry, mag, freqHz, fineHz, toneHz, fb, x, ring, shift, wet;
			sig = In.ar(in, 2);
			dry = sig;
			mag = ringsFreq.clip(-1, 1);
			freqHz = (mag.abs.linexp(0.001, 1, 1, 2000)) * mag.sign;
			fineHz = ringsFine.clip(-1, 1) * 20;
			toneHz = modfxTone.clip(0, 1).linexp(0, 1, 400, 18000);
			fb = LocalIn.ar(2);
			x = sig + (fb * ringsFeedback.clip(0, 1) * 0.85);
			ring = x * SinOsc.ar((freqHz + fineHz).abs.max(0.1));
			shift = FreqShift.ar(x, freqHz + fineHz);
			wet = LPF.ar(Select.ar(ringsMode.round(1).clip(0, 1), [ring, shift]), toneHz);
			LocalOut.ar(wet.softclip);
			Out.ar(out, fxMixBlend.value(dry, wet, mix));
		}).add;

		// Limit (#19): brickwall + loudness for the master slot. limitGain pushes
		// 0..+18 dB into a -6..0 dB ceiling; limitRelease maps to the lookahead
		// window. No mix arg -- it IS the output stage.
		SynthDef(\elasticatFxLimit, {
			arg out=0, in=0, limitGain=0, limitCeil=0.95, limitRelease=0.3, meterTrack=0;
			var sig, g, ceil, dur, wet, inAmp, outAmp, grDb, keyDb;
			sig = In.ar(in, 2);
			g = limitGain.clip(0, 1).linlin(0, 1, 0, 18).dbamp;
			ceil = limitCeil.clip(0, 1).linlin(0, 1, -6, 0).dbamp;
			dur = limitRelease.clip(0, 1).linexp(0, 1, 0.002, 0.1);
			wet = Limiter.ar(sig * g, ceil, dur);
			// Metering feed, same shape as COMP: gain reduction (out/in dB),
			// post-gain input level, and the ceiling as the threshold tick.
			inAmp  = Amplitude.kr(sig[0] * g);
			outAmp = Amplitude.kr(wet[0]);
			grDb   = (outAmp / (inAmp + 0.0001)).clip(0.0001, 1).ampdb;
			keyDb  = inAmp.clip(0.0001, 4).ampdb;
			SendReply.kr(Impulse.kr(20), '/elasticat/fxMeterRaw', [grDb, keyDb, ceil.ampdb], meterTrack);
			Out.ar(out, wet);
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

		// --- Track mix stage (EVERY track, 1-8 alike) ---------------------------
		// The tail synth of each track's chain: reads that track's private mix bus
		// and sums into masterBus with the mute gate + click-free teardown fade. It
		// runs at UNITY amp/pan -- the FILTER output stage carries this track's
		// volume/pan (and the AMP/PAN mod destinations), so the mix staging is
		// IDENTICAL for track 1 and tracks 2-8: no per-track difference, no double
		// gain. `alive` fades to 0 (~30 ms Lag) before freeing the chain.
		SynthDef(\elasticatTrackMix, {
			arg out=0, in=0, amp=1, pan=0, mute=0, alive=1, trackIndex=1;
			var sig, gain, outSig, lvl;
			sig = In.ar(in, 2);
			gain = Lag.kr(
				amp.max(0) * (1 - mute.clip(0, 1)) * alive.clip(0, 1),
				0.03
			);
			outSig = Balance2.ar(sig[0], sig[1], pan.clip(-1, 1), gain);
			// Idle detector feed: this track's POST-gain output level at 2Hz.
			// Post-everything on purpose -- a ringing insert delay/reverb tail
			// registers here, so the idle scan can never pause a track that is
			// still audible. The slow 0.3s release keeps gaps between grains /
			// sparse hits from reading as silence between two 2Hz samples.
			lvl = Amplitude.kr(outSig[0] + outSig[1], 0.01, 0.3);
			SendReply.kr(Impulse.kr(2), '/elasticat/idleRaw', [lvl], trackIndex);
			Out.ar(out, outSig);
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
			menvDepth=0, menvTrig=0, menvGateSeconds=0.5, menvReleaseTrig=0,
			mvelDest=0, mvelDepth=0, modVelocity=0, trackIndex=1,
			macro1Base=0, macro1PitchDepth=0, macro1CutoffDepth=0, macro1ResDepth=0, macro1AmpDepth=0, macro1PanDepth=0,
			macro2Base=0, macro2PitchDepth=0, macro2CutoffDepth=0, macro2ResDepth=0, macro2AmpDepth=0, macro2PanDepth=0,
			macro3Base=0, macro3PitchDepth=0, macro3CutoffDepth=0, macro3ResDepth=0, macro3AmpDepth=0, macro3PanDepth=0,
			macro4Base=0, macro4PitchDepth=0, macro4CutoffDepth=0, macro4ResDepth=0, macro4AmpDepth=0, macro4PanDepth=0;
			var lfoValue, routed, lfo1, lfo2, menv, mvel, macroVal, mv1, mv2, mv3, mv4;
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
			// Velocity as a mod source: the LATCHED last trigger velocity (0..1, set
			// per slice trig -- a per-track control, consistent with the per-track
			// filter that overlapping voices already share). Unipolar (a louder hit
			// pushes the dest further) scaled by the bipolar depth, routed like any
			// other source. A short Lag smooths the step between hits.
			mvel = Lag.kr(modVelocity.clip(0, 1), 0.01) * mvelDepth.clip(-1, 1);

			// Stage 1: each macro's effective value = its base knob plus any
			// LFO/mod-env whose dest points at it (indices 6..9), clipped 0..1.
			macroVal = { arg base, macroIdx;
				(base
					+ routed.value(lfo1, lfo1Dest, 5 + macroIdx)
					+ routed.value(lfo2, lfo2Dest, 5 + macroIdx)
					+ routed.value(menv, menvDest, 5 + macroIdx)
					+ routed.value(mvel, mvelDest, 5 + macroIdx)).clip(0, 1);
			};
			mv1 = macroVal.value(macro1Base, 1);
			mv2 = macroVal.value(macro2Base, 2);
			mv3 = macroVal.value(macro3Base, 3);
			mv4 = macroVal.value(macro4Base, 4);

			// Stage 2: each destination bus sums the direct LFO/env contributions
			// plus every macro's value * that macro's depth to THIS destination
			// (the mod matrix). A zero matrix depth contributes nothing.
			pitchSum = routed.value(lfo1, lfo1Dest, 1) + routed.value(lfo2, lfo2Dest, 1) + routed.value(menv, menvDest, 1) + routed.value(mvel, mvelDest, 1)
				+ (mv1 * macro1PitchDepth) + (mv2 * macro2PitchDepth) + (mv3 * macro3PitchDepth) + (mv4 * macro4PitchDepth);
			// Cutoff is the one dest scaled to the FULL range (see filterPrep): the
			// LFO/env/macro terms are damped x0.3 back to their usual +/-3 octaves,
			// and VELOCITY is added at full weight for a whole-range velocity sweep.
			cutoffSum = ((routed.value(lfo1, lfo1Dest, 2) + routed.value(lfo2, lfo2Dest, 2) + routed.value(menv, menvDest, 2)
				+ (mv1 * macro1CutoffDepth) + (mv2 * macro2CutoffDepth) + (mv3 * macro3CutoffDepth) + (mv4 * macro4CutoffDepth)) * 0.3)
				+ routed.value(mvel, mvelDest, 2);
			resSum = routed.value(lfo1, lfo1Dest, 3) + routed.value(lfo2, lfo2Dest, 3) + routed.value(menv, menvDest, 3) + routed.value(mvel, mvelDest, 3)
				+ (mv1 * macro1ResDepth) + (mv2 * macro2ResDepth) + (mv3 * macro3ResDepth) + (mv4 * macro4ResDepth);
			ampSum = routed.value(lfo1, lfo1Dest, 4) + routed.value(lfo2, lfo2Dest, 4) + routed.value(menv, menvDest, 4) + routed.value(mvel, mvelDest, 4)
				+ (mv1 * macro1AmpDepth) + (mv2 * macro2AmpDepth) + (mv3 * macro3AmpDepth) + (mv4 * macro4AmpDepth);
			panSum = routed.value(lfo1, lfo1Dest, 5) + routed.value(lfo2, lfo2Dest, 5) + routed.value(menv, menvDest, 5) + routed.value(mvel, mvelDest, 5)
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
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var phase, frames, sourcePhase, pos, sig, modeGain, playGate, pitchRatio, startNorm, range, nativeIncrement;
			var ampEnv;
			// --- Task 2 (PRD S8): tempo_varispeed pitch -- extra vars for the
			// modeId==1 branch below.
			var varispeedCyclesPerSecond, pitchDrift;
			var contRate, oldStart, oldPhase, xfade, srcNew, srcOld, posNew, posOld, resetAt;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.03125, 32);
			startNorm = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002);
			range = Lag.kr(((endPoint.clip(startPoint + 0.01, 128) - startPoint.clip(0, 127.99)) / 128).clip(0.0001, 1), 0.002);
			if(modeId == 0, {
				// Tape ignores the transport phase, so it applies warpRate to its OWN
				// native Phasor here (a rate multiplier on the native playback speed).
				nativeIncrement = (BufRateScale.kr(bufL) * speed.max(0.03125) * pitchRatio * Lag.kr(warpRate.max(0.001), 0.02)) / (frames * range).max(1);
				phase = Phasor.ar(TDelay.kr(Changed.kr(resetTrig), 0.003), nativeIncrement * playing.clip(0, 1), 0, 1, resetPos.clip(0, 0.999999));
				contRate = nativeIncrement * SampleRate.ir;
			}, {
				phase = In.ar(phaseBus, 1);
				// tempo_varispeed follows the shared transport phase (locked to the main
				// tempo) -- a classic tempo-synced varispeed timestretch. The discrete
				// PITCH param does NOT nudge its rate (owner: pitch is a byproduct of the
				// tempo stretch, not an independent control). (Removed the PRD-S8 Task-2
				// pitch->rate drift.)
				if(modeId == 1, {
					varispeedCyclesPerSecond = (targetBpm.max(1) / 60) / loopBeats.max(0.03125);
					contRate = varispeedCyclesPerSecond;
				});
				// --- end Task 2 block ------------------------------------------------
			});
			// --- Playhead-JUMP crossfade (click-free) ----------------------------
			// A jump resets the read phasor -> waveform discontinuity -> click.
			// Rather than dip the amp to 0 (which leaves an audible HOLE -- wider =
			// MORE obvious), read the buffer at BOTH the OLD trajectory (continued
			// forward from the pre-jump phase at the play rate) and the NEW (post-
			// reset) position, and equal-power crossfade OLD->NEW over 6ms. Both
			// sides are continuous through the fade -> no discontinuity, no hole.
			// resetAt is the moment the phasor actually jumps (shared 3ms delay);
			// contRate (cycles/sec) is this mode's play rate, set in the branches
			// above. Latch grabs the phase one sample BEFORE the reset so the OLD
			// side matches the live signal exactly at the crossfade's start.
			resetAt = TDelay.kr(Changed.kr(resetTrig), 0.003);
			oldStart = Latch.ar(Delay1.ar(phase), resetAt);
			oldPhase = (oldStart + Sweep.ar(resetAt, contRate * playing.clip(0, 1))).wrap(0, 1);
			// Rests at 1 (all-NEW: live playback / spawn follows the real phase);
			// on a jump snaps to 0 (all-OLD, = the continuous pre-jump signal) then
			// ramps back to 1 over 6ms. NOT [0,1] -- that would rest at 0 and play
			// the OLD Sweep path at spawn instead of the real phase.
			xfade = EnvGen.ar(Env.new([1, 0, 1], [0, loopXfade.clip(0.0005, 0.25)], \sin), resetAt);
			srcNew = Select.ar(direction >= 0, [1 - phase, phase]).wrap(0, 1);
			srcOld = Select.ar(direction >= 0, [1 - oldPhase, oldPhase]).wrap(0, 1);
			posNew = (startNorm + (srcNew * range)).clip(0, 0.999999) * (frames - 1);
			posOld = (startNorm + (srcOld * range)).clip(0, 0.999999) * (frames - 1);
			pos = posNew;
			sig = [
				XFade2.ar(BufRd.ar(1, bufL, posOld, loop: 1, interpolation: 4), BufRd.ar(1, bufL, posNew, loop: 1, interpolation: 4), (xfade * 2) - 1),
				XFade2.ar(BufRd.ar(1, bufR, posOld, loop: 1, interpolation: 4), BufRd.ar(1, bufR, posNew, loop: 1, interpolation: 4), (xfade * 2) - 1)
			];
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [sig[0], sig[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				modeId, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;
	}

	// Build a warp-mode reader from the compiled click-free ElasticatReader (softcut
	// model): absolute-frame reads + one queued 2-head crossfade (position jumps AND
	// the loop seam). statusModeId is echoed in /statusRaw so several modes can share
	// this reader yet stay distinct in the UI. Guarded -- falls back to the SC-graph
	// native tape reader if the .so is not installed (build via lib/ugens/build.sh).
	addUGenReaderDef { arg synthName, statusModeId, tempoSync = false;
		if(\ElasticatReader.asClass.notNil, {
		SynthDef(synthName, {
			arg out=0, phaseBus=0, bufL=0, bufR=0, modeAmp=1, fadeTime=0.05,
			playing=0, resetTrig=0, resetPos=0,
			amp=0.8, pan=0, pitch=0, speed=1, direction=1,
			targetBpm=120, derivedSourceBpm=120, loopBeats=4, startPoint=0, endPoint=128,
			envMode=1, envAttack=0.002, envDecay=0.15, envSustain=0.8, envRelease=0.15,
			envHold=0.35, envTrig=0, envGateSeconds=0.5, portamento=0, envReleaseTrig=0,
			pitchModBus=0, warpRate=1, loopXfade=0.01, trackIndex=1;
			var frames, pitchRatio, loopStartF, loopEndF, rate, resetFrame, rd, sig, modeGain, playGate, ampEnv, phase, cps;
			frames = BufFrames.kr(bufL).max(4);
			pitchRatio = (Lag.kr(pitch, 0.03) + (In.kr(pitchModBus, 1).clip(-1, 1) * 12)).midiratio.clip(0.03125, 32);
			// Absolute-frame loop fences (softcut model): moving these never remaps the
			// read position, so a region relock on a step -- or on its RELEASE return-
			// jump -- doesn't teleport the read (the pop tape_xf couldn't dodge).
			loopStartF = Lag.kr(startPoint.clip(0, 127.99) / 128, 0.002) * frames;
			loopEndF = Lag.kr(endPoint.clip(0.01, 128) / 128, 0.002) * frames;
			// rate is FRAMES per sample, signed by direction, gated by playing. tempoSync
			// (tempo_varispeed): the region traverses once per loop (grid-locked, pitch a
			// byproduct of the stretch). NATIVE (tape): speed * pitch.
			rate = if(tempoSync, {
				cps = (targetBpm.max(1) / 60 / loopBeats.max(0.03125)) * Lag.kr(warpRate.max(0.001), 0.02);
				(loopEndF - loopStartF) * cps / SampleRate.ir * direction * playing.clip(0, 1)
			}, {
				BufRateScale.kr(bufL) * speed.max(0.03125) * pitchRatio * Lag.kr(warpRate.max(0.001), 0.02) * direction * playing.clip(0, 1)
			});
			resetFrame = loopStartF + (resetPos.clip(0, 1) * (loopEndF - loopStartF));
			rd = ElasticatReader.ar(bufL, bufR, loopStartF, loopEndF, rate, resetTrig, resetFrame, loopXfade.clip(0.0005, 0.25), 1);
			phase = rd[2];
			modeGain = Lag.kr(modeAmp.clip(0, 1), fadeTime).sqrt;
			playGate = Lag.kr(playing.clip(0, 1), 0.01);
			ampEnv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, portamento, envReleaseTrig);
			sig = [rd[0], rd[1]] * (modeGain * playGate * ampEnv);
			sig = LeakDC.ar(sig);
			SendReply.kr(Impulse.kr(15), cmdName: '/elasticat/statusRaw', values: [
				statusModeId, phase, frames, Amplitude.kr(sig[0]), Amplitude.kr(sig[1])
			], replyID: trackIndex);
			Out.ar(out, sig);
		}).add;
		}, {
			this.addDirectReaderDef(synthName, if(tempoSync, 1, 0));
		});
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
		// chop steps -> slice count. chopBeats is now the NUMBER OF SLICES (not beats),
		// so this maps 1:1 -- the old /4 unit conversion (steps->beats) was left over
		// from the pre-ElasticatSlicer chopped mode and quartered the user's slice count.
		this.addCommand(\trChopSteps, "if", { arg msg;
			var tr; tr = this.track(msg[1]);
			if(tr.notNil, { tr.set(\chopBeats, msg[2].max(1)); });
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
		this.addCommand(\trSliceTrigger, "iiffiifffii", { arg msg;
			this.trackTriggerSlice(msg);
		});
		this.addCommand(\trTriggerSlice, "iiffiifffii", { arg msg;
			this.trackTriggerSlice(msg);
		});
		this.addCommand(\trReleaseSlice, "ii", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.releaseSlice(msg[2]); });
		});
		this.addCommand(\trReleaseAllSlices, "i", { arg msg;
			var tr; tr = this.track(msg[1]); if(tr.notNil, { tr.releaseAllSlices; });
		});
		// Panic: HARD-kill every slice voice on every track (20ms fade + free),
		// unlike releaseAllSlices which only opens the gate. Owner: stop-twice.
		this.addCommand(\killAllSlices, "", { this.stealAllSlices; });
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

		// --- Genuinely global commands --------------------------------------
		this.addCommand(\activeTrackCount, "i", { arg msg; this.setActiveTrackCount(msg[1]); });
		// Which track's mod / filter-env stream the script receives.
		this.addCommand(\uiTrack, "i", { arg msg; uiTrack = msg[1].asInteger.clip(1, 8); });
		this.addCommand(\viewTrack, "i", { arg msg; this.setViewTrack(msg[1]); });
		this.addCommand(\idlePauseEnable, "i", { arg msg; this.setIdlePauseEnabled(msg[1]); });
		this.addCommand(\idleGrace, "f", { arg msg; this.setIdleGrace(msg[1]); });
		this.addCommand(\meterAll, "i", { arg msg; meterAll = msg[1].asInteger.clip(0, 1); });
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
		this.addCommand(\setPreviewRegion, "fff", { arg msg;
			this.setPreviewRegion(msg[1], msg[2], msg[3]);
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

		// --- Generated: the new machines' (Comp/Destroy/Echo/Blackhole) send +
		// master FX params. One row per param generates send1<Cmd>/send2<Cmd>/
		// master<Cmd>, storing into sendFxExtra so a respawn (sendFxArgs) reapplies
		// it. Additive to the hand-written commands above; existing sends untouched.
		this.sendFxExtraSpec.do({ arg row;
			var cmdBase = row[0], key = row[1], lo = row[2], hi = row[3];
			[[\send1, 0], [\send2, 1], [\master, 2]].do({ arg sp;
				var prefix = sp[0], idx = sp[1];
				this.addCommand((prefix ++ cmdBase).asSymbol, "f", { arg msg;
					var v = msg[1].clip(lo, hi);
					sendFxExtra[idx][key] = v;
					this.setSendSlot(idx, key, v);
				});
			});
		});
	}

	// The new machines' send/master param table: [cmdBase, synthArg, lo, hi,
	// default]. cmdBase is the UpperCamel suffix the Lua slot prefix ("send1"/
	// "send2"/"master") is prepended to. Values arrive already in engine units
	// (0-1 amounts, bipolar -1..1, or beats) -- lo/hi just clips. Add a machine's
	// send params by adding rows here; nothing else in the command surface changes.
	sendFxExtraSpec {
		^[
			[\CompThresh,   \compThresh,   0, 1, 0.3],
			[\CompRatio,    \compRatio,    0, 1, 0.2],
			[\CompAttack,   \compAttack,   0, 1, 0.1],
			[\CompRelease,  \compRelease,  0, 1, 0.3],
			[\CompMakeup,   \compMakeup,   0, 1, 0],
			[\DestroyWarble, \destroyWarble, 0, 1, 0],
			[\DestroyFold,  \destroyFold,  0, 1, 0],
			[\DestroySat,   \destroySat,   0, 1, 0],
			[\DestroyCrush, \destroyCrush, 0, 1, 0],
			[\DestroySrr,    \destroySrr,   0, 1, 0],
			[\DestroyTone,  \destroyTone,  0, 1, 1],
			[\DestroyLevel, \destroyLevel, 0, 1, 0.55],
			[\EchoBeats,    \echoBeats,    0.03125, 8, 1],
			[\EchoOffset,   \echoOffset,   -1, 1, 0],
			[\EchoMode,     \echoMode,     0, 1, 0],
			[\EchoTone,     \echoTone,     0, 1, 1],
			[\EchoWobble,   \echoWobble,   0, 1, 0],
			[\BhGravity,    \bhGravity,    0, 1, 0.5],
			[\BhMod,        \bhMod,        0, 1, 0.2],
			[\BhLow,        \bhLow,        0, 1, 0.1],
			[\BhPredelay,   \bhPredelay,   0, 1, 0.1],
			[\ModfxRate,      \modfxRate,      0, 1, 0.3],
			[\ModfxDepth,     \modfxDepth,     0, 1, 0.3],
			[\ModfxTone,      \modfxTone,      0, 1, 0.8],
			[\ChorusWidth,    \chorusWidth,    0, 1, 0.5],
			[\FlangerFeedback, \flangerFeedback, -1, 1, 0],
			[\PhaserCenter,   \phaserCenter,   0, 1, 0.5],
			[\PhaserStages,   \phaserStages,   0, 3, 1],
			[\PhaserFeedback, \phaserFeedback, 0, 1, 0.2],
			[\EqLow,          \eqLow,          -1, 1, 0],
			[\EqMid,          \eqMid,          -1, 1, 0],
			[\EqHigh,         \eqHigh,         -1, 1, 0],
			[\EqXlow,         \eqXlow,         0, 1, 0.3],
			[\EqXhi,          \eqXhi,          0, 1, 0.7],
			[\DuckAmount,     \duckAmount,     0, 1, 0.6],
			[\DuckSens,       \duckSens,       0, 1, 0.5],
			[\DuckAttack,     \duckAttack,     0, 1, 0.2],
			[\DuckRelease,    \duckRelease,    0, 1, 0.4],
			[\TapeWow,        \tapeWow,        0, 1, 0.2],
			[\TapeFlutter,    \tapeFlutter,    0, 1, 0.12],
			[\TapeSat,        \tapeSat,        0, 1, 0.24],
			[\CassNoise,      \cassNoise,      0, 1, 0.08],
			[\CassCrackle,    \cassCrackle,    0, 1, 0],
			[\CassDrop,       \cassDrop,       0, 1, 0],
			[\CassTone,       \cassTone,       0, 1, 0.63],
			[\MotionWidth,    \motionWidth,    -1, 1, 0],
			[\MotionBeats,    \motionBeats,    0.0625, 16, 1],
			[\MotionTrem,     \motionTrem,     0, 1, 0],
			[\MotionPan,      \motionPan,      0, 1, 0],
			[\MotionShape,    \motionShape,    0, 2, 0],
			[\RingsMode,      \ringsMode,      0, 1, 0],
			[\RingsFreq,      \ringsFreq,      -1, 1, 0.5],
			[\RingsFine,      \ringsFine,      -1, 1, 0],
			[\RingsFeedback,  \ringsFeedback,  0, 1, 0],
			[\LimitGain,      \limitGain,      0, 1, 0],
			[\LimitCeil,      \limitCeil,      0, 1, 0.95],
			[\LimitRelease,   \limitRelease,   0, 1, 0.3]
		];
	}

	// Set one arg on whichever send/master synth slotIdx names (0/1/2), reusing
	// the existing per-slot setters (no-op when that synth is None / not spawned).
	setSendSlot { arg slotIdx, key, value;
		switch(slotIdx,
			0, { this.setSend1(key, value); },
			1, { this.setSend2(key, value); },
			2, { this.setMasterFx(key, value); });
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
		tr.triggerSlice(msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8], msg[9], msg[10], msg[11]);
	}

	// =======================================================================
	// Global slice voice cap
	// =======================================================================
	// Voices live in their own track's sourceGroup; this list is the only
	// engine-wide bookkeeping -- oldest first, across ALL tracks. 8 tracks x 8
	// voices would cliff the CPU, so hitting the cap steals the oldest voice.
	// The per-track limit (the 32-slot map + slice mono) is untouched.
	registerSliceVoice { arg tr, slot, synth, chokeGroup = 0;
		var oldest;
		// Choke group first (MPC mute group, POLY only -- mono already steals every
		// voice, so choke is moot there). A new voice in group G > 0 cuts every live
		// voice in the SAME group on the SAME track (open/closed hat), before the
		// caps and before this voice is added, so it never steals itself. Other
		// groups (and group 0 = None) are untouched -- they stay polyphonic.
		if(chokeGroup > 0, {
			sliceVoiceOrder.select({ arg e;
				(e[\track] === tr) and: { e[\chokeGroup] == chokeGroup }
			}).do({ arg victim;
				sliceVoiceOrder = sliceVoiceOrder.reject({ arg e; e === victim });
				victim[\track].stealSlice(victim[\slot], victim[\synth]);
			});
		});
		// Per-track cap: steal THIS track's oldest so it stays within its own
		// budget and can't starve the shared pool. detect returns the oldest (the
		// list is oldest-first).
		while({ sliceVoiceOrder.count({ arg e; e[\track] === tr }) >= maxSliceVoicesPerTrack }, {
			oldest = sliceVoiceOrder.detect({ arg e; e[\track] === tr });
			sliceVoiceOrder = sliceVoiceOrder.reject({ arg e; e === oldest });
			oldest[\track].stealSlice(oldest[\slot], oldest[\synth]);
		});
		// Then the global pool cap across all tracks.
		while({ sliceVoiceOrder.size >= maxSliceVoices }, {
			oldest = sliceVoiceOrder[0];
			sliceVoiceOrder = sliceVoiceOrder.drop(1);
			oldest[\track].stealSlice(oldest[\slot], oldest[\synth]);
		});
		sliceVoiceOrder = sliceVoiceOrder.add((track: tr, slot: slot, synth: synth, chokeGroup: chokeGroup));
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

	// Panic hard-kill: steal (fade+free) every slice voice on every track, so a
	// stuck or long-releasing voice dies NOW instead of gate-off + release.
	stealAllSlices {
		this.activeTracks.do({ arg tr; tr.stealActiveSlices; });
	}

	// =======================================================================
	// Send 1/2 + master insert FX (global; PRD SS3/SS8)
	// =======================================================================
	// Shared arg list for any send/master FX slot -- slotIdx indexes the
	// sendFx* arrays (0 = Send 1, 1 = Send 2, 2 = Master).
	sendFxArgs { arg slotIdx, inBusIndex, outBusIndex;
		var extra;
		// The new machines' params (Comp/Destroy/Echo/Blackhole) come from the
		// per-slot dict so a respawn reapplies the last value; unknown args are
		// ignored by whatever SynthDef spawns, so this is safe for every machine.
		extra = [];
		this.sendFxExtraSpec.do({ arg row;
			var key = row[1];
			extra = extra ++ [key, sendFxExtra[slotIdx][key]];
		});
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
			\targetBpm, targetBpm,
			\keyIn, masterBus.index,   // Duck sidechain source (the dry program)
			// Comp/Duck meter id for the GLOBAL slots: 101 = Send 1, 102 = Send 2,
			// 103 = Master. Never collides with a track index (1-8); the responder
			// forwards ids > 100 unconditionally so the send/master FX pages can
			// show their meters too.
			\meterTrack, 101 + slotIdx
		] ++ extra;
	}

	spawnSend1 {
		if(send1Synth.notNil, { send1Synth.free; });
		send1Synth = nil;
		// Machine None (index 0) is \elasticatFxNone -- a bare PASSTHROUGH. As a
		// per-track insert that is correct (the chain must stay connected), but a
		// send RETURN that just copies sendBus1 into masterBus doubles the sent
		// signal (the owner hears it even with the send "off"). A send return
		// adds an effect or nothing: None spawns NO synth, so sendBus1 is simply
		// left unread (nothing downstream depends on it).
		if(send1Machine.asInteger == 0, { ^nil });
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
		send2Synth = nil;
		// Machine None: no return synth (see spawnSend1 -- a None passthrough
		// would double the sent signal back into masterBus).
		if(send2Machine.asInteger == 0, { ^nil });
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
	// Per-track clock lock. `beatsSinceOrigin` is the shared clock position since
	// play-start; each PLAYING loop track locks to its OWN expected phase
	// (beatsSinceOrigin / its loopBeats), so a loop on ANY track -- not just
	// track 1 -- starts and stays in sync with the clock-driven slice trigs.
	// Loops of different lengths share the play-start downbeat (all expected 0 at
	// beatsSinceOrigin 0). The status-stream diagnostics track the first playing
	// loop (the reference), preserving the single-loop behaviour.
	syncClock { arg beatsSinceOrigin, tempo, sequence;
		var haveRef;
		if(sequence <= lastClockSeq, {
			staleClockCount = staleClockCount + 1;
			^nil;
		});
		lastClockSeq = sequence;
		targetBpm = tempo.max(1);
		haveRef = false;
		this.activeTracks.do({ arg tr;
			var expected, err, loopSeconds, absMs;
			if(tr.playing == 1, {
				// warpRate scales the effective loop length: a half-speed loop (rate
				// 0.5) takes twice as many beats to complete one phase cycle, so its
				// expected phase advances at rate/loopBeats.
				expected = ((beatsSinceOrigin * tr.warpRate) / tr.loopBeats.max(0.03125)) % 1;
				err = expected - tr.lastPhase;
				if(err > 0.5, { err = err - 1; });
				if(err < -0.5, { err = err + 1; });
				loopSeconds = (tr.loopBeats / tr.warpRate.max(0.001)) * 60 / targetBpm;
				absMs = err.abs * loopSeconds * 1000;
				// Tape (mode 0) free-runs at NATIVE rate on its own Phasor -- it does
				// not follow the loopBeats transport phase, so there is nothing to
				// lock. Realigning it just fought the native rate: the reader drifts,
				// err crosses hardThreshold, the realign resets the tape Phasor, it
				// drifts again -> an audible playhead jump (small mismatch) or a fast
				// back-and-forth yo-yo (large). Only bus-following machines clock-lock.
				// A non-unity warpRate also free-runs: at a constant tempo the sample-
				// accurate Phasor stays perfectly in ratio with the grid, and clock-
				// locking it to the rate-1 expected phase would fight the rate multiple
				// (yo-yo). It re-aligns cleanly on the next play-start / setPlayhead.
				if((tr.machine == 0) or: { (tr.warpRate - 1).abs > 0.001 }, {
					tr.correction = 0;
				}, {
					if(err.abs > hardThreshold, {
						tr.correction = 0;
						hardRealignCount = hardRealignCount + 1;
						tr.setPlayhead(expected);
						scriptAddress.sendBundle(0, ["/elasticat/reset", tr.index, tr.lastPhase]);
					}, {
						if(absMs < 0.5, {
							tr.correction = 0;
						}, {
							tr.correction = (err * 0.5).clip(maxCorrection.neg, maxCorrection);
						});
					});
				});
				// First playing loop = the reference for the (track-1) status stream.
				if(haveRef.not, {
					haveRef = true;
					lastExpectedPhase = expected;
					lastPhase = tr.lastPhase;
					lastPhaseError = err;
					lastErrorMs = absMs;
					correction = tr.correction;
				});
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

	// Live region/gain update for the running preview -- no re-spawn, so trim
	// scrubbing on the File page follows in real time (the synth Lags it smooth).
	setPreviewRegion { arg startFrac, endFrac, gain;
		if(previewSynth.notNil, {
			previewSynth.set(\startFrac, startFrac.clip(0, 0.999), \endFrac, endFrac.clip(0.001, 1), \gain, gain.max(0));
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

	// ---- Idle pause (see the var block comment) ---------------------------
	// Eligibility lives in ONE place: stopped, awake, allocated, not the
	// viewed track, silent past the grace window, and holding no live slice
	// voices (a stopped track can still be auditioning pads).
	idleScan {
		var now;
		if(idlePauseEnabled == 0, { ^this });
		now = Main.elapsedTime;
		(1..8).do({ arg t;
			var tr = tracks[t];
			if(tr.notNil and: { tr.isAllocated }, {
				if(tr.idleEligible(now, viewTrack, idleGraceSeconds) and: {
					sliceVoiceOrder.count({ arg e; e[\track] === tr }) == 0
				}, {
					tr.idlePause;
					// Drop the script-side mixer meter to zero: the paused mix
					// synth can no longer report its (silent) level itself.
					scriptAddress.sendBundle(0, ["/elasticat/track/level", t, 0, 0]);
				});
			});
		});
		idlePausedCount = (1..8).count({ arg t;
			tracks[t].notNil and: { tracks[t].idlePaused }
		});
	}

	wakeAllTracks {
		(1..8).do({ arg t;
			if(tracks[t].notNil, { tracks[t].idleWake; });
		});
		idlePausedCount = 0;
	}

	setIdlePauseEnabled { arg flag;
		idlePauseEnabled = flag.asInteger.clip(0, 1);
		if(idlePauseEnabled == 0, { this.wakeAllTracks; });
	}

	setIdleGrace { arg secs;
		idleGraceSeconds = secs.clip(0.1, 60);
	}

	setViewTrack { arg t;
		viewTrack = t.asInteger.clip(1, 8);
		// The viewed track drives the UI feeds (meter/phase/mod) and is the
		// one being auditioned -- it must never sit paused.
		if(tracks[viewTrack].notNil, { tracks[viewTrack].idleWake; });
	}

	free {
		this.releaseAllSlices;
		if(idleScanRoutine.notNil, { idleScanRoutine.stop; });
		if(idleResponder.notNil, { idleResponder.free; });
		if(statusResponder.notNil, { statusResponder.free; });
		if(modResponder.notNil, { modResponder.free; });
		if(filterEnvResponder.notNil, { filterEnvResponder.free; });
		if(fxMeterResponder.notNil, { fxMeterResponder.free; });
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

	// --- idle pause state (engine.idleScan drives it; see engine var block) ---
	var <idlePaused = false;
	var lastLoudTime = 0;   // Main.elapsedTime of the last non-silent 2Hz report

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
	// Per-track clock-lock correction: syncClock locks EVERY playing loop track to
	// its OWN expected phase (its own loopBeats), so a loop on any track -- not
	// just track 1 -- stays in sync with the shared clock.
	var <>correction = 0;

	// --- warp machine params (seeded on every reader respawn) ---------------
	// chopBeats = SLICE COUNT (1-64); chopSliceLen = SLEN, how many steps each slice
	// plays (a step = a 16th); chopMode = LOOP mode (0 chop / 1 loop / 2 pingpong / 3 runaway).
	var <chopBeats = 16, <chopMode = 2, <chopSliceLen = 1;
	var <chopAttack = 0.002, <chopHold = 0.9, <chopRelease = 0.01;
	var <grainSize = 0.08, <grainOverlap = 8, <grainJitter = 0;
	var <grainSpeed = 1, <grainSpeedRand = 0, <grainDirection = 1;
	var <wsolaWindow = 0.1, <wsolaSearch = 0.03;
	var <pvWindow = 0.2, <pvDispersion = 0;
	var <harmInterval = 7, <harmInterval2 = 0, <harmInterval3 = 0;
	// Wavetable Scan: wtWindow is a SLICE COUNT (how many cycles are spread across
	// the range); wtCycle is each cycle's WIDTH in samples (the single-cycle len);
	// wtLfo* auto-scan MORF. See the \elasticatWavetable def.
	var <wtWindow = 8, <wtCycle = 600, <wtLfoRate = 0, <wtLfoDepth = 64, <wtLfoShape = 0;
	var <freezeAmount = 0, <spectralBlur = 0, <formantShift = 0;
	// Synced rate multiplier (warp-page slot 8, every mode). 1 = normal; 0.5 =
	// half-speed loop; 2 = double. Scales the transport phasor for bus-following
	// modes and the tape reader's native Phasor. syncClock reads it so clock-lock
	// uses the effective loop length.
	var <warpRate = 1;
	// Playhead-JUMP crossfade time (source-page "loop xfade"). The direct reader
	// (tape / tempo_varispeed) reads old + new trajectories and equal-power fades
	// between them over this; longer = a softer tape-splice, shorter = a tight
	// declick. Only the direct reader uses it today.
	var <xfade = 0.01;

	// --- filter + filter envelope -------------------------------------------
	var <filterMachine = 0, <filterType = 0, <filterCutoff = 20000;
	var <filterRes = 0, <filterDrive = 0, <filterMorph = 0, <filterBalance = 0, <filterMix = 1, <filterMixMode = 0;
	var <filterEnvMode = 1, <filterEnvAttack = 0.0001, <filterEnvDecay = 0.15;
	var <filterEnvSustain = 0.8, <filterEnvRelease = 0.0001, <filterEnvHold = 1000000;
	var <filterEnvDepth = 0;

	// --- insert FX -----------------------------------------------------------
	var <fxInsertMachine = 0, <fxDrive = 0, <fxMix = 0.5;
	var <delayBeats = 1, <delayFeedback = 0.3, <delayTone = 1;
	var <reverbSize = 0.5, <reverbDamp = 0.5, <lofiBits = 24, <lofiRate = 48000;
	// New machines' per-track insert params (Comp/Destroy/Echo/Blackhole). Each is
	// a setSpec field (instVarPut writes here) AND seeded into fxInsertArgs so it
	// survives a machine swap. Defaults mirror the SynthDef arg defaults.
	var <compThresh = 0.3, <compRatio = 0.2, <compAttack = 0.1, <compRelease = 0.3, <compMakeup = 0;
	var <destroyWarble = 0, <destroyFold = 0, <destroySat = 0, <destroyCrush = 0, <destroySrr = 0, <destroyTone = 1, <destroyLevel = 0.55;
	var <echoBeats = 1, <echoOffset = 0, <echoMode = 0, <echoTone = 1, <echoWobble = 0;
	var <bhGravity = 0.5, <bhMod = 0.2, <bhLow = 0.1, <bhPredelay = 0.1;
	// Chorus/Flanger/Phaser (share modfx*), DJ EQ, Duck.
	var <modfxRate = 0.3, <modfxDepth = 0.3, <modfxTone = 0.8;
	var <chorusWidth = 0.5, <flangerFeedback = 0, <phaserCenter = 0.5, <phaserStages = 1, <phaserFeedback = 0.2;
	var <eqLow = 0, <eqMid = 0, <eqHigh = 0, <eqXlow = 0.3, <eqXhi = 0.7;
	var <duckAmount = 0.6, <duckSens = 0.5, <duckAttack = 0.2, <duckRelease = 0.4;
	// Tape Echo / Cassette (share tapeWow/Flutter), Motion, Rings, Limit.
	var <tapeWow = 0.2, <tapeFlutter = 0.12, <tapeSat = 0.24;
	var <cassNoise = 0.08, <cassCrackle = 0, <cassDrop = 0, <cassTone = 0.63;
	var <motionWidth = 0, <motionBeats = 1, <motionTrem = 0, <motionPan = 0, <motionShape = 0;
	var <ringsMode = 0, <ringsFreq = 0.5, <ringsFine = 0, <ringsFeedback = 0;
	var <limitGain = 0, <limitCeil = 0.95, <limitRelease = 0.3;

	// --- send levels into the two GLOBAL send busses ------------------------
	var <sendTap = 0, <sendLevel1 = 0, <sendLevel2 = 0;

	// --- mod: 2 LFOs + mod env + 4 macros (base + 4x5 depth matrix) ---------
	var <lfo1Dest = 0, <lfo1Wave = 0, <lfo1Beats = 4, <lfo1Depth = 0, <lfo1Mode = 0;
	var <lfo2Dest = 0, <lfo2Wave = 0, <lfo2Beats = 4, <lfo2Depth = 0, <lfo2Mode = 0;
	var <menvDest = 0, <menvAttack = 0.01, <menvDecay = 0.15;
	var <menvSustain = 0.8, <menvRelease = 0.15, <menvDepth = 0;
	// Velocity as a mod source: dest + depth; modVelocity is the latched last
	// trigger velocity, set per slice trig.
	var <mvelDest = 0, <mvelDepth = 0;
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
			\chopBeats    -> (arg: \chopBeats,    synth: \reader, lo: 1, hi: 256, int: true),
			\chopSliceLen -> (arg: \chopSliceLen, synth: \reader, lo: 0.05, hi: 64),
			\chopMode     -> (arg: \chopMode,     synth: \reader, lo: 0, hi: 7, int: true),
			\chopAttack   -> (arg: \chopAttack,   synth: \reader, lo: 0.0001),
			\chopHold     -> (arg: \chopHold,     synth: \reader, lo: 0),
			\chopRelease  -> (arg: \chopRelease,  synth: \reader, lo: 0.0001),
			// Domino model (owner): the RANGE (chopRangeStart/End, 0-128 of the whole
			// sample) is the slice area; the TRACK window (chopPlayLo/Hi, 0-1) bounds the
			// playhead so only the slices under the track fire. Facade sends the range +
			// the raw loop separately (see elasticat.push_chop_regions).
			\chopRangeStart -> (arg: \chopRangeStart, synth: \reader, lo: 0, hi: 128),
			\chopRangeEnd   -> (arg: \chopRangeEnd,   synth: \reader, lo: 0, hi: 128),
			\chopPlayLo     -> (arg: \chopPlayLo,     synth: \reader, lo: 0, hi: 1),
			\chopPlayHi     -> (arg: \chopPlayHi,     synth: \reader, lo: 0, hi: 1),
			\grainSize    -> (arg: \grainSize,    synth: \reader, lo: 0.002, hi: 0.5),
			\grainOverlap -> (arg: \grainOverlap, synth: \reader, lo: 1, hi: 64),
			\grainJitter  -> (arg: [\grainJitter, \grainSpray], synth: \reader, lo: 0, hi: 0.25),
			\grainSpeed     -> (arg: \grainSpeed,     synth: \reader, lo: 0, hi: 4),
			\grainSpeedRand -> (arg: \grainSpeedRand, synth: \reader, lo: 0, hi: 1),
			\grainDirection -> (arg: \grainDirection, synth: \reader, lo: 0, hi: 1),
			\wsolaWindow  -> (arg: \grainSize,    synth: \reader, lo: 0.005, hi: 0.5),
			\wsolaSearch  -> (arg: \wander,       synth: \reader, lo: 0, hi: 0.1),
			\pvWindow     -> (arg: \pvWindow,     synth: \reader, lo: 0.005, hi: 2),
			\pvDispersion -> (arg: \pvDispersion, synth: \reader, lo: 0, hi: 1),
			\harmInterval -> (arg: \harmInterval, synth: \reader, lo: -24, hi: 24),
			\harmInterval2 -> (arg: \harmInterval2, synth: \reader, lo: -24, hi: 24),
			\harmInterval3 -> (arg: \harmInterval3, synth: \reader, lo: -24, hi: 24),
			\wtWindow     -> (arg: \wtWindow,     synth: \reader, lo: 2, hi: 64, int: true),
			\wtCycle      -> (arg: \wtCycle,      synth: \reader, lo: 16, hi: 8192, int: true),
			\wtLfoRate    -> (arg: \wtLfoRate,    synth: \reader, lo: 0, hi: 8000),
			\wtLfoDepth   -> (arg: \wtLfoDepth,   synth: \reader, lo: 0, hi: 128),
			\wtLfoShape   -> (arg: \wtLfoShape,   synth: \reader, lo: 0, hi: 4, int: true),
			\freezeAmount -> (arg: \freezeAmount, synth: \reader, lo: 0, hi: 1),
			\spectralBlur -> (arg: \spectralBlur, synth: \reader, lo: 0, hi: 1),
			\formantShift -> (arg: \formantShift, synth: \reader, lo: -24, hi: 24),
			// warpRate pushes to the READER (tape's native Phasor); set() also fans it
			// to the transport synth (bus-following modes). syncClock reads tr.warpRate.
			\warpRate     -> (arg: \warpRate, synth: \reader, lo: 0.03125, hi: 8),
			// Playhead-jump crossfade time -> the direct reader's \loopXfade arg.
			\xfade        -> (arg: \loopXfade, synth: \reader, lo: 0.0005, hi: 0.25),
			// filter stage (also the amp/pan output stage -- see setAmp)
			\pan              -> (arg: \pan,        synth: \filter, lo: -1, hi: 1),
			\filterType       -> (arg: \filterType, synth: \filter, lo: 0, hi: 3, int: true),
			\filterCutoff     -> (arg: \cutoff,     synth: \filter, lo: 20, hi: 20000),
			\filterRes        -> (arg: \res,        synth: \filter, lo: 0, hi: 1),
			\filterDrive      -> (arg: \drive,      synth: \filter, lo: 0, hi: 1),
			\filterMorph      -> (arg: \morph,      synth: \filter, lo: 0, hi: 1),
			\filterBalance    -> (arg: \balance,    synth: \filter, lo: -1, hi: 1),
			\filterMix        -> (arg: \mix,        synth: \filter, lo: 0, hi: 1),
			\filterMixMode    -> (arg: \mixMode,    synth: \filter, lo: 0, hi: 1),
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
			// new insert FX machines (Comp/Destroy/Echo/Blackhole). Values arrive in
			// engine units (0-1 amounts, -1..1 offset, or beats); lo/hi just clips.
			\compThresh    -> (arg: \compThresh,    synth: \insert, lo: 0, hi: 1),
			\compRatio     -> (arg: \compRatio,     synth: \insert, lo: 0, hi: 1),
			\compAttack    -> (arg: \compAttack,    synth: \insert, lo: 0, hi: 1),
			\compRelease   -> (arg: \compRelease,   synth: \insert, lo: 0, hi: 1),
			\compMakeup    -> (arg: \compMakeup,    synth: \insert, lo: 0, hi: 1),
			\destroyWarble -> (arg: \destroyWarble, synth: \insert, lo: 0, hi: 1),
			\destroyFold   -> (arg: \destroyFold,   synth: \insert, lo: 0, hi: 1),
			\destroySat    -> (arg: \destroySat,    synth: \insert, lo: 0, hi: 1),
			\destroyCrush  -> (arg: \destroyCrush,  synth: \insert, lo: 0, hi: 1),
			\destroySrr    -> (arg: \destroySrr,    synth: \insert, lo: 0, hi: 1),
			\destroyTone   -> (arg: \destroyTone,   synth: \insert, lo: 0, hi: 1),
			\destroyLevel  -> (arg: \destroyLevel,  synth: \insert, lo: 0, hi: 1),
			\echoBeats     -> (arg: \echoBeats,     synth: \insert, lo: 0.03125, hi: 8),
			\echoOffset    -> (arg: \echoOffset,    synth: \insert, lo: -1, hi: 1),
			\echoMode      -> (arg: \echoMode,      synth: \insert, lo: 0, hi: 1, int: true),
			\echoTone      -> (arg: \echoTone,      synth: \insert, lo: 0, hi: 1),
			\echoWobble    -> (arg: \echoWobble,    synth: \insert, lo: 0, hi: 1),
			\bhGravity     -> (arg: \bhGravity,     synth: \insert, lo: 0, hi: 1),
			\bhMod         -> (arg: \bhMod,         synth: \insert, lo: 0, hi: 1),
			\bhLow         -> (arg: \bhLow,         synth: \insert, lo: 0, hi: 1),
			\bhPredelay    -> (arg: \bhPredelay,    synth: \insert, lo: 0, hi: 1),
			// Chorus/Flanger/Phaser (shared modfx*), DJ EQ, Duck
			\modfxRate      -> (arg: \modfxRate,      synth: \insert, lo: 0, hi: 1),
			\modfxDepth     -> (arg: \modfxDepth,     synth: \insert, lo: 0, hi: 1),
			\modfxTone      -> (arg: \modfxTone,      synth: \insert, lo: 0, hi: 1),
			\chorusWidth    -> (arg: \chorusWidth,    synth: \insert, lo: 0, hi: 1),
			\flangerFeedback -> (arg: \flangerFeedback, synth: \insert, lo: -1, hi: 1),
			\phaserCenter   -> (arg: \phaserCenter,   synth: \insert, lo: 0, hi: 1),
			\phaserStages   -> (arg: \phaserStages,   synth: \insert, lo: 0, hi: 3, int: true),
			\phaserFeedback -> (arg: \phaserFeedback, synth: \insert, lo: 0, hi: 1),
			\eqLow          -> (arg: \eqLow,          synth: \insert, lo: -1, hi: 1),
			\eqMid          -> (arg: \eqMid,          synth: \insert, lo: -1, hi: 1),
			\eqHigh         -> (arg: \eqHigh,         synth: \insert, lo: -1, hi: 1),
			\eqXlow         -> (arg: \eqXlow,         synth: \insert, lo: 0, hi: 1),
			\eqXhi          -> (arg: \eqXhi,          synth: \insert, lo: 0, hi: 1),
			\duckAmount     -> (arg: \duckAmount,     synth: \insert, lo: 0, hi: 1),
			\duckSens       -> (arg: \duckSens,       synth: \insert, lo: 0, hi: 1),
			\duckAttack     -> (arg: \duckAttack,     synth: \insert, lo: 0, hi: 1),
			\duckRelease    -> (arg: \duckRelease,    synth: \insert, lo: 0, hi: 1),
			// Tape Echo / Cassette / Motion / Rings / Limit
			\tapeWow        -> (arg: \tapeWow,        synth: \insert, lo: 0, hi: 1),
			\tapeFlutter    -> (arg: \tapeFlutter,    synth: \insert, lo: 0, hi: 1),
			\tapeSat        -> (arg: \tapeSat,        synth: \insert, lo: 0, hi: 1),
			\cassNoise      -> (arg: \cassNoise,      synth: \insert, lo: 0, hi: 1),
			\cassCrackle    -> (arg: \cassCrackle,    synth: \insert, lo: 0, hi: 1),
			\cassDrop       -> (arg: \cassDrop,       synth: \insert, lo: 0, hi: 1),
			\cassTone       -> (arg: \cassTone,       synth: \insert, lo: 0, hi: 1),
			\motionWidth    -> (arg: \motionWidth,    synth: \insert, lo: -1, hi: 1),
			\motionBeats    -> (arg: \motionBeats,    synth: \insert, lo: 0.0625, hi: 16),
			\motionTrem     -> (arg: \motionTrem,     synth: \insert, lo: 0, hi: 1),
			\motionPan      -> (arg: \motionPan,      synth: \insert, lo: 0, hi: 1),
			\motionShape    -> (arg: \motionShape,    synth: \insert, lo: 0, hi: 2, int: true),
			\ringsMode      -> (arg: \ringsMode,      synth: \insert, lo: 0, hi: 1, int: true),
			\ringsFreq      -> (arg: \ringsFreq,      synth: \insert, lo: -1, hi: 1),
			\ringsFine      -> (arg: \ringsFine,      synth: \insert, lo: -1, hi: 1),
			\ringsFeedback  -> (arg: \ringsFeedback,  synth: \insert, lo: 0, hi: 1),
			\limitGain      -> (arg: \limitGain,      synth: \insert, lo: 0, hi: 1),
			\limitCeil      -> (arg: \limitCeil,      synth: \insert, lo: 0, hi: 1),
			\limitRelease   -> (arg: \limitRelease,   synth: \insert, lo: 0, hi: 1),
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
			\menvDepth   -> (arg: \menvDepth,   synth: \mod, lo: -1, hi: 1),
			\mvelDest  -> (arg: \mvelDest,  synth: \mod, lo: 0, hi: 9, int: true),
			\mvelDepth -> (arg: \mvelDepth, synth: \mod, lo: -1, hi: 1)
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
		// warpRate also drives the transport phasor (the spec push only reached the
		// reader, for tape). Every bus-following mode picks it up through the phase.
		if(field == \warpRate and: { transportSynth.notNil }, {
			transportSynth.set(\warpRate, v);
		});
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
		if(mvelDepth != 0, { ^true });
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
		if(playing == 1, { this.idleWake; });
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

	// ---- Idle pause (engine.idleScan decides; these do the node work) --------
	// Post-gain output level from this track's mix synth (2Hz). Anything above
	// the floor counts as "recently audible" and defers the pause -- FX tails
	// included, since the level is measured after the insert.
	reportOutLevel { arg lvl;
		if(lvl > 0.001, { lastLoudTime = Main.elapsedTime; });
	}

	idleEligible { arg now, view, grace;
		^(playing == 0)
			and: { idlePaused.not }
			and: { index != view }
			and: { group.notNil }
			and: { (now - lastLoudTime) > grace }
	}

	// Pause the WHOLE track group -- transport, reader, mod, filter, insert,
	// send tap and mix all stop executing. Nodes spawned into the paused group
	// later (machine swaps on a background track) stay paused with it, and one
	// run(true) resumes the entire subtree, so the bookkeeping is a single flag.
	idlePause {
		if(idlePaused or: { group.isNil }, { ^this });
		group.run(false);
		idlePaused = true;
	}

	// Called from EVERY entry point that makes this track sound (play, note and
	// slice trigs, mod trig) plus becoming the viewed track. Also bumps
	// lastLoudTime so the next scan tick can't re-pause the track before its
	// first audio arrives.
	idleWake {
		lastLoudTime = Main.elapsedTime;
		if(idlePaused.not, { ^this });
		idlePaused = false;
		if(group.notNil, { group.run(true); });
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
				\correction, correction,
				\warpRate, warpRate,
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
				\correction, correction,
				\warpRate, warpRate
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
		this.idleWake;
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
		this.idleWake;
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
		this.idleWake;
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
			\warpRate, warpRate,
			\loopXfade, xfade,
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
			\chopSliceLen, chopSliceLen,
			\chopMode, chopMode,
			\chopAttack, chopAttack,
			\chopHold, chopHold,
			\chopRelease, chopRelease,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter,
			\grainSpray, grainJitter,
			\grainSpeed, grainSpeed,
			\grainSpeedRand, grainSpeedRand,
			\grainDirection, grainDirection,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion,
			\harmInterval, harmInterval,
			\harmInterval2, harmInterval2,
			\harmInterval3, harmInterval3,
			\wtWindow, wtWindow,
			\wtCycle, wtCycle,
			\wtLfoRate, wtLfoRate,
			\wtLfoDepth, wtLfoDepth,
			\wtLfoShape, wtLfoShape,
			\freezeAmount, freezeAmount,
			\spectralBlur, spectralBlur,
			\formantShift, formantShift
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
			\mix, filterMix,
			\mixMode, filterMixMode,
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
			\targetBpm, engine.targetBpm,
			// new machines' params (unknown args are ignored by whichever machine spawns)
			\compThresh, compThresh, \compRatio, compRatio, \compAttack, compAttack,
			\compRelease, compRelease, \compMakeup, compMakeup,
			\destroyWarble, destroyWarble, \destroyFold, destroyFold, \destroySat, destroySat,
			\destroyCrush, destroyCrush, \destroySrr, destroySrr, \destroyTone, destroyTone, \destroyLevel, destroyLevel,
			\echoBeats, echoBeats, \echoOffset, echoOffset, \echoMode, echoMode,
			\echoTone, echoTone, \echoWobble, echoWobble,
			\bhGravity, bhGravity, \bhMod, bhMod, \bhLow, bhLow, \bhPredelay, bhPredelay,
			\modfxRate, modfxRate, \modfxDepth, modfxDepth, \modfxTone, modfxTone,
			\chorusWidth, chorusWidth, \flangerFeedback, flangerFeedback,
			\phaserCenter, phaserCenter, \phaserStages, phaserStages, \phaserFeedback, phaserFeedback,
			\eqLow, eqLow, \eqMid, eqMid, \eqHigh, eqHigh, \eqXlow, eqXlow, \eqXhi, eqXhi,
			\duckAmount, duckAmount, \duckSens, duckSens, \duckAttack, duckAttack, \duckRelease, duckRelease,
			\tapeWow, tapeWow, \tapeFlutter, tapeFlutter, \tapeSat, tapeSat,
			\cassNoise, cassNoise, \cassCrackle, cassCrackle, \cassDrop, cassDrop, \cassTone, cassTone,
			\motionWidth, motionWidth, \motionBeats, motionBeats, \motionTrem, motionTrem,
			\motionPan, motionPan, \motionShape, motionShape,
			\ringsMode, ringsMode, \ringsFreq, ringsFreq, \ringsFine, ringsFine, \ringsFeedback, ringsFeedback,
			\limitGain, limitGain, \limitCeil, limitCeil, \limitRelease, limitRelease,
			// Duck keys off the master bus (the dry program); best on a send return.
			\keyIn, engine.masterBus.index,
			// Comp/Duck meter reply id = this track's index (so the engine responder
			// forwards only the viewed track's meter to the script).
			\meterTrack, index
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
		var defName;
		if(group.isNil, { ^nil });
		defName = engine.modeSynthNames.wrapAt(machine.asInteger);
		// Spectral modes (freeze = 8 / formant = 9) run an FFT chain -- one is
		// affordable, 8 are not. Track-1-only: fall back to tape on any other track.
		// (Named explicitly, not >=8, so gstretch (10) / gstretch2 (11) / chopped (12) still run on every track.)
		if(((machine.asInteger == 8) or: { machine.asInteger == 9 }) and: { index != 1 }, { defName = \elasticatTape; });
		^Synth.after(transportSynth, defName, this.commonArgs(startAmp));
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
		// The instance survives free/alloc cycles (activeTrackCount changes),
		// but the paused NODE does not -- a fresh group runs. Reset the flag so
		// idleWake/idleScan reason about the new group, not the freed one.
		idlePaused = false;
		lastLoudTime = Main.elapsedTime;
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
			\correction, correction,
			\warpRate, warpRate,
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
			\alive, 1,
			\trackIndex, index
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
		// A freed track is not "paused" -- the node the flag described is gone
		// (and idlePausedCount must not keep counting it).
		idlePaused = false;
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
	triggerSlice { arg sliceIndex, startPoint, endPoint, playMode, reverse, velocity, lengthSeconds, notePitch, chokeGroup = 0, mono = (-1);
		var idx, startPos, endPos, mode, rev, pitchValue, pitchRatio, duration, sliceRatio, synth, chk, isMono;
		if(group.isNil, { ^nil });
		this.idleWake;
		idx = sliceIndex.asInteger.clip(1, 32);
		chk = (chokeGroup ? 0).asInteger.clip(0, 8);
		startPos = startPoint.asFloat.clip(0, 127.99);
		endPos = endPoint.asFloat.clip(0.01, 128);
		if(endPos <= startPos, { endPos = (startPos + 0.01).clip(0.01, 128); });
		mode = playMode.asInteger.clip(0, 5);
		rev = reverse.asInteger.clip(0, 1);
		pitchValue = notePitch.asFloat.clip(-48, 48);
		pitchRatio = pitchValue.midiratio.max(0.001);
		duration = lengthSeconds.asFloat;
		// `duration` is the GATE/lifetime now, not the read rate. Gated modes pass a
		// real length from Lua (step note length, or a long value for a live key-hold
		// that releaseSlice ends); One-Shot passes 0 and the read sweep-end gates it,
		// so this natural length is only the envHold reference + a lifetime cap.
		if(duration <= 0, {
			sliceRatio = ((endPos - startPos).abs / 128).max(0.0001);
			duration = ((sourceFrames.max(1) * sliceRatio) / sourceRate.max(1)) / pitchRatio;
		});
		duration = duration.clip(0.005, 60);

		// Voicing: the caller (Slice/Razor = mono, *Poly = poly) passes mono 0/1;
		// mono < 0 falls back to the engine's global default (old callers, tests).
		isMono = if(mono < 0, { engine.sliceMono }, { mono.asInteger });
		if(isMono == 1, { this.stealActiveSlices; });
		// Same-slice retrigger (ratchet / fast re-hit) STEALS the previous voice
		// (20ms fade + FREE), it does NOT just release it: releaseSlice's gate-0 is
		// INEFFECTIVE for an AHR voice (it ignores gate-off and holds to the end), so
		// a poly ratchet piled up full-length warp voices and spiked CPU. Each SLICE
		// is now monophonic; polyphony ACROSS different slices is unchanged (owner).
		this.stealSliceAt(idx);
		// Latch this trigger velocity into the mod synth (velocity as a mod
		// source). modSynth is nil until a mod is active -- needsMod counts
		// mvelDepth, so it exists whenever velocity mod is engaged.
		if(modSynth.notNil, { modSynth.set(\modVelocity, velocity.asFloat.clip(0, 1)); });

		// Pick the lean per-warp slice def for THIS track's warp mode (machine):
		// 0 tape / 1 varispeed / 2 chopped -> raw, 3 granular, 4 random_ola, 5 pc.
		synth = Synth.tail(sourceGroup, switch(machine.asInteger,
			3, { \elasticatSliceVoice_grain },
			4, { \elasticatSliceVoice_ola },
			5, { \elasticatSliceVoice_pc },
			{ \elasticatSliceVoice_raw }), [
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
			\tempoMode, if(machine.asInteger == 1, {1}, {0}),
			\sliceRate, engine.sliceRate,
			\targetBpm, engine.targetBpm,
			\derivedSourceBpm, derivedSourceBpm,
			\macro, macro,
			\grainSize, grainSize,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter,
			\grainSpeed, grainSpeed,
			\grainSpeedRand, grainSpeedRand,
			\grainDirection, grainDirection,
			\wsolaWindow, wsolaWindow,
			\wsolaSearch, wsolaSearch,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion,
			\pitchModBus, modBusPitch.index,
			\gate, 1
		]);
		sliceVoices[idx - 1] = synth;
		engine.registerSliceVoice(this, idx, synth, chk);
		// Drop the voice from the global order when it ACTUALLY frees (envelope,
		// steal, or free) -- NOT at its gate-close time. A bounded release outlives
		// `duration`, so forgetting at `duration` made the poly cap under-count live
		// voices and never reach the steal threshold. The steal paths forget
		// synchronously too; onFree is idempotent with them.
		// On ACTUAL free (envelope done, steal, or free) drop the voice from the
		// global order AND release its slot, so the gate Routine below never \gate a
		// node the envelope already freed (One-Shot frees at its sweep-end, before the
		// Routine timer).
		synth.onFree({ engine.forgetSliceVoice(synth); if(sliceVoices[idx - 1] == synth, { sliceVoices[idx - 1] = nil; }); });
		Routine({
			var gateSeconds;
			// Gate window for the EXTERNAL gate (Hold/Loop/Continue). AHR: the HOLD caps
			// it, so shortening the envelope hold releases the note early (owner); a long
			// default hold falls back to the note length. ADSR uses the note length as-is.
			// One-Shot ignores this gate (its own sweep-end releases it) -- harmless here.
			gateSeconds = if(envMode.asInteger == 1, { min(duration, envHold) }, { duration });
			gateSeconds.clip(0.005, 60).wait;
			// Close the gate (release) and free the slot only if this voice
			// still owns it: a stolen or replaced voice is already gone, and setting
			// a freed node just makes the server log a failure.
			if(sliceVoices[idx - 1] == synth, {
				synth.set(\gate, 0);
				sliceVoices[idx - 1] = nil;
			});
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

	// Per-slice hard steal: 20ms fade + FREE of the voice in ONE slot (a same-slice
	// retrigger), vs releaseSlice's gate-0 that lets it ring out (or, for AHR, play
	// on). Keeps each slice monophonic without touching the other slots' voices.
	stealSliceAt { arg sliceIndex;
		var idx, synth;
		idx = sliceIndex.asInteger.clip(1, 32);
		synth = sliceVoices[idx - 1];
		if(synth.notNil, {
			synth.set(\steal, 1);
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

	// MONO cut: a new slice must END the previous one NOW, not let it ring out.
	// releaseAllSlices only opens the release stage -- an AHR voice ignores
	// gate-off entirely (it holds to the end) and even an ADSR release lingers,
	// so fast sequenced slices piled up voices and the engine went staticy after
	// a few bars. \steal is the 20 ms fade-and-free that works for BOTH env
	// types, so mono re-uses it.
	stealActiveSlices {
		sliceVoices.do({ arg synth, i;
			if(synth.notNil, {
				synth.set(\steal, 1);
				sliceVoices[i] = nil;
				engine.forgetSliceVoice(synth);
			});
		});
	}
}
