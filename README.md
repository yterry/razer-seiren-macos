# Seiren for macOS

[![CI](https://github.com/yterry/razer-seiren-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/yterry/razer-seiren-macos/actions/workflows/ci.yml)

**The macOS companion app for Razer Seiren microphones.** A tiny menu-bar app that
gives a Seiren the full experience it has on Windows but never gets on a Mac —
**hear yourself**, **shape your tone**, **kill background noise**, send the
*processed* voice to OBS / Zoom / Discord, **mix your stream**, and **drive the
Chroma lighting**.
(Razer Synapse supports no microphone at all on the Mac.)

| | |
|---|---|
| 🎧 **Hear yourself** | Live headphone monitoring of your own voice — the sidetone Synapse never gives Mac mic owners. |
| 🎚 **Shape your voice** | A parametric **EQ** with Podcast / Studio / Broadcast presets. |
| 🤫 **Kill the noise** | A zero-latency **gate**, plus opt-in **RNNoise "Studio"** neural denoise. |
| 📡 **Reach every app** | A bundled virtual device (**Seiren FX**) so other apps record the *processed* voice, not the raw mic. |
| 🎛 **Mix your stream** | A **Stream Mixer**: your voice plus app audio, each with its own level and mute, in one **Seiren Stream Mix** device for OBS. |
| 💡 **Light it up** | Native control of the mic's 12-LED **Chroma ring** - effects, static colors, brightness - no Synapse needed. |

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

## Supported microphones

| Model | Status | Hear yourself | EQ + noise suppression | Lighting |
|---|---|---|---|---|
| **Seiren V3 Pro** | verified on hardware | ✅ headphone jack | ✅ via Seiren FX | ✅ 12-LED Chroma ring |
| **Seiren V3 Mini** | verified with a stand-in device | - no headphone jack | ✅ via Seiren FX | - mute LED only |
| Other Seirens | untested | if it has a jack | ✅ via Seiren FX | - |

No V3 Mini has been tested on a Mac yet: its support was tested with another input-only audio device ([`docs/PROTOCOL.md`](docs/PROTOCOL.md#11-razer-seiren-v3-mini-from-its-usb-descriptors)).
**A model not in the table** gets the audio features if macOS names the device with "Seiren" (monitoring needs a headphone jack), and no lighting.
If you try one, please [report how it went](https://github.com/yterry/razer-seiren-macos/issues/new/choose).

## Install

Seiren.app runs on macOS 13 or later, on both Apple silicon and Intel Macs.

### Option A — Homebrew (easiest)

```sh
brew tap yterry/tap
brew trust yterry/tap          # one-time: Homebrew 6 gates third-party taps
brew install --cask razer-seiren
```

That installs **Seiren.app** to `/Applications`.
Update to the latest release any time with:

```sh
brew update && brew upgrade --cask razer-seiren
```

Releases from **v1.1.0** on are **signed with an Apple Developer ID and notarized**, so the app opens with no Gatekeeper friction at all - each release's notes state its signing status.
(Installing the older v1.0.0?
That build predates the Developer ID - the cask clears its Gatekeeper quarantine flag for you, so it still launches with no manual bypass.)

> The `brew trust` line is a one-time approval for a third-party tap - Homebrew 6+ requires it for any tap outside the official repos (older Homebrew ignores it harmlessly).
> Skip it and you'll see *"Refusing to load cask … from untrusted tap"*; just run it once and retry.

That gets you **headphone monitoring** right away.
To unlock the **EQ and noise suppression** - and send the *processed* voice to other apps - open **🎙 → Voice ▸ Install Seiren FX…** once; it installs the bundled audio device and asks for your password (a one-time admin prompt).
See [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).

### Option B — download the app (no Xcode needed)

1. Grab `Seiren-<version>.zip` from the [latest release](https://github.com/yterry/razer-seiren-macos/releases/latest) and unzip it.
2. Move **Seiren.app** to `/Applications` and double-click it.
   Releases from **v1.1.0** on are signed and notarized, so it just opens - no Gatekeeper dance.
   (Only the old **v1.0.0** build was unsigned; if you need it, clear it once via **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Seiren.app`.)
3. **To process what other apps record** (EQ + noise suppression in OBS / Zoom / Discord), open the 🎙 menu → **Voice ▸ Install Seiren FX…** and enter your password once - that installs the bundled virtual audio device.
   Then pick **Seiren FX** as the mic in those apps.
   (Headphone monitoring works without this; the EQ and denoise need it - see [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).)

To build the app yourself, see [Building from source](#building-from-source).

### Is it safe?

Releases from **v1.1.0** on are **signed with an Apple Developer ID and notarized by Apple**, so Gatekeeper opens them cleanly - no bypass, no warnings.
If you'd rather not trust a prebuilt binary anyway, [build it from source](#building-from-source) - the whole app is this repo, no dependencies.
Released zips ship with a **SHA-256 checksum** so you can verify the download.
(The old **v1.0.0** build predates the Developer ID and is unsigned; its one-time **Open Anyway** instructions live in that release's notes, and the Homebrew cask clears its quarantine flag automatically.)

## First run

1. Open **Seiren** from `/Applications` (or run `.build/release/seiren-mac` from a [source build](#building-from-source)).
   A 🎙 icon appears in the menu bar; that menu is the whole app, with no Dock icon.
2. Plug headphones into the **Seiren's** headphone jack (not the Mac's).
   Monitoring routes mic → *Seiren's* output.
   (V3 Mini: no jack - skip this; your route is Seiren FX, see [V3 Mini](#v3-mini).)
3. Click the 🎙 menu and pick a **mode** (see [Monitoring modes](#monitoring-modes)).
4. The **first** time, macOS asks for **Microphone** permission - click **Allow** (the app reads the mic to monitor, EQ, and denoise your voice).
   If you miss the prompt, the menu says **Microphone access is required** and offers **Open Microphone Settings…**, which opens **System Settings → Privacy & Security → Microphone** for you.
5. Speak.
   You should hear yourself in the headphones.
   Drag the **Volume** slider to taste.

That's it - your choice is remembered, auto-starts when you plug the Seiren back in, and quietly waits when it's unplugged.
Then shape and clean your voice under **🎙 → Voice**, and install **Seiren FX** to send the processed voice to other apps (see [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx)).

### Monitoring modes

- **On — always**: monitor whenever the Seiren is connected.
  Simple, but the macOS recording indicator (orange dot) stays on the whole time - because software monitoring keeps the mic open.
- **Auto — only while an app uses the mic** *(recommended)*: monitor **only when another app is recording from the Seiren** - i.e. while you're on a Zoom/Teams call.
  The recording indicator is then on **only during calls**, when it would already be on anyway, and you're not "always recording" the rest of the day.
  *(Uses the macOS 14+ per-process audio API; on older macOS it behaves like "On — always".)*
  So your first words aren't cut off, Auto keeps the Seiren's headphone side running silently while you're at the Mac.
  When an app starts recording, the mic is already awake and your voice reaches the app in under a tenth of a second, instead of about a quarter of a second from cold.
  This doesn't record anything or turn on the recording indicator, and it pauses while the display or the Mac sleeps.
  The V3 Mini has no headphone side, so it still starts from cold.
- **Off**: not monitoring.

### V3 Mini

The Mini has no headphone jack, so there is nothing to monitor into - the app's job for it is the **EQ + noise suppression**, sent to OBS / Zoom / Discord through Seiren FX.
The menu says so the first time ("This mic has no headphone jack - it works through Seiren FX") and offers the one-time install; the volume slider and Lighting menu don't apply to the Mini and stay out of the way.
Confirm the route from the terminal with `swift run seiren-probe route` (see [Contributing](CONTRIBUTING.md)).

## Features

### When the Seiren is unplugged (Input)

Once Zoom, Discord, or OBS records **Seiren FX**, unplugging the Seiren used to leave them silent until you noticed and switched mics.
Now Seiren FX keeps carrying your voice from another mic:

- **🎙 → Input ▸ Automatic** (the default) uses your Seiren whenever one is connected.
  Without one, it uses your Mac's default input (never Seiren FX itself), then the built-in mic, and switches back the moment the Seiren returns.
- Pick a specific mic under **Input ▸** to process that one instead.
  While it is unplugged, Automatic takes over.
- Another mic runs only while an app records from Seiren FX, in both **On — always** and **Auto**, so the macOS recording indicator stays off the rest of the time.
  The first line of the menu says which mic Seiren FX is using.
- Another mic gets the EQ and noise suppression but no headphone monitoring: hearing yourself needs the Seiren's own headphone jack.

This needs Seiren FX installed (see below), because Seiren FX is how other apps receive the processed voice, and macOS 14 or later, which can tell the app when another app starts recording.
On macOS 13 only a Seiren is used, as before.
Automatic never picks a line-level input such as a capture card, unless it is your Mac's default input.

### Voice EQ — and making other apps hear it (Seiren FX)

The app includes a **parametric voice EQ** with built-in presets - **Flat / Podcast / Studio / Broadcast**.
Turn it on under **🎙 → Voice ▸ Equalizer** and pick a preset.

**What other apps hear - please read this.**
By default macOS hands every app the Seiren's *raw* hardware mic; there's no system hook to insert effects into it.
So the EQ reaches other apps (OBS, Zoom, Discord, QuickTime…) only through a small **virtual audio device** named **Seiren FX** that the app installs:

```
Seiren mic → Seiren for macOS (EQ) → Seiren FX → your recording / calling app
```

**Seiren FX and Seiren Stream Mix are microphones only.**
They have no output channels and cannot appear as speakers in calling apps.
The app sends audio through hidden output-only feeders that share each microphone's audio buffer and clock.
Keep your speakers or headphones selected as the call's output.

- **Your headphone monitor reflects the EQ** whenever you're monitoring through Seiren FX.
- **Other apps hear the EQ only if you pick “Seiren FX” as their microphone.**
  If an app still points at “Razer Seiren V3 Pro” (or “V3 Mini”), it records the raw, un-EQ'd mic.
- **On a jack-less mic (V3 Mini) Seiren FX is the whole feature**: with no headphone output there is nothing to monitor into, so until the driver is installed the menu reads “needs Seiren FX” and nothing runs.
  Once installed, **On — always** keeps the processed voice flowing to Seiren FX whenever the mic is plugged in; **Auto** does it only while an app records from the mic or from Seiren FX.

**Install the Seiren FX driver (one-time):**

- **Downloaded the app?**
  Open **🎙 → Voice ▸ Install Seiren FX…** and enter your password once.
  That's it.
- **Building from source?** Run:
  ```sh
  scripts/build-driver.sh             # builds dist/SeirenFX.driver (clang, no Xcode)
  sudo scripts/install-driver.sh      # installs it + restarts coreaudiod (~1s glitch)
  ```

**Upgrading an existing driver:** Seiren FX 3.0 removes the speaker outputs from both visible devices.
The Voice menu says **Seiren FX needs a one-time reinstall** and offers **Reinstall Seiren FX…**, using the same admin prompt as installation.
Processed voice continues through the old driver's output until you reinstall.
Your saved Seiren FX and Seiren Stream Mix microphone choices keep working because their UIDs are unchanged.
Source builds use the build and install commands above.

It's an MIT-licensed CoreAudio plug-in (`AudioServerPlugIn`) - no kext, no entitlements.
The copy bundled in releases is signed alongside the app; a local build is ad-hoc signed, which is all a local install needs.
To remove it, see [Uninstall](#uninstall).

Then, in the app you record or stream with, **select “Seiren FX” as the microphone**.
The app bridges the Seiren and Seiren FX under one clock (a private aggregate device), so there's no drift.
Without the driver installed, the Voice menu says so and the app still does plain headphone monitoring as before.

### Noise suppression

Under **🎙 → Voice ▸ Noise suppression** (creator path - needs Seiren FX):

- **Reduce noise (gate)** - a zero-latency downward gate that mutes room hiss / keyboard *between words* and opens instantly on speech.
  No latency, no model download - but, like the EQ, it runs on the Seiren FX route.
- **Studio Denoise (RNNoise)** - a neural denoiser that strips *steady* background noise (fan, AC, hum, computer) while you talk.
  Best quality.
  It adds ~10 ms of latency, but **only on the SeirenFX broadcast** - your **headphone monitor stays low-latency** (it gets gate + EQ, not Studio), so hearing yourself never feels laggy.
  Runs at 48 / 96 kHz.

When you monitor through Seiren FX, the EQ and the gate are heard in your monitor **and** by apps recording **Seiren FX**; Studio denoise applies to the Seiren FX broadcast only.

### Stream Mixer

The Stream Mixer builds one audio source for your stream: your processed voice plus the audio of your other apps, each at its own level, in a second virtual device named **Seiren Stream Mix**.
In OBS (or Discord Go Live, Twitch Studio, a browser studio), pick **Seiren Stream Mix** as the mic and you get the whole mix in one source.
It is the Mac counterpart of Synapse's Stream Mixer.

Open **🎙 → Stream Mixer ▸** and check **Mix into Seiren Stream Mix**:

- **Voice** is the same processed voice apps get from Seiren FX (EQ, noise suppression), so monitoring has to be **On** or **Auto**.
- **Desktop audio** is every app that has no channel of its own.
- **Add App ▸** gives an app its own channel (up to 6), so you can turn the music down without touching the game.
  **Remove App ▸** puts it back into Desktop audio.
- Each channel has a slider and a mute button.
  Both work while the menu stays open and apply instantly.
  A limiter on the mix keeps a loud game plus your voice from clipping.

What you hear yourself does not change: apps keep playing to your speakers or headphones as usual, and the faders only shape what the stream gets.
The mixer runs only while an app is recording Seiren Stream Mix, so macOS's audio-recording indicator is on only while you stream.

- Needs **macOS 14.2** or later (it uses Core Audio process taps) and **Seiren FX 3.0** for microphone-only devices.
  If you installed an older driver, open **Voice ▸ Reinstall Seiren FX…** (one admin prompt).
  The mixer continues to support the 2.0 driver while you arrange the reinstall.
- The first time the mixer runs, macOS asks to let Seiren record your computer's audio.
  If you decline, the app channels and Desktop audio stay silent.
  Turn it on later under **System Settings → Privacy & Security → Screen & System Audio Recording**.
- Safari plays web audio from shared WebKit processes, so a Safari channel also picks up web audio from other apps built on WebKit (Mail, for example).
- Keep OBS's audio monitoring off for the Seiren Stream Mix source.
  The mixer already leaves out any app that records the mix, so it can't loop back, but monitoring the source would play every app a second time, slightly delayed, in your headphones.

### Lighting

The V3 Pro's ring of 12 RGB LEDs is fully controllable from the app - no Synapse, no Windows.
(The V3 Mini has no Chroma zone - only a red/green mute LED - so the Lighting menu is hidden while a Mini is the attached mic, and the app never writes to its HID channel.)
Open **🎙 → Lighting ▸** and pick **Spectrum** (the device default), **Breathing**, **Wave**, a **Static** color (nine-color palette), or **Off**, and set **Brightness** with the slider.
Your choice is remembered and re-applied whenever the mic reconnects, because the hardware forgets its lighting state on unplug.

- The first lighting change prompts for **Input Monitoring** permission - that is how macOS gates the mic's HID control channel (grant it later under **System Settings → Privacy & Security → Input Monitoring** if you miss the prompt).
  The audio features never need this, and until you touch Lighting the app leaves the device's lights (and that permission) completely alone.
- CLI equivalent for scripting and diagnostics: `swift run seiren-probe lighting`.
- How the protocol was recovered from Synapse's own lighting engine (no USB capture involved): [`docs/PROTOCOL.md`](docs/PROTOCOL.md) §5.

### Why monitoring is software

macOS blocks every route to the Seiren's hardware sidetone, so the app copies the mic to your headphones itself, which adds about one audio buffer (a few milliseconds) of delay.
The details are in [How it works](CONTRIBUTING.md#how-it-works), [the latency trade-off](CONTRIBUTING.md#the-latency-trade-off-honestly), [Architecture](CONTRIBUTING.md#architecture), and [Why software monitoring?](docs/HARDWARE_SIDETONE.md#why-software-monitoring-the-hardware-sidetone-path-macos-blocks).

### Heads-up / caveats

- **Software monitoring, small latency.**
  ≈ one audio buffer (a few ms).
  Great for hearing yourself; not a zero-latency hardware monitor.
  See [the latency trade-off](CONTRIBUTING.md#the-latency-trade-off-honestly).
- **Needs Microphone permission (TCC).**
  The app reads the mic to monitor, EQ, denoise, and route your voice, so macOS prompts for **Microphone** access the first time.
  Without it, nothing can start and the menu will say so.
- **Creator features need Seiren FX.**
  The EQ and noise suppression reach your monitor and other apps only through the bundled **Seiren FX** device - install it once from **Voice ▸**.
  Plain headphone monitoring works without it.
- **The Stream Mixer needs macOS 14.2+ and system-audio permission (TCC).**
  It reads other apps' audio through Core Audio process taps; macOS asks the first time the mixer runs.
- **Lighting needs Input Monitoring (TCC).**
  The Chroma ring is driven over the mic's HID channel, which macOS gates behind **Input Monitoring**.
  The app only asks when you first use Lighting.
- **Old builds (v1.0.0 and earlier) are unsigned.**
  Current releases are signed and notarized; only the old builds need the one-time Gatekeeper bypass.
- **Headphones go in the Seiren, not the Mac.**
  Monitoring routes mic → *Seiren's* output.
  Plug your headphones into the mic.
- **V3 Mini: no monitoring, no lighting.**
  It has no headphone jack and no Chroma zone.
  It gets the EQ + noise suppression through Seiren FX, which is the feature its owners ask for.

## Troubleshooting

**`Invalid manifest … Undefined symbols … PackageDescription.Package.__allocating_init`**

`Package.swift` can't link against your toolchain's `PackageDescription`.
This almost always means **only the Command Line Tools are installed (no full Xcode)**, or `xcode-select` points at a stale/partial CLT.
Fix it:

```sh
xcode-select -p          # if this prints /Library/Developer/CommandLineTools, that's the problem
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift --version          # should report Swift 6.x
swift build
```

**Monitoring won't turn on / I hear nothing.**

- Confirm **Microphone** permission is granted (System Settings → Privacy & Security → Microphone).
- Confirm the Seiren is selected as a usable device - `swift run seiren-probe` should list a device whose name contains "Seiren".
- Confirm your headphones are in the **Seiren's** jack, not the Mac's.

**Apps on Seiren FX hear my Mac's mic instead of the Seiren.**

- The app didn't find the Seiren, so Automatic fell back to another mic (the menu's first line names it).
  `swift run seiren-probe inputs` lists every input and which one Automatic picks; the Seiren must appear there as eligible.
- Check that **Input ▸** is set to **Automatic** or to the Seiren.

**V3 Mini: the menu says “needs Seiren FX” / apps record a flat mic.**

- The Mini has no jack, so everything runs through Seiren FX: install it from **Voice ▸ Install Seiren FX…**, set the mode to **On — always**, then pick **Seiren FX** as the microphone in the app you record with.
- `swift run seiren-probe route` runs the real engine for 5 s and prints whether the route is live, the buffer layout, and the mic's peak level.
  A peak of “silence” with the route live usually means the mic is muted (the tap-to-mute LED is red).

## Uninstall

1. Quit the app: click the 🎙 menu → **Quit Seiren**.
   If you turned on **Launch at Login** in that menu, turn it off first.
2. Remove the app.
   If you installed it with Homebrew, run `brew uninstall --cask razer-seiren`.
   Otherwise drag **Seiren.app** from `/Applications` to the Trash.
3. Remove the Seiren FX driver, if you installed it.
   The app has no uninstall action for it yet; from a [source checkout](#building-from-source), run:
   ```sh
   sudo scripts/install-driver.sh --uninstall
   ```
   That deletes `/Library/Audio/Plug-Ins/HAL/SeirenFX.driver` and restarts `coreaudiod`, so all audio on the Mac drops out for about a second.
4. Remove the preferences:
   ```sh
   defaults delete com.yterry.seiren-mac
   ```
   If you added your own device files, also delete `~/Library/Application Support/seiren-mac`.

## Building from source

**Requirements:** macOS 13+ and a **Swift 6 toolchain** (full **Xcode 16+** recommended - see [Troubleshooting](#troubleshooting) for why Command-Line-Tools-only can fail).

```sh
git clone https://github.com/yterry/razer-seiren-macos.git && cd razer-seiren-macos
swift build -c release
.build/release/seiren-mac          # a 🎙 icon appears in the menu bar
```

Then continue with [First run](#first-run).
A source build installs Seiren FX with the scripts under [Install the Seiren FX driver](#voice-eq--and-making-other-apps-hear-it-seiren-fx).

### Run the tests / dev build

```sh
swift test                         # unit tests (SeirenKit and the app)
bash scripts/test-driver.sh        # SeirenFX driver tests (make test runs both)
swift run seiren-mac               # debug build of the menu-bar app
swift run seiren-probe             # read-only dump of the Seiren's audio controls
swift run seiren-probe route       # run the real engine for 5 s, report what the RT proc saw
swift run seiren-probe inputs      # list inputs and which one Automatic would pick
swift run seiren-probe listen "Seiren FX"   # what other apps hear on Seiren FX, per second
swift run seiren-probe startup     # measure cold mic startup and Seiren FX overhead
swift run seiren-probe mix 5 --app com.spotify.client   # run the Stream Mixer, report every channel's level
swift run seiren-probe lighting    # read-only lighting probe (firmware, serial, brightness)
```

How the app is put together is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Roadmap

Planned work is tracked in the [issue tracker](https://github.com/yterry/razer-seiren-macos/issues), and shipped versions are on the [releases page](https://github.com/yterry/razer-seiren-macos/releases).
See [`docs/CREATOR_DESIGN.md`](docs/CREATOR_DESIGN.md) for the full design.

## Credits & prior art

- [openrazer](https://github.com/openrazer/openrazer) — Razer USB protocol reference
- [Ashesh3/razer-device-control](https://github.com/Ashesh3/razer-device-control) — reverse-engineered Razer **audio** HID frames (EQ/DSP shape)
- [1kc/razer-macos](https://github.com/1kc/razer-macos) — the userspace-HID-on-macOS pattern (lighting)

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Razer Inc.; "Razer" and "Seiren"
are trademarks of Razer Inc.
