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

PluginLoad(ElasticatUGens) {
    ft = inTable;
    for (int i = 0; i <= kHannSize; ++i)
        gHann[i] = 0.5f * (1.f - cosf(2.f * (float)M_PI * (float)i / (float)kHannSize));
    registerUnit<ElasticatPassthru>(ft, "ElasticatPassthru", false);
    registerUnit<ElasticatReader>(ft, "ElasticatReader", false);
    registerUnit<ElasticatGrains>(ft, "ElasticatGrains", false);
}
