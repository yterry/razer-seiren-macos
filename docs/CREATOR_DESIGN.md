# Seiren Studio — Design Document

**Evolving `seiren-mac` from a headphone-monitor utility into a holistic Razer Seiren creator app on macOS**

Status: design / decision document · Target package: `seiren-mac` (SwiftPM, Swift 6, macOS 13+, unsigned, no-build-step)
Audience: maintainer + contributors · Supersedes: scattered per-feature notes

---

## 1. Executive summary

Razer Synapse does not support *any* microphone on macOS. Seiren owners on a Mac get nothing — no EQ, no noise suppression, no lighting, no mixer. `seiren-mac` already proves the wedge: it gives them the one thing they most need, software headphone monitoring ("hear yourself"), built in userspace because even the hardware monitor-on HID bytes were never captured.

This document defines how to grow that utility into a creator app along a single honest arc — **hear yourself → shape your voice → clean your voice → light it up** — without ever breaking the four invariants that make the project trustworthy:

- **Unsigned** (no paid Apple Developer ID).
- **No build step** (pure SwiftPM, `swift build` on a Command-Line-Tools-only toolchain).
- **Single menu-bar agent** (no Dock app, no settings window unless unavoidable).
- **Never send un-captured bytes to hardware.**

The app has **two independent control planes**, both already present in embryo:

1. **Audio plane** — per-buffer DSP run *inside the existing single full-duplex `monitorIOProc`*. This is where **EQ** and **Noise Suppression** live. It is monitor-only by construction (other apps still record the raw mic).
2. **HID plane** — the existing `SeirenController` / `DeviceModel` / `DeviceRegistry` transport (interface 3, usage page `0xFF53`, Feature report `0x07`, 63 data bytes). This is where **Lighting** lives. It is **hard-gated on a Windows Synapse byte capture that does not yet exist**, and may turn out to be a no-op forever if the V3 Pro has no addressable RGB.

The **Streamer Mixer** is **roadmap-only**. It fundamentally requires a virtual audio device (a signed/notarized CoreAudio HAL plug-in), which breaks unsigned + no-build-step and needs a Developer ID. It is the deliberate "v2 tier" milestone, not part of the menu-bar app.

Build order: **EQ (v0.2) → Noise Suppression (v0.3) → Lighting scaffold (v0.4, indefinitely gated) → stabilize (v1.0) → virtual-device + mixer (v2, Developer-ID tier).**

---

## 2. KEY DECISIONS FOR THE USER

These are the only three decisions that actually change what gets built. Everything else follows from them.

### Decision A — Reach: monitor-only now, or virtual audio device now?

*Does processed audio (EQ/NS) need to reach Zoom/OBS/Discord, or is shaping the headphone monitor enough for v1?*

| Option | What it means | Cost |
|---|---|---|
| **Monitor-only (in `monitorIOProc`)** ✅ **RECOMMENDED** | EQ/NS shape only what you hear in your headphones; other apps record the raw mic. | Free. Stays unsigned, no-build-step, single menu-bar app. |
| Virtual audio device now | A BlackHole-style HAL plug-in publishes a "Seiren FX" input that other apps select; processed audio reaches everything (Synapse parity). | Breaks all four invariants: separate C `.driver` bundle, `sudo` install to `/Library/Audio/Plug-Ins/HAL`, `coreaudiod` restart, **and requires at least ad-hoc signing — modern `coreaudiod` may refuse unsigned HAL plug-ins even locally**, so a paid Developer ID + notarized installer is the realistic distribution path. |

**Rationale:** the entire value of the project rests on staying a trivially-buildable unsigned menu-bar app. Monitor-only delivers real value (you hear your shaped/cleaned voice) at zero trust-model cost. The virtual device is a separate v2 project with its own build/installer/signing track. **The honest cost of "monitor-only" is a UX trap that must be paid down in docs and UI (see §3, §8).**

### Decision B — Noise-suppression engine

| Option | Fit | Verdict |
|---|---|---|
| In-tree **noise gate** (threshold + attack/hold/release) ✅ **RECOMMENDED as v0.3 default** | Pure Swift, zero deps, zero added latency, fully self-contained. | Ship first. The other half of Synapse's noise toolkit anyway. |
| **RNNoise** (BSD-3 C target) ✅ **RECOMMENDED as opt-in "Studio" mode** | Best speech quality; but first C dependency, ~13–18 ms added latency, 48 kHz-only, needs `×32768` scaling. | Opt-in, after a clean-CLT-build check. |
| Apple `VoiceProcessingIO` | Convenient, but it is an *I/O unit* that owns I/O — adopting it means tearing out `monitorIOProc` and re-architecting onto `AVAudioEngine`. | Rejected for v1; revisit only if AEC is ever needed. |
| vDSP spectral gating | Zero-dep but easy to musical-noise/pump for much more effort. | Documented fallback only. |

**Rationale:** the gate is cheap, latency-free, and preserves the near-zero-latency monitor promise (the app's core selling point). RNNoise is the quality upgrade but is opt-in because it is the first native dependency and adds audible latency.

### Decision C — Lighting: ship scaffold only, or attempt go-live?

| Option | What it means |
|---|---|
| **Scaffold-only, indefinitely gated** ✅ **RECOMMENDED** | Ship the data structures, the API, and a *disabled* menu submenu. Send **nothing** until a Windows Synapse capture proves (a) the V3 Pro exposes lighting and (b) a captured frame visibly changes the LEDs. |
| "Go-live" with byte substitution | Replay a captured base frame and patch R/G/B bytes at observed offsets. **REJECTED** — this is byte fuzzing, not replay, on a channel shared with audio control; it risks wedging audio state or a firmware/DFU path. There is also no captured frame to base it on. |

**Rationale:** the project has captured **zero** HID frames of any kind (the device JSON has `monitorOn/Off/handshake` all `null`). One research strand reported `hasLedStrips=false` — the V3 Pro is the *studio/broadcast* SKU; the *Chroma* (0x056F) is the RGB SKU. "No addressable RGB" is a **valid, expected outcome**, and a permanently-disabled lighting submenu is *success*, not failure.

---

## 3. Feature: Parametric EQ

### 3.1 Chosen approach + rationale

**Software DSP inside the existing `monitorIOProc`.** Mic samples already flow through that proc (read input ch0 → scale by `gMonitorLevel` → fan to outputs). A biquad cascade inserted *before* the gain is trivial, entitlement-free (existing mic TCC only), RT-safe, and ships under all invariants.

Rejected:
- **Hardware-HID EQ** — the V3 Pro's `CommandTable` is empty; no EQ bytes captured. The research log's "captured EQ frames" (Feature 9/8/26, 65-byte, XOR checksum) are *Windows USB captures not present in this repo*, are a different length than the documented 63-byte report-0x07 channel, and carry a checksum the PA frame does not have. **The only EQ shipping is monitor-path DSP; it sends nothing over HID.** Hardware EQ is explicitly out-of-scope and capture-gated.
- **Virtual device** — Decision A; deferred to v2.

### 3.2 Architecture

Signal chain in the proc (one buffer pass, no second graph):

```
mic ch0 → [Noise Suppression] → [EQ biquad cascade] → × gain (gMonitorLevel) → clamp → fan to outputs
```

EQ is recursive (IIR) → **~0 added latency**. NS goes *before* EQ so EQ shapes clean voice (see §4). Gain stays last as post-EQ make-up.

**RT-safe coefficient publish (the critical correctness point — reviewers flagged this):**
- Coefficients are POD only: a fixed-size `malloc`'d block of `BiquadCoeffs { b0,b1,b2,a1,a2: Float }`. **No Swift `Array`, no protocol/existential, no class-via-`Unmanaged` on the RT path** — those incur ARC/witness-table traffic the proc forbids.
- Published via a **real atomic** with release/acquire ordering: `Atomic<UnsafeRawPointer?>` (Swift `Synchronization`) *or* C11 `atomic_store_explicit(memory_order_release)`. A plain `var` store is **not** sufficient (no barrier → RT thread can read a half-initialized block). **Note:** `Synchronization` is macOS 15+; the package floor is macOS 13 → **use C11 atomics** (or a tiny C shim) to keep the floor.
- Filter **state** (`z1,z2` per section) is a separate pre-allocated raw buffer owned by the RT thread, advanced in place. On a coeffs swap, state runs through (transient inaudible).
- The old coeff block is freed on the **main thread one reconcile cycle later** (deferred free), never on the RT thread.
- `gEQEnabled` is a `nonisolated(unsafe) Bool` (torn-read-harmless, like `gMonitorLevel`).

**DSP math:** RBJ Audio-EQ-Cookbook (peaking / low-shelf / high-shelf / HPF), normalized by `a0`, computed off-thread at the device's actual `Fs`.

**Sample-rate / format correctness (reviewer MAJOR):** install a `kAudioDevicePropertyNominalSampleRate` + stream-format listener; on change, recompute coeffs from `@MainActor` and republish. CoreAudio can change the rate live *without* a start/teardown cycle — do not assume `startProc` brackets every change. Until recomputed, the proc keeps using the last valid block.

**Denormal protection (reviewer missing-consideration):** set FTZ/DAZ in the proc thread (flush-to-zero) to avoid IIR-state denormal CPU spikes during silence.

**Clipping (reviewer missing-consideration):** clamp the post-EQ sample to `[-1, 1]` (or a soft limiter) at the chain end so a +12 dB boost cannot hard-clip the DAC.

### 3.3 Swift API sketch

```swift
// SeirenKit/EQEngine.swift
public enum BiquadType: String, Codable, Sendable { case peaking, lowShelf, highShelf, highpass, lowpass }

public struct EQBand: Codable, Equatable, Sendable {
    public var type: BiquadType
    public var freq: Float       // 20...20000 Hz
    public var gainDB: Float     // -12...+12 (ignored for HPF/LPF)
    public var q: Float          // 0.1...10
    public var enabled: Bool
}

public struct EQPreset: Codable, Equatable, Sendable {
    public var name: String
    public var bands: [EQBand]
    public static let flat, podcast, studio, broadcastVocal: EQPreset
    public static let builtIns: [EQPreset]   // [flat, podcast, studio, broadcastVocal]
}

// MonitorEngine additions (all @MainActor)
extension MonitorEngine {
    public var eqEnabled: Bool { get set }       // writes gEQEnabled, notify()
    public var eqPreset: EQPreset { get set }    // builds coeffs off-thread @ current Fs, atomic swap, notify()
    public func setEQBands(_ bands: [EQBand])    // Custom (v0.3+)
    public private(set) var eqSampleRate: Double
}
```

POD-only on the RT side; everything refcounted stays `@MainActor`.

### 3.4 UI

A single **"Voice ▸"** submenu (shared with NS — see §6 IA), inside the existing menu, reusing `modeItem()` radio-checkmark and `volumeItem()` slider-in-`NSView` patterns:

- Disabled caption: **"Headphone monitor only"** (non-negotiable honesty line).
- **EQ On** checkmark (disabled when `mode == .off`).
- Preset radios: **Flat / Podcast / Studio / Broadcast-Vocal**.
- The existing volume slider acts as **post-EQ make-up gain**.

**v0.2 ships presets-only — no Custom editor, no window/panel, no curve canvas.** (Reviewer: even a slider-row panel is a new UI surface for an app that is currently menu-only.) The Custom slot + a single optional `NSPanel` of per-band slider rows is deferred to v0.3+. A draggable-curve canvas is **struck from the roadmap**, not merely deferred.

Persistence via the versioned `Settings` wrapper (§6): `voice.eq.enabled`, `voice.eq.preset`, later `voice.eq.bands`.

### 3.5 Reaches other apps vs monitor-only

**MONITOR-ONLY.** EQ output goes solely to the headphone device. Zoom/OBS/Discord open the Seiren directly and get the raw mic — they do **not** hear the EQ. Reaching them requires the virtual-device path (Decision A / v2). The "Headphone monitor only" caption + a README "What other apps hear" section are a **single acceptance criterion for v0.2**.

### 3.6 Risks

- **RT regression** (ARC/alloc/lock on the proc) → glitches. Mitigate: POD-only published via C11 atomic, deferred free on main, TSan + review (atomic-swap correctness is *not* unit-testable; rely on TSan).
- **Torn/garbage coeff read** if published without a release barrier → loud transient. Mitigate: real atomic store-release / load-acquire.
- **Live sample-rate change** detunes EQ. Mitigate: property listener + recompute.
- **Denormals** → CPU spike. Mitigate: FTZ/DAZ.
- **Clipping** on boosts. Mitigate: end-of-chain clamp/limiter.
- **Preset curves are approximations** (Razer's factory curves are unpublished). Mitigate: tune by ear; ship Custom slot in v0.3.

### 3.7 Effort

**M.** (Establishes the shared audio-pipeline plumbing all later audio features reuse.)

---

## 4. Feature: Noise Suppression

### 4.1 Chosen approach + rationale

Two engines, layered (Decision B):
- **v0.3 default: in-tree noise gate** — pure Swift, zero deps, **zero added latency**, fully self-contained.
- **Opt-in "Studio" mode: RNNoise** (BSD-3) vendored as a SwiftPM C target — best speech quality, gated behind a clean-CLT-build check.

`VoiceProcessingIO` rejected (it's an I/O unit forcing an `AVAudioEngine` rewrite of the one proc the app is built around). Spectral gating kept as documented fallback only.

### 4.2 Architecture

One shared per-sample stage inside `monitorIOProc`, ordered **gate/denoise → EQ → gain** (denoise the raw mic first so EQ doesn't amplify gated residue or pump the noise floor).

**Gate:** `nonisolated(unsafe)` POD state (threshold, attack/hold/release coeffs precomputed at `startProc` from `Fs`, current gate level). No latency, no ring buffer.

**RNNoise (Studio mode) — the hard parts reviewers flagged:**
- **Frame bridge:** RNNoise needs 480-sample (10 ms) mono frames @48 kHz; the device buffer is ~128. 128 and 480 are not commensurate (lcm 1920). A fixed-size input/output ring (allocated once at `startProc`, freed at `teardownProc`, **never** on the RT thread) decouples the cadences.
- **Honest latency budget (reviewer correction — the "~10 ms" claim was understated):** device-in (~2.7 ms) + 480-sample assembly + output priming ≈ **~13–18 ms one-way** with NS on. This can comb-filter your own voice → **NS is OFF by default**; EQ-only keeps the ~2.7 ms fast path. **Measure on hardware before shipping v0.3.**
- **Scaling (reviewer correctness bug):** RNNoise expects ±32768-range float, not CoreAudio's ±1.0. **Scale ×32768 in, ÷32768 out.** Add a round-trip unit test. Passing ±1.0 yields ~no suppression (feature looks broken).
- **48 kHz hard guard:** RNNoise is hard-wired to 48 kHz. **Bypass NS if the live device rate ≠ 48000** (don't merely assume).
- **First-buffer / half-primed:** the proc must treat a `nil` *or half-filled* ring as bypass to avoid an underrun click on the buffer where NS turns on.
- **Wet/dry mix (reviewer DSP bug):** a naïve `mix·wet + (1−mix)·dry` comb-filters because the wet path is ring-delayed and the dry path is not. **For v1, ship ON/OFF only** (no continuous mix) to avoid the comb trap; if a mix is added later, delay-compensate the dry path through a matched delay line.

**RT-safe handoff:** DenoiseState + rings published via a single C11-atomic pointer (release/acquire); `nil` ⇒ bypass. Same discipline as `gMonitorLevel`.

**RNNoise vendoring (must preserve no-build-step):** vendor pre-generated C sources only — **commit the generated model (`rnnoise_data.c`) and a hand-written module map, remove the autotools/CMake `config.h` dependency**. Verify `swift build` is clean on CLT-only *and* full Xcode before committing the target. **If it can't build CLT-only, ship the gate alone for v0.3 and add RNNoise later.**

### 4.3 Swift API sketch

```swift
public enum NSMode: String, Codable, Sendable { case off, gate, rnnoise }

extension MonitorEngine {
    public var noiseSuppression: NSMode { get set }   // default .off
    public var inputPeak: Float { get }               // RT-published, for the gate meter
}
```

`Package.swift`: add `.target(name: "RNNoise")` (vendored BSD-3 C sources + baked model + module map), add to `SeirenKit` deps. Still SwiftPM, no Xcode project.

### 4.4 UI

Inside **"Voice ▸"** (below EQ): **Noise Suppression** radios **Off / Gate / Studio** (Studio shown only when the RNNoise target is present), a gate open/closed meter (reuses `inputPeak`), and the caption **"Applies to your headphone monitor only."** Label it **"Reduce background noise"** — under-promise vs Razer's "AI" branding. Persist `voice.ns.mode`.

### 4.5 Reaches other apps vs monitor-only

**MONITOR-ONLY** (same as EQ). Callers/recordings still get the raw, noisy mic. Reaching them needs the virtual device (v2). The caption is mandatory or the feature reads as broken. Interim: document BlackHole + Aggregate Device in the README.

### 4.6 Risks

- **Latency** erodes the core promise → gate default (0 ms), RNNoise opt-in with a stated caveat, hardware latency test gates v0.3.
- **First C dependency** could break clone-and-build → prove CLT-only build first; fall back to gate-only.
- **48 kHz assumption** → hard bypass guard.
- **Scaling bug** → ×32768 + round-trip test.
- **Comb filtering** → ON/OFF only for v1.
- **RT regression** → atomic pointer, alloc/free only in start/teardown.

### 4.7 Effort

**M** (gate is **S**; RNNoise integration is the **M** part).

---

## 5. Feature: Lighting (RGB)

### 5.1 Chosen approach + rationale — honesty first

**No captured Seiren lighting bytes exist.** Unanimous across research and the repo: the device JSON has every command `null`; the Synapse log had **zero** lighting `dataSend` arrays (Chroma went through an opaque `RzLightingAPI` DLL logging only `Action:61447 / Status:0`); `razer-macos`/`librazermacos` contain no PID `0x058E`, no Seiren, no mic at all; one strand reported `hasLedStrips=false`.

Therefore: **ship scaffold + disabled UI now; send nothing until a verified capture lands** (Decision C). This mirrors the existing nil-until-captured `CommandTable` / `.notCaptured` pattern.

**Two CRITICAL reviewer issues, resolved in the design:**

1. **No byte substitution against hardware.** The original template-with-RGB-offsets + `crcOffset`-recompute model is byte *generation*, not replay — interpolated colors/brightness and recomputed checksums are byte combinations never captured, on a channel (`0xFF53`/`0x07`) shared with audio/device-mode control → wedge/DFU risk that PROTOCOL rules forbid. **Resolution:** permit **only verbatim replay of individually-captured frames** for this PID. Lighting is modeled as `effects: [String: CommandFrame]` where every entry is a literal captured frame; a color picker maps to the **nearest captured preset**, it never synthesizes bytes. **`ColorFrame`/`ScalarFrame`/`crcOffset` are removed.**

2. **The standard Chroma format does not apply and is never a fallback.** OpenRazer Chroma is 90 bytes, report ID 0, USB *control transfer* (`bmRequestType 0x21`, `wValue 0x300`), CRC = XOR bytes 2..87 — structurally incompatible with the Seiren's 63-byte Feature report `0x07` (which is documented as zero-padded, **no CRC**). **Resolution:** explicitly forbid the 90-byte Chroma format as a fallback; add a guard that rejects any lighting frame whose length/reportID doesn't match a captured-and-recorded Seiren frame. `razer-macos` is treated as documentation of a format we will **not** send.

### 5.2 Architecture

Extends the HID plane only — never touches the audio thread.

- **`DeviceModel`** gains an optional, Codable `LightingTable { presets: [String: CommandFrame]?; off: CommandFrame?; handshake: [CommandFrame]? }` — all `nil` for the V3 Pro. `var lightingSupported: Bool { (lighting?.presets?.isEmpty == false) }`.
- **`LightingController`** (thin peer over `SeirenController.send`): `setEffect(_:)`, `lightsOff()`, each returning the existing `ApplyResult` (`.notCaptured` when the field is `nil`; `.noDevice` / `.permissionDenied` reused). Sends `handshake` prefix first if captured; reuses the exact `IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x07, [0x07]+payload, 64)` path.
- **Zero-padding (reviewer MINOR):** pad captured payloads to the device's declared report length (63 data bytes) before sending — many HID stacks require the exact declared length. (Confirm/fix the same in the monitor `send()` once monitor bytes are captured.)
- **`DeviceRegistry`** unchanged: a captured model is just a JSON file with a populated `lighting` object dropped in `~/Library/Application Support/seiren-mac/devices/` — no rebuild.
- **Shared-channel serialization (reviewer MAJOR):** **all** `0xFF53`/`0x07` sends (lighting + any future DSP-over-HID) route through **one serialized queue / one controller** so frames never interleave. Sidetone stays on its UAC/Core Audio path — never on this HID channel.

### 5.3 Swift API sketch

```swift
public struct LightingTable: Codable, Equatable, Sendable {
    public var presets: [String: CommandFrame]?   // each value a LITERAL captured frame
    public var off: CommandFrame?
    public var handshake: [CommandFrame]?
}
extension DeviceModel {
    public var lighting: LightingTable?
    public var lightingSupported: Bool { lighting?.presets?.isEmpty == false }
}

public enum LightingEffect: String, Sendable { case off, staticColor, breathing, spectrum, audioMeter }

extension SeirenController {        // serialized on the single 0xFF53/0x07 queue
    public func setEffect(_ name: String) -> ApplyResult   // .notCaptured if presets[name] == nil
    public func lightsOff() -> ApplyResult
}
// Send guard: reject any frame whose reportID != 0x07 or length != captured-frame length.
```

No `ColorFrame`, no `ScalarFrame`, no `crcOffset` — removed per review.

### 5.4 UI

A **"Lighting ▸"** submenu:
- **Uncaptured (today's V3 Pro):** a single disabled line **"Lighting — needs a verified capture"** + a "How to capture…" item linking to `CONTRIBUTING.md`. Mirrors the existing `.notCaptured` UX.
- **Verified:** effect radios (Off / Static / Breathing / Spectrum) + an Audio-Meter item (deferred; reuses `inputPeak`); a color picker that maps to the nearest captured preset. Re-assert on hotplug (lighting state is volatile). No "applying" spinner — `ApplyResult` is synchronous.

Honest copy: **"Lighting (replayed Synapse commands)"**; never imply game/stream-reactive Chroma (needs Razer's SDK, out of scope on macOS).

### 5.5 Reaches other apps vs monitor-only

**Neither.** Lighting is pure HID device control, independent of audio. It touches no audio path and nothing other apps record/play. No virtual device, no driver, no signing — it stays inside the unsigned menu-bar app. The only shared resources are the Input-Monitoring TCC grant and the `0xFF53`/`0x07` channel (serialized per §5.2).

### 5.6 Phase-0 capture procedure (prerequisite, off-Mac, gates go-live)

On a Windows / Boot Camp box with Synapse 4 + the Seiren:
1. **GO/NO-GO first:** does Synapse expose *any* lighting UI for the V3 Pro on the physical unit? If not → record "no addressable RGB", ship the disabled stub, **stop**.
2. Prefer Synapse's HID logs (`%LOCALAPPDATA%\Razer\…\Logs\`); change to a *known* color (pure red), grep for the new `dataSend` array. Repeat green/blue/on/off to triangulate. Or USB-sniff with Wireshark + USBPcap, diff baseline vs single-change.
3. **Validation gate:** a capture is valid only if, on the physical unit, the change produces a HID frame **and** a visible LED change. Capture 3+ known states and **replay each verbatim** to confirm before shipping.
4. Record each as a literal `CommandFrame` in the device JSON; drop in app-support to test; PR into builtins. **No code change.**

### 5.7 Risks

- **Brick / firmware (highest):** mitigated by sending nothing unverified, verbatim-replay-only, length/reportID guard, single serialized channel. Recovery (re-plug / Synapse reset, keep a Windows box) documented in `CONTRIBUTING.md`.
- **No RGB hardware at all:** valid outcome → permanently-disabled submenu is success.
- **Channel collision** with future DSP-over-HID → single serialized queue.
- **TCC** → reuse `.permissionDenied` path.
- **Blocked on Windows capture** → exactly like monitor bytes; opportunistic, not scheduled.

### 5.8 Effort

**S to build the scaffold; L to unblock** (the unblock is the Windows capture, which may never yield bytes).

---

## 6. Integration & architecture

### 6.1 The shared AudioPipeline

One IOProc, one buffer pass, separate **stages** chained as concrete inlined math — **not** separate AudioUnits/graphs and **not** a Swift-protocol/existential chain (reviewer CRITICAL: protocol dispatch + a Swift `Array` of stages on the RT thread is exactly the runtime/ARC traffic the proc forbids).

```
monitorIOProc(buffer):
    cfg = atomic_load_acquire(gActivePipeline)   // raw pointer to POD block; nil ⇒ passthrough
    for each frame:
        s = mic[ch0]
        s = applyNoise(s, cfg)     // @inline(__always), POD state, bypass if nil/half-primed/Fs≠48k
        s = applyEQ(s, cfg)        // @inline(__always) biquad cascade over fixed-size POD coeffs
        s = clamp(s * cfg.gain)    // post-EQ make-up + clip guard
        fan s to all output channels
```

- `gActivePipeline` is a **C11 atomic raw pointer** to a `malloc`'d POD struct `{ gain: Float; eqCount: Int32; eqCoeffs: [fixed C array]; nsMode: Int32 }`. **No Swift `Array`, no class, no Unmanaged** in the published block.
- `@MainActor` setters build a fresh immutable POD block off-thread → `atomic_store_release`. Old block freed on main one reconcile cycle later (deferred free so the RT thread never dereferences freed memory).
- `gMonitorLevel` is folded into `cfg.gain` (the public `level` var routes through it — back-compat preserved).
- Per-stage **state** (biquad `z`, gate envelope, RNNoise DenoiseState + rings) lives in RT-owned pre-allocated buffers, allocated/freed only in `startProc`/`teardownProc`.

### 6.2 Module boundaries (SeirenKit, alongside the existing 5 files)

**Audio plane:**
- `AudioPipeline.swift` (NEW) — the POD config block, the C11-atomic publish/read, the inlined stage functions.
- `EQEngine.swift` (NEW) — RBJ coeff computation (off-thread), preset definitions.
- Gate + RNNoise glue live with the pipeline; `RNNoise` is a separate vendored C target.
- `MonitorEngine.swift` — unchanged ownership of discovery, hotplug, auto-mode, IOProc lifecycle; gains setters that forward to the pipeline + a `kAudioDevicePropertyNominalSampleRate`/format listener.

**HID plane:**
- `LightingController.swift` (NEW) — verbatim-replay sends over the single serialized `0xFF53`/`0x07` queue.
- `DeviceModel` gains `LightingTable`; `DeviceRegistry` unchanged (JSON override channel).

**App:**
- `Settings.swift` (NEW) — typed `UserDefaults` wrapper with `schemaVersion` + `migrate()`. **Lands as the first commit of v0.2, before any new keys** (today there is only the ad-hoc `legacyEnabled → .always` migration; 6+ new keys across three features need versioning). Namespaced keys: `voice.eq.*`, `voice.ns.*`, `lighting.*`.
- `AppDelegate` gains `voiceSubmenu()` and `lightingSubmenu()` builders.

The two planes are kept strictly separate: audio never sends HID; lighting never touches the audio thread; their only overlaps are the Input-Monitoring TCC grant and (for any future DSP-over-HID) the one serialized HID channel.

### 6.3 Menu-bar IA (single source of truth — adopt across all features)

Stay a **menu**, not a window app. Top level stays glanceable; features go in two shallow submenus so adding NS in v0.3 doesn't reflow the top level:

```
● Seiren V3 Pro — Monitoring            (disabled status line)
  ○ Off   ◉ Always   ○ Auto              (Mode radios)
  [ Volume ──────●──── ]                  (existing slider; doubles as post-EQ make-up)
  Voice ▸                                 → EQ presets, EQ On, NS Off/Gate/Studio, meter,
                                            "Headphone monitor only"
  Lighting ▸                              → effects/color, or disabled "needs a verified capture"
  ─────────
  ☐ Launch at Login
  Quit
```

Every feature reuses `modeItem()` radio-checkmarks and `volumeItem()` slider-in-`NSView` verbatim. At most **one** optional `NSPanel` ever (the future EQ band editor) — never a curve canvas, never a mixer window in the menu-bar app.

### 6.4 Tests & docs

- Hardware-free unit tests like `MonitorEngineTests` (dummy device): biquad frequency response (sine in, measure gain), gate threshold crossing, gain scaling, **RNNoise ×32768 round-trip scaling**, `LightingController` `.notCaptured` path, length/reportID guard. **Atomic pointer-swap correctness is NOT unit-testable** — rely on TSan + review (reviewer correction).
- README gains a **feature matrix** + a **"What other apps hear"** section (gating for v0.2) + the BlackHole/Aggregate-Device stopgap. `CONTRIBUTING.md` documents the HID capture protocol (report ID/length, no-CRC PA frame, how to add device JSON) and the brick-recovery procedure.

---

## 7. Phased release roadmap

Each phase is independently shippable and never breaks the trust model.

| Version | Scope | Effort | Notes |
|---|---|---|---|
| **v0.2.0 — Parametric EQ** | `Settings` wrapper (first commit) → `AudioPipeline` + RBJ biquad cascade (C11-atomic publish, FTZ, clamp, rate listener) → Flat/Podcast/Studio/Broadcast presets in "Voice ▸" → volume = post-EQ make-up → README "What other apps hear". **No Custom editor, no panel, no deps.** | M | Lowest risk; establishes the pipeline. |
| **v0.3.0 — Noise Suppression** | In-tree gate (default, 0-latency) → optional RNNoise "Studio" C target (×32768 scaling, 48 kHz guard, ring bridge, ON/OFF only) after a clean-CLT-build check → "Voice ▸" NS radios + meter. Optional: EQ Custom slot + one `NSPanel`. | M | Hardware latency test gates RNNoise. |
| **v0.4.0 — Lighting scaffold** | `LightingTable` + `LightingController` (verbatim-replay-only, length/reportID guard, serialized channel) → disabled "Lighting ▸" stub → capture docs in `CONTRIBUTING.md`. **Sends nothing.** | S build / L unblock | Go-live only after a validated Phase-0 capture; "no RGB" is a valid stop. |
| **v1.0.0 — Stabilize** | Harden settings migration, docs, feature matrix, tests; polish the three features. | S | |
| **v2.x — Developer-ID tier (ROADMAP-ONLY)** | Signed/notarized BlackHole-class **virtual audio device** so EQ/NS reach all apps → **Streamer Mixer** on top. Separate `.driver` bundle, installer, signing track. | XL | Requires a paid Developer ID; explicitly outside the menu-bar app. |

**Build-order rationale:** EQ first (native, lowest risk, builds the pipeline) → NS second (reuses the pipeline) → Lighting third (isolated HID plane, external-capture-gated) → mixer never until signing exists.

### 7.1 Streamer Mixer — ROADMAP-ONLY (do not design for build)

**What it is:** a macOS analog of Synapse's Stream Mixer — virtual **input** channels (Game / Chat / Browser / System / Music / Mic / Aux) with per-channel faders + mute, summed into two virtual **output** devices: a **Stream Mix** (one clean source OBS captures) and a **Playback Mix** (what the creator monitors).

**Why deferred:** it is fundamentally a multi-input → multi-virtual-output routing engine and **requires** one or more virtual audio devices (CoreAudio HAL plug-in / AudioServerPlugIn / DriverKit). That breaks every invariant: cannot be unsigned (modern `coreaudiod` may refuse unsigned/ad-hoc HAL plug-ins; DriverKit needs an Apple-granted entitlement), cannot be no-build-step (separate `.driver` bundle, `sudo` install to `/Library/Audio/Plug-Ins/HAL`, `coreaudiod` restart, system-extension approval), and bursts the menu-bar scope (multi-channel engine + per-app routing UI). It is the natural "we got a Developer ID" milestone.

**Honest interim:** a README page pointing creators at **BlackHole + an Aggregate Device** — acknowledge the gap rather than ship half a driver.

---

## 8. What we can build NOW vs what needs a Windows HID capture

### Buildable NOW (no capture, no signing, no driver)

- **Parametric EQ** — pure software DSP in `monitorIOProc`. Sends **zero** HID bytes. Ships in v0.2.
- **Noise Suppression** (gate + RNNoise) — same audio path. Sends **zero** HID bytes. Ships in v0.3.
- **Lighting scaffold** — structs, API, disabled UI, docs. Sends **zero** HID bytes. Ships in v0.4.
- **Honest UX/docs** — "monitor-only" captions, "What other apps hear", BlackHole stopgap.

These are **monitor-only** (EQ/NS) or **no-op** (lighting) — real value, zero trust-model risk.

### Needs a Windows HID capture before it can do anything

- **Lighting go-live** — blocked on a validated Synapse capture of the V3 Pro lighting report (and on the V3 Pro actually having addressable RGB — unconfirmed; may be permanently disabled).
- **Hardware EQ / DSP over HID** — the research log's 65-byte EQ frames are *not in this repo*, are a different length than the 63-byte report-0x07 channel, and carry a checksum the PA frame lacks. **Out of scope; capture-gated.** Software DSP supersedes it for v1.
- **Hardware monitor on/off** — even *this* was never captured (which is why monitoring is software in the first place).

### Needs a paid Apple Developer ID (separate v2 tier)

- **Virtual audio device** (reaches-other-apps EQ/NS) and the **Streamer Mixer** on top of it.

### The hard rule

**Never send un-captured or synthesized bytes to hardware.** Lighting and any DSP-over-HID are gated behind a **per-PID verified-capture flag** that is true only when the device JSON holds literal, individually-captured frames for that PID — replayed verbatim, zero-padded to the declared report length, on a single serialized `0xFF53`/`0x07` channel, never colliding with the (UAC/Core Audio) sidetone path.

---

## 9. Reviewer issues — resolution ledger

| # | Sev | Issue | Resolution |
|---|---|---|---|
| 1 | CRITICAL | AudioPipeline protocol/existential + Swift `Array` on the RT thread (ARC/witness-table traffic) | §6.1 — dropped; concrete inlined `@inline(__always)` math over a fixed-size POD coeff block; no protocol, no Array, no Unmanaged on the RT path. |
| 2 | CRITICAL | Coeff publish via plain `var`/`Unmanaged` lacks a memory barrier → torn/garbage read | §3.2/§6.1 — real **C11 atomic** store-release/load-acquire (macOS-13-safe; `Synchronization` is 15+ so not used); POD block; deferred free on main. |
| 3 | CRITICAL | Lighting byte substitution = fuzzing; no captured frame; brick/DFU risk on shared channel | §5.1 — **removed**; verbatim-replay-only of individually-captured frames; `ColorFrame`/`crcOffset` deleted; per-PID verified flag; default `.notCaptured`. |
| 4 | CRITICAL | Standard 90-byte Chroma format assumed/incompatible | §5.1 — explicitly forbidden as a fallback; length/reportID guard; `razer-macos` is reference-only. |
| 5 | CRITICAL | EQ narrative leans on un-captured "65-byte EQ frames" | §3.1/§8 — EQ is software-DSP only, sends nothing over HID; hardware EQ out-of-scope and capture-gated. |
| 6 | MAJOR | RNNoise latency understated ("~10 ms") | §4.2 — restated as **~13–18 ms** one-way; NS off by default; hardware latency test gates v0.3. |
| 7 | MAJOR | RNNoise ±1.0 vs ±32768 scaling bug | §4.2 — **×32768 in / ÷32768 out** + round-trip unit test. |
| 8 | MAJOR | Wet/dry mix comb-filters (delayed wet vs undelayed dry) | §4.2 — **ON/OFF only** for v1; if added later, delay-compensate the dry path. |
| 9 | MAJOR | Live sample-rate/format change without start/teardown detunes DSP | §3.2 — `kAudioDevicePropertyNominalSampleRate`/format listener → recompute & republish; bypass block-DSP if rate ≠ 48 kHz. |
| 10 | MAJOR | Unsigned HAL plug-in may not load on modern `coreaudiod` | §2-A / §7.1 — don't promise unsigned HAL loads; treat virtual device as needing ≥ad-hoc signing, verify on target OS, keep out of the menu-bar app. |
| 11 | MAJOR | Shared `0xFF53`/`0x07` channel serialization + recovery undocumented | §5.2 — single serialized queue for all lighting/DSP sends; recovery written into `CONTRIBUTING.md`; sidetone stays off this channel. |
| 12 | MAJOR | Lighting capture not validated against the physical unit | §5.6 — Phase-0 GO/NO-GO + visible-LED validation gate; 3+ known states replayed verbatim. |
| 13 | MAJOR | Monitor-only honesty relegated to a late "docs" phase | §3.4/§3.5/§6.4 — README "What other apps hear" is a **v0.2 acceptance criterion**, paired with the menu caption. |
| 14 | MAJOR | Four-feature scope unrealistic for a solo maintainer; Lighting hard-blocked | §2-C/§7 — only EQ is committed near-term; Lighting demoted to scaffold-only, indefinitely gated, with a GO/NO-GO checkpoint. |
| 15 | MAJOR | EQ Custom editor/panel is a new UI surface too early | §3.4 — v0.2 is **presets-only**; Custom slot + one `NSPanel` deferred to v0.3+; curve canvas struck from the roadmap. |
| 16 | MINOR | HID report length: `send()` uses captured length, not declared 63 | §5.2 — zero-pad to the declared report length; confirm/fix in monitor `send()` once monitor bytes are captured. |
| 17 | MINOR | vDSP.Biquad / DF2T state must not be a Swift Array | §3.2 — state is a fixed C array / pre-allocated raw buffer; hand-rolled DF2T preferred. |
| 18 | MINOR | `nonisolated(unsafe)` suppresses the checker without making access safe | §6.1 — every RT-shared global is **POD only**; the annotation is honored, not relied on. |
| 19 | MINOR | EQ biquad sample-rate correctness only listed as a risk | §3.2 — gated via the rate listener + recompute, same mechanism as the NS bypass. |
| 20 | MINOR | First C dependency may break CLT-only no-build-step | §4.2 — prove clean CLT-only build first; commit pre-generated model + module map, drop `config.h`; else ship gate-only. |
| 21 | MINOR | Settings migration debt (6+ keys, no versioning) | §6.2 — `Settings.swift` with `schemaVersion` + `migrate()` lands as the first v0.2 commit. |
| 22 | MINOR | Cross-feature UI inconsistency (flat vs submenus) | §6.3 — the "Voice ▸ / Lighting ▸" IA is the single source of truth for all features. |
| — | MISSING | Denormal/subnormal CPU spikes in IIR/gate during silence | §3.2 — FTZ/DAZ in the proc. |
| — | MISSING | Post-EQ clipping at the DAC | §3.2 — end-of-chain clamp/soft-limiter. |
| — | MISSING | Deferred-free ordering so RT never dereferences a freed coeff block | §6.1 — old block freed on main one reconcile cycle later. |
| — | MISSING | First-buffer / half-primed ring click on NS enable | §4.2 — proc treats nil/half-filled ring as bypass. |
| — | MISSING | RNNoise generated model/config preventing no-build-step | §4.2 — commit `rnnoise_data.c` + hand-written module map, remove `config.h`. |
| — | MISSING | Atomic-swap "unit test" is not meaningfully testable | §6.4 — rely on TSan + review, not a unit test. |

---

*Verified against the repo: `Package.swift` is three pure-Swift targets at `swift-tools-version:6.0` / `.macOS(.v13)` (confirming the C11-atomics-over-`Synchronization` and CLT-only constraints); `devices/seiren-v3-pro.json` has `monitorOn/monitorOff/handshake` all `null` ("Monitor bytes NOT yet captured") — the project has captured zero HID frames, and report `0x07` / usage `0xFF53` / interface 3 / 63 data bytes is the documented send channel (`docs/PROTOCOL.md`). Capture recipe + brick-recovery to be added to `CONTRIBUTING.md`.*