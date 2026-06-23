---
name: Feature request / device support
about: Request a feature, or report that a Seiren / Razer mic works (or doesn't)
title: "[feature] "
labels: enhancement
assignees: ''
---

## What you'd like

Describe the feature, or the device you'd like supported.

> **Adding device support is usually zero code** — Seiren for macOS matches any
> audio device whose name contains "seiren" (the EQ/denoise are device-agnostic DSP).
> The fastest path is to confirm it works
> with `swift run seiren-probe monitor swmon 0.9` and report below. See
> [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Device (if this is about a specific mic)

- **Device name** (exactly as shown by `swift run seiren-probe`):
- **VID / PID** (`ioreg -p IOUSB -l | grep -iE 'idVendor|idProduct'`):
- **macOS version**:
- **`swift --version`** output:
- **Does `swift run seiren-probe monitor swmon 0.9` let you hear yourself?** (yes / no):

<details>
<summary>seiren-probe output (helps a lot for device requests)</summary>

```
(paste output of `swift run seiren-probe` here)
```

</details>

## Why / use case

What problem does this solve for you?

## Alternatives considered

Anything you've already tried.
