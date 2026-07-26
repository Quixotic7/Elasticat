// Elasticat v2 foundation.
//
// One shared server-side transport phase drives one active mode synth at a time.
// Existing mode families are preserved under technically accurate names:
//   0 tape              former basic
//   1 tempo_varispeed   former classic
//   2 chopped
//   3 granular
//   4 random_ola        former wsola-style random overlap grains
//   5 pitch_corrected   former pv/PitchShift color
Engine_Elasticat : CroneEngine {

	var <transportSynth;
	var <activeSynth;
	var previewSynth;
	var <bufL;
	var <bufR;
	var <defaultBufL;
	var <defaultBufR;
	var <activeSliceSynths;
	var phaseBus;
	var scriptAddress;
	var statusResponder;
	var modResponder;      // live mod-bus values -> script (~15Hz UI feed)
	var transportResponder;
	var modeSynthNames;
	var modeNames;
	var readerAmpEnv;  // shared amp-envelope graph for the continuous mode readers
	var filterPrep;           // shared drive + env-modulated cutoff/res prep for filter machines
	var filterChannelClassic; // shared per-channel Classic (multimode) filter graph
	var filterChannelMorph;   // shared per-channel Morphing filter graph
	var filterBalanceCutoffs; // shared balance law: base cutoff + balance -> [fcA, fcB]
	var filterModOut;         // shared pan/amp output stage with pan/amp mod-bus input
	var fxMixBlend;           // shared dry/wet crossfade graph for insert FX machines
	var fxDriveShape;         // shared drive/clip curve for the insert FX chain
	var activeMode = 0;
	var playing = 0;
	var targetBpm = 120;
	var sampleSteps = 16;
	var loopStart = 0;
	var loopEnd = 128;
	var pitch = 0;
	var speed = 1;
	var direction = 1;
	var amp = 0.8;
	var pan = 0;
	var modeMacro = 0;
	var modeSwitchFade = 0.05;
	var loopXfade = 0.005;
	var maxCorrection = 0.02;
	var hardThreshold = 0.125;
	var correction = 0;
	var resetCount = 0;
	var loadGeneration = 0;
	var poolSize = 128;
	var poolBufL;
	var poolBufR;
	var poolPaths;
	var poolLoaded;
	var poolFrames;
	var poolRates;
	var poolGenerations;
	var sampleSlot = 1;
	var modeSwitchCount = 0;
	var failedModeSwitchCount = 0;
	var hardRealignCount = 0;
	var staleClockCount = 0;
	var lastClockSeq = -1;
	var lastPhase = 0;
	var lastExpectedPhase = 0;
	var lastPhaseError = 0;
	var lastErrorMs = 0;
	var derivedSourceBpm = 120;
	var sourceBpm = 120;
	var sourceFrames = 4;
	var sourceRate = 48000;
	var loaded = 0;
	var debugLevel = 1;
	var sliceAttack = 0.002;
	var sliceRelease = 0.02;
	// Amp envelope (Amp page). envMode 0 = ADSR, 1 = AHR. Times in seconds,
	// sustain 0..1. Stored here; the reader/slice-voice DSP wiring lands next.
	// Defaults match the AHR drone default (0 / INF / 0) so the first play drones
	// even before the script syncs the params.
	var envMode = 1;
	var envAttack = 0.0001;
	var envDecay = 0.15;
	var envSustain = 0.8;
	var envRelease = 0.0001;
	var envHold = 1000000;
	var envTrigCount = 0;      // bumped per note-on to retrigger the amp envelope
	var envNoteSeconds = 0.5;  // current note length (ADSR gate window); <= 0 means "hold until noteOff" (Task 1, PRD S8)
	var noteOffTrigCount = 0;  // bumped per noteOff to release an indefinitely-held ADSR gate (Task 1, PRD S8)
	var portamento = 0;        // 1 = overlapping trigger glides (no re-attack)
	var sliceMono = 0;
	var sliceSyncToClock = 1;
	var sliceRate = 1;
	var chopBeats = 0.25;
	var chopMode = 0;
	var chopAttack = 0.002;
	var chopHold = 0.04;
	var chopRelease = 0.01;
	var grainSize = 0.08;
	var grainOverlap = 8;
	var grainJitter = 0;
	var grainSpray = 0;
	var wsolaWindow = 0.1;
	var wsolaSearch = 0.03;
	var pvWindow = 0.2;
	var pvDispersion = 0;
	// Global filter (post-mix, pre master pan/vol). One shared instance per
	// track, sitting in filterGroup after the voice sourceGroup. Machine is a
	// setting (not p-lockable); Type/Cutoff/Res/Drive/Morph/Balance are. The
	// filter envelope is independent of the amp env (its own mode) but reuses
	// the amp env's seconds mapping on the script side.
	var fxBus;
	var sourceGroup;
	var filterGroup;
	var filterSynth;
	var filterSynthNames;
	var filterMachine = 0;
	var filterType = 0;         // 0 LP, 1 HP, 2 BP, 3 notch (classic machines)
	var filterCutoff = 20000;   // Hz (default wide open = effective bypass)
	var filterRes = 0;          // 0..1
	var filterDrive = 0;        // 0..1 pre-filter drive
	var filterMorph = 0;        // 0..1 morphing machines: 0 LP -> 0.5 notch -> 1 HP
	var filterBalance = 0;      // -1..1 stereo / mid-side balance (variant machines)
	var filterEnvMode = 1;      // independent of amp env: 0 ADSR, 1 AHR
	var filterEnvAttack = 0.0001;
	var filterEnvDecay = 0.15;
	var filterEnvSustain = 0.8;
	var filterEnvRelease = 0.0001;
	var filterEnvHold = 1000000;
	var filterEnvDepth = 0;     // -1..1, scaled to +/-6 octaves of cutoff mod
	// Insert 1 (global, post-filter). One shared instance per track, sitting in
	// insertGroup after filterGroup -- the filter now writes into insertBus
	// instead of straight to master. Machine is a setting (not p-lockable);
	// Drive/Mix/Delay*/Reverb*/Lofi* are. Index 0 is always the dry-passthrough
	// \elasticatFxNone SynthDef so the chain graph never leaves insertBus
	// unread (PRD SS4.3; Insert 1 only for now -- Insert 2/Sends/Master insert
	// are follow-ups).
	var insertBus;
	var insertGroup;
	var insertSynth;
	var fxInsertNames;
	var fxInsertMachine = 0;
	var fxDrive = 0;            // 0..1 pre-effect drive (DRIVE machine)
	var fxMix = 0.5;            // 0..1 dry/wet, shared by every wet fx machine
	var delayBeats = 1;         // beat division (quarter note = 1), tempo-synced
	var delayFeedback = 0.3;    // 0..1
	var delayTone = 1;          // 0..1 -> feedback-loop lowpass cutoff amount
	var reverbSize = 0.5;       // 0..1 -> FreeVerb2 room
	var reverbDamp = 0.5;       // 0..1 -> FreeVerb2 damp
	var lofiBits = 24;          // 1..24 bits (round-to-step quantizer)
	var lofiRate = 48000;       // Hz (Latch sample-and-hold rate)

	// --- Send buses (Send 1/2) + Master bus/insert (global; PRD SS3/SS8) -----
	// Insert 1 now writes into masterBus instead of straight to context.out_b;
	// masterGroup (after sendGroup) hosts the master insert FX synth, the only
	// thing writing context.out_b for this track. sendGroup (after
	// insertGroup, before masterGroup) hosts a tap synth (elasticatSendTap)
	// that copies either the pre-insert (post-filter, insertBus) or
	// post-insert-1 (masterBus, read there before any send return has landed
	// this block) signal into sendBus1/2 at sendLevel1/2, followed by each
	// send's own FX machine synth reading its send bus and writing back into
	// masterBus -- all ahead of masterGroup's read in node order, so the
	// master insert always sees Insert 1 + both send returns summed. Every
	// send/master FX slot reuses the same fxInsertNames machine set (None/
	// Drive/Delay/Reverb/Lofi) as Insert 1; index 0 (None) is the always-
	// present passthrough so no bus is ever left unread.
	var masterBus;
	var sendBus1;
	var sendBus2;
	var sendGroup;
	var masterGroup;
	var sendTapSynth;
	var send1Synth;
	var send2Synth;
	var masterSynth;
	var sendTap = 0;        // 0 = pre-insert (post-filter), 1 = post-insert-1
	var sendLevel1 = 0;     // 0..1 continuous send amount
	var sendLevel2 = 0;
	var send1Machine = 0;   // index into fxInsertNames
	var send2Machine = 0;
	var masterFxMachine = 0;
	// Per-slot FX params, indexed [send1, send2, master] -- mirrors the
	// Insert 1 scalars above (fxDrive/fxMix/delayBeats/.../lofiRate) but kept
	// as arrays here since there are three independent slots sharing the same
	// machine set.
	var sendFxDrive;
	var sendFxMix;
	var sendFxDelayBeats;
	var sendFxDelayFeedback;
	var sendFxDelayTone;
	var sendFxReverbSize;
	var sendFxReverbDamp;
	var sendFxLofiBits;
	var sendFxLofiRate;

	// --- Modulation: 2 LFOs + 1 mod envelope (MOD category) -----------------
	// SC-side modulation so it is smooth and never spams OSC: one control-rate
	// \elasticatMod synth computes lfo1/lfo2/menv and routes depth * value of
	// each source onto per-DESTINATION control buses (sources targeting the
	// same destination sum in-synth). Destination synths add In.kr(bus) to the
	// matching parameter:
	//   pitch  -> readers/slice voices, +/-12 semitones at full depth
	//   cutoff -> filterPrep, +/-3 octaves (36 semitones) at full depth
	//   res    -> filterPrep, +/-0.5 of the 0..1 resonance
	//   amp    -> filter output gain, amp * (1 + mod) clipped >= 0 (tremolo)
	//   pan    -> filter output pan, +/-1 added then clipped
	// Bus indices are passed as args on every respawn (commonArgs/filterArgs/
	// triggerSlice), so machine changes keep modulation wired.
	var modBusPitch;
	var modBusCutoff;
	var modBusRes;
	var modBusAmp;
	var modBusPan;
	var modSynth;
	var lfo1Dest = 0;      // 0 off, 1 pitch, 2 cutoff, 3 res, 4 amp, 5 pan
	var lfo1Wave = 0;      // 0 sine, 1 tri, 2 saw, 3 rsaw, 4 sqr, 5 rand (S&H)
	var lfo1Beats = 4;     // beats per LFO cycle (tempo-synced via targetBpm)
	var lfo1Depth = 0;     // -1..1
	var lfo1Mode = 0;      // 0 free, 1 trig, 2 one(-shot cycle), 3 hold (S&H)
	var lfo2Dest = 0;
	var lfo2Wave = 0;
	var lfo2Beats = 4;
	var lfo2Depth = 0;
	var lfo2Mode = 0;
	var menvDest = 0;
	var menvAttack = 0.01; // seconds (AD envelope for the first stab)
	var menvDecay = 0.15;
	var menvDepth = 0;     // -1..1
	var lfoTrigCount = 0;  // bumped per step where lfo_reset resolves ON
	var menvTrigCount = 0; // bumped per step where env_reset resolves ON
	// 4 macros -- each a small MOD MATRIX. A macro has a base value (0..1, the
	// knob the grid macro keys / macro page drive) and a SIGNED depth to every
	// one of the 5 destinations (pitch/cutoff/res/amp/pan). Holding a macro key
	// and turning a destination param dials that macro->param depth (Lua side).
	// The macro contributes value * depth[d] to each destination bus d, summing
	// with the direct LFO/env contributions. An LFO/mod-env can TARGET a macro
	// (dest 6..9 = macro 1..4) to modulate its value, so a macro is an extra
	// mod source whose "wave" is a (modulatable) knob feeding many destinations.
	var macroBase;         // Array[4], 0..1
	var macroMatrix;       // Array[4] of Array[5], -1..1 (depth per destination)

	// --- Phase 1 multitrack scaffolding (tracks 2-8; PHASE1_CONTRACT.md) ----
	// Track 1 stays on the instance vars above (zero regression risk); tracks
	// 2-8 each get a state Event in trackStates (indexed by track NUMBER, so
	// slots 0/1 stay unused) holding the per-track fields plus that track's
	// chain node/bus refs. Chains are allocated lazily by \activeTrackCount:
	// an inactive track owns NO synths and NO busses -- only the (tiny) state
	// Event once a command has touched it. Each active chain = its own
	// transport phasor + reader synth (same crossfade machine-swap mechanism
	// as track 1) + a small mix synth (amp/pan/mute plus the click-free fade
	// used when freeing), summing into masterBus from tracksGroup -- which
	// sits AFTER sendGroup (so tracks 2-8 never leak into track 1's send
	// taps, which read masterBus earlier in the block) and BEFORE masterGroup
	// (so they still pass through the master insert to context.out_b). No
	// per-track filter/amp-env/insert/mod in Phase 1; track 1 keeps its full
	// existing path through the global filter chain untouched.
	var trackStates;
	var activeTrackCount = 1;
	var tracksGroup;
	var trackZeroModBus;   // never-written control bus: tracks' pitchModBus reads 0
	var track1Mute = 0;    // \trMute 1 x gates the filter-stage amp for track 1

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
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

		sendFxDrive = [0, 0, 0];
		sendFxMix = [0.5, 0.5, 0.5];
		sendFxDelayBeats = [1, 1, 1];
		sendFxDelayFeedback = [0.3, 0.3, 0.3];
		sendFxDelayTone = [1, 1, 1];
		sendFxReverbSize = [0.5, 0.5, 0.5];
		sendFxReverbDamp = [0.5, 0.5, 0.5];
		sendFxLofiBits = [24, 24, 24];
		sendFxLofiRate = [48000, 48000, 48000];

		phaseBus = Bus.audio(server, 1);
		fxBus = Bus.audio(server, 2);
		insertBus = Bus.audio(server, 2);
		masterBus = Bus.audio(server, 2);
		sendBus1 = Bus.audio(server, 2);
		sendBus2 = Bus.audio(server, 2);
		// Per-destination modulation buses (control rate; see the mod var block).
		modBusPitch = Bus.control(server, 1);
		modBusCutoff = Bus.control(server, 1);
		modBusRes = Bus.control(server, 1);
		modBusAmp = Bus.control(server, 1);
		modBusPan = Bus.control(server, 1);
		macroBase = Array.fill(4, { 0 });
		macroMatrix = Array.fill(4, { Array.fill(5, { 0 }); });
		// Phase 1 multitrack: per-track state slots (lazy; see var block) and
		// the shared always-zero control bus tracks 2-8 read as pitchModBus
		// (mod routing is track-1-only in Phase 1). Neither costs any DSP.
		trackStates = Array.fill(9, { nil });
		trackZeroModBus = Bus.control(server, 1);
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
		bufL = Buffer.alloc(server, 4, 1);
		bufR = Buffer.alloc(server, 4, 1);
		defaultBufL = bufL;
		defaultBufR = bufR;
		poolBufL = Array.fill(poolSize, { nil });
		poolBufR = Array.fill(poolSize, { nil });
		poolPaths = Array.fill(poolSize, { "" });
		poolLoaded = Array.fill(poolSize, { 0 });
		poolFrames = Array.fill(poolSize, { 4 });
		poolRates = Array.fill(poolSize, { 48000 });
		poolGenerations = Array.fill(poolSize, { 0 });
		activeSliceSynths = Array.fill(32, { nil });

		this.addSynthDefs;
		server.sync;

		transportResponder = OSCFunc({
			arg msg;
			var track;
			// Phase 1 multitrack: msg[2] is SendReply's replyID, which every
			// transport synth now sets to its 1-based track index (track 1's
			// synth defaults to 1, preserving its behavior). Tracks 2-8 get a
			// cheap 1 Hz position report forwarded to the script and cached in
			// their state Event (used to re-anchor on machine swaps); ONLY
			// track 1 feeds the legacy lastPhase/correction globals.
			track = msg[2].asInteger;
			if(track > 1, {
				if(track <= 8 and: { trackStates.notNil } and: { trackStates[track].notNil }, {
					trackStates[track][\lastPhase] = msg[3].asFloat.wrap(0, 1);
				});
				scriptAddress.sendBundle(0, [
					"/elasticat/track/position",
					track,
					msg[3].asFloat
				]);
			}, {
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
		}, path: '/elasticat/transportRaw', srcID: server.addr);

		statusResponder = OSCFunc({
			arg msg;
			// Phase 1 multitrack: msg[2] (SendReply replyID) is the 1-based
			// track index; only track 1's reader feeds the legacy status
			// stream. Tracks 2-8 readers also fire statusRaw (shared
			// SynthDefs) but are dropped here -- their position report comes
			// from the cheaper 1 Hz transport responder above.
			if(msg[2].asInteger <= 1, {
				lastPhase = msg[4].asFloat;
				scriptAddress.sendBundle(0, [
					"/elasticat/status",
					loaded,
					playing,
					modeNames.wrapAt(activeMode),
					msg[3].asFloat,
					msg[4].asFloat,
					msg[5].asFloat,
					msg[6].asFloat,
					msg[7].asFloat,
					targetBpm,
					derivedSourceBpm,
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

		// Live modulation feed for the UI: forwards the five mod-bus sums so the
		// low-profile "actual value" bars and the filter render can follow LFOs /
		// mod-env / macros during playback. Fired at 15Hz by \elasticatMod.
		modResponder = OSCFunc({
			arg msg;
			scriptAddress.sendBundle(0, [
				"/elasticat/mod",
				msg[3].asFloat, msg[4].asFloat, msg[5].asFloat,
				msg[6].asFloat, msg[7].asFloat
			]);
		}, path: '/elasticat/modRaw', srcID: server.addr);

		// Voices (transport + readers + slices) live in sourceGroup and sum onto
		// fxBus; the global filter reads fxBus in filterGroup (after sourceGroup)
		// and writes into insertBus; Insert 1 reads insertBus in insertGroup
		// (after filterGroup) and writes the master out. New slice voices
		// tail-add within sourceGroup, so they always precede filter/insert in
		// the node order.
		sourceGroup = Group.head(context.xg);
		filterGroup = Group.after(sourceGroup);
		insertGroup = Group.after(filterGroup);
		sendGroup = Group.after(insertGroup);
		masterGroup = Group.after(sendGroup);
		// Phase 1 multitrack: container for track 2-8 chains. Created after
		// masterGroup so Group.after(sendGroup) inserts it BETWEEN sendGroup
		// and masterGroup: the send tap has already read masterBus (tap=post)
		// by the time these chains write into it, so tracks 2-8 reach the
		// master insert without leaking into track 1's sends. Empty (zero
		// cost) until \activeTrackCount allocates chains.
		tracksGroup = Group.after(sendGroup);

		transportSynth = Synth.new(\elasticatTransport, [
			\out, phaseBus.index,
			\playing, playing,
			\targetBpm, targetBpm,
			\loopBeats, this.activeLoopBeats,
			\correction, correction
		], sourceGroup);

		this.spawnModSynth;
		activeSynth = this.spawnMode(activeMode, 1);
		this.spawnFilter;
		this.spawnInsert;
		this.spawnSendTap;
		this.spawnSend1;
		this.spawnSend2;
		this.spawnMasterFx;
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
		filterPrep = { arg sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus;
			var driven, fenv, fc, rq, resMod;
			driven = (sig * (1 + (drive.clip(0, 1) * 12))).tanh;
			sig = XFade2.ar(sig, driven, (drive.clip(0, 1) * 2) - 1);
			fenv = readerAmpEnv.value(envMode, envAttack, envDecay, envSustain, envRelease, envHold, envTrig, envGateSeconds, 0, envReleaseTrig);
			// Depth is +/-6 octaves (72 semitones) of cutoff modulation; the mod
			// bus (LFO/mod-env CUTOFF destination, -1..1) adds up to +/-3 octaves
			// (36 semitones) on top -- both exponential, summed in semitones.
			fc = (Lag.kr(cutoff.clip(20, 20000), 0.01)
				* ((envDepth.clip(-1, 1) * fenv * 72) + (In.kr(cutoffModBus, 1).clip(-1, 1) * 36)).midiratio).clip(20, 20000);
			// RES destination: -1..1 mod adds +/-0.5 to the 0..1 resonance.
			resMod = (res.clip(0, 1) + (In.kr(resModBus, 1).clip(-1, 1) * 0.5)).clip(0, 1);
			rq = Lag.kr((1 - (resMod * 0.98)).clip(0.02, 1), 0.01);
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
		filterChannelMorph = { arg s, fc, rq, morph;
			var lp, hp, bp, notch, lowHalf, highHalf, m;
			m = Lag.kr(morph.clip(0, 1), 0.02);
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
		filterModOut = { arg sigL, sigR, pan, amp, panModBus, ampModBus;
			Balance2.ar(sigL, sigR,
				(pan + In.kr(panModBus, 1).clip(-1, 1)).clip(-1, 1),
				(amp * (1 + In.kr(ampModBus, 1).clip(-1, 1))).max(0));
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
			pvWindow=0.2, pvDispersion=0, pitchModBus=0;
			var frames, startFrame, endFrame, loFrame, hiFrame, continueMode, readLo, readHi, loopMode;
			var directionSign, resetFrame, rangeFrames, duration, pitchRatio, freePitchRatio, freeRate, fitRate, readRate;
			var pos, loopPos, sweepFrames, sweepForwardPos, sweepReversePos, sweepPos, readPhase, env, adsrEnv, ahrEnv, raw, grain, ola, pc, sig, playAmp;
			var grainDur, grainCount, grainRandom, olaTrig, olaPos, pcRatio;

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
			// Track pan + volume are applied downstream at the filter output stage;
			// the voice keeps only velocity and its per-note envelope.
			playAmp = velocity.clip(0, 1) * env;
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
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			filtered = [
				filterChannelClassic.value(sig[0], fc, rq, filterType),
				filterChannelClassic.value(sig[1], fc, rq, filterType)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing: one Morph knob sweeps LP -> notch -> HP (p-lockable Morph).
		SynthDef(\elasticatFilterMorph, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			filtered = [
				filterChannelMorph.value(sig[0], fc, rq, morph),
				filterChannelMorph.value(sig[1], fc, rq, morph)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
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
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, fcL, fcR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			# fcL, fcR = filterBalanceCutoffs.value(fc, balance);
			filtered = [
				filterChannelClassic.value(sig[0], fcL, rq, filterType),
				filterChannelClassic.value(sig[1], fcR, rq, filterType)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing Stereo (#4): same balance law as Classic Stereo, applied to two
		// independent Morphing filter instances.
		SynthDef(\elasticatFilterMorphStereo, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, fcL, fcR, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			# fcL, fcR = filterBalanceCutoffs.value(fc, balance);
			filtered = [
				filterChannelMorph.value(sig[0], fcL, rq, morph),
				filterChannelMorph.value(sig[1], fcR, rq, morph)
			];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
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
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, fcM, fcS, mid, side, filteredMid, filteredSide, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			mid = (sig[0] + sig[1]) * 0.5;
			side = (sig[0] - sig[1]) * 0.5;
			# fcM, fcS = filterBalanceCutoffs.value(fc, balance);
			filteredMid = filterChannelClassic.value(mid, fcM, rq, filterType);
			filteredSide = filterChannelClassic.value(side, fcS, rq, filterType);
			filtered = [filteredMid + filteredSide, filteredMid - filteredSide];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
			Out.ar(out, LeakDC.ar(filtered));
		}).add;

		// Morphing Mid/Side (#6): same M/S decode/encode and balance law as
		// Classic Mid/Side, applied to two independent Morphing filter instances.
		SynthDef(\elasticatFilterMorphMS, {
			arg out=0, in=0, amp=0.8, pan=0,
			filterType=0, cutoff=20000, res=0, drive=0, morph=0, balance=0,
			envMode=1, envAttack=0.0001, envDecay=0.15, envSustain=0.8, envRelease=0.0001, envHold=1000000,
			envDepth=0, envTrig=0, envGateSeconds=0.5, envReleaseTrig=0,
			cutoffModBus=0, resModBus=0, ampModBus=0, panModBus=0;
			var sig, fc, rq, fcM, fcS, mid, side, filteredMid, filteredSide, filtered;
			sig = In.ar(in, 2);
			# sig, fc, rq = filterPrep.value(sig, drive, cutoff, res, envMode, envAttack, envDecay, envSustain, envRelease, envHold, envDepth, envTrig, envGateSeconds, envReleaseTrig, cutoffModBus, resModBus);
			mid = (sig[0] + sig[1]) * 0.5;
			side = (sig[0] - sig[1]) * 0.5;
			# fcM, fcS = filterBalanceCutoffs.value(fc, balance);
			filteredMid = filterChannelMorph.value(mid, fcM, rq, morph);
			filteredSide = filterChannelMorph.value(side, fcS, rq, morph);
			filtered = [filteredMid + filteredSide, filteredMid - filteredSide];
			filtered = filterModOut.value(filtered[0], filtered[1], pan.clip(-1, 1), amp, panModBus, ampModBus);
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
			menvDest=0, menvAttack=0.01, menvDecay=0.15, menvDepth=0, menvTrig=0,
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
			// Mod envelope: one-shot AD burst (0..1), retriggered per note where the
			// step's env_reset resolves ON (the amp env's counter idiom).
			menv = EnvGen.kr(
				Env([0, 1, 0], [menvAttack.max(0.0001), menvDecay.max(0.0001)], [-4, -4]),
				Changed.kr(menvTrig)) * menvDepth.clip(-1, 1);

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
			SendReply.kr(Impulse.kr(15), '/elasticat/modRaw',
				[pitchSum, cutoffSum, resSum, ampSum, panSum]);
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

	installCommands {
		this.addCommand(\loadSample, "s", { arg msg; this.loadSample(msg[1]); });
		this.addCommand(\loadPoolSlot, "is", { arg msg; this.loadPoolSlot(msg[1], msg[2]); });
		this.addCommand(\clearPoolSlot, "i", { arg msg; this.clearPoolSlot(msg[1]); });
		this.addCommand(\setSampleSlot, "i", { arg msg; this.setSampleSlot(msg[1]); });
		this.addCommand(\sampleSlot, "i", { arg msg; this.setSampleSlot(msg[1]); });
		this.addCommand(\previewSlot, "iffff", { arg msg; this.previewSlot(msg[1], msg[2], msg[3], msg[4], msg[5]); });
		this.addCommand(\play, "i", { arg msg; this.play(msg[1]); });
		this.addCommand(\pause, "", { this.play(0); });
		this.addCommand(\stopAndReset, "", { this.stopAndReset; });
		this.addCommand(\stop, "", { this.stopAndReset; });
		this.addCommand(\reset, "", { this.setPlayhead(0); });
		this.addCommand(\setMode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\mode, "i", { arg msg; this.setMode(msg[1]); });
		this.addCommand(\setModeProfile, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/profile", msg[1].asInteger]);
		});
		this.addCommand(\setModeMacro, "f", { arg msg; modeMacro = msg[1].clip(0, 1); this.setActive(\macro, modeMacro); });
		this.addCommand(\setModeParam, "sf", { arg msg; this.setActive(msg[1].asSymbol, msg[2]); });
		this.addCommand(\setModeSwitchFade, "f", { arg msg; modeSwitchFade = msg[1].clip(0.001, 0.25); });
		this.addCommand(\setModeSwitchQuantization, "i", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/switchQuantization", msg[1].asInteger]);
		});
		this.addCommand(\setSampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\sampleSteps, "f", { arg msg; this.setSampleSteps(msg[1]); });
		this.addCommand(\setLoopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\loopBeats, "f", { arg msg; this.setSampleSteps(msg[1] * 4); });
		this.addCommand(\setLoopPreview, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/loopPreview", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\commitLoop, "ff", { arg msg;
			scriptAddress.sendBundle(0, ["/elasticat/commitLoopPending", msg[1].clip(0, 1), msg[2].clip(0, 1)]);
		});
		this.addCommand(\setPitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\pitch, "f", { arg msg; pitch = msg[1].clip(-24, 24); this.setActive(\pitch, pitch); });
		this.addCommand(\setSpeed, "f", { arg msg; speed = msg[1].clip(0.03125, 8); this.setActive(\speed, speed); });
		this.addCommand(\setReverse, "i", { arg msg; this.setReverse(msg[1]); });
		this.addCommand(\setDirection, "f", { arg msg;
			if(msg[1] < 0, { direction = -1; }, { direction = 1; });
			this.setActive(\direction, direction);
		});
		// Track volume + pan now live at the end of the chain, on the filter
		// output stage, so they mix the whole (filtered) track rather than each voice.
		// applyTrack1Amp == setFilter(\amp, amp) while track1Mute is 0 (the
		// default and the only pre-Phase-1 state); it just keeps a \trMute'd
		// track 1 muted through amp edits.
		this.addCommand(\setAmp, "f", { arg msg; amp = msg[1].max(0); this.applyTrack1Amp; });
		this.addCommand(\amp, "f", { arg msg; amp = msg[1].max(0); this.applyTrack1Amp; });
		this.addCommand(\setPan, "f", { arg msg; pan = msg[1].clip(-1, 1); this.setFilter(\pan, pan); });
		this.addCommand(\pan, "f", { arg msg; pan = msg[1].clip(-1, 1); this.setFilter(\pan, pan); });
		this.addCommand(\syncClock, "ffi", { arg msg; this.syncClock(msg[1], msg[2], msg[3]); });
		this.addCommand(\setPlayhead, "f", { arg msg; this.setPlayhead(msg[1]); });
		this.addCommand(\playhead, "f", { arg msg; this.setPlayhead(msg[1]); });
		this.addCommand(\requestStatus, "", { this.sendStatus; });
		this.addCommand(\setDebug, "i", { arg msg; debugLevel = msg[1].asInteger.clip(0, 3); });

		this.addCommand(\sourceBpm, "f", { arg msg; this.setSourceBpm(msg[1]); });
		this.addCommand(\targetBpm, "f", { arg msg; targetBpm = msg[1].max(1); this.updateTransport; this.setActive(\targetBpm, targetBpm); });
		this.addCommand(\loopStart, "f", { arg msg; this.setLoopStart(msg[1]); });
		this.addCommand(\loopEnd, "f", { arg msg; this.setLoopEnd(msg[1]); });
		this.addCommand(\loopRegionPlayhead, "fff", { arg msg; this.setLoopRegionPlayhead(msg[1], msg[2], msg[3]); });
		this.addCommand(\xfade, "f", { arg msg; loopXfade = msg[1].clip(0, 0.25); });
		this.addCommand(\chopSteps, "f", { arg msg; chopBeats = msg[1].max(0.03125) / 4; this.setActive(\chopBeats, chopBeats); });
		this.addCommand(\chopBeats, "f", { arg msg; chopBeats = msg[1].max(0.03125); this.setActive(\chopBeats, chopBeats); });
		this.addCommand(\chopLoopMode, "i", { arg msg; chopMode = msg[1].asInteger.clip(0, 2); this.setActive(\chopMode, chopMode); });
		this.addCommand(\chopAttack, "f", { arg msg; chopAttack = msg[1].max(0.0001); this.setActive(\chopAttack, chopAttack); });
		this.addCommand(\chopHold, "f", { arg msg; chopHold = msg[1].max(0); this.setActive(\chopHold, chopHold); });
		this.addCommand(\chopRelease, "f", { arg msg; chopRelease = msg[1].max(0.0001); this.setActive(\chopRelease, chopRelease); });
		this.addCommand(\grainSize, "f", { arg msg; grainSize = msg[1].clip(0.002, 0.5); this.setActive(\grainSize, grainSize); });
		this.addCommand(\grainDensity, "f", { arg msg; grainOverlap = msg[1].clip(1, 64); this.setActive(\grainOverlap, grainOverlap); });
		this.addCommand(\grainJitter, "f", { arg msg; grainJitter = msg[1].clip(0, 0.25); grainSpray = grainJitter; this.setActive(\grainJitter, grainJitter); this.setActive(\grainSpray, grainSpray); });
		this.addCommand(\wsolaWindow, "f", { arg msg; wsolaWindow = msg[1].clip(0.005, 0.5); this.setActive(\grainSize, wsolaWindow); });
		this.addCommand(\wsolaSearch, "f", { arg msg; wsolaSearch = msg[1].clip(0, 0.1); this.setActive(\wander, wsolaSearch); });
		this.addCommand(\pvWindow, "f", { arg msg; pvWindow = msg[1].clip(0.005, 2); this.setActive(\pvWindow, pvWindow); });
		this.addCommand(\pvDispersion, "f", { arg msg; pvDispersion = msg[1].clip(0, 1); this.setActive(\pvDispersion, pvDispersion); });
		this.addCommand(\triggerSlice, "iffiifff", { arg msg; this.triggerSlice(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8]); });
		this.addCommand(\releaseSlice, "i", { arg msg; this.releaseSlice(msg[1]); });
		this.addCommand(\releaseAllSlices, "", { this.releaseAllSlices; });
		this.addCommand(\sliceAttack, "f", { arg msg; sliceAttack = msg[1].clip(0.0001, 0.2); });
		this.addCommand(\sliceRelease, "f", { arg msg; sliceRelease = msg[1].clip(0.0001, 0.5); });
		this.addCommand(\setEnvMode, "i", { arg msg; envMode = msg[1].clip(0, 1); this.setActive(\envMode, envMode); });
		this.addCommand(\envAttack, "f", { arg msg; envAttack = msg[1].max(0); this.setActive(\envAttack, envAttack); });
		this.addCommand(\envDecay, "f", { arg msg; envDecay = msg[1].max(0); this.setActive(\envDecay, envDecay); });
		this.addCommand(\envSustain, "f", { arg msg; envSustain = msg[1].clip(0, 1); this.setActive(\envSustain, envSustain); });
		this.addCommand(\envRelease, "f", { arg msg; envRelease = msg[1].max(0); this.setActive(\envRelease, envRelease); });
		this.addCommand(\envHold, "f", { arg msg; envHold = msg[1].max(0); this.setActive(\envHold, envHold); });
		this.addCommand(\setPortamento, "i", { arg msg; portamento = msg[1].clip(0, 1); this.setActive(\portamento, portamento); });
		// Note-on: retrigger the amp envelope on the active reader. Sets the ADSR
		// gate window (note length) then bumps the trigger counter.
		// Task 1 (PRD S8): seconds <= 0 is the "indefinite hold" sentinel -- a
		// live-held note (grid key held, unknown duration) can send this instead
		// of a fixed length; the ADSR gate then stays open until an explicit
		// noteOff arrives (see readerAmpEnv's holdIndefinite branch) instead of
		// auto-closing after a timed window. Any seconds > 0 (every existing
		// call site) is untouched: msg[1].max(0.005) is byte-identical to before.
		this.addCommand(\noteOn, "f", { arg msg;
			if(msg[1] > 0, {
				envNoteSeconds = msg[1].max(0.005);
			}, {
				envNoteSeconds = -1;  // sentinel consumed by readerAmpEnv's holdIndefinite check
			});
			envTrigCount = envTrigCount + 1;
			if(activeSynth.notNil, {
				activeSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
			});
			// The global filter env shares the trigger counter, so it retriggers on
			// the same note-ons as the amp env (one shared env across slice voices).
			if(filterSynth.notNil, {
				filterSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
			});
		});
		// Note-off (Task 1, PRD S8): closes an indefinitely-held note's ADSR gate
		// now, so its amp envelope (and the filter envelope, which shares the same
		// gate) enters its release stage on command instead of on a timer. Bumps a
		// separate counter (envReleaseTrig) rather than reusing envTrig, so a
		// noteOff can't be mistaken for a new note-on retrigger. Harmless no-op on
		// a synth that's already closed/finite -- SetResetFF's reset edge just has
		// no open gate left to close.
		this.addCommand(\noteOff, "", {
			noteOffTrigCount = noteOffTrigCount + 1;
			if(activeSynth.notNil, {
				activeSynth.set(\envReleaseTrig, noteOffTrigCount);
			});
			if(filterSynth.notNil, {
				filterSynth.set(\envReleaseTrig, noteOffTrigCount);
			});
		});
		// Force a fresh amp/filter re-attack, for auditioning a stopped step
		// preview (grid loop/pitch-key edits while holding a step). Unlike a
		// plain noteOn, this ALWAYS re-attacks -- even under portamento, whose
		// held-gate legato deliberately swallows a note-on on a still-sounding
		// note (readerAmpEnv's port branch). A preview is monitoring, not
		// legato, so it must be heard. With portamento off a plain note-on
		// already re-attacks, so we just do that (no release blip). With
		// portamento on we mimic a manual re-press: close the gate now, reopen
		// it one block later via SystemClock.sched -- separated so SetResetFF
		// sees reset THEN set (same-block would be reset-wins -> stuck closed).
		this.addCommand(\retrigNote, "f", { arg msg;
			var seconds = msg[1];
			var applyNoteOn;
			applyNoteOn = {
				if(seconds > 0, { envNoteSeconds = seconds.max(0.005) }, { envNoteSeconds = -1 });
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
				if(activeSynth.notNil, { activeSynth.set(\envReleaseTrig, noteOffTrigCount) });
				if(filterSynth.notNil, { filterSynth.set(\envReleaseTrig, noteOffTrigCount) });
				SystemClock.sched(0.008, { applyNoteOn.value; nil });
			}, {
				applyNoteOn.value;
			});
		});
		this.addCommand(\setSliceMono, "i", { arg msg; sliceMono = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceSyncToClock, "i", { arg msg; sliceSyncToClock = msg[1].asInteger.clip(0, 1); });
		this.addCommand(\setSliceRate, "f", { arg msg; sliceRate = msg[1].clip(0.03125, 16); });

		// --- Filter -----------------------------------------------------------
		// Machine is a setting (respawns the filter synth); everything else is a
		// live/p-lockable set on the running filter synth.
		this.addCommand(\setFilterMachine, "i", { arg msg; this.setFilterMachine(msg[1]); });
		this.addCommand(\filterType, "i", { arg msg; filterType = msg[1].asInteger.clip(0, 3); this.setFilter(\filterType, filterType); });
		this.addCommand(\filterCutoff, "f", { arg msg; filterCutoff = msg[1].clip(20, 20000); this.setFilter(\cutoff, filterCutoff); });
		this.addCommand(\filterRes, "f", { arg msg; filterRes = msg[1].clip(0, 1); this.setFilter(\res, filterRes); });
		this.addCommand(\filterDrive, "f", { arg msg; filterDrive = msg[1].clip(0, 1); this.setFilter(\drive, filterDrive); });
		this.addCommand(\filterMorph, "f", { arg msg; filterMorph = msg[1].clip(0, 1); this.setFilter(\morph, filterMorph); });
		this.addCommand(\filterBalance, "f", { arg msg; filterBalance = msg[1].clip(-1, 1); this.setFilter(\balance, filterBalance); });
		this.addCommand(\filterEnvMode, "i", { arg msg; filterEnvMode = msg[1].asInteger.clip(0, 1); this.setFilter(\envMode, filterEnvMode); });
		this.addCommand(\filterEnvAttack, "f", { arg msg; filterEnvAttack = msg[1].max(0); this.setFilter(\envAttack, filterEnvAttack); });
		this.addCommand(\filterEnvDecay, "f", { arg msg; filterEnvDecay = msg[1].max(0); this.setFilter(\envDecay, filterEnvDecay); });
		this.addCommand(\filterEnvSustain, "f", { arg msg; filterEnvSustain = msg[1].clip(0, 1); this.setFilter(\envSustain, filterEnvSustain); });
		this.addCommand(\filterEnvRelease, "f", { arg msg; filterEnvRelease = msg[1].max(0); this.setFilter(\envRelease, filterEnvRelease); });
		this.addCommand(\filterEnvHold, "f", { arg msg; filterEnvHold = msg[1].max(0); this.setFilter(\envHold, filterEnvHold); });
		this.addCommand(\filterEnvDepth, "f", { arg msg; filterEnvDepth = msg[1].clip(-1, 1); this.setFilter(\envDepth, filterEnvDepth); });

		// --- Insert 1 FX --------------------------------------------------------
		// Machine is a setting (respawns the insert synth); everything else is a
		// live/p-lockable set on the running insert synth. Mirrors Filter above.
		this.addCommand(\setInsertMachine, "i", { arg msg; this.setInsertMachine(msg[1]); });
		this.addCommand(\fxDrive, "f", { arg msg; fxDrive = msg[1].clip(0, 1); this.setInsert(\drive, fxDrive); });
		this.addCommand(\fxMix, "f", { arg msg; fxMix = msg[1].clip(0, 1); this.setInsert(\mix, fxMix); });
		this.addCommand(\delayTime, "f", { arg msg; delayBeats = msg[1].clip(0.03125, 8); this.setInsert(\delayBeats, delayBeats); });
		this.addCommand(\delayFeedback, "f", { arg msg; delayFeedback = msg[1].clip(0, 1); this.setInsert(\delayFeedback, delayFeedback); });
		this.addCommand(\delayTone, "f", { arg msg; delayTone = msg[1].clip(0, 1); this.setInsert(\delayTone, delayTone); });
		this.addCommand(\reverbSize, "f", { arg msg; reverbSize = msg[1].clip(0, 1); this.setInsert(\reverbSize, reverbSize); });
		this.addCommand(\reverbDamp, "f", { arg msg; reverbDamp = msg[1].clip(0, 1); this.setInsert(\reverbDamp, reverbDamp); });
		this.addCommand(\lofiBits, "f", { arg msg; lofiBits = msg[1].clip(1, 24); this.setInsert(\lofiBits, lofiBits); });
		this.addCommand(\lofiRate, "f", { arg msg; lofiRate = msg[1].clip(500, 48000); this.setInsert(\lofiRate, lofiRate); });

		// --- Send 1/2 + Master insert FX (PRD SS3/SS8) --------------------------
		// Machine selects are settings (respawn); tap/level are live/p-lockable
		// sets on the tap synth; per-slot Drive/Mix/Delay*/Reverb*/Lofi* are
		// live/p-lockable sets on that slot's running FX synth. Mirrors Insert 1
		// above, x3 (Send 1, Send 2, Master).
		this.addCommand(\setSendTap, "i", { arg msg; this.setSendTap(msg[1]); });
		this.addCommand(\sendLevel1, "f", { arg msg; this.setSendLevel1(msg[1]); });
		this.addCommand(\sendLevel2, "f", { arg msg; this.setSendLevel2(msg[1]); });

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

		// --- Modulation: 2 LFOs + mod envelope (MOD category) -------------------
		// Everything is a live set on the one running \elasticatMod synth (no
		// respawns). Dest/wave/mode are 0-based selector ints; speed arrives as
		// beats-per-cycle (the script maps its musical-division option); depth is
		// -1..1; menv attack/decay are seconds (script maps its 0-127 knobs via
		// the shared env seconds curve). modTrig bumps the retrigger counters:
		// arg 1 != 0 retrigs both LFOs (their non-FREE modes), arg 2 != 0 retrigs
		// the mod envelope -- fired from Lua per step where lfo_reset/env_reset
		// resolve ON.
		// Dest 0..5 = off/pitch/cutoff/res/amp/pan; 6..9 = macro 1..4 (an LFO or
		// the mod env can modulate a macro's value).
		this.addCommand(\lfo1Dest, "i", { arg msg; lfo1Dest = msg[1].asInteger.clip(0, 9); this.setMod(\lfo1Dest, lfo1Dest); });
		this.addCommand(\lfo1Wave, "i", { arg msg; lfo1Wave = msg[1].asInteger.clip(0, 5); this.setMod(\lfo1Wave, lfo1Wave); });
		this.addCommand(\lfo1Speed, "f", { arg msg; lfo1Beats = msg[1].clip(0.0625, 128); this.setMod(\lfo1Beats, lfo1Beats); });
		this.addCommand(\lfo1Depth, "f", { arg msg; lfo1Depth = msg[1].clip(-1, 1); this.setMod(\lfo1Depth, lfo1Depth); });
		this.addCommand(\lfo1Mode, "i", { arg msg; lfo1Mode = msg[1].asInteger.clip(0, 3); this.setMod(\lfo1Mode, lfo1Mode); });
		this.addCommand(\lfo2Dest, "i", { arg msg; lfo2Dest = msg[1].asInteger.clip(0, 9); this.setMod(\lfo2Dest, lfo2Dest); });
		this.addCommand(\lfo2Wave, "i", { arg msg; lfo2Wave = msg[1].asInteger.clip(0, 5); this.setMod(\lfo2Wave, lfo2Wave); });
		this.addCommand(\lfo2Speed, "f", { arg msg; lfo2Beats = msg[1].clip(0.0625, 128); this.setMod(\lfo2Beats, lfo2Beats); });
		this.addCommand(\lfo2Depth, "f", { arg msg; lfo2Depth = msg[1].clip(-1, 1); this.setMod(\lfo2Depth, lfo2Depth); });
		this.addCommand(\lfo2Mode, "i", { arg msg; lfo2Mode = msg[1].asInteger.clip(0, 3); this.setMod(\lfo2Mode, lfo2Mode); });
		this.addCommand(\menvDest, "i", { arg msg; menvDest = msg[1].asInteger.clip(0, 9); this.setMod(\menvDest, menvDest); });
		this.addCommand(\menvAttack, "f", { arg msg; menvAttack = msg[1].max(0.0001); this.setMod(\menvAttack, menvAttack); });
		this.addCommand(\menvDecay, "f", { arg msg; menvDecay = msg[1].max(0.0001); this.setMod(\menvDecay, menvDecay); });
		this.addCommand(\menvDepth, "f", { arg msg; menvDepth = msg[1].clip(-1, 1); this.setMod(\menvDepth, menvDepth); });
		// Macros (indexed 1..4) as a mod matrix: base 0..1 (the knob), and a
		// signed depth per destination (dest 1..5 = pitch/cutoff/res/amp/pan).
		this.addCommand(\macroBase, "if", { arg msg; var i = msg[1].asInteger.clip(1, 4);
			macroBase[i - 1] = msg[2].clip(0, 1); this.setMod(("macro" ++ i ++ "Base").asSymbol, macroBase[i - 1]); });
		this.addCommand(\macroDepth, "iif", { arg msg; this.setMacroDepth(msg[1], msg[2], msg[3]); });
		this.addCommand(\modTrig, "ii", { arg msg;
			if(modSynth.notNil, {
				if(msg[1].asInteger != 0, {
					lfoTrigCount = lfoTrigCount + 1;
					modSynth.set(\lfoTrig1, lfoTrigCount, \lfoTrig2, lfoTrigCount);
				});
				if(msg[2].asInteger != 0, {
					menvTrigCount = menvTrigCount + 1;
					modSynth.set(\menvTrig, menvTrigCount);
				});
			});
		});

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

		// --- Phase 1 multitrack: tr*-prefixed commands ---------------------------
		// Every command takes a LEADING 1-based track index. Index 1 routes to
		// the legacy track-1 path (so \trLoopStart 1 x == \loopStart x,
		// byte-for-byte); 2-8 route to the per-track methods above. Track-1
		// branches replicate the matching legacy handler bodies verbatim.
		this.addCommand(\activeTrackCount, "i", { arg msg; this.setActiveTrackCount(msg[1]); });
		this.addCommand(\trPlay, "ii", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.play(msg[2]); }, { this.setTrackPlay(t, msg[2]); }); });
		this.addCommand(\trPlayhead, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setPlayhead(msg[2]); }, { this.setTrackPlayhead(t, msg[2]); }); });
		this.addCommand(\trLoopStart, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setLoopStart(msg[2]); }, { this.setTrackLoopStart(t, msg[2]); }); });
		this.addCommand(\trLoopEnd, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setLoopEnd(msg[2]); }, { this.setTrackLoopEnd(t, msg[2]); }); });
		this.addCommand(\trLoopRegionPlayhead, "ifff", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				this.setLoopRegionPlayhead(msg[2], msg[3], msg[4]);
			}, {
				this.setTrackLoopRegionPlayhead(t, msg[2], msg[3], msg[4]);
			}); });
		this.addCommand(\trPitch, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				pitch = msg[2].clip(-24, 24); this.setActive(\pitch, pitch);
			}, {
				var st; st = this.trackState(t);
				if(st.notNil, { st[\pitch] = msg[2].clip(-24, 24); this.setTrackReader(t, \pitch, st[\pitch]); });
			}); });
		this.addCommand(\trSpeed, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				speed = msg[2].clip(0.03125, 8); this.setActive(\speed, speed);
			}, {
				var st; st = this.trackState(t);
				if(st.notNil, { st[\speed] = msg[2].clip(0.03125, 8); this.setTrackReader(t, \speed, st[\speed]); });
			}); });
		this.addCommand(\trReverse, "ii", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				this.setReverse(msg[2]);
			}, {
				var st; st = this.trackState(t);
				if(st.notNil, {
					st[\direction] = if(msg[2].asInteger == 1, { -1 }, { 1 });
					this.setTrackReader(t, \direction, st[\direction]);
				});
			}); });
		this.addCommand(\trSetMachine, "ii", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setMode(msg[2]); }, { this.setTrackMachine(t, msg[2]); }); });
		this.addCommand(\trModeMacro, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				modeMacro = msg[2].clip(0, 1); this.setActive(\macro, modeMacro);
			}, {
				var st; st = this.trackState(t);
				if(st.notNil, { st[\macro] = msg[2].clip(0, 1); this.setTrackReader(t, \macro, st[\macro]); });
			}); });
		// Generic warp-param set (mirror of \setModeParam). Live-set only for
		// tracks 2-8, same as track 1: neither survives a machine respawn --
		// the script re-sends warp params after a machine change today.
		this.addCommand(\trModeParam, "isf", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				this.setActive(msg[2].asSymbol, msg[3]);
			}, {
				this.setTrackReader(t, msg[2].asSymbol, msg[3]);
			}); });
		this.addCommand(\trSampleSteps, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setSampleSteps(msg[2]); }, { this.setTrackSampleSteps(t, msg[2]); }); });
		this.addCommand(\trSourceBpm, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setSourceBpm(msg[2]); }, { this.setTrackSourceBpm(t, msg[2]); }); });
		this.addCommand(\trSampleSlot, "ii", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, { this.setSampleSlot(msg[2]); }, { this.setTrackSampleSlot(t, msg[2]); }); });
		// The pool is shared, so loading is track-agnostic: this is exactly
		// \loadPoolSlot with a leading index. Tracks watching the slot are
		// repointed by installPoolBuffers once the async load lands.
		this.addCommand(\trLoadPoolSlot, "iis", { arg msg; this.loadPoolSlot(msg[2], msg[3]); });
		this.addCommand(\trAmp, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				amp = msg[2].max(0); this.applyTrack1Amp;
			}, {
				this.setTrackAmp(t, msg[2]);
			}); });
		this.addCommand(\trPan, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				pan = msg[2].clip(-1, 1); this.setFilter(\pan, pan);
			}, {
				this.setTrackPan(t, msg[2]);
			}); });
		this.addCommand(\trMute, "ii", { arg msg; this.setTrackMute(msg[1], msg[2]); });
		this.addCommand(\trNoteOn, "if", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				// Replicates \noteOn (incl. the shared filter-env retrigger).
				if(msg[2] > 0, { envNoteSeconds = msg[2].max(0.005); }, { envNoteSeconds = -1; });
				envTrigCount = envTrigCount + 1;
				if(activeSynth.notNil, {
					activeSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
				});
				if(filterSynth.notNil, {
					filterSynth.set(\envGateSeconds, envNoteSeconds, \envTrig, envTrigCount);
				});
			}, {
				this.trackNoteOn(t, msg[2]);
			}); });
		this.addCommand(\trNoteOff, "i", { arg msg; var t; t = msg[1].asInteger;
			if(t == 1, {
				noteOffTrigCount = noteOffTrigCount + 1;
				if(activeSynth.notNil, { activeSynth.set(\envReleaseTrig, noteOffTrigCount); });
				if(filterSynth.notNil, { filterSynth.set(\envReleaseTrig, noteOffTrigCount); });
			}, {
				this.trackNoteOff(t);
			}); });
		// Named warp params, mirroring the legacy handlers (same clipping and
		// the same \grainSize/\wander aliasing for the wsola knobs).
		this.addCommand(\trChopBeats, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].max(0.03125);
			if(t == 1, { chopBeats = v; this.setActive(\chopBeats, chopBeats); }, { this.setTrackReader(t, \chopBeats, v); }); });
		// Per-track mirror of the legacy \chopSteps (steps -> beats, /4) so the
		// Lua warp param's mechanical tr-name resolution lands (Phase 1 seam).
		this.addCommand(\trChopSteps, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].max(0.03125) / 4;
			if(t == 1, { chopBeats = v; this.setActive(\chopBeats, chopBeats); }, { this.setTrackReader(t, \chopBeats, v); }); });
		this.addCommand(\trChopLoopMode, "ii", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].asInteger.clip(0, 2);
			if(t == 1, { chopMode = v; this.setActive(\chopMode, chopMode); }, { this.setTrackReader(t, \chopMode, v); }); });
		this.addCommand(\trChopAttack, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].max(0.0001);
			if(t == 1, { chopAttack = v; this.setActive(\chopAttack, chopAttack); }, { this.setTrackReader(t, \chopAttack, v); }); });
		this.addCommand(\trChopHold, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].max(0);
			if(t == 1, { chopHold = v; this.setActive(\chopHold, chopHold); }, { this.setTrackReader(t, \chopHold, v); }); });
		this.addCommand(\trChopRelease, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].max(0.0001);
			if(t == 1, { chopRelease = v; this.setActive(\chopRelease, chopRelease); }, { this.setTrackReader(t, \chopRelease, v); }); });
		this.addCommand(\trGrainSize, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0.002, 0.5);
			if(t == 1, { grainSize = v; this.setActive(\grainSize, grainSize); }, { this.setTrackReader(t, \grainSize, v); }); });
		this.addCommand(\trGrainDensity, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(1, 64);
			if(t == 1, { grainOverlap = v; this.setActive(\grainOverlap, grainOverlap); }, { this.setTrackReader(t, \grainOverlap, v); }); });
		this.addCommand(\trGrainJitter, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0, 0.25);
			if(t == 1, {
				grainJitter = v; grainSpray = grainJitter;
				this.setActive(\grainJitter, grainJitter); this.setActive(\grainSpray, grainSpray);
			}, {
				this.setTrackReader(t, \grainJitter, v); this.setTrackReader(t, \grainSpray, v);
			}); });
		this.addCommand(\trWsolaWindow, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0.005, 0.5);
			if(t == 1, { wsolaWindow = v; this.setActive(\grainSize, wsolaWindow); }, { this.setTrackReader(t, \grainSize, v); }); });
		this.addCommand(\trWsolaSearch, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0, 0.1);
			if(t == 1, { wsolaSearch = v; this.setActive(\wander, wsolaSearch); }, { this.setTrackReader(t, \wander, v); }); });
		this.addCommand(\trPvWindow, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0.005, 2);
			if(t == 1, { pvWindow = v; this.setActive(\pvWindow, pvWindow); }, { this.setTrackReader(t, \pvWindow, v); }); });
		this.addCommand(\trPvDispersion, "if", { arg msg; var t, v; t = msg[1].asInteger; v = msg[2].clip(0, 1);
			if(t == 1, { pvDispersion = v; this.setActive(\pvDispersion, pvDispersion); }, { this.setTrackReader(t, \pvDispersion, v); }); });
	}

	spawnMode { arg modeIndex, startAmp;
		var synth;
		if(transportSynth.notNil, {
			synth = Synth.after(transportSynth, modeSynthNames.wrapAt(modeIndex.asInteger), this.commonArgs(startAmp));
		}, {
			synth = Synth.tail(sourceGroup, modeSynthNames.wrapAt(modeIndex.asInteger), this.commonArgs(startAmp));
		});
		^synth;
	}

	commonArgs { arg startAmp;
		^[
			\out, fxBus.index,
			\phaseBus, phaseBus.index,
			\bufL, bufL.bufnum,
			\bufR, bufR.bufnum,
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
			\targetBpm, targetBpm,
			\derivedSourceBpm, derivedSourceBpm,
			\loopBeats, this.activeLoopBeats,
			\startPoint, loopStart,
			\endPoint, loopEnd,
			\macro, modeMacro,
			\envMode, envMode,
			\envAttack, envAttack,
			\envDecay, envDecay,
			\envSustain, envSustain,
			\envRelease, envRelease,
			\envHold, envHold,
			\envTrig, envTrigCount,
			\envGateSeconds, envNoteSeconds,
			\envReleaseTrig, noteOffTrigCount,  // Task 1 (PRD S8): engine noteOff
			\portamento, portamento,
			\pitchModBus, modBusPitch.index
		];
	}

	setActive { arg key, value;
		if(activeSynth.notNil, {
			activeSynth.set(key, value);
		});
	}

	setFilter { arg key, value;
		if(filterSynth.notNil, {
			filterSynth.set(key, value);
		});
	}

	setMod { arg key, value;
		if(modSynth.notNil, {
			modSynth.set(key, value);
		});
	}

	modSynthArgs {
		^[
			\pitchOut, modBusPitch.index,
			\cutoffOut, modBusCutoff.index,
			\resOut, modBusRes.index,
			\ampOut, modBusAmp.index,
			\panOut, modBusPan.index,
			\targetBpm, targetBpm,
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
			\menvDepth, menvDepth,
			\menvTrig, menvTrigCount
		] ++ this.macroSynthArgs;
	}

	// Flatten the 4 macros' base + 5-slot matrix into synth arg pairs
	// (macro{k}Base, macro{k}PitchDepth, ...CutoffDepth, ...ResDepth,
	// ...AmpDepth, ...PanDepth). Destination order matches macroMatrix indices.
	macroSynthArgs {
		var names = ["Pitch", "Cutoff", "Res", "Amp", "Pan"];
		var out = [];
		4.do { arg k;
			out = out ++ [("macro" ++ (k + 1) ++ "Base").asSymbol, macroBase[k]];
			5.do { arg d;
				out = out ++ [("macro" ++ (k + 1) ++ names[d] ++ "Depth").asSymbol, macroMatrix[k][d]];
			};
		};
		^out;
	}

	// Set one cell of a macro's matrix live: macro 1..4, dest 1..5 (pitch/
	// cutoff/res/amp/pan), signed depth. Kept as one indexed command.
	setMacroDepth { arg macroIdx, destIdx, value;
		var k = macroIdx.asInteger.clip(1, 4) - 1;
		var d = destIdx.asInteger.clip(1, 5) - 1;
		var names = ["Pitch", "Cutoff", "Res", "Amp", "Pan"];
		macroMatrix[k][d] = value.clip(-1, 1);
		this.setMod(("macro" ++ (k + 1) ++ names[d] ++ "Depth").asSymbol, macroMatrix[k][d]);
	}

	// One mod synth for the track, at the head of sourceGroup so every reader,
	// slice voice and the downstream filter read this block's fresh bus values.
	spawnModSynth {
		if(modSynth.notNil, { modSynth.free; });
		modSynth = Synth.head(sourceGroup, \elasticatMod, this.modSynthArgs);
		^modSynth;
	}

	setInsert { arg key, value;
		if(insertSynth.notNil, {
			insertSynth.set(key, value);
		});
	}

	filterArgs {
		^[
			// Insert 1 sits after the filter now: the filter writes into
			// insertBus instead of straight to master (see spawnInsert/
			// fxInsertArgs below, which reads insertBus and writes out_b).
			\out, insertBus.index,
			\in, fxBus.index,
			// Effective amp: 0 while \trMute 1 1 is engaged, else `amp` (the
			// pre-Phase-1 value) -- keeps a muted track 1 muted across filter
			// machine respawns.
			\amp, if(track1Mute == 1, { 0 }, { amp }),
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
			\envReleaseTrig, noteOffTrigCount,  // Task 1 (PRD S8): engine noteOff
			\cutoffModBus, modBusCutoff.index,
			\resModBus, modBusRes.index,
			\ampModBus, modBusAmp.index,
			\panModBus, modBusPan.index
		];
	}

	// Spawn (or respawn) the global filter at the tail of filterGroup, seeded with
	// current state so a machine change is seamless.
	spawnFilter {
		if(filterSynth.notNil, { filterSynth.free; });
		filterSynth = Synth.tail(filterGroup, filterSynthNames.wrapAt(filterMachine.asInteger), this.filterArgs);
		^filterSynth;
	}

	setFilterMachine { arg idx;
		filterMachine = idx.asInteger.clip(0, filterSynthNames.size - 1);
		this.spawnFilter;
	}

	fxInsertArgs {
		^[
			// Insert 1 now writes into masterBus, not straight to context.out_b --
			// masterGroup's master insert synth (spawnMasterFx below) is the only
			// thing writing context.out_b for this track (PRD SS3/SS8: Send 1/2 +
			// Master bus + master insert land after Insert 1, before the chain's
			// only stereo output path).
			\out, masterBus.index,
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
			\targetBpm, targetBpm
		];
	}

	// Spawn (or respawn) Insert 1 at the tail of insertGroup, seeded with current
	// state so a machine change is seamless. Mirrors spawnFilter.
	spawnInsert {
		if(insertSynth.notNil, { insertSynth.free; });
		insertSynth = Synth.tail(insertGroup, fxInsertNames.wrapAt(fxInsertMachine.asInteger), this.fxInsertArgs);
		^insertSynth;
	}

	setInsertMachine { arg idx;
		fxInsertMachine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnInsert;
	}

	// --- Send 1/2 + Master insert FX (global; PRD SS3/SS8) --------------------
	sendTapArgs {
		^[
			\preIn, insertBus.index,
			\postIn, masterBus.index,
			\tap, sendTap,
			\level1, sendLevel1,
			\level2, sendLevel2,
			\sendOut1, sendBus1.index,
			\sendOut2, sendBus2.index
		];
	}

	// Spawn (or respawn) the send tap at the head of sendGroup -- it must run
	// before send1Synth/send2Synth (below) so they read a current-block send
	// bus, not stale data from the previous block.
	spawnSendTap {
		if(sendTapSynth.notNil, { sendTapSynth.free; });
		sendTapSynth = Synth.head(sendGroup, \elasticatSendTap, this.sendTapArgs);
		^sendTapSynth;
	}

	setSendTap { arg idx;
		sendTap = idx.asInteger.clip(0, 1);
		if(sendTapSynth.notNil, { sendTapSynth.set(\tap, sendTap); });
	}

	setSendLevel1 { arg value;
		sendLevel1 = value.clip(0, 1);
		if(sendTapSynth.notNil, { sendTapSynth.set(\level1, sendLevel1); });
	}

	setSendLevel2 { arg value;
		sendLevel2 = value.clip(0, 1);
		if(sendTapSynth.notNil, { sendTapSynth.set(\level2, sendLevel2); });
	}

	// Shared arg list for any send/master FX slot -- slotIdx indexes the
	// sendFx* per-slot arrays (0 = Send 1, 1 = Send 2, 2 = Master). Mirrors
	// fxInsertArgs but reads/writes the given in/out busses instead of the
	// fixed insertBus -> masterBus path.
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

	// Send 1: reads sendBus1, writes into masterBus (adds to Insert 1's
	// already-written output; see sendGroup/masterGroup ordering above).
	spawnSend1 {
		if(send1Synth.notNil, { send1Synth.free; });
		send1Synth = Synth.tail(sendGroup, fxInsertNames.wrapAt(send1Machine.asInteger), this.sendFxArgs(0, sendBus1.index, masterBus.index));
		^send1Synth;
	}

	setSend1Machine { arg idx;
		send1Machine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnSend1;
	}

	setSend1 { arg key, value;
		if(send1Synth.notNil, { send1Synth.set(key, value); });
	}

	// Send 2: same shape as Send 1, its own bus.
	spawnSend2 {
		if(send2Synth.notNil, { send2Synth.free; });
		send2Synth = Synth.tail(sendGroup, fxInsertNames.wrapAt(send2Machine.asInteger), this.sendFxArgs(1, sendBus2.index, masterBus.index));
		^send2Synth;
	}

	setSend2Machine { arg idx;
		send2Machine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnSend2;
	}

	setSend2 { arg key, value;
		if(send2Synth.notNil, { send2Synth.set(key, value); });
	}

	// Master insert: reads masterBus (Insert 1 + both send returns, all
	// written by the time masterGroup runs) and is the only thing writing
	// context.out_b for this track's chain.
	spawnMasterFx {
		if(masterSynth.notNil, { masterSynth.free; });
		masterSynth = Synth.tail(masterGroup, fxInsertNames.wrapAt(masterFxMachine.asInteger), this.sendFxArgs(2, masterBus.index, context.out_b.index));
		^masterSynth;
	}

	setMasterMachine { arg idx;
		masterFxMachine = idx.asInteger.clip(0, fxInsertNames.size - 1);
		this.spawnMasterFx;
	}

	setMasterFx { arg key, value;
		if(masterSynth.notNil, { masterSynth.set(key, value); });
	}

	// --- Phase 1 multitrack (tracks 2-8; PHASE1_CONTRACT.md) -----------------
	// Track 1 stays on the legacy instance vars/synths above; every method
	// here operates on a track's state Event and (when its chain is
	// allocated) its transport/reader/mix synths. The tr* commands in
	// installCommands dispatch on the leading track index: 1 routes to the
	// legacy track-1 path, 2-8 route here. Deliberately boring, obvious
	// mirrors of the single-track methods rather than a clever unification.

	// Lazy per-track state. nil for out-of-range indices (incl. 1: track 1
	// has no Event -- its state is the legacy instance vars).
	trackState { arg track;
		var t;
		t = track.asInteger;
		if((t < 2) or: { t > 8 }, { ^nil });
		if(trackStates[t].isNil, { trackStates[t] = this.trackDefaultState; });
		^trackStates[t];
	}

	// Defaults mirror the track-1 instance-var defaults above, field for
	// field, so a fresh track 2-8 behaves exactly like a fresh track 1.
	trackDefaultState {
		^(
			machine: 0,
			playing: 0,
			muted: 0,
			sampleSlot: 1,
			loaded: 0,
			bufL: nil,
			bufR: nil,
			sourceFrames: 4,
			sourceRate: 48000,
			derivedSourceBpm: 120,
			sampleSteps: 16,
			loopStart: 0,
			loopEnd: 128,
			pitch: 0,
			speed: 1,
			direction: 1,
			amp: 0.8,
			pan: 0,
			macro: 0,
			envMode: 1,
			envAttack: 0.0001,
			envDecay: 0.15,
			envSustain: 0.8,
			envRelease: 0.0001,
			envHold: 1000000,
			envTrigCount: 0,
			envNoteSeconds: 0.5,
			noteOffTrigCount: 0,
			portamento: 0,
			resetCount: 0,
			lastPhase: 0,
			group: nil,
			phaseBus: nil,
			mixBus: nil,
			transportSynth: nil,
			activeSynth: nil,
			mixSynth: nil
		);
	}

	// Per-track activeLoopBeats (same formula as the track-1 method).
	trackLoopBeats { arg st;
		var region;
		region = ((st[\loopEnd] - st[\loopStart]).max(0.01) / 128).clip(0.0001, 1);
		^((st[\sampleSteps].max(1) / 4) * region).max(0.03125);
	}

	// Per-track recalculateNativeTempo.
	recalcTrackNativeTempo { arg st;
		var duration;
		duration = st[\sourceFrames].max(1) / st[\sourceRate].max(1);
		st[\derivedSourceBpm] = ((st[\sampleSteps].max(1) / 4) * 60 / duration).max(1);
	}

	// Live set on a track's reader synth (no-op while the chain is inactive).
	setTrackReader { arg track, key, value;
		var st;
		st = this.trackState(track);
		if(st.notNil and: { st[\activeSynth].notNil }, {
			st[\activeSynth].set(key, value);
		});
	}

	// Mirror of commonArgs, fed from the track's state Event. Readers get the
	// shared always-zero mod bus as pitchModBus (mod is track-1-only in
	// Phase 1) and their track index for SendReply routing.
	commonTrackArgs { arg track, st, startAmp;
		^[
			\out, st[\mixBus].index,
			\phaseBus, st[\phaseBus].index,
			\bufL, (st[\bufL] ? defaultBufL).bufnum,
			\bufR, (st[\bufR] ? defaultBufR).bufnum,
			\modeAmp, startAmp,
			\fadeTime, modeSwitchFade,
			\playing, st[\playing],
			\resetTrig, st[\resetCount],
			\resetPos, st[\lastPhase],
			\amp, st[\amp],
			\pan, st[\pan],
			\pitch, st[\pitch],
			\speed, st[\speed],
			\direction, st[\direction],
			\targetBpm, targetBpm,
			\derivedSourceBpm, st[\derivedSourceBpm],
			\loopBeats, this.trackLoopBeats(st),
			\startPoint, st[\loopStart],
			\endPoint, st[\loopEnd],
			\macro, st[\macro],
			\envMode, st[\envMode],
			\envAttack, st[\envAttack],
			\envDecay, st[\envDecay],
			\envSustain, st[\envSustain],
			\envRelease, st[\envRelease],
			\envHold, st[\envHold],
			\envTrig, st[\envTrigCount],
			\envGateSeconds, st[\envNoteSeconds],
			\envReleaseTrig, st[\noteOffTrigCount],
			\portamento, st[\portamento],
			\pitchModBus, trackZeroModBus.index,
			\trackIndex, track
		];
	}

	// Mirror of spawnMode for a track chain: the reader always sits after the
	// track's own transport synth, inside the track's group.
	spawnTrackMode { arg track, st, startAmp;
		^Synth.after(
			st[\transportSynth],
			modeSynthNames.wrapAt(st[\machine].asInteger),
			this.commonTrackArgs(track, st, startAmp)
		);
	}

	// Allocate a track's chain: private phase + mix busses, its own group in
	// tracksGroup, then transport -> reader -> mix in node order. Idempotent.
	allocateTrackChain { arg track;
		var st, server;
		st = this.trackState(track);
		if(st.isNil or: { st[\group].notNil }, { ^nil });
		server = context.server;
		st[\phaseBus] = Bus.audio(server, 1);
		st[\mixBus] = Bus.audio(server, 2);
		st[\group] = Group.tail(tracksGroup);
		st[\transportSynth] = Synth.new(\elasticatTransport, [
			\out, st[\phaseBus].index,
			\playing, st[\playing],
			\targetBpm, targetBpm,
			\loopBeats, this.trackLoopBeats(st),
			\correction, correction,
			\resetTrig, st[\resetCount],
			\resetPos, st[\lastPhase],
			\trackIndex, track
		], st[\group]);
		st[\activeSynth] = this.spawnTrackMode(track, st, 1);
		st[\mixSynth] = Synth.tail(st[\group], \elasticatTrackMix, [
			\out, masterBus.index,
			\in, st[\mixBus].index,
			\amp, st[\amp],
			\pan, st[\pan],
			\mute, st[\muted],
			\alive, 1
		]);
		// Bind whatever the track's selected pool slot currently holds.
		this.setTrackSampleSlot(track, st[\sampleSlot]);
	}

	// Free a track's chain click-free: fade the mix gain (~30 ms Lag on
	// `alive`), then free the group (transport + reader + mix) and busses.
	// The state Event survives, so re-raising \activeTrackCount restores the
	// track exactly as it was.
	freeTrackChain { arg track;
		var st, group, phaseBus2, mixBus2, mixSynth2;
		st = trackStates[track.asInteger];
		if(st.isNil or: { st[\group].isNil }, { ^nil });
		group = st[\group];
		phaseBus2 = st[\phaseBus];
		mixBus2 = st[\mixBus];
		mixSynth2 = st[\mixSynth];
		st[\group] = nil;
		st[\phaseBus] = nil;
		st[\mixBus] = nil;
		st[\transportSynth] = nil;
		st[\activeSynth] = nil;
		st[\mixSynth] = nil;
		if(mixSynth2.notNil, { mixSynth2.set(\alive, 0); });
		Routine({
			0.08.wait;  // > the 30 ms alive Lag: silence before the free
			if(group.notNil, { group.free; });
			if(phaseBus2.notNil, { phaseBus2.free; });
			if(mixBus2.notNil, { mixBus2.free; });
		}).play(SystemClock);
	}

	// \activeTrackCount: allocate chains for tracks 2..count, free chains
	// above count. Track 1 always runs; count 1 (the default) allocates
	// nothing -- zero added cost.
	setActiveTrackCount { arg count;
		activeTrackCount = count.asInteger.clip(1, 8);
		(2..8).do({ arg t;
			if(t <= activeTrackCount, {
				this.allocateTrackChain(t);
			}, {
				this.freeTrackChain(t);
			});
		});
	}

	setTrackPlay { arg track, state;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\playing] = state.asInteger.clip(0, 1);
		if(st[\transportSynth].notNil, { st[\transportSynth].set(\playing, st[\playing]); });
		if(st[\activeSynth].notNil, { st[\activeSynth].set(\playing, st[\playing]); });
	}

	setTrackPlayhead { arg track, phase;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\resetCount] = st[\resetCount] + 1;
		st[\lastPhase] = phase.wrap(0, 1);
		if(st[\transportSynth].notNil, {
			st[\transportSynth].set(\resetPos, st[\lastPhase], \resetTrig, st[\resetCount]);
		});
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(\resetPos, st[\lastPhase], \resetTrig, st[\resetCount]);
		});
	}

	// Push a track's loop region to its transport + reader (shared tail of
	// the loop-start/end/region setters below).
	applyTrackLoop { arg st;
		if(st[\transportSynth].notNil, {
			st[\transportSynth].set(\loopBeats, this.trackLoopBeats(st));
		});
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(
				\loopBeats, this.trackLoopBeats(st),
				\startPoint, st[\loopStart],
				\endPoint, st[\loopEnd]
			);
		});
	}

	setTrackLoopStart { arg track, position;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\loopStart] = position.clip(0, 127.99);
		if(st[\loopEnd] <= st[\loopStart], {
			st[\loopEnd] = (st[\loopStart] + 0.01).clip(0.01, 128);
		});
		this.applyTrackLoop(st);
	}

	setTrackLoopEnd { arg track, position;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\loopEnd] = position.clip(0.01, 128);
		if(st[\loopEnd] <= st[\loopStart], {
			st[\loopStart] = (st[\loopEnd] - 0.01).clip(0, 127.99);
		});
		this.applyTrackLoop(st);
	}

	// Mirror of setLoopRegionPlayhead: atomically set region + reset phase.
	setTrackLoopRegionPlayhead { arg track, startPosition, endPosition, phase;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\loopStart] = startPosition.clip(0, 127.99);
		st[\loopEnd] = endPosition.clip(0.01, 128);
		if(st[\loopEnd] <= st[\loopStart], {
			st[\loopEnd] = (st[\loopStart] + 0.01).clip(0.01, 128);
		});
		st[\resetCount] = st[\resetCount] + 1;
		st[\lastPhase] = phase.wrap(0, 1);
		if(st[\transportSynth].notNil, {
			st[\transportSynth].set(
				\playing, st[\playing],
				\targetBpm, targetBpm,
				\loopBeats, this.trackLoopBeats(st),
				\correction, correction,
				\resetPos, st[\lastPhase],
				\resetTrig, st[\resetCount]
			);
		});
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(
				\playing, st[\playing],
				\targetBpm, targetBpm,
				\loopBeats, this.trackLoopBeats(st),
				\startPoint, st[\loopStart],
				\endPoint, st[\loopEnd],
				\resetPos, st[\lastPhase],
				\resetTrig, st[\resetCount]
			);
		});
	}

	// Mirror of setMode: crossfade-swap the track's reader synth. While the
	// chain is inactive only the state changes; allocation re-seeds from it.
	setTrackMachine { arg track, modeIndex;
		var st, newMode, oldMode, oldSynth, newSynth;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		newMode = modeIndex.asInteger.clip(0, modeSynthNames.size - 1);
		oldMode = st[\machine];
		if((newMode == oldMode) and: { st[\activeSynth].notNil }, { ^nil });
		st[\machine] = newMode;
		if(st[\group].isNil, { ^nil });
		if((oldMode == 0) and: { newMode != 0 }, {
			this.setTrackPlayhead(track, st[\lastPhase]);
		});
		oldSynth = st[\activeSynth];
		newSynth = this.spawnTrackMode(track, st, 0);
		st[\activeSynth] = newSynth;
		newSynth.set(\modeAmp, 1, \fadeTime, modeSwitchFade);
		if(oldSynth.notNil, {
			oldSynth.set(\modeAmp, 0, \fadeTime, modeSwitchFade);
			Routine({
				modeSwitchFade.wait;
				oldSynth.free;
			}).play(SystemClock);
		});
	}

	// Mirror of setSampleSlot: point the track's reader at a shared pool
	// slot's buffers (slot < 1 or an empty slot -> the default silent
	// buffers). No buffer duplication -- tracks share poolBufL/poolBufR, and
	// repointing after an async (re)load happens in installPoolBuffers,
	// downstream of its generation check.
	setTrackSampleSlot { arg track, slot;
		var st, idx;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		slot = slot.asInteger;
		if(slot < 1, {
			st[\sampleSlot] = 0;
			st[\loaded] = 0;
			st[\bufL] = defaultBufL;
			st[\bufR] = defaultBufR;
		}, {
			slot = slot.clip(1, poolSize);
			idx = slot - 1;
			st[\sampleSlot] = slot;
			if(poolLoaded[idx] != 1, {
				st[\loaded] = 0;
				st[\bufL] = defaultBufL;
				st[\bufR] = defaultBufR;
			}, {
				st[\loaded] = 1;
				st[\bufL] = poolBufL[idx];
				st[\bufR] = poolBufR[idx];
				st[\sourceFrames] = poolFrames[idx].max(1);
				st[\sourceRate] = poolRates[idx].max(1);
				this.recalcTrackNativeTempo(st);
			});
		});
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(
				\bufL, (st[\bufL] ? defaultBufL).bufnum,
				\bufR, (st[\bufR] ? defaultBufR).bufnum,
				\derivedSourceBpm, st[\derivedSourceBpm]
			);
		});
		scriptAddress.sendBundle(0, [
			"/elasticat/track/slot",
			track.asInteger,
			st[\sampleSlot],
			st[\loaded],
			st[\sourceFrames],
			st[\sourceRate]
		]);
	}

	setTrackSampleSteps { arg track, steps;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\sampleSteps] = steps.clip(1, 512);
		this.recalcTrackNativeTempo(st);
		if(st[\transportSynth].notNil, {
			st[\transportSynth].set(\loopBeats, this.trackLoopBeats(st));
		});
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(
				\loopBeats, this.trackLoopBeats(st),
				\derivedSourceBpm, st[\derivedSourceBpm]
			);
		});
	}

	setTrackSourceBpm { arg track, bpm;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\derivedSourceBpm] = bpm.max(1);
		this.setTrackReader(track, \derivedSourceBpm, st[\derivedSourceBpm]);
	}

	// Track volume/pan for tracks 2-8 live on the mix synth (the job track
	// 1's filter output stage does).
	setTrackAmp { arg track, value;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\amp] = value.max(0);
		if(st[\mixSynth].notNil, { st[\mixSynth].set(\amp, st[\amp]); });
	}

	setTrackPan { arg track, value;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\pan] = value.clip(-1, 1);
		if(st[\mixSynth].notNil, { st[\mixSynth].set(\pan, st[\pan]); });
	}

	// \trMute: track 1 gates the filter-stage amp (its chain has no mix
	// synth); tracks 2-8 gate their mix synth. Muted tracks keep advancing.
	setTrackMute { arg track, state;
		var st, m;
		m = state.asInteger.clip(0, 1);
		if(track.asInteger == 1, {
			track1Mute = m;
			this.applyTrack1Amp;
			^nil;
		});
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\muted] = m;
		if(st[\mixSynth].notNil, { st[\mixSynth].set(\mute, m); });
	}

	// Track 1's effective filter-stage amp: 0 while muted, else the amp the
	// legacy \amp command maintains. When track1Mute == 0 this is exactly the
	// old setFilter(\amp, amp).
	applyTrack1Amp {
		this.setFilter(\amp, if(track1Mute == 1, { 0 }, { amp }));
	}

	// Mirror of \noteOn for a track's reader (no filter env for tracks 2-8 in
	// Phase 1). seconds <= 0 is the same indefinite-hold sentinel.
	trackNoteOn { arg track, seconds;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		if(seconds > 0, {
			st[\envNoteSeconds] = seconds.max(0.005);
		}, {
			st[\envNoteSeconds] = -1;
		});
		st[\envTrigCount] = st[\envTrigCount] + 1;
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(\envGateSeconds, st[\envNoteSeconds], \envTrig, st[\envTrigCount]);
		});
	}

	trackNoteOff { arg track;
		var st;
		st = this.trackState(track);
		if(st.isNil, { ^nil });
		st[\noteOffTrigCount] = st[\noteOffTrigCount] + 1;
		if(st[\activeSynth].notNil, {
			st[\activeSynth].set(\envReleaseTrig, st[\noteOffTrigCount]);
		});
	}

	applyGlobals { arg synth;
		if(synth.notNil, {
			synth.set(
				\amp, amp,
				\pan, pan,
				\bufL, bufL.bufnum,
				\bufR, bufR.bufnum,
				\pitch, pitch,
				\speed, speed,
				\direction, direction,
				\playing, playing,
				\resetTrig, resetCount,
				\resetPos, lastPhase,
				\targetBpm, targetBpm,
				\derivedSourceBpm, derivedSourceBpm,
				\loopBeats, this.activeLoopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd,
				\macro, modeMacro,
				\fadeTime, modeSwitchFade
			);
		});
	}

	play { arg state;
		playing = state.asInteger.clip(0, 1);
		if(playing == 0, { this.releaseAllSlices; });
		this.updateTransport;
		this.setActive(\playing, playing);
		scriptAddress.sendBundle(0, ["/elasticat/play", playing]);
	}

	stopAndReset {
		this.play(0);
		this.releaseAllSlices;
		this.setPlayhead(0);
	}

	setReverse { arg value;
		if(value.asInteger == 1, {
			direction = -1;
		}, {
			direction = 1;
		});
		this.setActive(\direction, direction);
	}

	triggerSlice { arg sliceIndex, startPoint, endPoint, playMode, reverse, velocity, lengthSeconds, notePitch;
		var idx, startPos, endPos, mode, rev, pitchValue, pitchRatio, duration, sliceRatio, synth;
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

		if(sliceMono == 1, { this.releaseAllSlices; });
		if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1].notNil }, {
			activeSliceSynths[idx - 1].set(\gate, 0);
		});

		synth = Synth.tail(sourceGroup, \elasticatSliceVoice, [
			\out, fxBus.index,
			\bufL, bufL.bufnum,
			\bufR, bufR.bufnum,
			\startPoint, startPos,
			\endPoint, endPos,
			\playMode, mode,
			\reverse, rev,
			\amp, amp,
			\pan, pan,
			\pitch, pitchValue,
			\velocity, velocity.asFloat.clip(0, 1),
			\sliceAttack, sliceAttack,
			\sliceRelease, sliceRelease,
			\envMode, envMode,
			\envAttack, envAttack,
			\envDecay, envDecay,
			\envSustain, envSustain,
			\envRelease, envRelease,
			\envHold, envHold,
			\lengthSeconds, duration,
			\syncToClock, sliceSyncToClock,
			\sliceRate, sliceRate,
			\warpMode, activeMode,
			\targetBpm, targetBpm,
			\macro, modeMacro,
			\grainSize, grainSize,
			\grainOverlap, grainOverlap,
			\grainJitter, grainJitter + grainSpray,
			\wsolaWindow, wsolaWindow,
			\wsolaSearch, wsolaSearch,
			\pvWindow, pvWindow,
			\pvDispersion, pvDispersion,
			\pitchModBus, modBusPitch.index,
			\gate, 1
		]);
		if(activeSliceSynths.notNil, { activeSliceSynths[idx - 1] = synth; });
		Routine({
			duration.wait;
			if(synth.notNil, { synth.set(\gate, 0); });
			if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1] == synth }, {
				activeSliceSynths[idx - 1] = nil;
			});
		}).play(SystemClock);
	}

	releaseSlice { arg sliceIndex;
		var idx;
		idx = sliceIndex.asInteger.clip(1, 32);
		if(activeSliceSynths.notNil and: { activeSliceSynths[idx - 1].notNil }, {
			activeSliceSynths[idx - 1].set(\gate, 0);
			activeSliceSynths[idx - 1] = nil;
		});
	}

	releaseAllSlices {
		if(activeSliceSynths.notNil, {
			activeSliceSynths.do({ arg synth, i;
				if(synth.notNil, {
					synth.set(\gate, 0);
					activeSliceSynths[i] = nil;
				});
			});
		});
	}

	activeLoopBeats {
		var region;
		region = ((loopEnd - loopStart).max(0.01) / 128).clip(0.0001, 1);
		^((sampleSteps.max(1) / 4) * region).max(0.03125);
	}

	setSampleSteps { arg steps;
		sampleSteps = steps.clip(1, 512);
		this.recalculateNativeTempo;
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
	}

	setSourceBpm { arg bpm;
		sourceBpm = bpm.max(1);
		derivedSourceBpm = sourceBpm;
		this.setActive(\derivedSourceBpm, derivedSourceBpm);
	}

	setLoopStart { arg position;
		loopStart = position.clip(0, 127.99);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
		this.setActive(\startPoint, loopStart);
		this.setActive(\endPoint, loopEnd);
	}

	setLoopEnd { arg position;
		loopEnd = position.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopStart = (loopEnd - 0.01).clip(0, 127.99); });
		this.updateTransport;
		this.setActive(\loopBeats, this.activeLoopBeats);
		this.setActive(\startPoint, loopStart);
		this.setActive(\endPoint, loopEnd);
	}

	setLoopRegionPlayhead { arg startPosition, endPosition, phase;
		loopStart = startPosition.clip(0, 127.99);
		loopEnd = endPosition.clip(0.01, 128);
		if(loopEnd <= loopStart, { loopEnd = (loopStart + 0.01).clip(0.01, 128); });
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\correction, correction,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
		if(activeSynth.notNil, {
			activeSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\startPoint, loopStart,
				\endPoint, loopEnd,
				\resetPos, lastPhase,
				\resetTrig, resetCount
			);
		});
		scriptAddress.sendBundle(0, ["/elasticat/reset", lastPhase]);
	}

	updateTransport {
		if(transportSynth.notNil, {
			transportSynth.set(
				\playing, playing,
				\targetBpm, targetBpm,
				\loopBeats, this.activeLoopBeats,
				\correction, correction
			);
		});
		this.setActive(\playing, playing);
		this.setActive(\targetBpm, targetBpm);
		this.setActive(\loopBeats, this.activeLoopBeats);
		// Delay is the only insert FX that reads tempo, but this is the one
		// choke point every tempo change (direct set, clock sync, reset) already
		// routes through, so push it here rather than duplicating at each call site.
		this.setInsert(\targetBpm, targetBpm);
		this.setSend1(\targetBpm, targetBpm);
		this.setSend2(\targetBpm, targetBpm);
		this.setMasterFx(\targetBpm, targetBpm);
		// LFO rates are musical divisions of targetBpm; this is the same choke
		// point every tempo change (direct set, clock sync, reset) routes through.
		this.setMod(\targetBpm, targetBpm);
		// Phase 1 multitrack: tempo is global (MASTER scope), so push it and
		// the clock-sync correction to every active track chain here -- the
		// same choke point track 1 uses. Per-track loopBeats/playing ride
		// along so the transports stay coherent after a tempo change.
		(2..8).do({ arg t;
			var st;
			st = trackStates[t];
			if(st.notNil and: { st[\group].notNil }, {
				if(st[\transportSynth].notNil, {
					st[\transportSynth].set(
						\playing, st[\playing],
						\targetBpm, targetBpm,
						\loopBeats, this.trackLoopBeats(st),
						\correction, correction
					);
				});
				if(st[\activeSynth].notNil, {
					st[\activeSynth].set(
						\targetBpm, targetBpm,
						\loopBeats, this.trackLoopBeats(st)
					);
				});
			});
		});
	}

	setPlayhead { arg phase;
		resetCount = resetCount + 1;
		lastPhase = phase.wrap(0, 1);
		if(transportSynth.notNil, {
			transportSynth.set(\resetPos, lastPhase, \resetTrig, resetCount);
		});
		this.setActive(\resetPos, lastPhase);
		this.setActive(\resetTrig, resetCount);
		scriptAddress.sendBundle(0, ["/elasticat/reset", lastPhase]);
	}

	setMode { arg modeIndex;
		var newMode, oldMode, oldSynth, newSynth;
		newMode = modeIndex.asInteger.clip(0, modeSynthNames.size - 1);
		if(newMode == activeMode and: { activeSynth.notNil }, {
			^nil;
		});

		oldMode = activeMode;
		oldSynth = activeSynth;
		if(oldMode == 0 and: { newMode != 0 }, {
			this.setPlayhead(lastPhase);
		});
		activeMode = newMode;
		newSynth = this.spawnMode(activeMode, 0);
		this.applyGlobals(newSynth);
		activeSynth = newSynth;
		activeSynth.set(\modeAmp, 1, \fadeTime, modeSwitchFade);

		if(oldSynth.notNil, {
			oldSynth.set(\modeAmp, 0, \fadeTime, modeSwitchFade);
			Routine({
				modeSwitchFade.wait;
				oldSynth.free;
			}).play(SystemClock);
		});

		modeSwitchCount = modeSwitchCount + 1;
		scriptAddress.sendBundle(0, ["/elasticat/mode", modeNames.wrapAt(activeMode), activeMode, modeSwitchCount]);
	}

	syncClock { arg expectedPhase, tempo, sequence;
		var err, absMs, loopSeconds;
		if(sequence <= lastClockSeq, {
			staleClockCount = staleClockCount + 1;
			^nil;
		});
		lastClockSeq = sequence;
		targetBpm = tempo.max(1);
		lastExpectedPhase = expectedPhase.wrap(0, 1);
		err = lastExpectedPhase - lastPhase;
		if(err > 0.5, { err = err - 1; });
		if(err < -0.5, { err = err + 1; });
		loopSeconds = this.activeLoopBeats * 60 / targetBpm;
		absMs = err.abs * loopSeconds * 1000;
		lastPhaseError = err;
		lastErrorMs = absMs;

		if(err.abs > hardThreshold, {
			correction = 0;
			hardRealignCount = hardRealignCount + 1;
			this.setPlayhead(lastExpectedPhase);
		}, {
			if(absMs < 0.5, {
				correction = 0;
			}, {
				correction = (err * 0.5).clip(maxCorrection.neg, maxCorrection);
			});
		});

		this.updateTransport;
		this.setActive(\targetBpm, targetBpm);
		this.setActive(\loopBeats, this.activeLoopBeats);
	}

	loadSample { arg path;
		this.loadPoolSlot(sampleSlot, path);
	}

	loadPoolSlot { arg slot, path;
		var sf, channels, frames, rate, generation, idx;
		if(path.isNil, { ^nil; });
		slot = slot.asInteger.clip(1, poolSize);
		idx = slot - 1;
		path = path.asString;
		loadGeneration = loadGeneration + 1;
		generation = loadGeneration;
		poolGenerations[idx] = generation;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/request", slot, path, generation]);
		if(slot == sampleSlot, {
			scriptAddress.sendBundle(0, ["/elasticat/load/request", path, generation]);
		});

		sf = SoundFile.openRead(path);
		if(sf.isNil, {
			scriptAddress.sendBundle(0, ["/elasticat/pool/load/failed", slot, path, generation]);
			if(slot == sampleSlot, {
				scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
			});
			^nil;
		});
		channels = sf.numChannels;
		frames = sf.numFrames;
		rate = sf.sampleRate;
		sf.close;
		scriptAddress.sendBundle(0, ["/elasticat/pool/load/opened", slot, path, channels, frames, rate, generation]);
		if(slot == sampleSlot, {
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
					if(slot == sampleSlot, {
						scriptAddress.sendBundle(0, ["/elasticat/load/failed", path, generation]);
					});
				}, {
					scriptAddress.sendBundle(0, ["/elasticat/pool/load/readDone", slot, 0, newL.numFrames, newL.numChannels, generation]);
					if(slot == sampleSlot, {
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
								if(slot == sampleSlot, {
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
		var idx, oldL, oldR;
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

		if(slot == sampleSlot, {
			this.setSampleSlot(slot);
			scriptAddress.sendBundle(0, [
				"/elasticat/load/installed",
				bufL.bufnum,
				bufR.bufnum,
				bufL.numFrames,
				bufL.sampleRate,
				derivedSourceBpm,
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

		// Phase 1 multitrack: repoint any track 2-8 currently on this slot at
		// the freshly installed buffers, BEFORE the old ones are freed below.
		// This runs downstream of the generation check above, so tracks obey
		// the same stale-load protection as track 1.
		(2..8).do({ arg t;
			var st;
			st = trackStates[t];
			if(st.notNil and: { st[\sampleSlot] == slot }, {
				this.setTrackSampleSlot(t, slot);
			});
		});

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
		// Phase 1 multitrack: any track 2-8 on this slot must let go of the
		// buffers BEFORE they are freed below (setTrackSampleSlot sees
		// poolLoaded == 0 and swaps in the default silent buffers).
		(2..8).do({ arg t;
			var st;
			st = trackStates[t];
			if(st.notNil and: { st[\sampleSlot] == slot }, {
				this.setTrackSampleSlot(t, slot);
			});
		});
		if(oldL.notNil, { oldL.free; });
		if(oldR.notNil and: { oldR != oldL }, { oldR.free; });
		// If the active reader was on this slot, repoint it at silence now
		// (setSampleSlot sees poolLoaded == 0 and swaps in the default buffers).
		if(slot == sampleSlot, {
			this.setSampleSlot(slot);
		});
	}

	setSampleSlot { arg slot;
		var idx;
		slot = slot.asInteger;

		// Slot 0 (Off): a deliberate silence slot -- point the reader at the
		// default (zeroed) buffers so it outputs silence while the transport
		// keeps running. Useful for sequencing gaps.
		if(slot < 1, {
			sampleSlot = 0;
			this.releaseAllSlices;
			loaded = 0;
			bufL = defaultBufL;
			bufR = defaultBufR;
			this.setActive(\bufL, bufL.bufnum);
			this.setActive(\bufR, bufR.bufnum);
			scriptAddress.sendBundle(0, ["/elasticat/pool/slot/active", 0, 0, 0, ""]);
			^nil;
		});

		slot = slot.clip(1, poolSize);
		idx = slot - 1;
		sampleSlot = slot;

		if(poolLoaded[idx] != 1, {
			// Empty slot -> silence too (was: keep the previous buffer, so the
			// last-loaded sample kept playing).
			this.releaseAllSlices;
			loaded = 0;
			bufL = defaultBufL;
			bufR = defaultBufR;
			this.setActive(\bufL, bufL.bufnum);
			this.setActive(\bufR, bufR.bufnum);
			scriptAddress.sendBundle(0, ["/elasticat/pool/slot/missing", sampleSlot]);
			^nil;
		});

		this.releaseAllSlices;
		bufL = poolBufL[idx];
		bufR = poolBufR[idx];
		loaded = 1;
		sourceFrames = poolFrames[idx].max(1);
		sourceRate = poolRates[idx].max(1);
		this.recalculateNativeTempo;
		this.setActive(\bufL, bufL.bufnum);
		this.setActive(\bufR, bufR.bufnum);
		this.applyGlobals(activeSynth);
		scriptAddress.sendBundle(0, [
			"/elasticat/pool/slot/active",
			sampleSlot,
			sourceFrames,
			sourceRate,
			poolPaths[idx]
		]);
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

	recalculateNativeTempo {
		var duration;
		duration = sourceFrames.max(1) / sourceRate.max(1);
		derivedSourceBpm = ((sampleSteps.max(1) / 4) * 60 / duration).max(1);
		sourceBpm = derivedSourceBpm;
		if(activeSynth.notNil, {
			activeSynth.set(\derivedSourceBpm, derivedSourceBpm);
		});
	}

	sendStatus {
		scriptAddress.sendBundle(0, [
			"/elasticat/requestedStatus",
			loaded,
			playing,
			modeNames.wrapAt(activeMode),
			lastPhase,
			sourceFrames,
			sourceRate,
			targetBpm,
			derivedSourceBpm,
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
		if(transportResponder.notNil, { transportResponder.free; });
		if(previewSynth.notNil, { previewSynth.free; });
		if(modSynth.notNil, { modSynth.free; });
		if(activeSynth.notNil, { activeSynth.free; });
		if(filterSynth.notNil, { filterSynth.free; });
		if(insertSynth.notNil, { insertSynth.free; });
		if(sendTapSynth.notNil, { sendTapSynth.free; });
		if(send1Synth.notNil, { send1Synth.free; });
		if(send2Synth.notNil, { send2Synth.free; });
		if(masterSynth.notNil, { masterSynth.free; });
		if(transportSynth.notNil, { transportSynth.free; });
		// Phase 1 multitrack: freeing a track's group frees its transport +
		// reader + mix synths together.
		if(trackStates.notNil, {
			(2..8).do({ arg t;
				var st;
				st = trackStates[t];
				if(st.notNil, {
					if(st[\group].notNil, { st[\group].free; });
					if(st[\phaseBus].notNil, { st[\phaseBus].free; });
					if(st[\mixBus].notNil, { st[\mixBus].free; });
					st[\group] = nil;
					st[\phaseBus] = nil;
					st[\mixBus] = nil;
					st[\transportSynth] = nil;
					st[\activeSynth] = nil;
					st[\mixSynth] = nil;
				});
			});
		});
		if(tracksGroup.notNil, { tracksGroup.free; });
		if(masterGroup.notNil, { masterGroup.free; });
		if(sendGroup.notNil, { sendGroup.free; });
		if(insertGroup.notNil, { insertGroup.free; });
		if(filterGroup.notNil, { filterGroup.free; });
		if(sourceGroup.notNil, { sourceGroup.free; });
		if(poolBufL.notNil, {
			poolBufL.do({ arg buffer, i;
				if(buffer.notNil, { buffer.free; });
				if(poolBufR[i].notNil and: { poolBufR[i] != buffer }, { poolBufR[i].free; });
			});
		});
		if(defaultBufL.notNil, { defaultBufL.free; });
		if(defaultBufR.notNil and: { defaultBufR != defaultBufL }, { defaultBufR.free; });
		if(phaseBus.notNil, { phaseBus.free; });
		if(fxBus.notNil, { fxBus.free; });
		if(insertBus.notNil, { insertBus.free; });
		if(masterBus.notNil, { masterBus.free; });
		if(sendBus1.notNil, { sendBus1.free; });
		if(sendBus2.notNil, { sendBus2.free; });
		if(modBusPitch.notNil, { modBusPitch.free; });
		if(modBusCutoff.notNil, { modBusCutoff.free; });
		if(modBusRes.notNil, { modBusRes.free; });
		if(modBusAmp.notNil, { modBusAmp.free; });
		if(modBusPan.notNil, { modBusPan.free; });
		if(trackZeroModBus.notNil, { trackZeroModBus.free; });
	}
}
