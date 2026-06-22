<!--
Thanks for contributing! Keep PRs small and focused. CI (macos-15, swift build +
swift test) must be green. See CONTRIBUTING.md.
-->

## What this changes

A short description of the change and why.

Closes #

## Type

- [ ] Bug fix
- [ ] New feature
- [ ] Device support / quirk
- [ ] Docs
- [ ] Refactor / chore

## How I tested it

- [ ] `swift build` succeeds
- [ ] `swift test` passes
- [ ] Smoke-tested `swift run seiren-mac` (if app/engine changed)

**Device(s) tested on** (for anything touching audio/device behavior):

- Device name (from `seiren-probe`):
- VID / PID:
- macOS version:
- `swift --version`:

<details>
<summary>Relevant seiren-probe output (for device work)</summary>

```
(paste here)
```

</details>

## Checklist

- [ ] `SeirenKit` stays **AppKit-free** (no `import AppKit`/`UIKit` in the library)
- [ ] Any `AudioDeviceIOProc` (and code it calls) is **RT-safe**: no allocation,
      locks, Obj-C, Swift-runtime calls, or blocking on the audio thread
- [ ] Every `CreateIOProcID` / property listener is paired with a clean teardown
- [ ] Builds Swift-6-clean — no new warnings, no `swiftLanguageModes` override
- [ ] No raw `.pcap`/`.pcapng` or Synapse `User Data` dumps committed
- [ ] Updated docs if behavior changed
