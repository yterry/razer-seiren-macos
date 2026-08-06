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
| **`0x07`** | **`0xFF53` vendor** | **Feature** | **64 B** | **Razer control (usage `0xF0`) — audio + lighting** |
| `0x05` | `0xFF53` | Input | 15 B | audio status/events (`0xF2`) |

**`0xFF53` is the Razer-audio vendor usage page.** Its **64-byte Feature report on
report ID `0x07`** is the prime channel for control commands (audio DSP and
lighting). 64 payload bytes + 1 report-ID byte = 65 on the wire; the body layout
is the "Device25" report in §5. Fallbacks if a capture says otherwise:
`0x55`/`0xFF90` (Output) or `0x41`/`0xFF82` (Output).

The macOS send is simply:

```
IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, /*reportID*/ 0x07, payload64, 64)
```

## 2. Razer audio command grammar

> **⚠️ Correction (Synapse-4 log mining, 2026-08-05): the V3 Pro does not use the
> "PA" frame.**
> Synapse's middleware log records the full `dataSend` buffer for every V3 Pro
> command, and none of them carry the `50 41` magic.
> The V3 Pro speaks the classic Razer control report (the openrazer family,
> "Device25") on this channel - for audio *and* lighting.
> See [§5](#5-lighting-razer-device25-chroma---confirmed-from-synapses-own-code)
> for the confirmed layout; the "PA" grammar below applies to the BlackShark
> family only and is kept for reference.

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

## 5. Lighting (Razer "Device25" Chroma) - confirmed from Synapse's own code

The V3 Pro has a **ring of 12 RGB LEDs** and full Chroma support
(`isChromaDevice: true`, `isChromaStudioSupported: true` in Synapse's device data).
None of this was captured over USB - it was recovered from Synapse 4's own
artifacts, which is better than a capture because it includes the command
*dictionary*, not just observed frames.
Implementation: `Sources/SeirenKit/RazerLighting.swift` (codec) and
`LightingController.swift` (HID transport); `swift run seiren-probe lighting`
drives it from the CLI.

### 5.1 Transport and report layout

Same channel as §1: HID **interface 3**, **Feature report `0x07`**, opened
non-exclusively.
Synapse registers the mic with its lighting driver as
`protocol: rzDevice25AudioCamyT3V2, write_function: hid.sendFeatureReportInBatch,
claimInterface: 3, report_id: 7` ("Camy" is the V3 Pro's internal codename; the
audio DLL names the device `CRzCamyAudioDevice`).

The report body is **64 bytes** (65 on the wire with the report ID; the §1 table's
"63 B" was a bad early read of the descriptor).
Layout - the classic Razer control report, shortened from openrazer's 90 bytes:

| Offset | Field | Notes |
|---|---|---|
| 0 | status | `0x00` on send; reply `0x02` = success, `0x01` busy, `0x03` failure, `0x04` timeout, `0x05` unsupported |
| 1 | transaction id | echoed in the reply |
| 2-3 | remaining packets | 0 |
| 4 | protocol type | 0 |
| 5 | data size | meaningful argument bytes |
| 6 | command class | `0x00` device, `0x08` audio, `0x0F` Chroma |
| 7 | command id | get = set \| `0x80` |
| 8-61 | arguments | zero-padded |
| 62 | crc | **XOR of bytes 0..61** - note this *includes* the transaction id, unlike openrazer's 90-byte report |
| 63 | reserved | 0 |

Replies are read back with GET_REPORT (Feature `0x07`), polling ~5 ms until the
transaction id matches (Synapse polls up to ~10 times).

### 5.2 Command dictionary (from Synapse's lighting-engine JS)

Headers are `[data size, class, id]`:

| Command | Header | Arguments |
|---|---|---|
| Get firmware version | `[0x02, 0x00, 0x81]` | reply `[major, minor]` |
| Get serial number | `[0x16, 0x00, 0x82]` | reply = ASCII serial |
| Set device mode | `[0x02, 0x00, 0x04]` | `[mode, 0]`; 0 = normal, 3 = driver (Synapse runs the mic in 3) |
| Get device mode | `[0x02, 0x00, 0x84]` | |
| **Set Chroma effect** | `[0x50, 0x0F, 0x02]` | `[profile, region, effect, flags, rate, nColors, r,g,b ...]`, size 6 + 3n |
| **Set Chroma frame** (one row) | `[0x50, 0x0F, 0x03]` | `[profile, region, row, startCol, endCol, r,g,b ...]`, size 5 + 3n |
| Set Chroma brightness | `[0x03, 0x0F, 0x04]` | `[profile, region, floor(pct / 100 * 255)]` |
| Get Chroma brightness | `[0x03, 0x0F, 0x84]` | `[profile, region]` |
| Set Audio Chroma display switch | `[0x03, 0x0F, 0x12]` | mic-specific (headphone / mic-gain / voice-activated / mute-effect modules) |
| Set Chroma tap | `[0x04, 0x0F, 0x13]` | tap-to-mute Chroma behavior |

Effect ids (`NEW_CHROMA_EFFECT_ID`): 0 Off, 1 Static, 2 Breathing, 3 Spectrum,
4 Wave, 5 Reactive, 6 BasicRipple, 7 Starlight, **8 CustomFrame**, 9 Fire,
10 AudioMeter, 11 Immersive, 12 Wheel.
The device's own default (and Synapse's `quickEffectOnExit`) is **Spectrum**.

Custom frames: upload the ring as row 0, columns 0..11
(`Set Chroma frame`), then select effect 8 to display it.
Synapse streams these at 25 fps for its software effects.

### 5.3 LED geometry

From Razer's public device manifest
(`https://apps.razer.com/synapse/products/1422/mw/lighting-manifests/DeviceManifest_1422_0.json`):
`DeviceMaxRow: 1, DeviceMaxCol: 12` - one logical row of 12 LEDs whose
`MatrixPos` entries trace a circle in a 6×6 grid, i.e. the ring around the mic.

### 5.4 Evidence trail

- `lighting_driver.log`: the device.register JSON quoted in §5.1.
- `products_1422_mw*.log`: 400+ full `dataSend` byte dumps (audio class `0x08`
  plus `Set Device Mode`), which pin the 64-byte layout and the checksum rule.
  `RazerLightingTests` replays four of them byte-for-byte.
- Synapse's lighting-engine web app (public, apps.razer.com
  `synapse/lighting-engine/static/js/`): the `rzDevice25AudioCamyT3V2` class
  (`_createDataSend`, `_calculateChecksum`, `generateChromaFrameData`) and the
  Chroma command/effect dictionaries in `main.*.js`.
- The device manifest above for the LED layout.

### 5.5 Verifying on hardware

1. `swift run seiren-probe lighting` - read-only; the reported serial must match
   the device sticker (Synapse logged `UC2618L08100451` for this unit).
2. `swift run seiren-probe lighting static 00FF00` - the ring should turn green.
3. If an effect command succeeds but nothing changes visually, try driver mode
   first: `swift run seiren-probe lighting mode 3`, then the effect (Synapse
   always runs the device in mode 3; mode 0 restores firmware control).

## 6. Sources

- openrazer report struct + CRC: <https://github.com/openrazer/openrazer/blob/master/driver/razercommon.c>
- Razer audio "PA" frames + `setRemoteMode`: <https://github.com/Ashesh3/razer-device-control>
- macOS userspace-HID pattern: <https://github.com/1kc/razer-macos>
- IOHIDManager Input-Monitoring permission: <https://nachtimwald.com/2020/11/08/macos-iohidmanager-permission-issue/>
