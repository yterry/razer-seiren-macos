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
2. **Open a [device report](https://github.com/yterry/razer-seiren-macos/issues/new?template=device-report.yml)**.
   It asks for the model, whether it has a headphone jack, which features work,
   and the text from **Copy Diagnostics** in the Seiren menu. If you built from
   source, add the `seiren-probe` output there too.

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

## Releasing

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`.
It runs `make test`, builds the universal app with `scripts/package.sh`, signs and notarizes it with `scripts/notarize.sh`, checks the zip with `scripts/verify-release.sh`, publishes the GitHub release, and opens and merges a pull request in `yterry/homebrew-tap` that bumps the cask.
The steps below are the ones a person does around that workflow.
In the commands, `X.Y.Z` is the new version and `P.Q.R` is the previous release.

### Before tagging

1. Run `make test` on the commit you will tag.
2. Check whether the driver changed since the last release with `git diff --stat vP.Q.R -- Driver/SeirenFX`.
   If it did, bump both `CFBundleShortVersionString` and `CFBundleVersion` in `Driver/SeirenFX/Info.plist` to the same new version.
   The app offers to update Seiren FX only when the bundled `CFBundleShortVersionString` is higher than the installed one, so a driver change without a bump never reaches users who already have Seiren FX.
3. If the driver changed, run the on-Mac driver checklist below and record the result of each check in the pull request that bumps the driver version.

The app's own version comes from the tag: `scripts/package.sh` writes it into `Seiren.app`, so there is no app version to bump by hand.

### On-Mac driver checklist

`make test` runs the driver's logic in `Driver/SeirenFX/Tests.c`, but only a real Mac loads the plug-in into `coreaudiod`.
These checks need admin rights, a mic, and a calling app such as Teams, Zoom or Google Meet.
Before you start, quit any installed `Seiren.app` and note the default input and output in System Settings ▸ Sound, then set them back when you are done.

1. **Reinstall prompt.**
   With the previous release's Seiren FX still installed, package the release commit with `VERSION=X.Y.Z scripts/package.sh` and open `dist/Seiren.app`.
   The 🎙 ▸ Voice menu shows **Update Seiren FX…** with "A newer Seiren FX comes with this app".
   If the installed driver is older than 3.0.0 (it has no hidden feeders), it shows "Seiren FX needs a one-time reinstall" and **Reinstall Seiren FX…** instead.
   Choose the item and enter your password.
   Afterwards the update item is gone from the Voice menu.
   If you cannot use the packaged app, install the new driver with `scripts/build-driver.sh` and then `sudo scripts/install-driver.sh`, and record this check as not run.
2. **Device topology.**
   `swift run seiren-probe inputs` lists `Seiren FX` and `Seiren Stream Mix` with `streams: 1 in / 0 out`, and prints `Seiren FX installed: yes`.
   Neither `Seiren FX Feeder` nor `Seiren Stream Mix Feeder` appears in `system_profiler SPAudioDataType`.
   The feeders are hidden output devices that the app writes into.
3. **Speaker lists.**
   Seiren FX and Seiren Stream Mix are missing from the output list in System Settings ▸ Sound and from the speaker list of the calling app.
   They still appear in both places as microphones.
4. **Recording across two calls, Seiren FX.**
   Run `dist/Seiren.app` in Auto mode.
   Join a call with Seiren FX as the microphone, check that the other side (or the app's mic test) hears your processed voice and that your speakers play the call, then leave.
   Join a second call and check both again.
   Then run `swift run seiren-probe listen "Seiren FX" 10` twice in a row while speaking; both runs print peaks well above silence.
5. **Recording across two calls, Seiren Stream Mix.**
   Turn on 🎙 ▸ Stream Mixer ▸ **Mix into Seiren Stream Mix**.
   Repeat the two calls from step 4 with Seiren Stream Mix as the microphone, then run `swift run seiren-probe listen "Seiren Stream Mix" 10` twice in a row while speaking; both runs print peaks well above silence.
6. **Sample-rate changes.**
   While the app sends your voice into Seiren FX, start `swift run seiren-probe listen "Seiren FX" 60` and keep speaking.
   During the run, open Audio MIDI Setup and set Seiren FX to 44.1 kHz, then 96 kHz, then back to 48 kHz.
   After each change the per-second peaks keep tracking your voice, with no long run of silence.
   Repeat with Seiren Stream Mix and `swift run seiren-probe listen "Seiren Stream Mix" 60`.

### Tagging

```sh
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
gh run list --workflow release.yml --limit 1
gh run watch <run-id>
```

Notarization can take hours.
`scripts/notarize.sh` polls Apple for up to 3 hours by default (`NOTARY_TIMEOUT_MINUTES`), and a new Developer ID account's first submissions have sat "In Progress" for over 40 minutes.
If notarization fails or times out, no GitHub release is created, and the signed build stays on the run as the `signed-prenotarization` artifact for 7 days.
Once the cause is fixed, rerun the workflow with `gh run rerun <run-id>`.

### After the workflow

1. **Add "What's new" to the release notes.**
   The workflow publishes only the generated install text.
   Put a `## What's new in vX.Y.Z` section and a `---` line above it:

   ```sh
   gh release view vX.Y.Z --json body -q .body > notes.md
   # edit notes.md: add "## What's new in vX.Y.Z", the changes, and "---" above the generated text
   gh release edit vX.Y.Z --notes-file notes.md
   ```

2. **Confirm the tap pull request merged.**
   `gh pr list --repo yterry/homebrew-tap --state all --search "razer-seiren X.Y.Z"` shows it as merged.
   The "Update Homebrew tap" step never fails the run, so read its log for a skip or a warning.
   If the pull request is still open, merge it.
   If there is none, bump the cask by hand in a clone of `yterry/homebrew-tap`: run `scripts/bump-cask.sh X.Y.Z` on a new branch, commit `Casks/razer-seiren.rb`, and merge it through a pull request, because the tap's main branch accepts changes only through pull requests.
3. **Upgrade on a Mac.**
   Run `brew update && brew upgrade --cask razer-seiren`, then check that `brew list --cask --versions razer-seiren` prints `X.Y.Z`.

### Rolling back a release

1. **Point Homebrew at the previous version.**
   In a clone of `yterry/homebrew-tap`, find the bump commit with `git log --oneline -- Casks/razer-seiren.rb`; its title is `razer-seiren X.Y.Z`.
   Run `git revert <commit>` on a new branch and merge it through a pull request.
   `Casks/razer-seiren.rb` then names version `P.Q.R` and its `sha256` again.
   Users who already upgraded get the previous version with `brew update && brew reinstall --cask razer-seiren`.
2. **Move "latest" back to the previous release.**
   Run `gh release edit vX.Y.Z --prerelease`, so GitHub's latest release is `vP.Q.R` again.

### Rolling back the driver

A driver rollback through the app is not possible today.
The app offers to install its bundled Seiren FX only when the bundled version is higher than the installed one (`DriverInstaller.updateAvailable` in `Sources/seiren-mac/DriverInstaller.swift`).
Going back to an older `Seiren.app` therefore leaves a newer, bad driver in place.
Users who installed a bad driver get the older one back only from a source checkout:

```sh
git checkout vP.Q.R
scripts/build-driver.sh
sudo scripts/install-driver.sh
```

### Secrets

The release workflow reads these repository secrets.
The comment block at the top of `.github/workflows/release.yml` describes the signing ones, and the comment above its "Update Homebrew tap" step describes the tap token.

- `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `NOTARY_PASSWORD` sign and notarize the app.
  Without `MACOS_CERT_P12` the workflow publishes an ad-hoc signed build; with it but any of the others missing, the run fails before packaging.
- `HOMEBREW_TAP_TOKEN` lets the workflow bump the tap; without it that step is skipped.
