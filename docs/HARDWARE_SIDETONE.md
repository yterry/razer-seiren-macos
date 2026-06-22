# Why hardware sidetone isn't reachable on macOS

This documents the dead ends so nobody repeats them, and explains why
`seiren-mac` does **software** monitoring instead. For device topology and the
Razer-audio HID grammar (a separate, EQ/DSP concern), see
[`PROTOCOL.md`](PROTOCOL.md).

**TL;DR:** On Windows, Razer Synapse drives the Seiren's hardware sidetone with
zero added latency. On macOS, every route to that hardware mix is either **blocked
by the OS** or **silently inert**. The only path that actually produces sound from
userspace is to do the mix ourselves — read the mic, write the headphones, in one
Core Audio `AudioDeviceIOProc`. That is `seiren-mac`. Confirmed audible on a Razer
Seiren V3 Pro (VID `0x1532` / PID `0x058E`).

## What sidetone actually is on this device

Early on we assumed monitoring was a Razer **vendor HID** Feature report (the
`0xFF53` / report `0x07` channel). It isn't. Mining Synapse's own middleware logs
and the `RzNative_058e` DLL showed:

- The mic monitor (`SetMicMonitorEnable` / `SetMicMonitorLevel`) is a
  **USB-Audio-Class (UAC) Feature-Unit control** — a **volume + mute `SET_CUR`**,
  issued through Thesycon's TUSBAUDIO driver on Windows.
- The DLL imports `TUSBAUDIO_SetVolume` / `TUSBAUDIO_SetMute` and has **no**
  `HidD_SetFeature` for sidetone. The logs record raw HID `dataSend[]` byte arrays
  for every *other* HID feature (EQ, noise gate, …) but **none** for sidetone —
  only `r: true`.
- The level is UAC volume in 1/256 dB units (`uLevel` 100 → `0x1F00`).

So sidetone is a **Core Audio** concern on macOS, not `IOHIDDeviceSetReport`. Good
news — Core Audio surfaces UAC Feature Units as control objects. Bad news — the
relevant ones don't work for us. Three things we tried:

## 1. Core Audio play-through — exposed, returns success, silent

macOS represents hardware input monitoring with
`kAudioDevicePropertyPlayThru` (and the owned `ptru`-scope volume/mute controls).
The probe finds these on the Seiren and they're settable:

```swift
// from seiren-probe: applyMonitor(...)
setUInt32(dev, address(kAudioDevicePropertyPlayThru,
                       kAudioObjectPropertyScopeInput, 0), 1)   // -> noErr
// clear ptru mute, set ptru volume on owned controls       -> noErr
```

Setting them returns `noErr`, and reading back shows play-through "engaged."
**No audio comes through the headphones.** We also tried starting the device
hardware first (a NULL `AudioDeviceStart`, on the theory play-through only engages
while the device runs) and holding it open (`seiren-probe monitor hold`). Still
silent. Apple's play-through plumbing is exposed for this device but **not wired to
its hardware mix** — the toggle is a no-op that lies about success.

## 2. Raw UAC `SET_CUR` to the Feature Unit — blocked by exclusivity

If Core Audio won't drive the Feature Unit, can we issue the UAC control transfer
ourselves (the same `SET_CUR` Synapse sends)? No. **`AppleUSBAudio` takes an
exclusive claim on the device's audio interface.** Userspace can't open that
interface to send the control transfer — the driver owns it. There's no kext-free,
entitlement-free way around an exclusive claim by an Apple driver. (Seizing it
would also fight `usbaudiod` and risk killing the mic.)

## 3. Vendor HID — wrong transport (and confirmed not used for sidetone)

For completeness: the `0xFF53` vendor HID channel *is* real and openable
non-exclusively (it's a separate HID interface, owned by `IOHIDFamily`,
independent of audio). But per the log/DLL analysis above it carries **EQ/DSP**,
not sidetone. Driving HID would change EQ, not turn on monitoring. (This channel
remains a viable path for a *future* EQ/gain feature — see `PROTOCOL.md`.)

## The solution: software monitoring (one IOProc)

What *does* make sound: open the Seiren as a full-duplex Core Audio device and
install one `AudioDeviceIOProc` that copies input → output every cycle.

```swift
// reference: swMonProc / softwareMonitor() in Sources/seiren-probe/main.swift
AudioDeviceCreateIOProcID(dev, swMonProc, nil, &procID)
AudioDeviceStart(dev, procID)        // mic ch0 -> all headphone channels * level
// ... later:
AudioDeviceStop(dev, procID)
AudioDeviceDestroyIOProcID(dev, procID)
```

- **No entitlements, no kext, no reverse engineering.** Just public Core Audio.
- **Confirmed audible** on real hardware (`swift run seiren-probe monitor swmon`).
- **Cost: a little latency** — about one audio I/O buffer (a few ms, tunable via
  `kAudioDevicePropertyBufferFrameSize`). Inaudible-to-negligible for hearing your
  own voice; not a substitute for true zero-latency hardware monitoring.
- **Requires Microphone permission (TCC)** — we read the mic to play it back. The
  app handles the prompt.

This is the trade we ship: we can't reach the hardware sidetone, but we *can* give
you working monitoring with public APIs and a few milliseconds of delay.

## Evidence trail

- Synapse middleware logs: `dataSend[]` HID arrays for EQ/gate, only `r: true`
  (no bytes) for sidetone.
- `RzNative_058e` DLL imports: `TUSBAUDIO_SetVolume` / `TUSBAUDIO_SetMute`; no
  `HidD_SetFeature` on the sidetone path.
- `seiren-probe` on macOS: `kAudioDevicePropertyPlayThru` present + settable +
  returns `noErr`, audibly silent; `swmon` IOProc audibly works.
- Device topology, interface ownership, and the `0xFF53` HID grammar:
  [`PROTOCOL.md`](PROTOCOL.md).
