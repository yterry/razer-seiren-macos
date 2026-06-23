# Contributing

Thanks for helping. **Seiren for macOS** is a small creator app for Razer Seiren
mics — **monitoring, EQ, and noise suppression** — and its foundation, *hearing
yourself*, is solved the same way for the whole Seiren line: one full-duplex Core
Audio loop that copies mic → headphone. There are no per-model command bytes to
capture for monitoring (and the EQ/denoise are device-agnostic DSP). That means
most contributions are small: confirm a model works, fix a quirk, or improve the
app.

## How support for other Seiren / Razer mics works

Monitoring is **device-agnostic**. `MonitorEngine` finds any audio device whose
name contains `seiren` (case-insensitive, configurable via
`MonitorEngine(deviceNameMatch:)`) and installs the IOProc on it. If macOS sees
your mic as a normal full-duplex USB-audio device with a headphone output, it
should Just Work — **no code, no JSON, no captured bytes.**

So the most useful thing you can do is **tell us your model works** (or doesn't):

1. **Confirm it the fast way** with the bundled probe + reference monitor:
   ```sh
   swift run seiren-probe                 # read-only: lists devices + every audio control
   swift run seiren-probe monitor swmon 0.9   # software monitor: speak, hear yourself, Return to stop
   ```
   `swmon` runs the *exact* IOProc the app uses. If you hear yourself, the app
   will work for your device.
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
- **Channel layout is unusual** (mic isn't input channel 0, or output isn't where
  you expect). The reference IOProc fans **input channel 0 → all output channels**;
  if a device differs, the probe dump tells us, and the fix is a small,
  data-driven tweak to channel selection — not a new transport.

### What `devices/*.json` is (and isn't) for

The `devices/` JSON files and the legacy `SeirenController`/`DeviceRegistry` HID
code are about the **EQ/DSP** feature set (the `0xFF53` HID channel), **not**
monitoring. Monitoring needs none of it. Only touch `devices/` if you're working
on EQ/gain. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) and
[`docs/HARDWARE_SIDETONE.md`](docs/HARDWARE_SIDETONE.md) for why monitoring lives
in Core Audio instead.

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
swift test           # must pass
swift run seiren-mac # smoke-test the menu-bar app
```

Then:

1. Branch, commit focused changes, push.
2. Open a PR using the template — describe what you tested and on which device
   (name + PID + macOS version + `swift --version`). Paste relevant `seiren-probe`
   output for device work.
3. CI (`.github/workflows/ci.yml`, `macos-15`, `swift build` + `swift test`) must
   stay **green**. If it's red, it's not ready.

Small, well-scoped PRs review fastest. Thank you.
