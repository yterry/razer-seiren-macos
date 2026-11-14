# Contributing

Thanks for helping. **Seiren for macOS** is a small creator app for Razer Seiren
mics — **monitoring, EQ, and noise suppression** — and its foundation, *hearing
yourself*, is solved the same way for the whole Seiren line: one full-duplex Core
Audio loop that copies mic → headphone. There are no per-model command bytes to
capture for monitoring (and the EQ/denoise are device-agnostic DSP). That means
most contributions are small: confirm a model works, fix a quirk, or improve the
app.

By participating, you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).

## How support for other Seiren / Razer mics works

Monitoring is **device-agnostic**. `MonitorEngine` finds any physical audio
device whose name contains `seiren` (case-insensitive, configurable via
`MonitorEngine(deviceNameMatch:)`) and installs the IOProc on it. If macOS sees
your mic as a normal full-duplex USB-audio device with a headphone output, it
should Just Work — **no code, no JSON, no captured bytes.**

Mics **without a headphone jack** (the V3 Mini is one) are input-only Core Audio
devices. They are supported too: the engine notices the missing output at
runtime, skips the monitor, and runs the same IOProc into **Seiren FX** so the
EQ + noise suppression reach other apps. The check for those is
`swift run seiren-probe route` (below), since there is nothing to hear.

So the most useful thing you can do is **tell us your model works** (or doesn't):

1. **Confirm it the fast way** with the bundled probe + reference monitor:
   ```sh
   swift run seiren-probe                 # read-only: lists devices + every audio control
   swift run seiren-probe monitor swmon 0.9   # software monitor: speak, hear yourself, Return to stop
   swift run seiren-probe route           # jack-less mic: run the real engine 5 s via Seiren FX
   ```
   `swmon` runs the *exact* IOProc the app uses. If you hear yourself, the app
   will work for your device. For a mic with no headphone jack, `route`
   (with Seiren FX installed) prints whether the route came up, the buffer
   layout the aggregate produced, and the mic's peak level - that output is
   what to paste in an issue.
2. **Open an issue / PR** with:
   - the device **name** as it appears in `seiren-probe` output (this is what the
     name-match keys on),
   - **VID/PID** (`ioreg -p IOUSB -l | grep -iE 'idVendor|idProduct'`),
   - macOS version and `swift --version`,
   - the full `seiren-probe` dump.

### When a model needs more than the name match

Two realistic cases, both small:

- **Name doesn't contain "seiren"** (some Razer mics are branded differently). Fix
  is a one-liner: broaden the match or let the app accept a user-supplied match
  string. Propose the device name in an issue and we'll add it.
- **No headphone jack** (input-only). Already handled - the engine detects it.
  What helps is a `seiren-probe route` printout confirming it on your model, and
  a `devices/<model>.json` entry (name, PID) so the registry knows the model.
- **Channel layout is unusual** (mic isn't input channel 0, or output isn't where
  you expect). The reference IOProc fans **input channel 0 → all output channels**;
  if a device differs, the probe dump tells us, and the fix is a small,
  data-driven tweak to channel selection — not a new transport.

### What `devices/*.json` is (and isn't) for

The `devices/` JSON files and the `DeviceRegistry` are about the **HID** side:
the vendor control channel (lighting today, EQ/DSP commands if ever captured)
and per-model capabilities - **not** monitoring or the audio DSP, which need
none of it. Two fields matter:

- `pid` - the USB product ID; how the HID code recognises the model.
- `chromaLighting` - `true` only for models with a Chroma zone driven by the
  verified "Device25" protocol (the V3 Pro). **Absent means `false`**, and a
  model without it is never opened or written to by the lighting code. Don't
  flip it on for a model just because it has an LED: the V3 Mini's HID channel
  has the same report shape on a different usage page (`0xFF07`) and has never
  been exercised - see [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §1.1.

See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) and
[`docs/HARDWARE_SIDETONE.md`](docs/HARDWARE_SIDETONE.md) for why monitoring lives
in Core Audio instead.

### Exercising the app without a Seiren

`SEIREN_DEVICE_MATCH="<name substring>" swift run seiren-mac` points the engine at
any other input device (an input-only USB interface is a faithful stand-in for a
jack-less Seiren), and `swift run seiren-probe route 5 --device "<name>"` does
the same for the probe. `SEIREN_MONITOR_DEBUG=1` logs Auto-mode detection.

## How it works

The app opens the Seiren as a **full-duplex Core Audio device** and installs **one `AudioDeviceIOProc`**.
On every audio cycle that callback copies the mic input (channel 0) into every headphone output channel, scaled by your level (`0…1`).
That's the whole monitoring path - input to output, in-process, on the real-time audio thread.

- **Auto start/stop.**
  The engine listens on `kAudioHardwarePropertyDevices`.
  When a Seiren appears it starts the IOProc; when it disappears it tears down cleanly (`AudioDeviceStop` + `AudioDeviceDestroyIOProcID`).
  Your "monitoring on" intent survives unplugging.
- **Real-time-safe callback.**
  The IOProc does no allocation, no locks, no Obj-C, no Swift-runtime calls - it just reads samples and writes samples.
  The level is a single atomically-readable value the UI can change live.
- **Device match by name.**
  Any *physical* audio device whose name contains `seiren` (case-insensitive) and has an input stream qualifies, so most Seiren models work with no per-model code.
  A model with an output stream (headphone jack) gets the monitor; an input-only model (V3 Mini) runs the same IOProc into Seiren FX only - the engine notices the missing output at runtime, so there is no model list to maintain.
  The app's own virtual devices (Seiren FX, its private aggregate) are excluded even though their names match.
  With no Seiren connected, the same route runs from another physical input (the Input menu), into Seiren FX only.

The core lives in **`SeirenKit`** (no AppKit, fully testable):

```swift
let engine = MonitorEngine(deviceNameMatch: "seiren")
engine.enable()          // find the Seiren, start the IOProc
engine.level = 0.8       // 0...1, applied live
engine.disable()         // stop monitoring (intent persists across unplug)
```

> The reference IOProc is already in the repo - see `swMonProc` / `softwareMonitor()` in [`Sources/seiren-probe/main.swift`](Sources/seiren-probe/main.swift), which you can run today (`swift run seiren-probe monitor swmon 0.9`) to hear the exact path the app uses.

### The latency trade-off, honestly

> **The monitor is *software*.**
> macOS blocks the route to the Seiren's *hardware* sidetone (every hardware path is blocked or silent - see [Why software monitoring?](docs/HARDWARE_SIDETONE.md#why-software-monitoring-the-hardware-sidetone-path-macos-blocks)), so the app runs one full-duplex Core Audio loop that copies mic → headphone in userspace.
> The EQ/denoise add nothing to this direct-monitor path (Studio denoise applies only to the broadcast).
> It is not a sample-accurate DAW monitor.

Monitoring delay ≈ one audio I/O buffer.
At a typical 256-frame buffer / 48 kHz that's ~5 ms each way; you can lower it with `kAudioDevicePropertyBufferFrameSize` at the cost of CPU and stability.
For *hearing your own voice* this is fine - it's well under the threshold where you'd notice an echo.
It is **not** a zero-latency hardware path (which, again, macOS won't give us here), so it isn't the right tool for sample-accurate latency-free DAW monitoring.

## Architecture

```
Sources/
  SeirenKit/         model-independent core (no AppKit, fully testable)
    MonitorEngine.swift   IOProc: mic → gate → EQ → monitor; +Studio → Seiren FX
    AudioDevices.swift    Core Audio device + recording-process queries
    MixerEngine.swift     Stream Mixer: process taps + Seiren FX → Seiren Stream Mix
    EQEngine.swift        RBJ-cookbook coefficient math + voice presets
    Settings.swift        versioned UserDefaults preferences + schema migrations
    ...                   (legacy HID model/registry types; see docs/PROTOCOL.md)
  SeirenDSP/         RT-safe C DSP: biquad EQ, noise gate, RNNoise bridge, resampler,
                     stream mix bus (gain ramps + limiter)
  RNNoise/           vendored xiph/rnnoise (BSD-3) — the "Studio" denoiser
  seiren-mac/        the menu-bar agent (main.swift + AppDelegate): 🎙 menu —
                     modes, Level, Input ▸, Voice ▸ (EQ + noise suppression),
                     Stream Mixer ▸, Seiren FX install
  seiren-probe/      read-only Core Audio diagnostic + the reference swmon IOProc
Driver/SeirenFX/     the loopback virtual audio devices, Seiren FX and Seiren
                     Stream Mix (AudioServerPlugIn)
docs/
  HARDWARE_SIDETONE.md  why hardware sidetone isn't reachable on macOS
  PROTOCOL.md           device topology + the (EQ/DSP) HID protocol notes
devices/             example/contributed device metadata (data, not code)
```

Supporting another Seiren is **usually zero code** - the name match catches it.
See [How support for other Seiren / Razer mics works](#how-support-for-other-seiren--razer-mics-works).

## Code style & rules

- **Keep `SeirenKit` AppKit-free.** No `import AppKit`/`UIKit` in the library — it
  must stay headless and unit-testable. AppKit lives only in the `seiren-mac`
  target.
- **The IOProc is real-time-safe — keep it that way.** Inside any
  `AudioDeviceIOProc` (and anything it calls): **no** memory allocation, locks,
  Obj-C/`NSObject`, Swift runtime calls (no `print`, no `String`, no
  reference-counted types), and no blocking. Read/write samples only. Share state
  with the UI through a `nonisolated(unsafe)` global or an atomic the callback
  reads — never a lock.
- **Swift 6 concurrency-clean.** The package builds under the Swift 6 language
  mode with no `swiftLanguageModes` override (CLT-only installs break on it). RT
  globals are marked `nonisolated(unsafe)`; delegate callbacks hop to `@MainActor`
  before touching UI. New code must compile clean — no new warnings.
- **Clean teardown.** Every `AudioDeviceCreateIOProcID` is paired with
  `AudioDeviceStop` + `AudioDeviceDestroyIOProcID`. Every property listener you
  add, you remove.
- **Don't fuzz HID bytes against hardware.** If you do work on the EQ/DSP HID path,
  only replay captured commands — a stray command class could hit a firmware/DFU
  path. Don't commit raw `.pcap`/`.pcapng` dumps (they're git-ignored); commit
  decoded JSON.

## Build / test / PR flow

```sh
swift build          # must succeed (CI pins a full Xcode toolchain)
make test            # SeirenFX driver tests + swift test; must pass
swift run seiren-mac # smoke-test the menu-bar app
```

Then:

1. Branch, commit focused changes, push.
2. Open a PR using the template — describe what you tested and on which device
   (name + PID + macOS version + `swift --version`). Paste relevant `seiren-probe`
   output for device work.
3. CI (`.github/workflows/ci.yml`, `macos-15`, `swift build`, `scripts/test-driver.sh`, `swift test`) must
   stay **green**. If it's red, it's not ready.

Small, well-scoped PRs review fastest. Thank you.
