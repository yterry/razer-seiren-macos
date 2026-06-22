---
name: Bug report
about: A feature (monitoring, EQ, noise suppression) doesn't work, or the app misbehaves
title: "[bug] "
labels: bug
assignees: ''
---

## What happened

A clear description of the problem.

## What you expected

What you expected instead.

## Steps to reproduce

1.
2.
3.

## Environment

- **Device name** (exactly as shown by `swift run seiren-probe`):
- **VID / PID** (`ioreg -p IOUSB -l | grep -iE 'idVendor|idProduct'`):
- **macOS version** (Apple menu → About This Mac):
- **`swift --version`** output:
- **Headphones plugged into the Seiren's jack?** (yes / no):
- **Microphone permission granted?** (System Settings → Privacy & Security → Microphone):

## `seiren-probe` output

Paste the full output of `swift run seiren-probe` (read-only; lists the device and
every audio control). For "I hear nothing" reports, also paste what happens with:

```
swift run seiren-probe monitor swmon 0.9
```

<details>
<summary>seiren-probe output</summary>

```
(paste here)
```

</details>

## Anything else

Logs, screenshots, or context.
