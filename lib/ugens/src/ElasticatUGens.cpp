// Elasticat custom SuperCollider UGens (compiled server plugins).
//
// Built ON the norns (armv7l) against the installed SC 3.13 plugin headers at
// /usr/local/include/SuperCollider -- no cross-toolchain or SC-source clone
// needed. See ../build-ugens.sh and ../README.md for the build/deploy flow.
//
// TESTING: NRT ONLY (offline, no jack). NEVER boot a second scsynth against the
// live jack -- it wedges jack shm and the norns shows "Audio system fail".

#include "SC_PlugIn.hpp"
#include <cmath>

static InterfaceTable *ft;
static const float kHalfPi = 1.57079632679f;
// cubicinterp(x, y0,y1,y2,y3) -- 4-point cubic -- is provided by SC_SndBuf.h.

// Shared Hann window LUT (filled once in PluginLoad) so grain UGens window with a
// table lookup + lerp instead of a cosf per grain per sample. Size+1 guard point.
static const int kHannSize = 2048;
static float gHann[kHannSize + 1];
// Caller guarantees phase01 in [0,1) (grains retire at >=1 before the next read), so
// no bounds branch: i in [0,kHannSize-1], i+1 in [1,kHannSize] (guard point). gHann[0]
// and gHann[kHannSize] are ~0, so grain edges still fade cleanly.
static inline float hannLerp(double phase01) {
    double x = phase01 * (double)kHannSize;
    int i = (int)x;
    float f = (float)(x - (double)i);
    return gHann[i] + f * (gHann[i + 1] - gHann[i]);
}

// Read one interpolated (cubic) sample from a buffer at an absolute frame pos.
static inline float egPeek(const SndBuf *b, int frames, double pos) {
    if (b == nullptr || b->data == nullptr || frames < 4) return 0.f;
    if (pos < 0.0) pos = 0.0;
    double mx = (double)(frames - 1);
    if (pos > mx) pos = mx;
    int i1 = (int)pos;
    float x = (float)(pos - (double)i1);
    int ch = b->channels; if (ch < 1) ch = 1;
    int i0 = i1 - 1; if (i0 < 0) i0 = 0;
    int i2 = i1 + 1; if (i2 > frames - 1) i2 = frames - 1;
    int i3 = i1 + 2; if (i3 > frames - 1) i3 = frames - 1;
    const float *d = b->data;
    return cubicinterp(x, d[i0 * ch], d[i1 * ch], d[i2 * ch], d[i3 * ch]);
}

// ---------------------------------------------------------------------------
// ElasticatPassthru -- toolchain smoke test: out = in * gain.
// ---------------------------------------------------------------------------
struct ElasticatPassthru : public SCUnit {
public:
    ElasticatPassthru() {
        set_calc_function<ElasticatPassthru, &ElasticatPassthru::next_a>();
        next_a(1);
    }
private:
    void next_a(int nSamples) {
        const float *input = in(0);
        const float *gain = in(1);
        float *outbuf = out(0);
        for (int i = 0; i < nSamples; ++i) outbuf[i] = input[i] * gain[i];
    }
};

// ---------------------------------------------------------------------------
// ElasticatReader -- click-free stereo buffer reader, a direct port of softcut's
// ReadWriteHead + SubHead crossfade model (read-only; softcut's record/resampler
// paths dropped, buffer reads replaced with cubic BufRd on an SC buffer).
//
// The two things that make softcut click-free, which our SC-graph tape_xf lacks:
//   1. ABSOLUTE-FRAME reads: a head's position IS a buffer frame; loopStart/End
//      are just fences that say "when you cross, loop". Moving the fence (a region
//      change) never moves the read position -- so a step that relocks the region
//      (esp. on the RELEASE return-jump) no longer teleports the read = no pop.
//   2. ONE QUEUED crossfade between exactly TWO heads: a new crossfade is queued
//      and only started once the current fade has finished (even a jump mid-fade
//      waits). Never-overlapping fades -> no pile-up (tape_ugen's bug at fast loops).
// The loop SEAM is crossfaded too (the old head continues past end, fading out,
// while the new head fades in at start) -- equal-power sine, same as softcut.
//
// ar inputs:  bufL bufR loopStart(frames) loopEnd(frames) rate(frames/sample,signed)
//             resetTrig resetPos(frames) fadeTime(s) loopFlag(0/1)
// ar outputs: [L, R, phase01(active head, 0..1 over region for the UI playhead)]
// ---------------------------------------------------------------------------
enum { ST_STOP = 0, ST_FADEIN = 1, ST_FADEOUT = 2, ST_PLAY = 3 };

struct ElasticatReader : public SCUnit {
public:
    ElasticatReader() {
        for (int h = 0; h < 2; ++h) { phase[h] = 0.0; fade[h] = 0.f; state[h] = ST_STOP; hactive[h] = false; }
        active = 0;
        queuedPos = 0.0; queuedFlag = false;
        prevReset = in0(5);
        set_calc_function<ElasticatReader, &ElasticatReader::next>();
        next(1);
    }

private:
    double phase[2];   // absolute frame position (may run past a fence during read-ahead)
    float fade[2];     // 0..1 linear; equal-power (sine) applied at mix
    int state[2];
    bool hactive[2];   // only the active head loop-checks its fence
    int active;
    double queuedPos;
    bool queuedFlag;
    float prevReset;

    static inline float peekBuf(const SndBuf *b, int frames, double pos) {
        if (b == nullptr || b->data == nullptr || frames < 4) return 0.f;
        if (pos < 0.0) pos = 0.0;
        double mx = (double)(frames - 1);
        if (pos > mx) pos = mx;
        int i1 = (int)pos;
        float x = (float)(pos - (double)i1);
        int ch = b->channels; if (ch < 1) ch = 1;
        int i0 = i1 - 1; if (i0 < 0) i0 = 0;
        int i2 = i1 + 1; if (i2 > frames - 1) i2 = frames - 1;
        int i3 = i1 + 2; if (i3 > frames - 1) i3 = frames - 1;
        const float *d = b->data;
        return cubicinterp(x, d[i0 * ch], d[i1 * ch], d[i2 * ch], d[i3 * ch]);
    }

    void enqueueCrossfade(double pos) { queuedPos = pos; queuedFlag = true; }

    void cutToPhase(double pos) {
        int newActive = active ^ 1;
        if (state[active] != ST_STOP) state[active] = ST_FADEOUT;
        state[newActive] = ST_FADEIN;
        phase[newActive] = pos;
        hactive[active] = false;
        hactive[newActive] = true;
        active = newActive;
    }

    // external jump: if the active head is mid-fade, queue it (softcut cutToPos).
    void cutToPos(double pos) {
        int s = state[active];
        if (s == ST_FADEIN || s == ST_FADEOUT) enqueueCrossfade(pos);
        else cutToPhase(pos);
    }

    void next(int nSamples) {
        World *w = mWorld;
        uint32 bnL = (uint32)in0(0); if (bnL >= w->mNumSndBufs) bnL = 0;
        uint32 bnR = (uint32)in0(1); if (bnR >= w->mNumSndBufs) bnR = 0;
        const SndBuf *bL = w->mSndBufs + bnL; int fL = bL->frames;
        const SndBuf *bR = w->mSndBufs + bnR; int fR = bR->frames;

        double loopStart = (double)in0(2);
        double loopEnd = (double)in0(3);
        if (loopEnd < loopStart + 1.0) loopEnd = loopStart + 1.0;
        double rate = (double)in0(4);
        float reset = in0(5);
        double resetPos = (double)in0(6);
        float fadeTime = in0(7); if (fadeTime < 0.0005f) fadeTime = 0.0005f;
        int loopFlag = (int)(in0(8) + 0.5f);
        float fadeInc = 1.f / (fadeTime * (float)sampleRate());
        double invRange = 1.0 / (loopEnd - loopStart);

        float *outL = out(0);
        float *outR = out(1);
        float *outPh = out(2);

        if (reset != prevReset) cutToPos(resetPos);
        prevReset = reset;

        // Auto-start: the other reader modes free-run via a Phasor whenever
        // playing==1 (no resetTrig needed to make sound on a plain loop start).
        // rate is 0 iff playing==0, so treat rate!=0 with nothing sounding as a
        // start and fade the active head in at resetPos (== the resetFrame the
        // engine passes = loopStart + resetPos*range, matching the phasor start).
        if (rate != 0.0 && state[0] == ST_STOP && state[1] == ST_STOP) {
            state[active] = ST_FADEIN;
            phase[active] = resetPos;
            fade[active] = 0.f;
            hactive[active] = true;
        }

        for (int i = 0; i < nSamples; ++i) {
            // 1. read + equal-power mix
            float mixL = 0.f, mixR = 0.f;
            if (state[0] != ST_STOP) { float g = sinf(fade[0] * kHalfPi); mixL += peekBuf(bL, fL, phase[0]) * g; mixR += peekBuf(bR, fR, phase[0]) * g; }
            if (state[1] != ST_STOP) { float g = sinf(fade[1] * kHalfPi); mixL += peekBuf(bL, fL, phase[1]) * g; mixR += peekBuf(bR, fR, phase[1]) * g; }
            outL[i] = mixL; outR[i] = mixR;

            // 2. advance phases; the ACTIVE head loops when it crosses a fence
            for (int h = 0; h < 2; ++h) {
                if (state[h] == ST_STOP) continue;
                double p = phase[h] + rate;
                if (hactive[h] && (p > loopEnd || p < loopStart)) {
                    if (loopFlag != 0) enqueueCrossfade(rate >= 0.0 ? loopStart : loopEnd);
                    else state[h] = ST_FADEOUT;
                }
                phase[h] = p;
            }

            // 3. ramp fades
            for (int h = 0; h < 2; ++h) {
                if (state[h] == ST_FADEIN) { fade[h] += fadeInc; if (fade[h] > 1.f) { fade[h] = 1.f; state[h] = ST_PLAY; } }
                else if (state[h] == ST_FADEOUT) { fade[h] -= fadeInc; if (fade[h] < 0.f) { fade[h] = 0.f; state[h] = ST_STOP; } }
            }

            // 4. perform a queued crossfade only when the active head is not mid-fade
            int as = state[active];
            if (as != ST_FADEIN && as != ST_FADEOUT && queuedFlag) {
                cutToPhase(queuedPos);
                queuedFlag = false;
            }

            double ph01 = (phase[active] - loopStart) * invRange;
            ph01 = ph01 - floor(ph01);
            outPh[i] = (float)ph01;
        }
    }
};

// ---------------------------------------------------------------------------
// ElasticatGrains -- particle granular engine. The PLAYHEAD (input 2) is a silent
// cursor scanning the fenced range; it does NOT play the sample. It EMITS grains at
// its position (+/- spread), and each grain independently reads the sample as its
// own particle, WRAPPING seamlessly at the trim bounds ([0,frames], circular cubic).
// Because grains wrap at trim -- never at the loop/range points -- moving loop start/
// end just relocates the emitter, so in-flight grains are untouched = no clicks.
//
// Per grain: read rate = baseRate * (1 +/- speedRand) * direction, where the engine
// folds baseRate = playheadRate * grainSpeed * pitchRatio (simple model: grain speed
// is a multiplier of the playhead scan speed, pitch is the grain-cycle read rate).
// Direction is a 0..1 morph: 0 = all backward, 0.5 = 50/50, 1 = all forward. One
// schedule reads BOTH channels (shared L/R). No dry/wet -- grains ARE the output.
//
// ar inputs:  bufL bufR playhead(0..1, ar) density cycleMs spread(0..1)
//             baseRate(frames/sample, signed) speedRand(0..1) dirBalance(0..1)
// ar outputs: [L, R]
// ---------------------------------------------------------------------------
struct EGrain { double pos; double rate; float phase; float phaseInc; };

struct ElasticatGrains : public SCUnit {
public:
    ElasticatGrains() {
        nActive = 0;
        spawnCounter = 0.0;
        rngState = 0x2545F491u ^ (uint32)(size_t)this;
        set_calc_function<ElasticatGrains, &ElasticatGrains::next>();
        next(1);
    }
private:
    static const int kMaxGrains = 72;  // density up to 64 + headroom
    EGrain g[kMaxGrains];
    int nActive;                       // g[0..nActive-1] are live (compact, no holes)
    double spawnCounter;
    uint32 rngState;

    inline float frand() {  // xorshift32 -> [-1, 1)
        rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5;
        return ((float)(rngState & 0xFFFFFFu) / (float)0x800000) - 1.f;
    }

    // Cubic (4-point) interp read, CIRCULAR over [0,frames) so a grain scanning off
    // an end wraps seamlessly to the other (the trim auto-loop). Caller keeps pos in
    // [0,frames). Cubic (not linear): linear sounded gritty on rich material.
    static inline float peekCubWrap(const float *d, int ch, int frames, double pos) {
        int i1 = (int)pos;
        if (i1 >= frames) i1 = frames - 1; else if (i1 < 0) i1 = 0;
        float x = (float)(pos - (double)i1);
        int i0 = i1 - 1; if (i0 < 0) i0 += frames;
        int i2 = i1 + 1; if (i2 >= frames) i2 -= frames;
        int i3 = i1 + 2; if (i3 >= frames) i3 -= frames;
        return cubicinterp(x, d[i0 * ch], d[i1 * ch], d[i2 * ch], d[i3 * ch]);
    }

    void next(int nSamples) {
        World *w = mWorld;
        uint32 bnL = (uint32)in0(0); if (bnL >= w->mNumSndBufs) bnL = 0;
        uint32 bnR = (uint32)in0(1); if (bnR >= w->mNumSndBufs) bnR = 0;
        const SndBuf *bL = w->mSndBufs + bnL;
        const SndBuf *bR = w->mSndBufs + bnR;
        float *outL = out(0);
        float *outR = out(1);

        int fL = bL->frames, fR = bR->frames;
        int frames = fL < fR ? fL : fR;
        if (bL->data == nullptr || bR->data == nullptr || frames < 4) {
            for (int i = 0; i < nSamples; ++i) { outL[i] = 0.f; outR[i] = 0.f; }
            nActive = 0;
            return;
        }
        const float *dL = bL->data; int chL = bL->channels < 1 ? 1 : bL->channels;
        const float *dR = bR->data; int chR = bR->channels < 1 ? 1 : bR->channels;
        bool mono = (bnL == bnR);  // same buffer L/R -> read once

        const float *ptr = in(2);
        double density = (double)in0(3);
        if (density < 1.0) density = 1.0;
        if (density > (double)(kMaxGrains - 1)) density = (double)(kMaxGrains - 1);
        double cycleMs = (double)in0(4); if (cycleMs < 1.0) cycleMs = 1.0;
        double spread = (double)in0(5); if (spread < 0.0) spread = 0.0;
        double baseRate = (double)in0(6);
        double speedRand = (double)in0(7); if (speedRand < 0.0) speedRand = 0.0; if (speedRand > 1.0) speedRand = 1.0;
        double dirBalance = (double)in0(8); if (dirBalance < 0.0) dirBalance = 0.0; if (dirBalance > 1.0) dirBalance = 1.0;

        double sr = (double)sampleRate();
        double cycleSamples = cycleMs * sr / 1000.0; if (cycleSamples < 4.0) cycleSamples = 4.0;
        double spawnInterval = cycleSamples / density; if (spawnInterval < 1.0) spawnInterval = 1.0;
        float phaseInc = (float)(1.0 / cycleSamples);
        double fbuf = (double)frames;
        double spreadFrames = spread * fbuf;
        // direction morph -> a threshold on frand()'s [-1,1): dirBalance 1 => always
        // forward, 0 => always backward, 0.5 => ~50/50.
        double dirThresh = 2.0 * dirBalance - 1.0;

        for (int i = 0; i < nSamples; ++i) {
            double emitCenter = (double)ptr[i] * fbuf;

            // spawn a grain roughly every spawnInterval samples, but JITTER the interval
            // +/-30%. Grains re-read overlapping content (that's how the independent-time
            // stretch works); at a REGULAR spawn rate those correlated re-reads comb-filter
            // into a metallic/scratchy timbre. Jittering the spawn timing smears the comb
            // frequency into a smooth wash. Average density is preserved (mean jitter ~0).
            spawnCounter -= 1.0;
            if (spawnCounter <= 0.0) {
                spawnCounter += spawnInterval * (1.0 + (0.3 * (double)frand()));
                if (nActive < kMaxGrains) {
                    EGrain &ng = g[nActive++];
                    double p = emitCenter + ((double)frand() * spreadFrames);
                    p = fmod(p, fbuf); if (p < 0.0) p += fbuf;   // wrap emit into [0,frames)
                    ng.pos = p;
                    double sMul = 1.0 + (speedRand * (double)frand());
                    double dir = ((double)frand() < dirThresh) ? 1.0 : -1.0;
                    ng.rate = baseRate * sMul * dir;
                    ng.phase = 0.f;
                    ng.phaseInc = phaseInc;
                }
            }

            // render live grains only (compact array; swap-remove on retire)
            float mixL = 0.f, mixR = 0.f;
            int k = 0;
            while (k < nActive) {
                EGrain &gr = g[k];
                float win = hannLerp((double)gr.phase);
                if (mono) {
                    float v = peekCubWrap(dL, chL, frames, gr.pos) * win;
                    mixL += v; mixR += v;
                } else {
                    mixL += peekCubWrap(dL, chL, fL, gr.pos) * win;
                    mixR += peekCubWrap(dR, chR, fR, gr.pos) * win;
                }
                gr.pos += gr.rate;
                if (gr.pos >= fbuf) gr.pos -= fbuf; else if (gr.pos < 0.0) gr.pos += fbuf;  // trim wrap
                gr.phase += gr.phaseInc;
                if (gr.phase >= 1.f) { g[k] = g[--nActive]; }  // retire: pull last into slot k
                else { ++k; }
            }
            outL[i] = mixL;
            outR[i] = mixR;
        }
    }
};

// ---------------------------------------------------------------------------
// ElasticatSlicer -- a slice player. The region [startFrac,endFrac] is divided into
// numSlices equal slices; a tempo-driven slicePhase (0..1 over the region; the engine
// runs it BACKWARD for track-reverse) selects the current slice. On a slice change a
// TWO-HEAD crossfade hands off -- the displaced head goes to RELEASE while the new head
// ATTACKS -- so even a long attack/gate never hard-cuts the previous slice = no click.
// Each slice has an A / gate / R amplitude envelope (gate = 0..1 of the slice duration)
// and a per-slice read obeying the loop mode + slice reverse.
//
// ar inputs: bufL bufR slicePhase(0..1 ar) startFrac endFrac numSlices attackSamp
//            releaseSamp gate(0..1) sliceDurSamp loopMode(0 chop 1 loop 2 pingpong
//            3 runaway) sliceReverse(0/1) pitchRate(frames/sample, magnitude)
// ar outputs: [L, R]
// ---------------------------------------------------------------------------
enum { SV_ATTACK = 0, SV_HOLD = 1, SV_RELEASE = 2, SV_DONE = 3 };
struct SVoice { double pos, lo, hi, sinceTrig; int dir, state; float env; };

struct ElasticatSlicer : public SCUnit {
public:
    ElasticatSlicer() {
        for (int v = 0; v < 2; ++v) { voice[v].state = SV_DONE; voice[v].env = 0.f; }
        active = 0; prevIdx = -1;
        set_calc_function<ElasticatSlicer, &ElasticatSlicer::next>();
        next(1);
    }
private:
    SVoice voice[2];
    int active, prevIdx;

    void next(int nSamples) {
        World *w = mWorld;
        uint32 bnL = (uint32)in0(0); if (bnL >= w->mNumSndBufs) bnL = 0;
        uint32 bnR = (uint32)in0(1); if (bnR >= w->mNumSndBufs) bnR = 0;
        const SndBuf *bL = w->mSndBufs + bnL;
        const SndBuf *bR = w->mSndBufs + bnR;
        float *outL = out(0);
        float *outR = out(1);
        int fL = bL->frames, fR = bR->frames;
        int frames = fL < fR ? fL : fR;
        if (bL->data == nullptr || bR->data == nullptr || frames < 4) {
            for (int i = 0; i < nSamples; ++i) { outL[i] = 0.f; outR[i] = 0.f; }
            for (int v = 0; v < 2; ++v) voice[v].state = SV_DONE;
            return;
        }
        bool mono = (bnL == bnR);

        const float *sph = in(2);
        double startFrac = (double)in0(3);
        double endFrac = (double)in0(4); if (endFrac < startFrac + 1e-6) endFrac = startFrac + 1e-6;
        int nSlices = (int)(in0(5) + 0.5f); if (nSlices < 1) nSlices = 1; if (nSlices > 256) nSlices = 256;
        double atkInc = 1.0 / ((double)in0(6) > 1.0 ? (double)in0(6) : 1.0);
        double relInc = 1.0 / ((double)in0(7) > 1.0 ? (double)in0(7) : 1.0);
        double gate = (double)in0(8); if (gate < 0.0) gate = 0.0; else if (gate > 1.0) gate = 1.0;
        double sliceDur = (double)in0(9); if (sliceDur < 1.0) sliceDur = 1.0;
        int loopMode = (int)(in0(10) + 0.5f);
        bool srev = (in0(11) > 0.5f);
        double pitchRate = (double)in0(12); if (pitchRate < 0.0) pitchRate = 0.0;

        double gateClose = gate * sliceDur;
        double regFrac = endFrac - startFrac;
        double fmax = (double)(frames - 1);

        for (int i = 0; i < nSamples; ++i) {
            double sp = (double)sph[i];
            if (sp < 0.0) sp = 0.0; else if (sp > 0.999999) sp = 0.999999;
            int idx = (int)(sp * (double)nSlices);
            if (idx < 0) idx = 0; else if (idx >= nSlices) idx = nSlices - 1;

            if (idx != prevIdx) {
                // slice change: displace the active head (-> RELEASE, no hard cut) + start a new head
                if (voice[active].state != SV_DONE) voice[active].state = SV_RELEASE;
                int nv = active ^ 1;
                SVoice &v = voice[nv];
                v.lo = (startFrac + ((double)idx / (double)nSlices) * regFrac) * fmax;
                v.hi = (startFrac + ((double)(idx + 1) / (double)nSlices) * regFrac) * fmax;
                v.dir = srev ? -1 : 1;
                v.pos = srev ? v.hi : v.lo;
                v.env = 0.f; v.state = SV_ATTACK; v.sinceTrig = 0.0;
                active = nv; prevIdx = idx;
            }

            float mixL = 0.f, mixR = 0.f;
            for (int vi = 0; vi < 2; ++vi) {
                SVoice &v = voice[vi];
                if (v.state == SV_DONE) continue;
                double rp = v.pos; if (rp < 0.0) rp = 0.0; else if (rp > fmax) rp = fmax;
                if (mono) {
                    float s = egPeek(bL, fL, rp) * v.env; mixL += s; mixR += s;
                } else {
                    mixL += egPeek(bL, fL, rp) * v.env;
                    mixR += egPeek(bR, fR, rp) * v.env;
                }
                v.pos += pitchRate * (double)v.dir;
                if (loopMode == 0) {                 // chop: hold at the slice bound
                    if (v.pos >= v.hi) v.pos = v.hi; else if (v.pos <= v.lo) v.pos = v.lo;
                } else if (loopMode == 1) {           // loop: wrap within the slice
                    double sw = v.hi - v.lo; if (sw < 1.0) sw = 1.0;
                    if (v.pos >= v.hi) v.pos -= sw; else if (v.pos < v.lo) v.pos += sw;
                } else if (loopMode == 2) {           // pingpong: reflect
                    if (v.pos >= v.hi) { v.pos = v.hi; v.dir = -1; }
                    else if (v.pos <= v.lo) { v.pos = v.lo; v.dir = 1; }
                }                                     // loopMode 3 runaway: no slice bound (clamped to buffer above)
                v.sinceTrig += 1.0;
                if (v.state == SV_ATTACK) { v.env += (float)atkInc; if (v.env >= 1.f) { v.env = 1.f; v.state = SV_HOLD; } }
                else if (v.state == SV_HOLD) { if (v.sinceTrig >= gateClose) v.state = SV_RELEASE; }
                else if (v.state == SV_RELEASE) { v.env -= (float)relInc; if (v.env <= 0.f) { v.env = 0.f; v.state = SV_DONE; } }
            }
            outL[i] = mixL; outR[i] = mixR;
        }
    }
};

// ---------------------------------------------------------------------------
// ElasticatWavetable -- a wavetable-scanning oscillator with CLICK-FREE region
// (loop start/end) changes and an AUDIO-RATE morph LFO.
//
// The region [startFrac,endFrac] is treated as a bank of numSlices single-cycle
// wavetable frames, each cycleLen buffer-samples wide, spread evenly across the
// region. `morph` (0..1, plus the internal LFO) scans the bank, crossfading the
// two adjacent frames. Each frame is read as a TWO-GRAIN, half-cycle-overlapped
// oscillator with a unity-gain sin^2/cos^2 window, so the single-cycle loop is
// click-free. freq sets the oscillator pitch; the read stays inside the region.
//
// The old SynthDef clicked when you scrubbed loop start/end because the frame
// read positions jump. Here the region is DOUBLE-BUFFERED with ONE queued equal-
// power crossfade (the softcut / ElasticatReader model): on a region change the
// old region fades out over xfadeSamp while the new region fades in, and a change
// that arrives mid-fade is queued until the current fade finishes -> no pile-up,
// no click. Steady state (no change) reads a single region (1x cost).
//
// The LFO runs on an internal per-sample phasor, so it reaches AUDIO RATES (FM/AM
// of the morph) even though lfoRate is a control input. Unipolar 0..1 * lfoDepth
// (signed) is added to morph, matching the old kr LFO's 64=off convention which
// the SynthDef pre-scales into lfoDepth.
//
// ar inputs:  bufL bufR startFrac endFrac numSlices cycleLen morph freq(Hz)
//             lfoRate(Hz) lfoDepth(signed) lfoShape(0 sin 1 tri 2 saw 3 s&h
//             4 rand) xfadeSamp
// ar outputs: [L, R]
// ---------------------------------------------------------------------------
enum { WT_STOP = 0, WT_FADEIN = 1, WT_FADEOUT = 2, WT_PLAY = 3 };

struct ElasticatWavetable : public SCUnit {
public:
    ElasticatWavetable() {
        rngState = 0x1B873593u ^ (uint32)(size_t)this;
        oscPhase = 0.0; lfoPhase = 0.0;
        lfoCur = frand() * 0.5f + 0.5f; lfoNext = frand() * 0.5f + 0.5f;
        for (int h = 0; h < 2; ++h) { rStart[h] = 0.0; rLen[h] = 8.0; fade[h] = 0.f; state[h] = WT_STOP; }
        active = 0; committed = false;
        queuedStart = 0.0; queuedLen = 8.0; queued = false;
        set_calc_function<ElasticatWavetable, &ElasticatWavetable::next>();
        next(1);
    }
private:
    uint32 rngState;
    double oscPhase;            // [0,1) oscillator cycle phase
    double lfoPhase;           // [0,1) LFO phase
    float lfoCur, lfoNext;     // S&H holds lfoCur; smooth-rand lerps lfoCur->lfoNext
    double rStart[2], rLen[2]; // per-head region snapshot (frames)
    float fade[2];             // 0..1 linear; equal-power (sine) at mix
    int state[2];
    int active;
    bool committed;
    double queuedStart, queuedLen;
    bool queued;

    inline float frand() {  // xorshift32 -> [-1,1)
        rngState ^= rngState << 13; rngState ^= rngState >> 17; rngState ^= rngState << 5;
        return ((float)(rngState & 0xFFFFFFu) / (float)0x800000) - 1.f;
    }

    // One channel of the wavetable read for a region snapshot.
    static inline float readRegion(const SndBuf *b, int frames, double regStart, double regLen,
                                   int slices, double cycleLen, double morphPos, double oscPhase01) {
        if (cycleLen > regLen) cycleLen = regLen;
        if (cycleLen < 4.0) cycleLen = 4.0;
        int div = (slices - 1) > 0 ? (slices - 1) : 1;
        double step = (regLen - cycleLen) / (double)div; if (step < 0.0) step = 0.0;
        double sliceF = morphPos * (double)(slices - 1); if (sliceF < 0.0) sliceF = 0.0;
        int si = (int)sliceF; if (si > slices - 1) si = slices - 1;
        double frac = sliceF - (double)si;
        int si2 = si + 1; if (si2 > slices - 1) si2 = slices - 1;
        double startA = regStart + (double)si * step;
        double startB = regStart + (double)si2 * step;
        double ph = oscPhase01 * cycleLen;
        double p2ph = oscPhase01 + 0.5; if (p2ph >= 1.0) p2ph -= 1.0;
        double p2 = p2ph * cycleLen;
        float sp = sinf((float)(oscPhase01 * M_PI));
        float w1 = sp * sp;          // sin^2(phase*pi)
        float w2 = 1.f - w1;         // cos^2(phase*pi) = sin^2((phase+0.5)*pi) -- unity sum
        float fA = egPeek(b, frames, startA + ph) * w1 + egPeek(b, frames, startA + p2) * w2;
        float fB = egPeek(b, frames, startB + ph) * w1 + egPeek(b, frames, startB + p2) * w2;
        return fA * (float)(1.0 - frac) + fB * (float)frac;
    }

    void startXfade(double newStart, double newLen) {
        int nv = active ^ 1;
        if (state[active] != WT_STOP) state[active] = WT_FADEOUT;
        rStart[nv] = newStart; rLen[nv] = newLen;
        fade[nv] = 0.f; state[nv] = WT_FADEIN;
        active = nv;
    }

    void next(int nSamples) {
        World *w = mWorld;
        uint32 bnL = (uint32)in0(0); if (bnL >= w->mNumSndBufs) bnL = 0;
        uint32 bnR = (uint32)in0(1); if (bnR >= w->mNumSndBufs) bnR = 0;
        const SndBuf *bL = w->mSndBufs + bnL;
        const SndBuf *bR = w->mSndBufs + bnR;
        int fL = bL->frames, fR = bR->frames;
        int frames = fL < fR ? fL : fR;
        float *outL = out(0);
        float *outR = out(1);
        if (bL->data == nullptr || bR->data == nullptr || frames < 4) {
            for (int i = 0; i < nSamples; ++i) { outL[i] = 0.f; outR[i] = 0.f; }
            return;
        }
        bool mono = (bnL == bnR);

        double startFrac = (double)in0(2); if (startFrac < 0.0) startFrac = 0.0; else if (startFrac > 1.0) startFrac = 1.0;
        double endFrac = (double)in0(3); if (endFrac < 0.0) endFrac = 0.0; else if (endFrac > 1.0) endFrac = 1.0;
        if (endFrac < startFrac + 1e-4) endFrac = startFrac + 1e-4;
        int slices = (int)(in0(4) + 0.5f); if (slices < 2) slices = 2; if (slices > 64) slices = 64;
        double cycleLen = (double)in0(5); if (cycleLen < 4.0) cycleLen = 4.0; if (cycleLen > 8192.0) cycleLen = 8192.0;
        double morph = (double)in0(6);
        double freq = (double)in0(7); if (freq < 0.0) freq = 0.0;
        double lfoRate = (double)in0(8); if (lfoRate < 0.0) lfoRate = 0.0;
        double lfoDepth = (double)in0(9);
        int lfoShape = (int)(in0(10) + 0.5f); if (lfoShape < 0) lfoShape = 0; if (lfoShape > 4) lfoShape = 4;
        double xfadeSamp = (double)in0(11); if (xfadeSamp < 1.0) xfadeSamp = 1.0;

        double sr = (double)sampleRate();
        double fmax = (double)(frames - 1);
        double tgtStart = startFrac * fmax;
        double tgtLen = (endFrac - startFrac) * fmax; if (tgtLen < 8.0) tgtLen = 8.0;

        if (!committed) {
            rStart[active] = tgtStart; rLen[active] = tgtLen;
            fade[active] = 1.f; state[active] = WT_PLAY;
            committed = true;
        }

        // Region change -> queued equal-power crossfade. start/end are control-rate,
        // so this is evaluated once per block.
        bool fading = (state[0] == WT_FADEIN || state[0] == WT_FADEOUT ||
                       state[1] == WT_FADEIN || state[1] == WT_FADEOUT);
        bool changed = (fabs(tgtStart - rStart[active]) > 1.0 || fabs(tgtLen - rLen[active]) > 1.0);
        if (changed) {
            if (fading) { queuedStart = tgtStart; queuedLen = tgtLen; queued = true; }
            else startXfade(tgtStart, tgtLen);
        }

        double oscInc = freq / sr;
        double lfoInc = lfoRate / sr;
        float fadeInc = (float)(1.0 / xfadeSamp);

        for (int i = 0; i < nSamples; ++i) {
            // --- LFO (audio-rate capable) -> unipolar 0..1 ---
            lfoPhase += lfoInc;
            if (lfoPhase >= 1.0) {
                lfoPhase -= 1.0; if (lfoPhase >= 1.0) lfoPhase = 0.0;
                lfoCur = lfoNext; lfoNext = frand() * 0.5f + 0.5f;
            }
            float raw;
            switch (lfoShape) {
                case 0: raw = 0.5f + 0.5f * sinf((float)(lfoPhase * 2.0 * M_PI)); break;
                case 1: raw = 1.f - fabsf((float)(2.0 * lfoPhase - 1.0)); break;
                case 2: raw = (float)lfoPhase; break;
                case 3: raw = lfoCur; break;
                default: raw = lfoCur + (lfoNext - lfoCur) * (float)lfoPhase; break;
            }
            double morphPos = morph + (double)raw * lfoDepth;
            if (morphPos < 0.0) morphPos = 0.0; else if (morphPos > 1.0) morphPos = 1.0;

            // --- read + equal-power mix of the active region head(s) ---
            float mixL = 0.f, mixR = 0.f;
            for (int h = 0; h < 2; ++h) {
                if (state[h] == WT_STOP) continue;
                float g = sinf(fade[h] * kHalfPi);
                if (mono) {
                    float s = readRegion(bL, fL, rStart[h], rLen[h], slices, cycleLen, morphPos, oscPhase);
                    mixL += s * g; mixR += s * g;
                } else {
                    mixL += readRegion(bL, fL, rStart[h], rLen[h], slices, cycleLen, morphPos, oscPhase) * g;
                    mixR += readRegion(bR, fR, rStart[h], rLen[h], slices, cycleLen, morphPos, oscPhase) * g;
                }
            }
            outL[i] = mixL; outR[i] = mixR;

            // --- advance oscillator phase ---
            oscPhase += oscInc;
            while (oscPhase >= 1.0) oscPhase -= 1.0;
            if (oscPhase < 0.0) oscPhase = 0.0;

            // --- ramp fades; consume the queued region when a fade completes ---
            for (int h = 0; h < 2; ++h) {
                if (state[h] == WT_FADEIN) { fade[h] += fadeInc; if (fade[h] >= 1.f) { fade[h] = 1.f; state[h] = WT_PLAY; } }
                else if (state[h] == WT_FADEOUT) { fade[h] -= fadeInc; if (fade[h] <= 0.f) { fade[h] = 0.f; state[h] = WT_STOP; } }
            }
            bool nowFading = (state[0] == WT_FADEIN || state[0] == WT_FADEOUT ||
                              state[1] == WT_FADEIN || state[1] == WT_FADEOUT);
            if (!nowFading && queued) {
                queued = false;
                if (fabs(queuedStart - rStart[active]) > 1.0 || fabs(queuedLen - rLen[active]) > 1.0)
                    startXfade(queuedStart, queuedLen);
            }
        }
    }
};

PluginLoad(ElasticatUGens) {
    ft = inTable;
    for (int i = 0; i <= kHannSize; ++i)
        gHann[i] = 0.5f * (1.f - cosf(2.f * (float)M_PI * (float)i / (float)kHannSize));
    registerUnit<ElasticatPassthru>(ft, "ElasticatPassthru", false);
    registerUnit<ElasticatReader>(ft, "ElasticatReader", false);
    registerUnit<ElasticatGrains>(ft, "ElasticatGrains", false);
    registerUnit<ElasticatSlicer>(ft, "ElasticatSlicer", false);
    registerUnit<ElasticatWavetable>(ft, "ElasticatWavetable", false);
}
