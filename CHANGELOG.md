# Changelog

All notable changes are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [1.0.0]

First public release — the full voice chain for Razer Seiren microphones on macOS,
in one menu-bar app.

### Hear yourself
- **Software headphone monitoring** — hear yourself live through headphones plugged
  into the Seiren, the sidetone Synapse never offers Mac mic owners. One
  full-duplex Core Audio `AudioDeviceIOProc` copies mic input to the headphone
  output, real-time-safe, with hotplug auto start/stop.
- **Three modes** — *Off*, *On — always*, and *Auto — only while another app is
  recording from the Seiren* (e.g. a Zoom/Teams call). Auto uses the macOS 14+
  per-process audio API and degrades to always-on on older macOS.

### Shape your voice
- **Parametric voice EQ** with presets — **Flat / Podcast / Studio / Broadcast** —
  tuned to be clearly audible. The per-sample filtering runs in a C DSP core
  (`SeirenDSP`) on the audio thread with a lock-free C11-atomic coefficient
  handoff; Swift computes the RBJ-cookbook coefficients off-thread.

### Kill the noise
- **Noise suppression** (creator path — needs Seiren FX), as a 3-way choice:
  - **Reduce noise (gate)** — a zero-latency downward gate that mutes room hiss /
    keyboard between words. Pure C, no dependencies.
  - **Studio Denoise (RNNoise)** — an opt-in neural denoiser for *steady*
    background noise (fan / AC / hum / computer). Vendored as a no-build-step
    SwiftPM C target (BSD-3; committed model, pinned in `MODEL_VERSION`). Runs at
    48 kHz; 96 kHz is resampled 2:1 with a half-band FIR. ~10 ms latency, off by
    default — and applied **only to the broadcast**, so the headphone monitor
    stays low-latency.

### Reach every app
- **Seiren FX** — an original, MIT-licensed loopback virtual audio device
  (`AudioServerPlugIn`, `Driver/SeirenFX`) so the EQ + noise suppression reach
  *other apps*: pick "Seiren FX" as the mic in OBS / Zoom / Discord and they
  record the processed voice. Bundled inside `Seiren.app`; **Voice ▸ Install
  Seiren FX…** copies it into place with a single admin prompt (no Terminal, no
  Developer ID).
- **Unified routing** — `MonitorEngine` runs one IOProc on a private aggregate
  device (Seiren as clock master + Seiren FX, drift-compensated), reads the mic,
  applies the chain, and fans it to both the headphone monitor (× level) and the
  Seiren FX broadcast. Falls back to direct-Seiren monitoring when Seiren FX
  isn't installed.

### Distribution
- **Homebrew** — `brew tap yterry/tap && brew install --cask razer-seiren`. The
  cask clears the Gatekeeper quarantine flag, so the unsigned build launches with
  no manual bypass; `brew upgrade --cask razer-seiren` updates it.
- Tag-triggered release CI builds the ad-hoc `.app`, zips it with a SHA-256
  checksum, and publishes a GitHub Release.

### Notes
- Monitoring is **software** (latency ≈ one audio buffer); the Seiren's hardware
  sidetone is not reachable from macOS userspace — see `docs/HARDWARE_SIDETONE.md`.
- Releases are **unsigned** until there's a paid Apple Developer ID; first launch
  of a downloaded build needs a one-time Gatekeeper bypass (see the README).
- Third-party attribution in `NOTICE` (RNNoise, BSD-3).
