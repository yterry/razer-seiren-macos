# Seiren for macOS

[![CI](https://github.com/yterry/razer-seiren-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/yterry/razer-seiren-macos/actions/workflows/ci.yml)

**The macOS companion app for Razer Seiren microphones.** A tiny menu-bar app that
gives a Seiren the full voice chain it has on Windows but never gets on a Mac —
**hear yourself**, **shape your tone**, **kill background noise**, and send the
*processed* voice to OBS / Zoom / Discord. (Razer Synapse supports no microphone
at all on the Mac.)

| | |
|---|---|
| 🎧 **Hear yourself** | Live headphone monitoring of your own voice — the sidetone Synapse never gives Mac mic owners. |
| 🎚 **Shape your voice** | A parametric **EQ** with Podcast / Studio / Broadcast presets. |
| 🤫 **Kill the noise** | A zero-latency **gate**, plus opt-in **RNNoise "Studio"** neural denoise. |
| 📡 **Reach every app** | A bundled virtual device (**Seiren FX**) so other apps record the *processed* voice, not the raw mic. |

Flip a switch in the menu bar — no Synapse, no Windows, no kext. One admin prompt
installs the Seiren FX audio device; everything else is one click.

*Independent, open-source software for Razer Seiren microphones. Not affiliated
with, authorized, or endorsed by Razer Inc. "Razer" and "Seiren" are trademarks of
Razer Inc., used here only to describe hardware compatibility.*

## Why this exists

- **Razer Synapse on macOS supports no microphone at all** — so Seiren owners on
  a Mac get nothing: no monitoring, no sidetone, no EQ, no noise suppression.
- **openrazer** (the Linux Razer project) explicitly ships **no audio support**,
  and no Seiren is implemented.

A Seiren is a lovely mic with software-defined sound — and on a Mac that software
simply doesn't exist. If you've recorded or streamed on a Mac with a Seiren and
felt like you were talking into a void — flat, noisy, with no idea how loud you
are — this is the fix.

## Install & run

### Option A — Homebrew (easiest)

```sh
brew tap yterry/tap
brew install --cask razer-seiren
```

That installs **Seiren.app** to `/Applications` and, because the build is unsigned
(no paid Apple Developer ID yet), clears the Gatekeeper quarantine flag for you —
so it launches with **no manual bypass**. Update later with `brew upgrade --cask
razer-seiren`.

> If Homebrew refuses the cask as an "untrusted tap" (newer Homebrew can gate
> third-party taps), run `brew trust yterry/tap` once and retry.

That gets you **headphone monitoring** right away. To unlock the **EQ and noise
suppression** — and send the *processed* voice to other apps — open
**🎙 → Voice ▸ Install Seiren FX…** once; it installs the bundled audio device and
asks for your password (a one-time admin prompt). See
[Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).

### Option B — download the app (no Xcode needed)

1. Grab `Seiren-<version>.zip` from the [latest release](https://github.com/yterry/razer-seiren-macos/releases/latest) and unzip it.
2. Move **Seiren.app** to `/Applications` and double-click it.
3. The build is **unsigned** (no paid Apple Developer ID yet), so macOS will say
   it "cannot be opened." Clear it **once**: **System Settings → Privacy &
   Security**, scroll to *"Seiren was blocked…"* → **Open Anyway** → authenticate
   → **Open**. (Terminal alternative: `xattr -dr com.apple.quarantine /Applications/Seiren.app`.)
   Future launches are silent. See [Is it safe?](#is-it-safe) for the trade-off.
4. **To process what other apps record** (EQ + noise suppression in OBS / Zoom /
   Discord), open the 🎙 menu → **Voice ▸ Install Seiren FX…** and enter your
   password once — that installs the bundled virtual audio device. Then pick
   **Seiren FX** as the mic in those apps. (Headphone monitoring works without
   this; the EQ and denoise need it — see
   [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).)

### Option C — build from source

**Requirements:** macOS 13+ and a **Swift 6 toolchain** (full **Xcode 16+**
recommended — see [Troubleshooting](#troubleshooting) for why Command-Line-Tools-only
can fail).

```sh
git clone https://github.com/yterry/razer-seiren-macos.git && cd razer-seiren-macos
swift build -c release
.build/release/seiren-mac          # a 🎙 icon appears in the menu bar
```

Then:

1. Plug headphones into the **Seiren's** headphone jack (not the Mac's).
2. Click the 🎙 menu and pick a **mode** (see below).
3. The **first** time, macOS asks for **Microphone** permission — click **Allow**
   (the app reads the mic to monitor, EQ, and denoise your voice). If you miss the
   prompt, grant it in **System Settings → Privacy & Security → Microphone**.
4. Speak. You should hear yourself in the headphones. Drag the **Level** slider to
   taste.

That's it — your choice is remembered, auto-starts when you plug the Seiren back
in, and quietly waits when it's unplugged. Then shape and clean your voice under
**🎙 → Voice**, and install **Seiren FX** to send the processed voice to other apps
(see [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx)).

### Monitoring modes

- **On — always**: monitor whenever the Seiren is connected. Simple, but the
  macOS recording indicator (orange dot) stays on the whole time — because
  software monitoring keeps the mic open.
- **Auto — only while an app uses the mic** *(recommended)*: monitor **only when
  another app is recording from the Seiren** — i.e. while you're on a Zoom/Teams
  call. The recording indicator is then on **only during calls**, when it would
  already be on anyway, and you're not "always recording" the rest of the day.
  *(Uses the macOS 14+ per-process audio API; on older macOS it behaves like
  "On — always".)*
- **Off**: not monitoring.

### Voice EQ — and making other apps hear it (Seiren FX)

The app includes a **parametric voice EQ** with built-in presets —
**Flat / Podcast / Studio / Broadcast**. Turn it on under **🎙 → Voice ▸
Equalizer** and pick a preset.

**What other apps hear — please read this.** By default macOS hands every app the
Seiren's *raw* hardware mic; there's no system hook to insert effects into it. So
the EQ reaches other apps (OBS, Zoom, Discord, QuickTime…) only through a small
**virtual audio device** named **Seiren FX** that the app installs:

```
Seiren mic → Seiren for macOS (EQ) → Seiren FX → your recording / calling app
```

- **Your headphone monitor reflects the EQ** whenever you're monitoring through Seiren FX.
- **Other apps hear the EQ only if you pick “Seiren FX” as their microphone.** If
  an app still points at “Razer Seiren V3 Pro”, it records the raw, un-EQ'd mic.

**Install the Seiren FX driver (one-time):**

- **Downloaded the app?** Open **🎙 → Voice ▸ Install Seiren FX…** and enter your
  password once. That's it.
- **Building from source?** Run:
  ```sh
  scripts/build-driver.sh             # builds dist/SeirenFX.driver (clang, no Xcode)
  sudo scripts/install-driver.sh      # installs it + restarts coreaudiod (~1s glitch)
  ```

It's an unsigned, MIT-licensed CoreAudio plug-in (`AudioServerPlugIn`) — no kext,
no entitlements, no Developer ID required for a local install. Remove it with
`sudo scripts/install-driver.sh --uninstall`.

Then, in the app you record or stream with, **select “Seiren FX” as the
microphone**. The app bridges the Seiren and Seiren FX under one clock (a
private aggregate device), so there's no drift. Without the driver installed, the
Voice menu says so and the app still does plain headphone monitoring as before.

### Noise suppression

Under **🎙 → Voice ▸ Noise suppression** (creator path — needs Seiren FX):

- **Reduce noise (gate)** — a zero-latency downward gate that mutes room hiss /
  keyboard *between words* and opens instantly on speech. No latency, no model
  download — but, like the EQ, it runs on the Seiren FX route.
- **Studio Denoise (RNNoise)** — a neural denoiser that strips *steady*
  background noise (fan, AC, hum, computer) while you talk. Best quality. It adds
  ~10 ms of latency, but **only on the SeirenFX broadcast** — your **headphone
  monitor stays low-latency** (it gets gate + EQ, not Studio), so hearing
  yourself never feels laggy. Runs at 48 / 96 kHz.

When you monitor through Seiren FX, the EQ and the gate are heard in your monitor
**and** by apps recording **Seiren FX**; Studio denoise applies to the Seiren FX
broadcast only.

### Run the tests / dev build

```sh
swift test                         # unit tests (SeirenKit)
swift run seiren-mac               # debug build of the menu-bar app
swift run seiren-probe             # read-only dump of the Seiren's audio controls
```

## How it works

The app opens the Seiren as a **full-duplex Core Audio device** and installs
**one `AudioDeviceIOProc`**. On every audio cycle that callback copies the mic
input (channel 0) into every headphone output channel, scaled by your level
(`0…1`). That's the whole monitoring path — input to output, in-process, on
the real-time audio thread.

- **Auto start/stop.** The engine listens on `kAudioHardwarePropertyDevices`. When
  a Seiren appears it starts the IOProc; when it disappears it tears down cleanly
  (`AudioDeviceStop` + `AudioDeviceDestroyIOProcID`). Your "monitoring on" intent
  survives unplugging.
- **Real-time-safe callback.** The IOProc does no allocation, no locks, no Obj-C,
  no Swift-runtime calls — it just reads samples and writes samples. The level is
  a single atomically-readable value the UI can change live.
- **Device match by name.** Any audio device whose name contains `seiren`
  (case-insensitive) qualifies, so most Seiren models work with no per-model code.

The core lives in **`SeirenKit`** (no AppKit, fully testable):

```swift
let engine = MonitorEngine(deviceNameMatch: "seiren")
engine.enable()          // find the Seiren, start the IOProc
engine.level = 0.8       // 0...1, applied live
engine.disable()         // stop monitoring (intent persists across unplug)
```

> The reference IOProc is already in the repo — see `swMonProc` / `softwareMonitor()`
> in [`Sources/seiren-probe/main.swift`](Sources/seiren-probe/main.swift), which
> you can run today (`swift run seiren-probe monitor swmon 0.9`) to hear the exact
> path the app uses.

### The latency trade-off, honestly

> **The monitor is *software*.** macOS blocks the route to the Seiren's
> *hardware* sidetone (every hardware path is blocked or silent — see
> [Why software monitoring?](#why-software-monitoring-the-hardware-sidetone-path-macos-blocks)),
> so the app runs one full-duplex Core Audio loop that copies mic → headphone
> in userspace. The EQ/denoise add nothing to this direct-monitor path (Studio
> denoise applies only to the broadcast). It is not a sample-accurate DAW monitor.

Monitoring delay ≈ one audio I/O buffer. At a typical 256-frame buffer / 48 kHz
that's ~5 ms each way; you can lower it with
`kAudioDevicePropertyBufferFrameSize` at the cost of CPU and stability. For
*hearing your own voice* this is fine — it's well under the threshold where you'd
notice an echo. It is **not** a zero-latency hardware path (which, again, macOS
won't give us here), so it isn't the right tool for sample-accurate latency-free
DAW monitoring.

## Why software monitoring? (the hardware-sidetone path macOS blocks)

On Windows, Synapse drives the Seiren's **hardware** sidetone directly, with zero
added latency. The same hardware mix is not reachable from macOS userspace, and
**every hardware path is blocked or silent.** Short version so you don't repeat
the dead ends:

- **It isn't HID.** Sidetone looks like a Razer vendor **HID** Feature
  report (`0xFF53` / report `0x07`) at first, but mining Synapse's own logs and the
  `RzNative_058e` DLL shows sidetone is a **USB-Audio-Class Feature-Unit
  control** (volume + mute `SET_CUR`), not a HID frame. The `0xFF53` HID channel
  is real, but it carries EQ/DSP — wrong transport for monitoring.
- **Core Audio play-through is exposed but silent.** macOS surfaces the device's
  UAC controls, including `kAudioDevicePropertyPlayThru` (Apple's term for
  hardware input monitoring). Setting it returns success — but **no audio comes
  through.** Apple's play-through plumbing simply isn't wired to this device's
  hardware mix.
- **Raw UAC `SET_CUR` is blocked.** Talking to the Feature Unit directly is
  impossible from userspace: `AppleUSBAudio` takes an **exclusive** claim on the
  audio interface, so you can't issue the control transfer yourself.

So the only thing left that actually makes sound is to do the mix ourselves: read
the mic, write the headphones, in one Core Audio loop.

Full investigation and evidence: [`docs/HARDWARE_SIDETONE.md`](docs/HARDWARE_SIDETONE.md)
(and the device/protocol notes in [`docs/PROTOCOL.md`](docs/PROTOCOL.md)).

## Heads-up / caveats

- **Software monitoring, small latency.** ≈ one audio buffer (a few ms). Great for
  hearing yourself; not a zero-latency hardware monitor. See
  [above](#the-latency-trade-off-honestly).
- **Needs Microphone permission (TCC).** The app reads the mic to monitor, EQ,
  denoise, and route your voice, so macOS prompts for **Microphone** access the
  first time. Without it, nothing can start and the menu will say so.
- **Creator features need Seiren FX.** The EQ and noise suppression reach your
  monitor and other apps only through the bundled **Seiren FX** device — install it
  once from **Voice ▸**. Plain headphone monitoring works without it.
- **Unsigned build.** Until there's a notarized release, you're running a binary
  built from this source. Gatekeeper may warn on a downloaded build (Homebrew clears
  it); a local `swift build` run is fine.
- **Headphones go in the Seiren, not the Mac.** Monitoring routes mic →
  *Seiren's* output. Plug your headphones into the mic.

## Is it safe?

The downloadable app is **unsigned** — there's no paid Apple Developer ID behind
it yet — so macOS hasn't notarized it and Gatekeeper warns on first launch. That's
why the download asks you to **Open Anyway** once (Homebrew clears it for you).
If you'd rather not trust a prebuilt binary, **build it from source** (Option C) — the whole app is this repo,
no dependencies. Released zips ship with a **SHA-256 checksum** so you can verify
the download. A notarized, double-click-clean release will come if/when there's a
Developer ID.

## Architecture

```
Sources/
  SeirenKit/         model-independent core (no AppKit, fully testable)
    MonitorEngine.swift   IOProc: mic → gate → EQ → monitor; +Studio → Seiren FX
    EQEngine.swift        RBJ-cookbook coefficient math + voice presets
    ...                   (legacy HID model/registry types; see docs/PROTOCOL.md)
  SeirenDSP/         RT-safe C DSP: biquad EQ, noise gate, RNNoise bridge, resampler
  RNNoise/           vendored xiph/rnnoise (BSD-3) — the "Studio" denoiser
  seiren-mac/        the menu-bar agent (main.swift + AppDelegate): 🎙 menu —
                     modes, Level, Voice ▸ (EQ + noise suppression), Seiren FX install
  seiren-probe/      read-only Core Audio diagnostic + the reference swmon IOProc
Driver/SeirenFX/     the loopback virtual audio device (AudioServerPlugIn)
docs/
  HARDWARE_SIDETONE.md  why hardware sidetone isn't reachable on macOS
  PROTOCOL.md           device topology + the (EQ/DSP) HID protocol notes
devices/             example/contributed device metadata (data, not code)
```

Supporting another Seiren is **usually zero code** — the name match catches it.
See [`CONTRIBUTING.md`](CONTRIBUTING.md).

### Troubleshooting

**`Invalid manifest … Undefined symbols … PackageDescription.Package.__allocating_init`**

`Package.swift` can't link against your toolchain's `PackageDescription`. This
almost always means **only the Command Line Tools are installed (no full Xcode)**,
or `xcode-select` points at a stale/partial CLT. Fix it:

```sh
xcode-select -p          # if this prints /Library/Developer/CommandLineTools, that's the problem
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift --version          # should report Swift 6.x
swift build
```

**Monitoring won't turn on / I hear nothing.**

- Confirm **Microphone** permission is granted (System Settings → Privacy &
  Security → Microphone).
- Confirm the Seiren is selected as a usable device — `swift run seiren-probe`
  should list a device whose name contains "Seiren".
- Confirm your headphones are in the **Seiren's** jack, not the Mac's.

## Roadmap

**Shipped:**

- [x] Software headphone monitoring — menu-bar modes + Level slider, launch-at-login
- [x] Parametric **voice EQ** — Podcast / Studio / Broadcast presets
- [x] **Noise suppression** — a zero-latency C gate, plus opt-in RNNoise **"Studio"** neural denoise
- [x] **Seiren FX** virtual device — other apps record the *processed* voice (OBS / Zoom / Discord)
- [x] **Homebrew** distribution — `brew install --cask razer-seiren`

**Next:**

- [ ] **Lighting** — opportunistic. Still gated on a verified Windows Synapse USB
      capture of the monitor-on bytes, and the V3 Pro may simply have no
      addressable RGB.
- [ ] **Streamer Mixer** — the last roadmap item; now genuinely feasible on the
      virtual-device foundation (per-source levels into one broadcast bus).
- [ ] **Notarization** — removes the one-time Gatekeeper bypass, but needs a paid
      Apple Developer ID.

See [`docs/CREATOR_DESIGN.md`](docs/CREATOR_DESIGN.md) for the full design.

## Credits & prior art

- [openrazer](https://github.com/openrazer/openrazer) — Razer USB protocol reference
- [Ashesh3/razer-device-control](https://github.com/Ashesh3/razer-device-control) — reverse-engineered Razer **audio** HID frames (EQ/DSP shape)
- [1kc/razer-macos](https://github.com/1kc/razer-macos) — the userspace-HID-on-macOS pattern (lighting)

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Razer Inc.; "Razer" and "Seiren"
are trademarks of Razer Inc.
