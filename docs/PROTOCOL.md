# Protocol notes — Razer Seiren on macOS

This is the technical basis for `seiren-mac`: what we confirmed on the hardware,
the Razer audio protocol grammar, and how to capture a model's command bytes.

> **⚠️ Correction (log-mining, 2026-06-20): sidetone is USB-Audio-Class, not HID.**
> Analysis of Razer Synapse's own logs + the `RzNative_058e` DLL shows the mic
> monitor / sidetone (`SetMicMonitorEnable` / `SetMicMonitorLevel`) is driven by a
> **UAC Feature-Unit volume + mute `SET_CUR`** (through Thesycon's TUSBAUDIO audio
> driver), *not* a vendor HID Feature report. Evidence: the middleware log records
> raw HID `dataSend[]` byte arrays for every HID feature (EQ, noise gate, etc.) but
> **none** for sidetone (only `r: true`), and the DLL imports `TUSBAUDIO_SetVolume`/
> `TUSBAUDIO_SetMute` with **no** `HidD_SetFeature`. The level is UAC volume in
> 1/256 dB (`uLevel` 100 → `0x1F00`). So on macOS sidetone is controlled via
> **Core Audio** (see the `seiren-probe` tool), *not* `IOHIDDeviceSetReport`. The
> HID `0xFF53`/report `0x07` material below is accurate but applies to the
> **EQ/DSP** feature set (a possible future addition) — the wrong transport for
> sidetone.

## 1. The device (Razer Seiren V3 Pro, confirmed on macOS)

`VID 0x1532` (Razer), `PID 0x058E`. A USB composite device (`bDeviceClass 0xEF`,
IAD) with four interfaces:

| Interface | Class | Owner | Role |
|---|---|---|---|
| 0 | 1 / sub 1 | `AppleUSBAudioControlNub` | USB-Audio control |
| 1 | 1 / sub 2 | `usbaudiod` | USB-Audio streaming |
| 2 | 1 / sub 2 | `usbaudiod` | USB-Audio streaming |
| **3** | **3 (HID)** | `AppleUserUSBHostHIDDevice` / `IOHIDInterface` | **control** |

Interface 3 is a normal HID interface, owned by `IOHIDFamily` — **independent of
the audio interfaces**. We can open it non-exclusively and send reports without
touching audio.

### HID interface 3 — collections

`hidutil list` shows only the *primary* usage (`0x0C` Consumer), but the device's
`DeviceUsagePairs` / `ReportDescriptor` reveal the real map:

| Report ID | Usage page | Direction | Size | Notes |
|---|---|---|---|---|
| `0x06` | `0x0C` Consumer | Input | 8b | media keys (dial/buttons) |
| `0x08` | `0x0B` Telephony | Input | — | mute / hook |
| `0x55` | `0xFF90` vendor | In **+ Out** | 63 B | vendor channel |
| `0x41` | `0xFF82` vendor | In **+ Out** | — | vendor channel |
| **`0x07`** | **`0xFF53` vendor** | **Feature** | **63 B** | **Razer audio (usage `0xF0`)** |
| `0x05` | `0xFF53` | Input | 15 B | audio status/events (`0xF2`) |

**`0xFF53` is the Razer-audio vendor usage page.** Its **63-byte Feature report on
report ID `0x07`** is the prime channel for monitoring/DSP commands. 63 payload
bytes + 1 report-ID byte = the 64-byte Razer-audio "PA" frame. Fallbacks if a
capture says otherwise: `0x55`/`0xFF90` (Output) or `0x41`/`0xFF82` (Output).

The macOS send is simply:

```
IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, /*reportID*/ 0x07, payload64, 64)
```

## 2. Razer audio command grammar

The only published Razer-**audio** frames come from `Ashesh3/razer-device-control`
(a BlackShark headset). They establish the format you'll decode a Seiren capture
against. The 64-byte "PA" report:

| Offset | Value | Meaning |
|---|---|---|
| 0 | `0x02` (BlackShark) / `0x07` (V3 Pro) | HID report ID |
| 1 | `0x80` | direction = output |
| 2 | `total_len` | payload length from byte 5 |
| 3–4 | `00 00` | reserved |
| 5–6 | `50 41` | magic **"PA"** |
| 7 | `inner_len` | `0x0E` for remote-mode, `0x08` for data |
| 8 | `00` | reserved |
| 9 | `cmd_type` | `02`=set, `04`=set+ack, `06`=config, `0D`=bulk |
| 10 | `cmd_id` | command id |
| 11+ | params | command-specific |
| rest | `00` | zero-pad |

Known frames (none toggle monitoring — they show the shape):

```
set_remote_mode(true):   02 80 07 00 00 50 41 0E 00 02 E1 01
set_remote_mode(false):  02 80 07 00 00 50 41 0E 00 02 E1 00
set_volume(0x80):        02 80 09 00 00 50 41 08 00 04 93 00 01 80
set_enhancement(true):   02 80 09 00 00 50 41 08 00 04 9D 00 01 01
```

**The sidetone/monitor `cmd_id` is in no public source** — it must be captured.
Likely a neighbor in the `0x04`/`0x9x` (set+ack) range on the mic side.

### `setRemoteMode` handshake (probably required)

Synapse claims software control before settings "take": it sends
`set_remote_mode(true)` (`… 02 E1 01`) before data commands and re-pushes on
profile switches. So **capture a full plug-in + toggle exchange**, not just the
single visible frame, and replay any prefix as `commands.handshake`.

### CRC

The 90-byte openrazer keyboard report uses an XOR-of-bytes-[2..87] CRC. The
64-byte "PA" audio report has **no CRC** (zero-padded). Whether the Seiren adds
one is unknown until capture — if present, it'll show as a non-zero trailing byte
that changes with the payload.

## 3. Capturing a model (Windows)

1. **Prefer the Synapse log shortcut.** Synapse 4 logs HID byte dumps to
   `%LOCALAPPDATA%\Razer\RazerAppEngine\User Data\Logs\`. Toggle monitoring, grep
   the logs for the new `sendCommandOut` line — that array is your payload.
2. **Or USB-sniff.** Wireshark + USBPcap on real Windows/Boot Camp (USB-audio
   passthrough into a VM is flaky). Baseline capture untouched, then a capture
   toggling **only** monitoring; diff. The changed **OUT/Feature** frame on the
   vendor HID interface is it. Map volume/mute the same way to validate the
   channel and locate the on/off byte.

Record for ON and OFF: report ID, feature-vs-output, full payload, and any
handshake prefix. Put them in the model JSON (see `CONTRIBUTING.md`); `hex` is the
payload **after** the report ID.

## 4. macOS specifics / risks

- **Open non-exclusively** (`IOHIDManagerOpen(mgr, 0)` = `kIOHIDOptionsTypeNone`).
  Seizing the device would fight `AppleUSBAudio` and could kill the mic.
- **Input Monitoring (TCC).** `IOHIDDeviceOpen`/`IOHIDManagerOpen` may return
  `kIOReturnNotPermitted` until the binary is granted Privacy → Input Monitoring.
  The app detects this and links to the setting.
- **Volatile state.** The setting resets on unplug/reboot — re-apply on hotplug
  (the controller does this via the IOHIDManager match callback).
- **Don't guess bytes.** Replay only captured commands; a stray command class
  could hit a firmware/DFU path. Keep a Windows+Synapse box to recover.

## 5. Sources

- openrazer report struct + CRC: <https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c>
- Razer audio "PA" frames + `setRemoteMode`: <https://github.com/Ashesh3/razer-device-control>
- macOS userspace-HID pattern: <https://github.com/1kc/razer-macos>
- IOHIDManager Input-Monitoring permission: <https://nachtimwald.com/2020/11/08/macos-iohidmanager-permission-issue/>
