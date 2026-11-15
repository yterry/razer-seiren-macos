//
//  SeirenDSP.h
//  Real-time-safe audio DSP primitives for seiren-mac, written in C.
//
//  WHY C: the processing functions run on Core Audio's real-time IOProc thread,
//  where the Swift/ObjC runtimes are forbidden (no ARC, no witness tables, no
//  allocation, no locks). Doing the per-sample math and the coefficient handoff
//  in C makes that guarantee structural rather than hopeful — there is simply no
//  Swift object to touch. Swift computes the filter coefficients off-thread and
//  publishes them here; the IOProc calls seiren_dsp_process().
//
//  The coefficient handoff is lock-free: a new immutable coefficient block is
//  published with a C11 atomic store-release; the RT thread loads it with
//  acquire ordering. The old block is freed one publish later ("deferred free")
//  so the RT thread can never dereference freed memory. (We target macOS 13, so
//  Swift's Synchronization.Atomic — macOS 15+ — is unavailable; C11 <stdatomic.h>
//  is the portable choice.)
//

#ifndef SEIREN_DSP_H
#define SEIREN_DSP_H

#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Max biquad sections in an EQ cascade (one per band).
#define SEIREN_DSP_MAX_SECTIONS 12
/// Max audio channels processed in place.
#define SEIREN_DSP_MAX_CHANNELS 2
/// Coefficients per biquad section: {b0, b1, b2, a1, a2}, normalized by a0.
#define SEIREN_DSP_COEFFS_PER_SECTION 5

/// Publish a new EQ coefficient set. Call OFF the real-time thread (e.g. the
/// main thread when the user changes a preset or the sample rate changes).
///
/// @param coeffs    Pointer to (nSections * 5) floats, laid out per section as
///                  {b0, b1, b2, a1, a2} already normalized by a0. May be NULL.
/// @param nSections Number of biquad sections. Pass 0 (or coeffs == NULL) to
///                  DISABLE the EQ — the RT thread will then pass audio through
///                  untouched.
///
/// Thread-safety: safe to call concurrently with seiren_dsp_process(). Internally
/// allocates a new block, atomically swaps it in (release ordering), and frees
/// the block retired by the *previous* publish (deferred free).
void seiren_dsp_publish(const float *coeffs, int nSections);

/// Apply the currently-published EQ to an interleaved float buffer, in place.
/// REAL-TIME SAFE: no allocation, no locks, no system calls. If the EQ is
/// disabled (nothing published, or published NULL), returns immediately leaving
/// the buffer unchanged.
///
/// @param interleaved Interleaved float samples (channel-interleaved).
/// @param frames      Number of frames (sample groups).
/// @param channels    Channels per frame (clamped to SEIREN_DSP_MAX_CHANNELS).
///
/// Per-channel biquad state persists across calls. Output is clamped to
/// [-1, 1] so EQ boosts cannot hard-clip the DAC. Denormal filter state is
/// flushed to zero to avoid CPU spikes during silence.
void seiren_dsp_process(float *interleaved, int frames, int channels);

/// Apply the published EQ to a MONO buffer using an independent filter-state
/// bank selected by `stateIndex` (0..SEIREN_DSP_MAX_CHANNELS-1). Lets two mono
/// signals (e.g. a low-latency monitor and a denoised broadcast) run the same
/// EQ with separate history. RT-safe; same coefficients as seiren_dsp_process.
void seiren_dsp_process_mono(float *mono, int frames, int stateIndex);

/// Zero all per-channel filter state. Call when the stream/format changes (e.g.
/// sample-rate change or device switch) so stale history doesn't ring. Cheap;
/// safe to call from the main thread between IO cycles.
void seiren_dsp_reset(void);

// MARK: - Noise gate
//
// A simple, zero-added-latency downward gate: when the input sits below a
// threshold (room hiss, fan, keyboard between words) it smoothly mutes; speech
// opens it instantly. This is the always-available, dependency-free noise
// option (RNNoise "Studio" mode comes separately). Apply it BEFORE the EQ.

/// Configure the gate. Call OFF the real-time thread.
/// @param enabled     0 = bypass, non-zero = active.
/// @param thresholdDB open above this input level (dBFS, e.g. -50), gate below.
/// @param sampleRate  device sample rate, for the attack/hold/release timings.
void seiren_dsp_set_gate(int enabled, float thresholdDB, float sampleRate);

/// Apply the gate in place to an interleaved float buffer. REAL-TIME SAFE; a
/// no-op when disabled. Per-channel envelope/gain state persists across calls.
void seiren_dsp_gate(float *interleaved, int frames, int channels);

// MARK: - Studio noise suppression (RNNoise)
//
// A neural denoiser (RNNoise) for steady broadband noise (fan / AC / hum /
// computer). Heavier than the gate and ~10 ms latency, so it is opt-in and
// off by default. RNNoise runs at 48 kHz with fixed 480-sample frames; at
// 96 kHz the processor resamples 2:1 each way, other rates bypass (no-op).

/// 2:1 half-band decimate (anti-alias): reads 2*outFrames samples, writes
/// outFrames. Mono, RT-safe; delay line cleared by seiren_dsp_reset.
void seiren_dsp_downsample2(const float *in, float *out, int outFrames);

/// 2:1 half-band interpolate (anti-image): reads inFrames samples, writes
/// 2*inFrames. Mono, RT-safe; delay line cleared by seiren_dsp_reset.
void seiren_dsp_upsample2(const float *in, float *out, int inFrames);

/// Enable/disable Studio (RNNoise) NS. Call OFF the real-time thread — it
/// allocates/frees the RNNoise state. Publishes the state atomically; the RT
/// processor is a no-op until a state is published, and again once disabled.
void seiren_dsp_set_studio(int enabled);

/// Apply Studio NS in place to a mono buffer. REAL-TIME SAFE; a no-op when
/// disabled. `rateIs96k` != 0 runs the 2:1 resampler (the buffer is 96 kHz);
/// 0 means the buffer is already 48 kHz. Maintains an internal 480-sample
/// frame bridge (latency ≈ one frame + accumulation), cleared by reset.
void seiren_dsp_studio_process(float *mono, int frames, int rateIs96k);

// MARK: - Stream mixer

#define SEIREN_MIXER_MAX_CHANNELS 8
#define SEIREN_MIXER_MAX_INPUTS 32

/// Per-engine C storage: fixed input map, RT gain/limiter history, atomic target
/// gains and diagnostic counters. Create/free OFF the audio thread, with the
/// IOProc stopped. The sample rate controls the bus limiter's 120 ms release.
typedef struct SeirenMixer SeirenMixer;
SeirenMixer *seiren_mixer_create(double sampleRate, int mixOutput);
void seiren_mixer_destroy(SeirenMixer *mixer);

/// Map an input AudioBuffer to a channel (0 = voice, 1 = desktop, 2...7 = apps).
/// Unmapped buffers are ignored, including Stream Mix's loopback input. All
/// output buffers except mixOutput are silenced, including Seiren FX's output.
/// Call only while stopped. Input indices must be < SEIREN_MIXER_MAX_INPUTS.
void seiren_mixer_map_input(SeirenMixer *mixer, int input, int channel);

/// Publish linear gain (clamped to 0...1) with C11 atomics. Safe concurrently
/// with processing. Each buffer ramps from the preceding gain to this target.
void seiren_mixer_set_gain(SeirenMixer *mixer, int channel, float gain);

/// Mix Float32 mono/stereo inputs into the selected output. Mono duplicates to
/// stereo; missing/short input is silence. A stereo-linked limiter has instant
/// attack and a -1 dBFS ceiling. REAL-TIME SAFE: no allocation, locks, system or
/// Swift/ObjC runtime calls. One audio-thread writer per mixer.
void seiren_mixer_process(SeirenMixer *mixer, const AudioBufferList *input,
                          AudioBufferList *output);

/// Core Audio entry point; clientData is the SeirenMixer allocated above.
AudioDeviceIOProc seiren_mixer_proc(void);

/// Lock-free cumulative diagnostics since creation. Safe on the main thread;
/// counters/peaks are individually atomic, not a coherent multi-field snapshot.
uint64_t seiren_mixer_callbacks(const SeirenMixer *mixer);
uint32_t seiren_mixer_input_buffers(const SeirenMixer *mixer);
uint32_t seiren_mixer_output_buffers(const SeirenMixer *mixer);
float seiren_mixer_input_peak(const SeirenMixer *mixer, int input);
float seiren_mixer_channel_peak(const SeirenMixer *mixer, int channel);
float seiren_mixer_output_peak(const SeirenMixer *mixer);

#ifdef __cplusplus
}
#endif

#endif /* SEIREN_DSP_H */
