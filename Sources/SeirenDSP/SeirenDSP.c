//
//  SeirenDSP.c — see SeirenDSP.h for the contract and rationale.
//

#include "SeirenDSP.h"
#include "rnnoise.h"

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// --- Handoff of heap objects to the audio thread -----------------------------
// The configuring thread publishes immutable heap objects (EQ coefficient
// blocks, RNNoise states) for the one audio thread to use. Each object has
// exactly one owner at a time, and ownership moves only by an atomic exchange
// on `slot`:
//
//   publisher -> `slot`, tagged new -> audio thread (`current`)
//             -> `slot`, untagged   -> publisher
//
// Only the owner reads an object, and the publisher frees one only after taking
// it back out of the slot. The audio thread owns `current` from the exchange
// that took it until the exchange that gives it back, so an object it can still
// reach is never freed, however fast publishes come. The audio thread does at
// most one load and one exchange per call: no lock, allocation, free or retry.
typedef struct {
    // A published object the audio thread has not adopted yet (HANDOFF_NEW set;
    // a NULL pointer then means "turn off"), or the object the audio thread
    // gave back, or 0.
    _Atomic(uintptr_t) slot;
    void *current;  // audio thread only: the object in use; NULL ⇒ off
} rt_handoff;

// Tag in the low bit of `slot`, which heap pointers never use.
#define HANDOFF_NEW ((uintptr_t)1)

// Publisher side: make `next` (NULL ⇒ off) the object the audio thread adopts
// at the start of its next call.
static void handoff_publish(rt_handoff *h, void *next, void (*destroy)(void *))
{
    // What comes back was published and never adopted, or was given back by the
    // audio thread. Either way nothing else can reach it any more.
    uintptr_t old = atomic_exchange(&h->slot, (uintptr_t)next | HANDOFF_NEW);
    void *unreachable = (void *)(old & ~HANDOFF_NEW);
    if (unreachable != NULL) destroy(unreachable);
}

// Audio thread side: make the newly published object, if there is one,
// h->current. Returns nonzero when it adopted one.
static int handoff_adopt(rt_handoff *h)
{
    // Only this thread clears the tag, so once seen it is still set at the
    // exchange, which then takes a published object (the latest one) and leaves
    // the replaced one for the publisher to free.
    if (!(atomic_load(&h->slot) & HANDOFF_NEW)) return 0;
    uintptr_t next = atomic_exchange(&h->slot, (uintptr_t)h->current);
    h->current = (void *)(next & ~HANDOFF_NEW);
    return 1;
}

// An immutable, heap-allocated coefficient block. Once published it is never
// mutated; a change means publishing a brand-new block.
typedef struct {
    int   nSections;
    float c[SEIREN_DSP_MAX_SECTIONS][SEIREN_DSP_COEFFS_PER_SECTION]; // {b0,b1,b2,a1,a2}
} eq_block;

// The coefficient handoff. No current block ⇒ EQ disabled (passthrough).
static rt_handoff g_eq;

// Per-channel, per-section biquad state (Direct Form II Transposed): z1, z2.
// Owned exclusively by the RT thread (and zeroed by seiren_dsp_reset between
// IO cycles). Fixed storage ⇒ no allocation on the audio thread.
static float g_z[SEIREN_DSP_MAX_CHANNELS][SEIREN_DSP_MAX_SECTIONS][2];

// Anything with magnitude below this in the filter state is flushed to zero to
// dodge subnormal-float CPU spikes during silence.
#define SEIREN_DENORMAL_EPS 1.0e-20f

// --- Noise gate --------------------------------------------------------------
// Params are set off-thread and read on the RT thread as independent relaxed
// atomics: a buffer that overlaps a reconfigure may mix old and new values,
// which costs at most one slightly-off buffer and is inaudible. `enabled` is
// written last with release, so the first enable sees a complete set.
static _Atomic(int)   g_gate_enabled    = 0;
static _Atomic(float) g_gate_thresh     = 0.00316f;  // linear, ≈ -50 dBFS
static _Atomic(float) g_gate_open_coef  = 0.0f;      // gain smoothing when opening
static _Atomic(float) g_gate_close_coef = 0.0f;      // gain smoothing when closing
static _Atomic(float) g_gate_env_rel    = 0.0f;      // detector envelope release
static _Atomic(int)   g_gate_hold_samps = 0;
// Per-channel state.
static float g_gate_env[SEIREN_DSP_MAX_CHANNELS]  = {0};
static float g_gate_gain[SEIREN_DSP_MAX_CHANNELS] = {0};
static int   g_gate_hold[SEIREN_DSP_MAX_CHANNELS] = {0};

// --- Studio (RNNoise) -------------------------------------------------------
// 31-tap linear-phase half-band low-pass (Kaiser β=5), used for BOTH 2:1
// decimation (anti-alias) and interpolation (anti-image). Same kernel → equal
// group delay each way, so it cancels over the round trip. DC gain 1.0.
// (Generated offline; see docs/RNNOISE_PLAN.md §2.1.)
#define HB_TAPS 31
static const float HB[HB_TAPS] = {
    -0.00077911f,  0.00000000f,  0.00294493f, -0.00000000f,
    -0.00720442f,  0.00000000f,  0.01467577f, -0.00000000f,
    -0.02725494f,  0.00000000f,  0.04936378f, -0.00000000f,
    -0.09696881f,  0.00000000f,  0.31519626f,  0.50005309f,
     0.31519626f,  0.00000000f, -0.09696881f, -0.00000000f,
     0.04936378f,  0.00000000f, -0.02725494f, -0.00000000f,
     0.01467577f,  0.00000000f, -0.00720442f, -0.00000000f,
     0.00294493f,  0.00000000f, -0.00077911f
};
static float g_ds_z[HB_TAPS] = {0};   // decimator delay line
static float g_us_z[HB_TAPS] = {0};   // interpolator delay line

// RNNoise frame bridge, all in the 48 kHz domain, RT-owned, never allocates.
#define STUDIO_FRAME 480              // RNNoise frame @ 48k (10 ms)
#define STUDIO_RING  (4 * STUDIO_FRAME)  // 1920: headroom for a 96k buffer + a frame
static float g_in_ring[STUDIO_RING];  static int g_in_count  = 0;  // input accumulator
static float g_out_ring[STUDIO_RING]; static int g_out_count = 0;  // processed-output queue
static float g_st_tmp48[STUDIO_RING];                              // scratch (decimated in / drained out)
static float g_st_in[STUDIO_FRAME], g_st_out[STUDIO_FRAME];        // one RNNoise frame, scaled
static int   g_studio_primed = 0;     // drop RNNoise's first (warmup) output frame

// DenoiseState handoff (same as the EQ coeffs). No current state ⇒ passthrough.
static rt_handoff g_studio;

void seiren_dsp_publish(const float *coeffs, int nSections)
{
    eq_block *nb = NULL;

    if (coeffs != NULL && nSections > 0) {
        if (nSections > SEIREN_DSP_MAX_SECTIONS) {
            nSections = SEIREN_DSP_MAX_SECTIONS;
        }
        nb = (eq_block *)malloc(sizeof(eq_block));
        if (nb == NULL) {
            return; // out of memory: leave the current EQ in place
        }
        memset(nb, 0, sizeof(*nb));
        nb->nSections = nSections;
        for (int i = 0; i < nSections; i++) {
            for (int k = 0; k < SEIREN_DSP_COEFFS_PER_SECTION; k++) {
                nb->c[i][k] = coeffs[i * SEIREN_DSP_COEFFS_PER_SECTION + k];
            }
        }
    }

    handoff_publish(&g_eq, nb, free);
}

void seiren_dsp_process(float *interleaved, int frames, int channels)
{
    handoff_adopt(&g_eq);
    const eq_block *b = g_eq.current;
    if (b == NULL || b->nSections <= 0 || interleaved == NULL || frames <= 0) {
        return; // EQ disabled → passthrough
    }
    if (channels > SEIREN_DSP_MAX_CHANNELS) channels = SEIREN_DSP_MAX_CHANNELS;
    if (channels <= 0) return;

    const int ns = b->nSections;

    for (int f = 0; f < frames; f++) {
        for (int c = 0; c < channels; c++) {
            float s = interleaved[f * channels + c];

            for (int i = 0; i < ns; i++) {
                const float b0 = b->c[i][0];
                const float b1 = b->c[i][1];
                const float b2 = b->c[i][2];
                const float a1 = b->c[i][3];
                const float a2 = b->c[i][4];

                float z1 = g_z[c][i][0];
                float z2 = g_z[c][i][1];

                // Direct Form II Transposed.
                const float y = b0 * s + z1;
                z1 = b1 * s - a1 * y + z2;
                z2 = b2 * s - a2 * y;

                // Flush denormal state to zero (silence CPU-spike guard).
                if (z1 < SEIREN_DENORMAL_EPS && z1 > -SEIREN_DENORMAL_EPS) z1 = 0.0f;
                if (z2 < SEIREN_DENORMAL_EPS && z2 > -SEIREN_DENORMAL_EPS) z2 = 0.0f;

                g_z[c][i][0] = z1;
                g_z[c][i][1] = z2;
                s = y;
            }

            // Post-EQ clamp: a boost must never hard-clip past full scale.
            if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
            interleaved[f * channels + c] = s;
        }
    }
}

void seiren_dsp_process_mono(float *x, int frames, int stateIndex)
{
    handoff_adopt(&g_eq);
    const eq_block *b = g_eq.current;
    if (b == NULL || b->nSections <= 0 || x == NULL || frames <= 0) return;
    if (stateIndex < 0 || stateIndex >= SEIREN_DSP_MAX_CHANNELS) stateIndex = 0;

    const int ns = b->nSections;
    for (int f = 0; f < frames; f++) {
        float s = x[f];
        for (int i = 0; i < ns; i++) {
            const float b0 = b->c[i][0];
            const float b1 = b->c[i][1];
            const float b2 = b->c[i][2];
            const float a1 = b->c[i][3];
            const float a2 = b->c[i][4];

            float z1 = g_z[stateIndex][i][0];
            float z2 = g_z[stateIndex][i][1];

            const float y = b0 * s + z1;
            z1 = b1 * s - a1 * y + z2;
            z2 = b2 * s - a2 * y;

            if (z1 < SEIREN_DENORMAL_EPS && z1 > -SEIREN_DENORMAL_EPS) z1 = 0.0f;
            if (z2 < SEIREN_DENORMAL_EPS && z2 > -SEIREN_DENORMAL_EPS) z2 = 0.0f;

            g_z[stateIndex][i][0] = z1;
            g_z[stateIndex][i][1] = z2;
            s = y;
        }
        if (s > 1.0f) s = 1.0f; else if (s < -1.0f) s = -1.0f;
        x[f] = s;
    }
}

void seiren_dsp_reset(void)
{
    memset(g_z, 0, sizeof(g_z));
    memset(g_gate_env, 0, sizeof(g_gate_env));
    memset(g_gate_gain, 0, sizeof(g_gate_gain));
    memset(g_gate_hold, 0, sizeof(g_gate_hold));
    // Studio bridge + resampler delay lines (not the RNNoise state itself).
    memset(g_ds_z, 0, sizeof(g_ds_z));
    memset(g_us_z, 0, sizeof(g_us_z));
    g_in_count = 0;
    g_out_count = 0;
    g_studio_primed = 0;
}

// --- 2:1 half-band resamplers (mono, RT-safe; delay lines cleared by reset) --

void seiren_dsp_downsample2(const float *in, float *out, int outFrames)
{
    int idx = 0;
    for (int k = 0; k < outFrames; k++) {
        // Shift in two new input samples, emit one filtered output (decimate).
        for (int t = 0; t < 2; t++) {
            memmove(&g_ds_z[1], &g_ds_z[0], (HB_TAPS - 1) * sizeof(float));
            g_ds_z[0] = in[idx++];
        }
        float acc = 0.0f;
        for (int i = 0; i < HB_TAPS; i++) acc += HB[i] * g_ds_z[i];
        out[k] = acc;
    }
}

void seiren_dsp_upsample2(const float *in, float *out, int inFrames)
{
    int o = 0;
    for (int k = 0; k < inFrames; k++) {
        // Phase 0: real sample. (×2 restores energy lost to zero-stuffing.)
        memmove(&g_us_z[1], &g_us_z[0], (HB_TAPS - 1) * sizeof(float));
        g_us_z[0] = in[k];
        float a0 = 0.0f;
        for (int i = 0; i < HB_TAPS; i++) a0 += HB[i] * g_us_z[i];
        out[o++] = 2.0f * a0;
        // Phase 1: zero sample.
        memmove(&g_us_z[1], &g_us_z[0], (HB_TAPS - 1) * sizeof(float));
        g_us_z[0] = 0.0f;
        float a1 = 0.0f;
        for (int i = 0; i < HB_TAPS; i++) a1 += HB[i] * g_us_z[i];
        out[o++] = 2.0f * a1;
    }
}

// --- Studio (RNNoise) -------------------------------------------------------

static void studio_destroy(void *st) { rnnoise_destroy((DenoiseState *)st); }

void seiren_dsp_set_studio(int enabled)
{
    void *publish = NULL;
    if (enabled) {
        DenoiseState *st = rnnoise_create(NULL);   // ALLOCATES — caller is off the RT thread
        if (st == NULL) return;                     // leave current state untouched
        publish = st;
    }
    handoff_publish(&g_studio, publish, studio_destroy);
}

void seiren_dsp_studio_process(float *x, int frames, int rateIs96k)
{
    // A new state starts from an empty frame bridge and resampler history.
    // Both belong to this thread, so it clears them as it adopts the state.
    if (handoff_adopt(&g_studio) && g_studio.current != NULL) {
        memset(g_ds_z, 0, sizeof(g_ds_z));
        memset(g_us_z, 0, sizeof(g_us_z));
        g_in_count = 0; g_out_count = 0; g_studio_primed = 0;
    }
    DenoiseState *st = (DenoiseState *)g_studio.current;
    if (st == NULL || x == NULL || frames <= 0) return;        // disabled → passthrough
    if (rateIs96k && (frames & 1)) return;                     // need even count to halve

    // 1. Push input into the 48 kHz accumulator (decimate first at 96 kHz).
    int n48;
    const float *push;
    if (rateIs96k) {
        n48 = frames / 2;
        if (n48 > STUDIO_RING) return;
        seiren_dsp_downsample2(x, g_st_tmp48, n48);
        push = g_st_tmp48;
    } else {
        n48 = frames;
        if (n48 > STUDIO_RING) return;
        push = x;
    }
    if (g_in_count + n48 > STUDIO_RING) { g_in_count = 0; return; }  // overflow guard (shouldn't happen)
    for (int i = 0; i < n48; i++) g_in_ring[g_in_count + i] = push[i];
    g_in_count += n48;

    // 2. Process every complete 480-sample frame (scale to ±32768 around RNNoise).
    while (g_in_count >= STUDIO_FRAME) {
        for (int i = 0; i < STUDIO_FRAME; i++) g_st_in[i] = g_in_ring[i] * 32768.0f;
        rnnoise_process_frame(st, g_st_out, g_st_in);
        for (int i = 0; i < STUDIO_FRAME; i++) g_st_out[i] *= (1.0f / 32768.0f);
        memmove(g_in_ring, g_in_ring + STUDIO_FRAME, (g_in_count - STUDIO_FRAME) * sizeof(float));
        g_in_count -= STUDIO_FRAME;
        if (!g_studio_primed) { g_studio_primed = 1; continue; }  // drop the warmup frame
        if (g_out_count + STUDIO_FRAME <= STUDIO_RING) {
            for (int i = 0; i < STUDIO_FRAME; i++) g_out_ring[g_out_count + i] = g_st_out[i];
            g_out_count += STUDIO_FRAME;
        }
    }

    // 3. Drain n48 processed samples (zero-fill only during startup priming).
    if (g_out_count >= n48) {
        for (int i = 0; i < n48; i++) g_st_tmp48[i] = g_out_ring[i];
        memmove(g_out_ring, g_out_ring + n48, (g_out_count - n48) * sizeof(float));
        g_out_count -= n48;
    } else {
        for (int i = 0; i < n48; i++) g_st_tmp48[i] = 0.0f;
    }

    // 4. Write back to x (interpolate to 96 kHz if needed).
    if (rateIs96k) {
        seiren_dsp_upsample2(g_st_tmp48, x, n48);   // writes 2*n48 == frames
    } else {
        for (int i = 0; i < n48; i++) x[i] = g_st_tmp48[i];
    }
}

void seiren_dsp_set_gate(int enabled, float threshold_db, float sample_rate)
{
    float fs = (sample_rate > 0.0f) ? sample_rate : 48000.0f;
    atomic_store_explicit(&g_gate_thresh, powf(10.0f, threshold_db / 20.0f), memory_order_relaxed);
    // One-pole smoothing coefficients: gain opens fast (~3 ms), closes gently
    // (~150 ms) to avoid chatter; the detector envelope releases over ~60 ms.
    atomic_store_explicit(&g_gate_open_coef, 1.0f - expf(-1.0f / (fs * 0.003f)), memory_order_relaxed);
    atomic_store_explicit(&g_gate_close_coef, 1.0f - expf(-1.0f / (fs * 0.150f)), memory_order_relaxed);
    atomic_store_explicit(&g_gate_env_rel, expf(-1.0f / (fs * 0.060f)), memory_order_relaxed);
    atomic_store_explicit(&g_gate_hold_samps, (int)(fs * 0.200f), memory_order_relaxed);
    atomic_store_explicit(&g_gate_enabled, enabled, memory_order_release); // publish last
}

void seiren_dsp_gate(float *x, int frames, int channels)
{
    if (!atomic_load_explicit(&g_gate_enabled, memory_order_acquire) || x == NULL || frames <= 0) return;
    if (channels > SEIREN_DSP_MAX_CHANNELS) channels = SEIREN_DSP_MAX_CHANNELS;
    if (channels <= 0) return;

    const float thresh    = atomic_load_explicit(&g_gate_thresh, memory_order_relaxed);
    const float openCoef  = atomic_load_explicit(&g_gate_open_coef, memory_order_relaxed);
    const float closeCoef = atomic_load_explicit(&g_gate_close_coef, memory_order_relaxed);
    const float envRel    = atomic_load_explicit(&g_gate_env_rel, memory_order_relaxed);
    const int   holdN     = atomic_load_explicit(&g_gate_hold_samps, memory_order_relaxed);

    for (int f = 0; f < frames; f++) {
        for (int c = 0; c < channels; c++) {
            const float s = x[f * channels + c];
            const float a = fabsf(s);

            // Detector envelope: instant attack, smooth release.
            float env = g_gate_env[c];
            env = (a > env) ? a : (a + (env - a) * envRel);
            g_gate_env[c] = env;

            // Target gain: open above threshold; hold open briefly after.
            float target;
            if (env >= thresh) { g_gate_hold[c] = holdN; target = 1.0f; }
            else if (g_gate_hold[c] > 0) { g_gate_hold[c]--; target = 1.0f; }
            else { target = 0.0f; }

            float g = g_gate_gain[c];
            g += (target > g ? openCoef : closeCoef) * (target - g);
            g_gate_gain[c] = g;

            x[f * channels + c] = s * g;
        }
    }
}

// --- Stream mixer ------------------------------------------------------------

_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 &&
               __atomic_always_lock_free(sizeof(float), 0),
               "Mixer atomics must be lock-free on the audio thread");

struct SeirenMixer {
    int inputChannels[SEIREN_MIXER_MAX_INPUTS];
    int mixOutput;
    _Atomic(float) targets[SEIREN_MIXER_MAX_CHANNELS];
    float previous[SEIREN_MIXER_MAX_CHANNELS];
    float limiterGain, release;
    _Atomic(uint64_t) callbacks;
    _Atomic(uint32_t) inputBuffers, outputBuffers;
    _Atomic(float) inputPeaks[SEIREN_MIXER_MAX_INPUTS];
    _Atomic(float) channelPeaks[SEIREN_MIXER_MAX_CHANNELS];
    _Atomic(float) outputPeak;
};

SeirenMixer *seiren_mixer_create(double sampleRate, int mixOutput) {
    SeirenMixer *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    for (int i = 0; i < SEIREN_MIXER_MAX_INPUTS; ++i) {
        m->inputChannels[i] = -1;
        atomic_init(&m->inputPeaks[i], 0);
    }
    for (int i = 0; i < SEIREN_MIXER_MAX_CHANNELS; ++i) {
        atomic_init(&m->targets[i], 0);
        atomic_init(&m->channelPeaks[i], 0);
    }
    atomic_init(&m->callbacks, 0);
    atomic_init(&m->inputBuffers, 0);
    atomic_init(&m->outputBuffers, 0);
    atomic_init(&m->outputPeak, 0);
    m->mixOutput = mixOutput;
    m->limiterGain = 1;
    m->release = expf(-1.0f / (0.120f * (float)(sampleRate > 0 ? sampleRate : 48000)));
    return m;
}

void seiren_mixer_destroy(SeirenMixer *m) { free(m); }

void seiren_mixer_map_input(SeirenMixer *m, int input, int channel) {
    if (m && input >= 0 && input < SEIREN_MIXER_MAX_INPUTS &&
        channel >= 0 && channel < SEIREN_MIXER_MAX_CHANNELS)
        m->inputChannels[input] = channel;
}

void seiren_mixer_set_gain(SeirenMixer *m, int channel, float gain) {
    if (!m || channel < 0 || channel >= SEIREN_MIXER_MAX_CHANNELS) return;
    if (!isfinite(gain)) gain = 0;
    atomic_store_explicit(&m->targets[channel], fminf(1, fmaxf(0, gain)), memory_order_relaxed);
}

static void mixer_peak(_Atomic(float) *stored, float value) {
    // Only the RT proc writes diagnostics, so no compare-exchange loop needed.
    if (value > atomic_load_explicit(stored, memory_order_relaxed))
        atomic_store_explicit(stored, value, memory_order_relaxed);
}

void seiren_mixer_process(SeirenMixer *m, const AudioBufferList *input, AudioBufferList *output) {
    if (!m || !input || !output) return;
    atomic_fetch_add_explicit(&m->callbacks, 1, memory_order_relaxed);
    atomic_store_explicit(&m->inputBuffers, input->mNumberBuffers, memory_order_relaxed);
    atomic_store_explicit(&m->outputBuffers, output->mNumberBuffers, memory_order_relaxed);
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData)
            memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);

    // Meter all observed inputs, even the explicitly ignored loopback buffer.
    UInt32 inputs = input->mNumberBuffers < SEIREN_MIXER_MAX_INPUTS
        ? input->mNumberBuffers : SEIREN_MIXER_MAX_INPUTS;
    for (UInt32 b = 0; b < inputs; ++b) {
        const AudioBuffer *in = &input->mBuffers[b];
        if (!in->mData) continue;
        const float *samples = in->mData;
        float peak = 0;
        for (UInt32 i = 0; i < in->mDataByteSize / sizeof(float); ++i)
            if (isfinite(samples[i])) peak = fmaxf(peak, fabsf(samples[i]));
        mixer_peak(&m->inputPeaks[b], peak);
        int channel = m->inputChannels[b];
        if (channel >= 0) mixer_peak(&m->channelPeaks[channel], peak);
    }
    if (m->mixOutput < 0 || (UInt32)m->mixOutput >= output->mNumberBuffers) return;
    AudioBuffer *out = &output->mBuffers[m->mixOutput];
    if (!out->mData || out->mNumberChannels == 0) return;
    UInt32 frames = out->mDataByteSize / (sizeof(float) * out->mNumberChannels);
    if (!frames) return;
    float targets[SEIREN_MIXER_MAX_CHANNELS];
    for (int c = 0; c < SEIREN_MIXER_MAX_CHANNELS; ++c)
        targets[c] = atomic_load_explicit(&m->targets[c], memory_order_relaxed);
    float *dest = out->mData;
    const float ceiling = 0.891250938f; // -1 dBFS
    float outputPeak = 0;
    for (UInt32 f = 0; f < frames; ++f) {
        float left = 0, right = 0;
        float progress = (float)(f + 1) / (float)frames;
        for (UInt32 b = 0; b < inputs; ++b) {
            int c = m->inputChannels[b];
            const AudioBuffer *in = &input->mBuffers[b];
            if (c < 0 || !in->mData || !in->mNumberChannels) continue;
            UInt32 channels = in->mNumberChannels;
            if (f >= in->mDataByteSize / (sizeof(float) * channels)) continue;
            const float *src = in->mData;
            float gain = m->previous[c] + (targets[c] - m->previous[c]) * progress;
            float l = src[f * channels], r = src[f * channels + (channels > 1 ? 1 : 0)];
            left += (isfinite(l) ? l : 0) * gain;
            right += (isfinite(r) ? r : 0) * gain;
        }
        float peak = fmaxf(fabsf(left), fabsf(right));
        float required = peak > ceiling ? ceiling / peak : 1;
        m->limiterGain = fminf(required, 1 - (1 - m->limiterGain) * m->release);
        left *= m->limiterGain; right *= m->limiterGain;
        // Clamp rounding at the ceiling without changing the linked gain.
        left = fmaxf(-ceiling, fminf(ceiling, left));
        right = fmaxf(-ceiling, fminf(ceiling, right));
        dest[f * out->mNumberChannels] = left;
        if (out->mNumberChannels > 1) dest[f * out->mNumberChannels + 1] = right;
        outputPeak = fmaxf(outputPeak, fmaxf(fabsf(left), fabsf(right)));
    }
    for (int c = 0; c < SEIREN_MIXER_MAX_CHANNELS; ++c) m->previous[c] = targets[c];
    mixer_peak(&m->outputPeak, outputPeak);
}

OSStatus seiren_mixer_io_proc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData) {
    seiren_mixer_process(clientData, input, output);
    return noErr;
}

AudioDeviceIOProc seiren_mixer_proc(void) { return seiren_mixer_io_proc; }

uint64_t seiren_mixer_callbacks(const SeirenMixer *m) {
    return m ? atomic_load_explicit(&m->callbacks, memory_order_relaxed) : 0;
}
uint32_t seiren_mixer_input_buffers(const SeirenMixer *m) {
    return m ? atomic_load_explicit(&m->inputBuffers, memory_order_relaxed) : 0;
}
uint32_t seiren_mixer_output_buffers(const SeirenMixer *m) {
    return m ? atomic_load_explicit(&m->outputBuffers, memory_order_relaxed) : 0;
}
float seiren_mixer_input_peak(const SeirenMixer *m, int input) {
    return m && input >= 0 && input < SEIREN_MIXER_MAX_INPUTS
        ? atomic_load_explicit(&m->inputPeaks[input], memory_order_relaxed) : 0;
}
float seiren_mixer_channel_peak(const SeirenMixer *m, int channel) {
    return m && channel >= 0 && channel < SEIREN_MIXER_MAX_CHANNELS
        ? atomic_load_explicit(&m->channelPeaks[channel], memory_order_relaxed) : 0;
}
float seiren_mixer_output_peak(const SeirenMixer *m) {
    return m ? atomic_load_explicit(&m->outputPeak, memory_order_relaxed) : 0;
}
