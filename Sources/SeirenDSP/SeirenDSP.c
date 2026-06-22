//
//  SeirenDSP.c — see SeirenDSP.h for the contract and rationale.
//

#include "SeirenDSP.h"
#include "rnnoise.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// An immutable, heap-allocated coefficient block. Once published it is never
// mutated; a change means publishing a brand-new block and retiring the old one.
typedef struct {
    int   nSections;
    float c[SEIREN_DSP_MAX_SECTIONS][SEIREN_DSP_COEFFS_PER_SECTION]; // {b0,b1,b2,a1,a2}
} eq_block;

// The live coefficients, swapped atomically. NULL ⇒ EQ disabled (passthrough).
static _Atomic(eq_block *) g_coeffs = NULL;

// The block retired by the *previous* publish. Touched only on the publishing
// (main) thread. Freed on the next publish, by which point the RT thread — which
// reloads g_coeffs every buffer — can no longer be holding it. This deferred
// free is what makes the lock-free swap safe.
static eq_block *g_retired = NULL;

// Per-channel, per-section biquad state (Direct Form II Transposed): z1, z2.
// Owned exclusively by the RT thread (and zeroed by seiren_dsp_reset between
// IO cycles). Fixed storage ⇒ no allocation on the audio thread.
static float g_z[SEIREN_DSP_MAX_CHANNELS][SEIREN_DSP_MAX_SECTIONS][2];

// Anything with magnitude below this in the filter state is flushed to zero to
// dodge subnormal-float CPU spikes during silence.
#define SEIREN_DENORMAL_EPS 1.0e-20f

// --- Noise gate --------------------------------------------------------------
// Params are set off-thread and read on the RT thread. Like gMonitorLevel in the
// app, these are plain scalars: a torn read during the rare reconfigure costs at
// most one slightly-off sample, which is inaudible. `enabled` is written last.
static volatile int   g_gate_enabled = 0;
static volatile float g_gate_thresh  = 0.00316f;  // linear, ≈ -50 dBFS
static float g_gate_open_coef  = 0.0f;            // gain smoothing when opening
static float g_gate_close_coef = 0.0f;            // gain smoothing when closing
static float g_gate_env_rel    = 0.0f;            // detector envelope release
static int   g_gate_hold_samps = 0;
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

// DenoiseState handoff (same deferred-free discipline as the EQ coeffs).
static _Atomic(void *) g_studio_state   = NULL;  // opaque DenoiseState*; NULL = passthrough
static void           *g_studio_retired = NULL;  // freed on the next set_studio call

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

    // Swap the new block in; get the one it replaced.
    eq_block *old = atomic_exchange_explicit(&g_coeffs, nb, memory_order_acq_rel);

    // Free the block retired two publishes ago — the RT thread has long since
    // moved on from it. Then remember `old` as the newly retired block.
    if (g_retired != NULL) {
        free(g_retired);
    }
    g_retired = old;
}

void seiren_dsp_process(float *interleaved, int frames, int channels)
{
    eq_block *b = atomic_load_explicit(&g_coeffs, memory_order_acquire);
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
    eq_block *b = atomic_load_explicit(&g_coeffs, memory_order_acquire);
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

void seiren_dsp_set_studio(int enabled)
{
    void *publish = NULL;
    if (enabled) {
        DenoiseState *st = rnnoise_create(NULL);   // ALLOCATES — caller is off the RT thread
        if (st == NULL) return;                     // leave current state untouched
        // The previous state is NULL here (we only enter studio from off/gate),
        // so the RT thread is in passthrough and not touching the bridge — safe
        // to reset it before publishing the new state.
        memset(g_ds_z, 0, sizeof(g_ds_z));
        memset(g_us_z, 0, sizeof(g_us_z));
        g_in_count = 0; g_out_count = 0; g_studio_primed = 0;
        publish = st;
    }
    void *old = atomic_exchange_explicit(&g_studio_state, publish, memory_order_acq_rel);
    if (g_studio_retired != NULL) {
        rnnoise_destroy((DenoiseState *)g_studio_retired);  // retired one call ago → RT done with it
    }
    g_studio_retired = old;
}

void seiren_dsp_studio_process(float *x, int frames, int rateIs96k)
{
    DenoiseState *st = (DenoiseState *)atomic_load_explicit(&g_studio_state, memory_order_acquire);
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
    g_gate_thresh = powf(10.0f, threshold_db / 20.0f);
    // One-pole smoothing coefficients: gain opens fast (~3 ms), closes gently
    // (~150 ms) to avoid chatter; the detector envelope releases over ~60 ms.
    g_gate_open_coef  = 1.0f - expf(-1.0f / (fs * 0.003f));
    g_gate_close_coef = 1.0f - expf(-1.0f / (fs * 0.150f));
    g_gate_env_rel    = expf(-1.0f / (fs * 0.060f));
    g_gate_hold_samps = (int)(fs * 0.200f);   // hold open 200 ms between words
    g_gate_enabled    = enabled;              // publish last
}

void seiren_dsp_gate(float *x, int frames, int channels)
{
    if (!g_gate_enabled || x == NULL || frames <= 0) return;
    if (channels > SEIREN_DSP_MAX_CHANNELS) channels = SEIREN_DSP_MAX_CHANNELS;
    if (channels <= 0) return;

    const float thresh   = g_gate_thresh;
    const float openCoef = g_gate_open_coef;
    const float closeCoef = g_gate_close_coef;
    const float envRel   = g_gate_env_rel;
    const int   holdN    = g_gate_hold_samps;

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
