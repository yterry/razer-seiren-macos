# Plan: Opt-in RNNoise "Studio Denoise" mode for seiren-mac

**Status:** implementation-ready. OFF by default. RT-safe. No build step. MIT-bundle-compatible.

A naming decision drove much of this plan: the EQ preset list already contains a preset literally named **"Studio"** (`Sources/SeirenKit/EQEngine.swift:61`). To avoid two user-facing "Studio" concepts, the RNNoise NS mode is labeled **"Studio Denoise"** in the UI, and the enum case is `NoiseSuppression.studio` (an EQ-preset name vs. an NS enum case never collide in code, only in the menu — which the distinct label fixes).

---

## 0. Scope & sequencing (what to build, in order)

The adversarial review's verdict is the spine of this plan: **GO on vendoring; NO-GO on starting `routeIOProc` wiring until the frame-accumulator + scaling + latency design exists.** So the work is staged:

1. **Stage A — Vendor RNNoise as a SwiftPM C target** (Section 1). Verified by `swift build` + a smoke test. No app wiring yet. Mergeable on its own.
2. **Stage B — Resampler + RT primitives in SeirenDSP** (Sections 2–5): half-band 2:1 FIR, the 48 kHz frame-bridge ring, the `±32768` scaling shim, `seiren_dsp_set_studio` / `seiren_dsp_studio_process` with deferred-free `DenoiseState` handoff. Pure C, unit-testable offline with **no CoreAudio**.
3. **Stage C — Swift wiring + UI** (Section 6): `NoiseSuppression.studio`, `routeIOProc` chain, `MonitorEngine`/`AppDelegate`/`Settings`, the "Studio Denoise" radio with the latency caveat.
4. **Stage D — License/attribution** (Section 7) and **doc updates** (Section 8).

Do **not** begin Stage C until Stage B's offline tests pass. Stages A and B are independent and can land in either order.

---

## 1. GO/NO-GO: no-build-step vendoring

**GO.** The research verified a clean SwiftPM C target with Command-Line-Tools-only clang — no config.h, no autotools, no CMake, zero `-D` flags. One hard prerequisite (the model blob) and one decision for the user (Section 7) gate it.

### 1.1 New target: `Sources/RNNoise/`

```
Sources/RNNoise/
  include/
    rnnoise.h            ← upstream public header — KEEP THIS EXACT NAME (do not add RNNoise.h)
    module.modulemap     ← hand-written, below
  src/
    denoise.c rnn.c pitch.c kiss_fft.c celt_lpc.c
    nnet.c nnet_default.c parse_lpcnet_weights.c rnnoise_tables.c
    rnnoise_data.c        ← DOWNLOADED via download_model.sh, then committed (see 1.3 + Section 7)
    arch.h celt_lpc.h cpu_support.h common.h denoise.h
    _kiss_fft_guts.h kiss_fft.h nnet.h nnet_arch.h opus_types.h
    pitch.h rnn.h rnnoise_data.h  ← DOWNLOADED
    vec.h vec_neon.h vec_avx.h
    x86/
      x86_arch_macros.h   ← the ONLY x86 file needed (no-op outside MSVC)
  COPYING                 ← upstream BSD-3 (also surfaced in NOTICE — Section 7)
  MODEL_VERSION           ← record the vendored hash for reproducibility
```

Excluded on purpose: every other `src/x86/*.c`, `src/x86/dnn_x86.h`, `src/arm/*`, `examples/`, `training/`, `torch/`, dump/write-weights tools. The conditional includes (`osce.h` behind `ENABLE_OSCE`, `x86/dnn_x86.h` behind `RNN_ENABLE_X86_RTCD`, `arm/fft_arm.h` behind `HAVE_ARM_NE10`) are all off by default.

### 1.2 `module.modulemap` (VERIFIED)

`Sources/RNNoise/include/module.modulemap`:

```
module RNNoise {
    umbrella header "rnnoise.h"
    export *
}
```

> **CRITICAL (resolved):** Do **not** create a separate `RNNoise.h`. On macOS's case-insensitive FS it is the same file as `rnnoise.h` and silently overwrites the public header, yielding misleading `unknown type name DenoiseState` errors. The modulemap's umbrella header **is** the existing public `rnnoise.h`.

### 1.3 `Package.swift` target

Insert into the `targets:` array of `Package.swift` (after `.target(name: "SeirenDSP")`), and add `"RNNoise"` to `SeirenKit`'s dependencies:

```swift
// Vendored RNNoise (xiph/rnnoise) — RT noise suppression for "Studio Denoise".
// No build step: prebuilt C sources + committed model weights. BSD-3 (MIT-compat),
// see Sources/RNNoise/COPYING and NOTICE. Model pinned in MODEL_VERSION.
.target(
    name: "RNNoise",
    path: "Sources/RNNoise",
    sources: ["src"],
    publicHeadersPath: "include",
    cSettings: [ .headerSearchPath("src") ]
),
```

```swift
.target(name: "SeirenKit", dependencies: ["SeirenDSP", "RNNoise"]),
```

SeirenDSP itself does **not** depend on RNNoise — the C glue calls RNNoise through SeirenKit-provided function pointers (Section 3.4) so SeirenDSP stays a pure leaf with no large weights blob linked into the probe/test targets unnecessarily. (Alternative simpler wiring in 3.4 if you prefer SeirenDSP→RNNoise directly.)

### 1.4 One-time vendoring procedure (maintainer runs this once, NOT at build time)

```bash
git clone https://github.com/xiph/rnnoise /tmp/rnnoise
cd /tmp/rnnoise
./download_model.sh                 # fetches the tarball named by ./model_version
cp model_version Sources/RNNoise/MODEL_VERSION   # record the pinned hash
# Copy the file set in 1.1 into Sources/RNNoise/. For the lean ~30 MB model:
#   cp src/rnnoise_data_little.c Sources/RNNoise/src/rnnoise_data.c
#   cp src/rnnoise_data_little.h Sources/RNNoise/src/rnnoise_data.h
# (the _little .h interface is byte-identical and also defines rnnoise_arrays)
```

> **Resolved (no-build-step vs lean repo, MAJOR):** `.git` is currently **1.1 MB**. Committing the **78 MB full** model is a ~70× permanent history blow-up; even the **~30 MB little** model is ~25×. **Decision required from the user before committing any blob.** Recommendation: vendor the **`rnnoise_data_little`** variant (rename `_little` → `rnnoise_data`) to stay strictly no-build-step at the lowest cost; the quality delta is small for speech. If the user rejects a multi-MB commit, the fallback is a documented maintainer-run fetch into an **untracked** `Sources/RNNoise/src/rnnoise_data.c` (the file is .gitignored; the maintainer runs `download_model.sh` once per clone) — but that is *not* truly no-build-step for fresh clones and should be a conscious tradeoff, not the default. Either way, pin and commit `MODEL_VERSION` (currently `0a8755f8e2d834eff6a54714ecc7d75f9932e845df35f8b59bc52a7cfe6e8b37`).

> **Resolved (x86_64 slice, MINOR):** before merging Stage A, run `swift build --arch arm64 --arch x86_64` (or an `xcodebuild` universal archive) on the RNNoise target and run the smoke test on x86_64 so `vec_avx.h`/scalar fallback is proven, since the signed release may ship universal. Cheap, removes a release-day surprise.

### 1.5 Stage-A acceptance

A SeirenKitTests case that links RNNoise and asserts `rnnoise_get_frame_size() == 480`, creates a state with `rnnoise_create(nil)`, processes a 480-frame zero buffer, and destroys it — proving the module imports and links on the CI arch(s).

---

## 2. Resampling: 96 kHz ↔ 48 kHz (and 44.1k / other)

RNNoise is **48 kHz only**, fixed 480-sample frames. The aggregate runs at the Seiren's nominal rate. Strategy: keep the RNNoise ring strictly in the **48 kHz domain**; resample only on the way in/out.

| Device nominal rate | Path |
|---|---|
| **48000** | No resampler. Mono mic → ring (48k) directly. |
| **96000** | 2:1 half-band decimate in → ring (48k) → process → 2:1 half-band interpolate out. |
| **44100 / 32000 / any other** | **RNNoise bypassed.** `studio` silently degrades to `gate + EQ` (Section 5). No arbitrary-ratio resampler is shipped — RT-safe rational resampling for 44.1↔48 is out of scope and not worth the aliasing/latency risk for a niche rate. The UI shows a caveat (Section 6.5). |

**AudioConverter is rejected** (allocates / not documented RT-safe). **vDSP skipped** (no measured benefit at this size; keeps the math in the testable C core). **Forcing the device to 48 kHz is NOT implemented in v1** — it is a global, persistent, multi-app side effect on shared hardware (review MINOR). The half-band path (TIER-2) is the only resampler we ship; a future TIER-1 force-48k can be added later with the full guard discipline below.

### 2.1 Half-band FIR spec (review MAJOR — now specified, not asserted)

- **One symmetric linear-phase kernel** used for *both* decimation (anti-alias) and interpolation (anti-image). **Same taps**, so group delay is identical in/out and cancels in the round trip.
- **Design:** half-band low-pass, **Fpass = 0.43·(fs/2)**, **Fstop = 0.57·(fs/2)** in the 96 kHz domain (i.e. pass < ~20.6 kHz, stop > ~27.4 kHz), **≥ 60 dB stopband** so HF content (sibilance, fan whine) above 24 kHz does not alias into the voice band where RNNoise would then mis-denoise it.
- **Taps:** a 15-tap half-band gives only modest rejection; for ≥ 60 dB use a **31-tap** half-band (Kaiser, β≈5). Half-band kernels have alternate **zero** taps (every other coefficient except center is 0), so a 31-tap half-band costs ~16 multiplies — cheap. Generate offline with `scipy.signal.firwin(31, 0.5, window=('kaiser', 5.0))`, normalize DC gain to 1.0 (decimate) / 2.0 (interpolate, to restore energy after zero-stuffing), and **commit the literal coefficients** as a `static const float HB[31]` in the resampler .c.
- **Offline test (committed):** feed a 30 kHz tone sampled at 96 kHz through `downsample2` and assert the aliased image inside the 0–24 kHz band is **≥ 60 dB** below the passband — guards against an under-length kernel slipping through.

### 2.2 New SeirenDSP resampler functions

Added to `Sources/SeirenDSP/SeirenDSP.c` + `.h` (delay-line state is module-static, zeroed in `seiren_dsp_reset`):

```c
// in SeirenDSP.h
/// 2:1 half-band decimate (anti-alias). Reads 2*outFrames input samples,
/// writes outFrames. RT-safe; mono. State persists across calls; cleared by
/// seiren_dsp_reset.
void seiren_dsp_downsample2(const float *in, float *out, int outFrames);

/// 2:1 half-band interpolate (anti-image). Reads inFrames samples, writes
/// 2*inFrames. RT-safe; mono.
void seiren_dsp_upsample2(const float *in, float *out, int inFrames);
```

`seiren_dsp_reset` (`SeirenDSP.c:139`) gains `memset` of the two delay lines plus the ring state from Section 3.

---

## 3. RT-safe DenoiseState handoff + frame-bridge ring + latency budget

This is the load-bearing part the review flagged as the **#1 RT correctness gap**: RNNoise needs **exactly 480-sample frames**, but the live IOProc buffer is `preferredBufferFrames = 128` (`MonitorEngine.swift:308`), HAL-clamped — never guaranteed to be 480 or any multiple. Calling `process_frame` on a 128-sample buffer is simply wrong.

### 3.1 The frame-bridge ring (48 kHz domain, pre-allocated, RT-owned)

Add to `SeirenDSP.c` a process-lifetime, statically-allocated mono ring pair (input accumulator + output queue). Capacity ≥ `2*960` to absorb a full 96 kHz buffer's worth of decimated samples plus a 480 frame:

```c
// --- RNNoise frame bridge (48 kHz domain, RT-owned, never allocates) --------
#define STUDIO_FRAME 480              // RNNoise frame @ 48k
#define STUDIO_RING  (4 * STUDIO_FRAME)  // 1920: headroom for 96k buffers + 1 frame

static float g_in_ring[STUDIO_RING];   // accumulates input until >= 480
static int   g_in_count = 0;
static float g_out_ring[STUDIO_RING];  // holds processed output to drain
static int   g_out_head = 0, g_out_count = 0;
static int   g_studio_primed = 0;      // 1 after we've buffered the warmup frame
```

All of `g_in_count`, `g_out_*`, `g_studio_primed`, and both delay lines are zeroed in `seiren_dsp_reset`.

### 3.2 The per-IOProc algorithm (review MAJOR — explicit chain, straddles decimation)

`seiren_dsp_studio_process(float *x, int frames, int rateIs96k)` operates **in place** on the mono scratch and is the single RT entry point:

```
1. If no DenoiseState published → return (passthrough; studio inactive).
2. Push input into the 48k ring:
     - 48k:  push all `frames` samples.
     - 96k:  seiren_dsp_downsample2(x, tmp48, frames/2); push frames/2 samples.
3. While g_in_count >= 480:
     - pop 480 into frame[480]
     - for i: frame[i] *= 32768.0f                    // scale UP (Section 4)
     - rnnoise_process_frame(state, frame, frame)      // via fn ptr (3.4)
     - for i: frame[i] *= (1.0f/32768.0f)              // scale DOWN
     - if !g_studio_primed: g_studio_primed = 1; continue   // DROP warmup frame
     - push 480 into g_out_ring
4. Drain output back into x (48k domain):
     - need = (96k ? frames/2 : frames)
     - if g_out_count >= need: pop `need` into out48
       else: zero-fill the deficit (priming underrun guard — only at startup)
     - 48k:  copy out48 → x
       96k:  seiren_dsp_upsample2(out48, x, need)       // back to 96k, `frames` out
```

The ring **straddles** decimation (input pushed *after* downsample, output upsampled *after* drain), exactly as the review requires. At 96 kHz a 128-frame buffer yields 64 ring samples, so ~7.5 buffers accumulate per RNNoise frame — handled correctly by the `while >= 480` loop and the drain deficit guard.

### 3.3 RNNoise state lifecycle — reuse the proven deferred-free discipline

The codebase already has the exact safe pattern for the EQ (`SeirenDSP.c:20–82`: `g_coeffs` atomic-exchanged, `g_retired` freed one publish later). **A `DenoiseState` is stateful and heavy**, so a naive copy that frees one-publish-later can free a state the RT thread is mid-`process_frame` on if publishes outpace buffers. Mitigation: NS mode changes are user-driven and rare (orders of magnitude slower than buffer cadence), and we publish via `atomic_exchange` + free-on-next-publish, by which point the RT thread has reloaded. One `DenoiseState` per stream (mono). **`create`/`destroy` happen OFF the RT thread; the IOProc never allocates.**

```c
// in SeirenDSP.c
static _Atomic(void *) g_studio_state  = NULL;   // opaque DenoiseState*
static void           *g_studio_retired = NULL;  // freed on next publish
```

### 3.4 Avoiding a SeirenDSP→RNNoise link dependency: function-pointer injection

SeirenDSP stays a pure leaf. SeirenKit injects RNNoise's three functions once at startup:

```c
// SeirenDSP.h
typedef struct {
    void  *(*create)(void *model);                 // rnnoise_create
    void   (*destroy)(void *st);                    // rnnoise_destroy
    float  (*process)(void *st, float *out, const float *in); // rnnoise_process_frame
} seiren_studio_vtable;

/// Install RNNoise entry points (call once, off-thread, before set_studio).
void seiren_dsp_install_studio(const seiren_studio_vtable *vt);

/// Enable/disable Studio NS. Call OFF the RT thread. Creates the DenoiseState
/// on enable (off-thread) and publishes it atomically; deferred-frees the
/// previous state on the next call. enabled==0 publishes NULL (passthrough).
void seiren_dsp_set_studio(int enabled);

/// Apply Studio NS in place to the mono scratch. RT-SAFE; no-op if no state
/// published. rateIs96k selects the 2:1 resampler path.
void seiren_dsp_studio_process(float *mono, int frames, int rateIs96k);
```

> If you'd rather skip the vtable, make `SeirenDSP` depend on `RNNoise` directly in `Package.swift` and `#include "rnnoise.h"` in `SeirenDSP.c`. The vtable keeps the weights blob out of the `seiren-probe`/test link and keeps SeirenDSP dependency-free; pick based on link-size preference. Either is correct.

`seiren_dsp_install_studio` is called from `MonitorEngine.init` with a static C vtable in SeirenKit that forwards to `rnnoise_create`/`_destroy`/`_process_frame`.

### 3.5 Measured/honest latency budget (review MAJOR — single honest figure)

The "~0.3 ms" claim was **FIR group delay only** and is wrong as a total. Real added latency under Studio:

- **Frame accumulation:** must collect 480 samples before the first RNNoise output. At 48 kHz with 128-frame buffers that's ⌈480/128⌉ ≈ **4 IOProc cycles** of fill, i.e. up to ~one buffer (≈2.7 ms) of *steady-state* accumulation jitter once primed.
- **RNNoise algorithmic warmup:** **1 frame = 10 ms** (the first output frame is dropped — `g_studio_primed`).
- **Half-band FIR group delay:** (31−1)/2 = 15 taps each way → ≈0.3 ms total at 96 kHz; negligible.

**Headline figure to publish:** *Studio Denoise adds ~10 ms (algorithmic) + up to ~one I/O buffer of accumulation (~13 ms total at 128 frames / 48 kHz), plus negligible filter delay.* Gate mode remains zero added latency.

**Optional jitter reduction:** when Studio is enabled, raise the I/O buffer toward **480 frames** so one buffer ≈ one RNNoise frame (removes accumulation jitter at the cost of base buffer latency). Documented tradeoff; default keeps 128 and accepts the ring. `CREATOR_DESIGN.md` records the real number (Section 8).

---

## 4. ±32768 scaling (review CRITICAL — anchored to THIS pipeline)

This pipeline is **entirely normalized to ±1.0**: CoreAudio Float32 is ±1.0, `seiren_dsp_process` clamps to [-1,1] (`SeirenDSP.c:124`), and the gate threshold `0.00316` (`SeirenDSP.c:42`) is linear in ±1.0 terms. RNNoise wants **int16-scaled floats (±32768), NOT ±1.0**.

**Containment:** the scale lives **only inside `seiren_dsp_studio_process`**, on the 480-sample frame, immediately around the `process` call (see 3.2 step 3): `*= 32768.0f` before, `*= 1/32768.0f` after. Nothing else in the chain — gate, EQ, the [-1,1] clamp, the IOProc fan-out — sees anything but ±1.0. The scale is **never** smeared across the Swift IOProc.

**Committed unit test:** a full-scale ±1.0 sine fed through `studio_process` survives the round trip at **±1.0** (asserting it isn't near-silent *or* clipped) — proving the scale pairs correctly and the invariant holds.

---

## 5. Chain order & the three NS modes

### 5.1 Chain order (resolved)

`deinterleave → GATE → STUDIO (RNNoise) → EQ → clamp → fan out`

- **Gate first:** removes between-word room noise so RNNoise sees cleaner input and the EQ shapes already-cleaned voice (matches the existing "gate before EQ" comment at `MonitorEngine.swift:115` and `SeirenDSP.h`).
- **Studio and gate are NOT mutually exclusive at the C level** — but the *user-facing modes* are a single 3-way choice (below), so in practice only one of {gate, studio} is active. The C functions are independent no-ops when disabled, so the chain is always the same straight line.
- **EQ last**, exactly as today.

### 5.2 `NoiseSuppression` becomes 3-way

`MonitorEngine.swift:249` today:

```swift
public enum NoiseSuppression: String, Equatable, Sendable {
    case off, gate
}
```

becomes:

```swift
public enum NoiseSuppression: String, Equatable, Sendable {
    case off      // passthrough
    case gate     // zero-latency downward gate (always available)
    case studio   // RNNoise — "Studio Denoise" in UI; ~10 ms latency; 48k/96k only
}
```

`rawValue` strings stay stable (`"off"`, `"gate"`, new `"studio"`), so the persisted `voice.ns.mode` key (`Settings.swift:18`) round-trips; an unknown value already falls back to `.off` (`Settings.swift:79`).

**Mutual exclusion** is enforced by the apply step: `gate` enables the C gate + disables studio; `studio` enables studio + disables the gate; `off` disables both.

---

## 6. SeirenDSP C API + Swift wiring + UI

### 6.1 SeirenDSP.h / .c additions (summary)

- `seiren_dsp_downsample2`, `seiren_dsp_upsample2` (Section 2.2)
- `seiren_studio_vtable`, `seiren_dsp_install_studio`, `seiren_dsp_set_studio`, `seiren_dsp_studio_process` (Section 3.4)
- ring/state statics + their zeroing in `seiren_dsp_reset` (Section 3.1)

### 6.2 SeirenKit RNNoise glue (new file `Sources/SeirenKit/StudioNS.swift`)

```swift
import RNNoise
import SeirenDSP

/// Static C vtable forwarding to RNNoise. Installed once into SeirenDSP so the
/// RT thread reaches RNNoise without SeirenDSP depending on the weights blob.
enum StudioNS {
    static func install() {
        var vt = seiren_studio_vtable(
            create:  { model in UnsafeMutableRawPointer(rnnoise_create(model?.assumingMemoryBound(to: RNNModel.self))) },
            destroy: { st in rnnoise_destroy(st?.assumingMemoryBound(to: DenoiseState.self)) },
            process: { st, out, inp in
                rnnoise_process_frame(st?.assumingMemoryBound(to: DenoiseState.self), out, inp)
            })
        seiren_dsp_install_studio(&vt)
    }
}
```

### 6.3 `MonitorEngine` wiring

- In `init` (`MonitorEngine.swift:307`): call `StudioNS.install()` once.
- Replace `applyGate()` (`MonitorEngine.swift:267`) with `applyNoiseSuppression()`:

```swift
private func applyNoiseSuppression() {
    let fs = Float(eqEngine.sampleRate)
    let rateOK = (fs == 48000 || fs == 96000)            // RNNoise-capable rates
    let wantStudio = (noiseSuppression == .studio && rateOK)
    // gate is active for .gate, OR as the graceful fallback when .studio is
    // selected at an unsupported rate (44.1k etc).
    let wantGate = (noiseSuppression == .gate) ||
                   (noiseSuppression == .studio && !rateOK)
    seiren_dsp_set_gate(wantGate ? 1 : 0, gateThresholdDB, fs)
    seiren_dsp_set_studio(wantStudio ? 1 : 0)
}
```

- `setNoiseSuppression` (`:259`) calls `applyNoiseSuppression()` instead of `applyGate()`.
- `startProc` creator path (`:424`) calls `applyNoiseSuppression()` instead of `applyGate()` (after `setSampleRate`/`reset`, so the rate is known).
- Add a **nominal-rate listener** on the aggregate (mirroring `devicesListenerBlock`): on a live rate change, call `eqEngine.setSampleRate`, `seiren_dsp_reset` (clears EQ state, gate state, **and the new ring/delay-line state**), and `applyNoiseSuppression()` — so switching 48↔96↔44.1 re-arms or bypasses Studio correctly without a stale ring.
- Expose `studioRateSupported: Bool { let fs = eqEngine.sampleRate; return fs == 48000 || fs == 96000 }` and `studioActive: Bool { noiseSuppression == .studio && studioRateSupported }` for the UI caveat.

### 6.4 `routeIOProc` change

`MonitorEngine.swift:114–119` — the deinterleave + gate + EQ block — becomes:

```swift
var f = 0
while f < frames { scratch[f] = mic[f * micCh]; f += 1 }
seiren_dsp_gate(scratch, Int32(frames), 1)                 // no-op unless gate active
seiren_dsp_studio_process(scratch, Int32(frames), gStudio96k) // no-op unless studio published
seiren_dsp_process(scratch, Int32(frames), 1)              // EQ, no-op if disabled
```

`gStudio96k` is a `nonisolated(unsafe) var Int32` global (like `gMonitorLevel`) set off-thread in `startProc`/the rate listener to `1` when the live rate is 96000, else `0`. The IOProc still touches only C functions + globals — no Swift runtime, no allocation.

> **Resolved (one DenoiseState per stream, RT concurrency):** `rnnoise_process_frame` is not safe to call concurrently on one state; there is exactly one stream (mono) and one RT thread here, and create/destroy are off-thread — invariant held.

### 6.5 AppDelegate UI — "Studio Denoise" radio + latency caveat

`AppDelegate.swift:189–195` (the Noise-suppression block) gains one row plus a caveat. Current:

```swift
submenu.addItem(disabledItem("Noise suppression"))
submenu.addItem(nsItem("Off", .off))
submenu.addItem(nsItem("Reduce noise", .gate))
```

becomes:

```swift
submenu.addItem(disabledItem("Noise suppression"))
submenu.addItem(nsItem("Off", .off))
submenu.addItem(nsItem("Reduce noise", .gate))
submenu.addItem(nsItem("Studio Denoise", .studio))      // distinct from the "Studio" EQ preset
if engine.noiseSuppression == .studio {
    submenu.addItem(disabledItem(studioCaption()))      // honest latency / rate caveat
}
```

```swift
private func studioCaption() -> String {
    if !engine.studioRateSupported {
        return "Needs 48 or 96 kHz — using Reduce noise at this rate"
    }
    return "AI denoise · adds ~10 ms latency"
}
```

`nsItem`/`selectNS` (`:202` / `:312`) already round-trip `representedObject = ns.rawValue` and persist via `settings.noiseSuppression`, so the new `.studio` case needs **no** change to those methods — the radio "just works" through the existing handler.

### 6.6 Settings

`Settings.swift` needs **no change**: `noiseSuppression` (`:76`) already encodes/decodes `NoiseSuppression.rawValue` and defaults unknown values to `.off`. `AppDelegate.didFinishLaunching` (`:34`) already calls `engine.setNoiseSuppression(settings.noiseSuppression)`, so a persisted `studio` is restored on launch — re-validated against the live rate by `applyNoiseSuppression()`.

**OFF by default** is preserved: the default for an absent `voice.ns.mode` is `.off` (`Settings.swift:79`).

---

## 7. License & attribution

RNNoise is **BSD-3-Clause** (+ kiss_fft by Mark Borgerding); both are **MIT-compatible**. The app currently ships only `LICENSE` (MIT) and has **no** `NOTICE`/`THIRD_PARTY` file. Steps:

1. **Add `NOTICE` at repo root** containing the full RNNoise `COPYING` text (Jean-Marc Valin, Amazon, Mozilla, Xiph.Org) **and** the kiss_fft notice (Mark Borgerding), plus the `rnnoise.h` 2-clause block (Gregor Richards/Mozilla). Note the bundled model weights are covered by the same project license; record `MODEL_VERSION`.
2. **Keep `Sources/RNNoise/COPYING`** in the source tree (upstream-as-vendored).
3. **Surface attribution in the app's About/menu** — RNNoise's BSD-3 requires reproducing the notice in binary distribution docs. Add an "Acknowledgements" menu item (or include `NOTICE` in the packaged `.app` Resources via `package.sh`) so the running binary carries the text.
4. **README/`package.sh`:** add a one-line "Includes RNNoise (BSD-3) — see NOTICE" and ensure `NOTICE` ships in the release artifact.

---

## 8. Review issues — disposition

**CRITICAL**
- *Missing frame accumulator/ring* → **resolved**, Section 3.1–3.2 (48 kHz ring, `while ≥480`, drain-deficit guard, zeroed in `reset`).
- *±32768 vs ±1.0 under-specified* → **resolved**, Section 4 (scale contained inside `studio_process`; ±1.0 round-trip unit test).

**MAJOR**
- *Latency optimistic/contradictory* → **resolved**, Section 3.5 (~10 ms + ~1 buffer ≈ 13 ms headline; FIR delay negligible; optional 480-frame buffer; doc update).
- *96k frame math unaddressed by ring* → **resolved**, Sections 2 + 3.2 (ring lives in 48k domain; pushes happen *after* downsample, drain *before* upsample; 96k sample-count test).
- *Half-band asserted not specified* → **resolved**, Section 2.1 (Fpass/Fstop, ≥60 dB, single shared 31-tap kernel, committed coeffs, alias-rejection test; 15 taps rejected as too few).
- *DenoiseState lifecycle vs existing pattern* → **resolved**, Section 3.3 (reuse `g_coeffs`/`g_retired` deferred-free discipline as `g_studio_state`/`g_studio_retired`; create/destroy off-thread; one state per stream).
- *No-build-step vs lean repo conflict* → **flagged for user decision**, Section 1.4 (recommend committing ~30 MB `_little`; alternative untracked fetch documented; pin `MODEL_VERSION`). **Do not commit a multi-MB blob without confirming with the user.**

**MINOR**
- *Attribution incomplete for this repo* → **resolved**, Section 7 (`NOTICE` + About surfacing).
- *"Studio" naming collision with EQ preset* → **resolved**, label **"Studio Denoise"**, enum `NoiseSuppression.studio` (Sections 0, 5.2, 6.5).
- *Force-48k global side effect / weak guard* → **deferred out of v1**, Section 2 (ship only the half-band; force-48k is a documented future TIER-1 with snapshot/restore + input-and-output guard + no live-rate-change-while-running, never the default).
- *x86_64 slice unverified* → **resolved as a gate**, Section 1.4 (universal build + smoke test before merge).

---

## 9. File-change checklist

- `Package.swift` — add `RNNoise` target; add to `SeirenKit` deps.
- `Sources/RNNoise/**` — vendored sources, `module.modulemap`, `COPYING`, `MODEL_VERSION` (new).
- `Sources/SeirenDSP/include/SeirenDSP.h` — resampler + studio API (Sections 2.2, 3.4).
- `Sources/SeirenDSP/SeirenDSP.c` — half-band FIR, ring, studio state + deferred free, `reset` zeroing.
- `Sources/SeirenKit/StudioNS.swift` — RNNoise vtable glue (new).
- `Sources/SeirenKit/MonitorEngine.swift` — `NoiseSuppression.studio` (:249), `applyNoiseSuppression` (:267), `init` install (:307), `startProc` (:424), nominal-rate listener, `gStudio96k` global, IOProc chain (:114).
- `Sources/seiren-mac/AppDelegate.swift` — "Studio Denoise" row + `studioCaption()` (:189).
- `Tests/SeirenKitTests/` — Stage-A link smoke test; ±1.0 round-trip; 30 kHz alias-rejection; 96k sample-count.
- `NOTICE` (new) + README/`package.sh` attribution line.
- `docs/CREATOR_DESIGN.md` — 96k + Studio latency addendum.

*(All paths relative to the repo root.)*