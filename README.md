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
**A model without its own row** (the Other Seirens line) gets the audio features if macOS names the device with "Seiren" (monitoring needs a headphone jack), and no lighting.
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

Then open **Seiren** from `/Applications`.
It appears as a microphone icon (🎙) in the menu bar, with no window and no Dock icon; [First run](#first-run) covers what to do next.
Headphone monitoring works from there.
To unlock the **EQ and noise suppression** - and send the *processed* voice to other apps - open **🎙 → Voice ▸ Install Seiren FX…** once; it installs the bundled audio device and asks for your password (a one-time admin prompt).
See [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).

### Option B — download the app (no Xcode needed)

1. Grab `Seiren-<version>.zip` from the [latest release](https://github.com/yterry/razer-seiren-macos/releases/latest) and unzip it.
2. Move **Seiren.app** to `/Applications` and double-click it.
   Releases from **v1.1.0** on are signed and notarized, so it just opens - no Gatekeeper dance.
   (Only the old **v1.0.0** build was unsigned; if you need it, clear it once via **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Seiren.app`.)
   Follow [First run](#first-run) to start monitoring from the menu bar.
3. **To process what other apps record** (EQ + noise suppression in OBS / Zoom / Discord), open the 🎙 menu → **Voice ▸ Install Seiren FX…** and enter your password once - that installs the bundled virtual audio device.
   Then pick **Seiren FX** as the mic in those apps.
   (Headphone monitoring works without this; the EQ and denoise need it - see [Creator features](#voice-eq--and-making-other-apps-hear-it-seiren-fx).)

To build the app yourself, see [Building from source](#building-from-source).

### Is it safe?

Releases from **v1.1.0** on are **signed with an Apple Developer ID and notarized by Apple**, so Gatekeeper opens them cleanly - no bypass, no warnings.
If you'd rather not trust a prebuilt binary anyway, [build it from source](#building-from-source) - the whole app is this repo, no dependencies.
Released zips ship with a **SHA-256 checksum** so you can verify the download.
(The old **v1.0.0** build predates the Developer ID and is unsigned; its one-time **Open Anyway** instructions live in that release's notes, and the Homebrew cask clears its quarantine flag automatically.)
If you find a security problem, please report it privately as described in the [security policy](SECURITY.md).

### Updates

At launch and once a day, the app requests `https://api.github.com/repos/yterry/razer-seiren-macos/releases/latest` to learn the latest release's version.
That is its only network request, and it carries no account, identifier or cookie, only what any HTTP client sends: your IP address and a default User-Agent naming the app, its build number and the versions of macOS's networking stack and kernel.
When the latest release is newer than the running app, the 🎙 menu shows **Version X.Y.Z is available**, which opens that release's page.
The app does not install anything itself: Homebrew users run the `brew upgrade` line above, and zip users download the new zip.
A failed request shows nothing, and a build without a release version, such as the packaging script's default `0.0.0-dev`, skips the check.

To turn the check off, run this in Terminal and then quit and relaunch the app:

```sh
defaults write com.yterry.seiren-mac updates.checkEnabled -bool false
```

To turn it back on, run `defaults delete com.yterry.seiren-mac updates.checkEnabled` and relaunch.

## First run

Connect the Seiren and open **Seiren** from `/Applications` (or run `.build/release/seiren-mac` from a [source build](#building-from-source)).
Look for the microphone icon in the menu bar.
If a welcome dialog appears, choose **Not now** to try the headphone check below, or **Turn on Auto** to monitor during recordings.
If you have a **V3 Mini**, follow the [V3 Mini steps](#v3-mini) for recording through Seiren FX.

**Headphone check**

1. Plug your headphones into the Seiren's headphone jack.
2. Click the microphone icon in the menu bar and choose **On &mdash; always**.
   You can do this even if no welcome dialog appeared.
3. When macOS asks for microphone access, click **Allow**.
   If you previously denied access, follow the [microphone permission steps](#microphone-access-denied).
4. Speak into the Seiren and listen for your voice in the headphones.
   Use **Volume** in the same menu to adjust how loud you sound.

To switch to Auto from the microphone menu, choose **Auto &mdash; only while an app uses the mic**.
Allow microphone access if asked.
On macOS 14 or later, select the Seiren (or Seiren FX if installed) as the input in your recording app and start recording to hear yourself.
On macOS 13, Auto monitors whenever the Seiren is connected, just like On.
Seiren remembers your choice the next time you plug it in.
See [Monitoring modes](#monitoring-modes) for details.

### Monitoring modes

- **On — always**: monitor whenever the Seiren is connected.
  Simple, but the macOS recording indicator (orange dot) stays on the whole time - because software monitoring keeps the mic open.
- **Auto — only while an app uses the mic** *(recommended)*: monitor **only when another app is recording from the Seiren** - i.e. while you're on a Zoom/Teams call.
  The recording indicator stays on only while an app is recording.
  *(Uses the macOS 14+ per-process audio API; on older macOS it behaves like "On — always".)*
  So your first words aren't cut off, Auto keeps the Seiren's headphone side running silently while you're at the Mac.
  When an app starts recording, the mic is already awake and your voice reaches the app in under a tenth of a second, instead of about a quarter of a second from cold.
  This doesn't record anything or turn on the recording indicator, and it pauses while the display or the Mac sleeps.
  The V3 Mini has no headphone side, so it still starts from cold.
- **Off**: not monitoring.

### V3 Mini

The Mini has no headphone jack, so there is nothing to monitor into - the app's job for it is the **EQ + noise suppression**, sent to OBS / Zoom / Discord through Seiren FX.
Choose **On &mdash; always** in the microphone menu and allow microphone access if asked.
If the menu says the Mini needs Seiren FX, follow the [Seiren FX installation steps](#voice-eq--and-making-other-apps-hear-it-seiren-fx).
Select **Seiren FX** as the microphone in your recording app and play back a short recording to check your voice.
From a source checkout, confirm the route from the terminal with `swift run seiren-probe route` (see [Contributing](CONTRIBUTING.md)).

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

Open the menu while Seiren FX is running to see how loud your processed voice is.
The bar below the status line follows speech, and a red mark stays on for two seconds when the signal reaches full scale.

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
The 🎙 menu says **Seiren FX needs a one-time reinstall** and offers **Reinstall Seiren FX…**, using the same admin prompt as installation.
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
  If you installed an older driver, choose **Reinstall Seiren FX…** in the 🎙 menu (one admin prompt).
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
- CLI equivalent for scripting and diagnostics, from a source checkout: `swift run seiren-probe lighting`.
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

To file a [bug report](https://github.com/yterry/razer-seiren-macos/issues/new?template=bug.yml), choose how you installed Seiren and enter your **Microphone model**.
Click the microphone icon in the menu bar and look near the bottom of the menu.

- If you see **Copy Diagnostics**, choose it, review the text, and paste it into **Diagnostics** on the form.
  It lists app and Seiren FX versions, audio devices, permissions, engine state and recent events.
  Devices other than Seirens are listed by type only.
- If **Copy Diagnostics** is missing, enter `not available in my version` in **Diagnostics**.
  For **macOS version**, open the Apple menu and choose **About This Mac**.
  For **Seiren app version**, select Seiren in Finder's Applications folder and choose **File → Get Info**.

### Nothing appears in the menu bar after installing

- Seiren has no window and no Dock icon.
  Open **Seiren** from `/Applications`, then look for the microphone icon in the menu bar.
- On a Mac with a notch, menu bar icons that do not fit are hidden behind the camera.
  Quit or hide some other menu bar apps to make room.
- On macOS 26 or later, open **System Settings → Menu Bar** and check that Seiren is allowed in the menu bar.
- If you can't tell whether Seiren is running, open Activity Monitor and search for Seiren.

### "Microphone access denied"

- If the microphone menu offers **Open Microphone Settings…**, choose it.
  You can also open **System Settings → Privacy & Security → Microphone** yourself.
- Turn on Seiren in that list, then open the microphone menu and select your monitoring mode again.
- If the menu still says "Microphone access denied", choose **Quit Seiren** and open Seiren from `/Applications` again.

### "Couldn't start audio"

- If the menu says "Couldn't start audio" or "Audio error", note the error message or number.
  If you see **Try Again**, choose it.
- If audio still does not start, unplug the Seiren, plug it back in and wait a few seconds.
- Check that the Seiren is listed under **System Settings → Sound → Input**.
- If it still fails, include the error in your [bug report](#troubleshooting).
- From a source checkout: `swift run seiren-probe route` runs the engine for 5 s and prints what it saw.

### The menu says a mic "needs Seiren FX"

- The mic has no headphone jack (the V3 Mini is one), so the menu says "This mic has no headphone jack - it works through Seiren FX" and nothing runs until Seiren FX is installed.
- Choose **Install Seiren FX…** in the menu, confirm, and enter your password.
- Choose **On — always** or **Auto — only while an app uses the mic**, then pick **Seiren FX** as the microphone in the app you record with.
- If the app records silence, check the mic's tap-to-mute LED: red means the mic is muted.
- From a source checkout: `swift run seiren-probe route` runs the engine for 5 s and prints whether the route is live, the buffer layout and the mic's peak level.

### "Seiren FX was copied but macOS did not load it"

- This dialog appears when the install finished but macOS did not start the new audio device.
  Restart the Mac.
- After the restart, open the 🎙 menu and then **Voice ▸**.
  If it shows **Equalizer**, macOS loaded Seiren FX.
- If it still offers **Install Seiren FX…**, choose it again.
  If that shows the same dialog, [file a bug report](#troubleshooting).
- From a source checkout: `swift run seiren-probe driver-check` lists the Seiren FX devices macOS loaded and names each check that failed.

### Apps on Seiren FX hear silence or the wrong microphone

- Check that the mode is **On — always** or **Auto — only while an app uses the mic**.
  With **Off**, nothing reaches Seiren FX.
- If the menu says "Seiren FX couldn't start - apps using it hear silence", choose **Try Again**.
- The first line of the menu names the mic Seiren FX is using.
  If it names your Mac's mic instead of the Seiren, the app did not find the Seiren and **Input ▸ Automatic** fell back to another mic.
  Unplug the Seiren and plug it back in, and check that **Input ▸** is set to **Automatic** or to the Seiren.
- Check that the recording app's microphone is **Seiren FX** and that the mic's tap-to-mute LED is not red.
- From a source checkout: `swift run seiren-probe inputs` lists every input and which one Automatic picks, and `swift run seiren-probe listen "Seiren FX"` prints what other apps hear, once a second.

### Stream Mixer channels are silent

- The app channels and **Desktop audio** need permission to record your computer's audio.
  Open **System Settings → Privacy & Security → Screen & System Audio Recording** and turn on Seiren, then choose **Quit Seiren** from the 🎙 menu and open it again.
- **Voice** is silent while the mode is **Off**, and the menu says "Voice is silent while monitoring is Off".
- The mixer runs only while an app records **Seiren Stream Mix**; until then it says "Starts when an app records Seiren Stream Mix".
  Check that your streaming app's microphone is **Seiren Stream Mix**.
- If the menu says "Couldn't start the Stream Mixer", choose **Try Again** under it.
- Check that the channel is not muted: a muted channel's button shows a crossed-out speaker.
- From a source checkout: `swift run seiren-probe mix 5 --app <bundle id>` runs the mixer for 5 s and prints every channel's level.

### Lighting does nothing

- Only the V3 Pro has a Chroma ring; the Lighting menu is hidden for a V3 Mini.
- If **Lighting ▸** says "Lighting needs Input Monitoring access", choose **Open Input Monitoring Settings…** and turn on Seiren in **System Settings → Privacy & Security → Input Monitoring**.
- "Applies when the Seiren is connected" means the app does not see the mic's lighting yet; check the USB cable and plug the mic back in.
- If it says "Couldn't reach the mic's lighting", choose **Try Again** under it.
- From a source checkout: `swift run seiren-probe lighting` reads the firmware version, serial number, lighting mode and brightness.

### "Seiren quit unexpectedly last time"

- The top of the menu shows this after the app crashed, with three items.
- **Copy Crash Report** copies the report macOS wrote, and **Report on GitHub…** opens a new bug report.
  Paste the report into its **Crash report** field, and add the text from **Copy Diagnostics** too.
- Read the crash report before posting: it includes your Mac model, your macOS version and file paths that can contain your account name.
- **Dismiss** hides the notice until the app crashes again.

### Monitoring is on but I hear nothing

- The first line of the menu should say "Monitoring:" and the Seiren's name.
- Plug your headphones into the **Seiren's** jack, not the Mac's.
- Drag the **Volume** slider up.
- From a source checkout: `swift run seiren-probe monitor swmon 0.9` runs the same monitor the app uses until you press Return.

### Turn off Auto's standby

- To rule out the silent headphone-side standby while you troubleshoot Auto, turn it off from Terminal and then quit and relaunch the app:
  ```sh
  defaults write com.yterry.seiren-mac auto.standbyEnabled -bool false
  ```
- Auto then starts the microphone from cold when an app starts recording, so the first quarter of a second of your voice can be cut off.
- To turn standby back on, run `defaults delete com.yterry.seiren-mac auto.standbyEnabled` and relaunch.

## Uninstall

1. Remove the Seiren FX driver, if you installed it: open **🎙 → Voice ▸ Uninstall Seiren FX…**, confirm, and enter your password.
   Without the app, run this from a [source checkout](#building-from-source) instead:
   ```sh
   sudo scripts/install-driver.sh --uninstall
   ```
   Either way, `/Library/Audio/Plug-Ins/HAL/SeirenFX.driver` is deleted and `coreaudiod` restarts, so all audio on the Mac drops out for about a second.
2. Quit the app: click the 🎙 menu → **Quit Seiren**.
   If you turned on **Launch at Login** in that menu, turn it off first.
3. Remove the app.
   If you installed it with Homebrew, run `brew uninstall --cask razer-seiren`.
   Otherwise drag **Seiren.app** from `/Applications` to the Trash.
4. Remove the preferences:
   ```sh
   defaults delete com.yterry.seiren-mac
   ```
   If you added your own device files, also delete `~/Library/Application Support/seiren-mac`.

## Building from source

**Requirements:** macOS 13+ and a **Swift 6 toolchain** (full **Xcode 16+** recommended - see [Build error with only the Command Line Tools](#build-error-with-only-the-command-line-tools) for why Command-Line-Tools-only can fail).

```sh
git clone https://github.com/yterry/razer-seiren-macos.git && cd razer-seiren-macos
swift build -c release
.build/release/seiren-mac          # a 🎙 icon appears in the menu bar
```

Then continue with [First run](#first-run).
A source build installs Seiren FX with the scripts under [Install the Seiren FX driver](#voice-eq--and-making-other-apps-hear-it-seiren-fx).

### Build error with only the Command Line Tools

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
swift run seiren-probe driver-check   # check the installed Seiren FX driver's devices
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
