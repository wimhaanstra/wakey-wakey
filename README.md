# Wakey

Menu bar app for macOS: **put the mouse on its charging dock → displays go dark; pick it up → they come back.**

Design, measurements and the risk list live in [PLAN.md](PLAN.md).

## Status

| Milestone | State |
|---|---|
| **M0** sensor calibration | ✅ charging = `flags & 0x80` on HID++ feature `0x1001` |
| **M1** displays blank/wake, assertions | ✅ verified on a clamshell MacBook Pro |
| **M2** dock sensor + logging | ✅ running, logs a heartbeat every 5 min |
| **M3** automation | ✅ on by default, with stand-down override |
| **M4** settings, login item, icon | ✅ built |

## Build and run

```bash
make app          # builds + ad-hoc signs Wakey.app
open Wakey.app    # menu bar icon appears, no Dock icon
make install      # copies to /Applications (recommended before enabling login)
make selftest     # constructs the windows, prints login-item status, touches no displays
make clean
```

`make app` calls `swiftc` directly: SwiftPM's build system writes outside the workspace and fails in
sandboxed environments, so `Package.swift` is kept only for opening the folder in Xcode.

## Settings

Menu → **Settings…** (shown automatically on first launch):

| Setting | Effect |
|---|---|
| **Automate while the mouse is on its charger** | blanks on dock, releases on pickup |
| **Keep this Mac awake while the displays are off** | holds sleep-preventing assertions so a clamshell Mac doesn't suspend and drop the USB receiver |
| **Start Wakey at login** | `SMAppService.mainApp`, falling back to a LaunchAgent if ServiceManagement refuses |
| **Show mouse battery** / **Show keyboard battery** | which devices appear in the menu bar and which menu rows exist; both off leaves a plain status icon so the menu stays reachable |
| **Blank the displays when this device charges** | the mouse on its dock (default) or the keyboard while charging |
| **Green charging badge** | colour badge vs a template image that always matches the menu bar tint |
| **Rescan** / slot picker | re-enumerates the Logitech receiver's six paired slots; the picker appears when more than one answers |

The panel also has *Blank now*, *Wake now*, and *Reveal log in Finder*.

**Install to `/Applications` first** if you want login-at-startup to survive: the login item points at
the app bundle's current path, so an app left on an external volume will not come back after a reboot.

## Which device it listens to

The menu carries a `Receiver: …` line and **Settings** shows a Device section:

```
Receiver:      USB Receiver (046d:c539)
Listening to:  slot 0x01, battery feature 0x06 (only slot answering)
Keyboard:      87% · 4.02 V · not charging
Sensor:        state=away 3.98 V discharging failures=0 flags seen: 0x00
```

**Rescan** re-enumerates all six receiver slots. If more than one slot answers, a picker appears and
the choice is remembered.

There is no model name to show: this mouse reports a 37-character name length through the standard
`0x0005` device-name feature but returns zero bytes for every character index, in both short and long
report forms (checked with `probe/device_info.swift`). Receiver ID plus slot is the identity the
hardware is willing to give.

## Choosing devices

Two independent questions, so they are two controls:

- **What to show** — each device's menu-bar entry and menu row can be switched off independently. This
  matters if you only ever care about one of them, or have the keyboard on a machine where it never
  reports.
- **What to react to** — exactly one device drives the displays: the mouse on its dock, or the keyboard
  while charging. Deliberately not both: two sources blanking and waking the same displays would fight
  each other.

For the mouse there is a third level, already present: the receiver exposes six paired slots, and if
more than one answers the Settings panel shows a picker (automatic, or a specific slot).

## Menu bar

The status bar shows both devices at a glance — `🖱 76%  ⌨ 75%` — composed as one template image so
it inverts correctly and never reflows as the numbers change. A device with no reading shows `—`.

The menu rows carry device icons too, with a bolt badge tucked against the glyph while that device is
charging.

## Battery percentage

The device reports **voltage only**. Functions `0x01`, `0x10` and `0x20` on the battery feature all
echo the same three-byte voltage reply, and the capacity features (`0x1000` battery level status,
`0x1004` unified battery) are absent from its feature set.

So the percentage is derived from the discharge curve the Linux kernel uses for `0x1001`-only devices
(`hidpp20_map_battery_capacity`) and displayed as **≈77%**, never as an exact figure:

- while charging the cell sits above its resting voltage, so the estimate reads high
- the curve is generic — Logitech itself warns it doesn't fit every battery chemistry
- when the device reports its own *full* flag, the app shows 100% rather than the curve's ~96%

Checked once against G HUB on 2026-11-18: G HUB reported 78 % where Wakey showed ≈77 % at 3.975 V, so
the curve fits this battery in the mid range. The low end (below ~20 %) is where generic curves
usually drift, and that hasn't been checked yet.

## How it decides

1. It polls `0x1001 BATTERY_VOLTAGE` every 2 s over the receiver's vendor HID interface. Bit 7 of the
   flags byte means charging. No permissions, no Accessibility grant, no Screen Recording.
2. Two agreeing readings are required — one glitchy reply can't flap the displays.
3. A failed poll never changes state; HID++ errors are intermittent.
4. **Leaving "docked" needs proof**: pointer motion (read from
   `CGEventSource.secondsSinceLastEventType`, permission-free) or ten minutes of real battery drain.
   At 100 % the dock stops charging and the device reports *discharging* while still parked, so
   charging state alone is not enough.
5. Waking is left to macOS: picking the mouse up produces HID input and the displays come back on
   their own. Wakey only releases its assertions.

Your screen-lock delay is 5 minutes, so short charges return straight to your desktop and longer ones
ask for your password.

## Verifying by hand

```bash
make status                                     # is the display asleep?
./Wakey.app/Contents/MacOS/Wakey --sensor 30    # watch dock detection for 30 s
pmset -g assertions | grep -i wakey             # held assertions while blanked
```

The log is at `~/Library/Logs/Wakey/wakey.log`, also visible under **Show diagnostics…**.

Things worth grepping for:

- `SENSOR new flags value …` — an unseen flags byte (this is how `0x91`, full charge, was identified)
- `implausible reading … rediscovering` — should be rare; a cluster suggests G HUB is crowding the receiver
- `HEARTBEAT … failures=N` — a steadily rising `N` means the receiver is getting hard to talk to

## Keyboard battery (Keychron K5 Max over 2.4 GHz)

Stock firmware cannot report it — that's established, not assumed. Keychron's own QMK source exposes
only `0xA8`–`0xAB` on raw HID (RGB, analog matrix, BT DFU, factory test), and Launcher's battery code
belongs to its *mouse* classes. The firmware computes a percentage internally
(`battery_get_percentage()`) but only to drive the Fn+B LED.

So the repo carries a small firmware patch — [`firmware/patches/k5max-battery-rawhid.patch`](firmware/patches/k5max-battery-rawhid.patch),
73 insertions over 5 files — that adds one raw-HID command:

| Byte | Meaning |
|---|---|
| `[0]` | `0xA4` |
| `[1]` | battery percentage |
| `[2..3]` | voltage, mV little-endian |
| `[4]` | 0 not charging · 1 charging · 2 full |
| `[5]` | transport: `0x01` USB · `0x02` Bluetooth · `0x04` 2.4 GHz |

Two transports, two directions, because the dongle only bridges traffic *from* the keyboard: over USB
the host pulls `0xA4`; over 2.4 GHz the keyboard **pushes** it every ~2 s. Wakey only ever listens.

With that firmware flashed, the menu shows `Keyboard: 87% · 4.02 V · not charging` and the Settings
panel repeats it. On stock firmware it shows `Keyboard: no data`.

Building, flashing and rollback are covered in [firmware/FLASHING.md](firmware/FLASHING.md); the stock
image is kept alongside the patched one for a one-command revert.

## Credits

The keyboard half of this project exists because of
**[k10he-battery-firmware](https://github.com/OutersGIT/k10he-battery-firmware)** by OutersGIT
(GPLv2): the `0xA4` command, the payload layout and the push-over-2.4-GHz model are all its design,
ported here to the K5 Max. The firmware we patch is
[Keychron's QMK tree](https://github.com/Keychron/qmk_firmware) (GPLv2), and the mouse percentage uses
the voltage curve from the Linux kernel's `hid-logitech-hidpp.c`.

Full attribution, including protocol references and licensing: **[CREDITS.md](CREDITS.md)**.
Firmware-specific notice: [firmware/NOTICE.md](firmware/NOTICE.md).

## Notes

- **G HUB** polls the same receiver using HID++ client id 0. Wakey ignores those reports entirely and
  never acts on an error, so both can run side by side.
- The mouse goes quiet on its own; silence is treated as "no news", never as "picked up".
- Nothing here is sandboxed and nothing needs a privileged helper.
