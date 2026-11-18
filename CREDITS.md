# Credits

Wakey stands on several open-source projects and on one piece of reverse engineering
done by someone else.

## Firmware

**[Keychron QMK firmware](https://github.com/Keychron/qmk_firmware)** — branch `2025q3`, GPLv2.
The K5 Max board support, the wireless stack and the build target all come from here. Our patch
only adds to it, and the files we touch keep Keychron's original copyright headers.

**[k10he-battery-firmware](https://github.com/OutersGIT/k10he-battery-firmware)** by OutersGIT —
GPLv2. **This project is the reason the keyboard battery works at all.**
The whole design came from it: the `KC_GET_BATTERY = 0xA4` raw-HID command, the payload layout
(percentage, millivolts, charging state, transport), the idea of advertising a `FEATURE_BATTERY` bit
so hosts can detect support, and — critically — the observation that the 2.4 GHz dongle does not
bridge host→keyboard raw HID, so the keyboard has to *push* the report on a timer. Our patch is a
port of that approach to the K5 Max.

**[QMK Firmware](https://qmk.fm)** and its submodules (ChibiOS, ChibiOS-Contrib, LUFA) — build system
and drivers.

## Protocol references

**Linux kernel, [`drivers/hid/hid-logitech-hidpp.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-logitech-hidpp.c)** —
GPLv2. The HID++ 2.0 battery-voltage parsing (feature `0x1001`) and the 100-point voltage→capacity
curve that [`BatteryEstimator.swift`](Sources/Wakey/BatteryEstimator.swift) ports, including its
warning that the curve does not fit every battery.

**[Solaar](https://github.com/pwr-Solaar/Solaar)** — GPLv2. Reference for HID++ framing, feature
lookup and the `0x1001` flag semantics during exploration.

**[KeyTray](https://github.com/voxors/KeyTray)** by voxors — MIT.
First pointer that Keychron dongles expose battery on a vendor HID page (`0x8C`, report `0xB3`). That
protocol did not fit this keyboard, but it is what told us the dongle was worth probing at all.

**[Keychron Launcher](https://launcher.keychron.com)** — proprietary, used only as an
interoperability reference. We captured its WebHID traffic and read its published JavaScript to learn
which interface the keyboard actually speaks (raw HID on `0xFF60`) and to establish that it has no
keyboard battery command. No Launcher code is included or adapted here.

## Tooling

QMK's build system, the Arm GNU Toolchain, `dfu-util` and `iconutil`; Apple's IOHID, SF Symbols and
AppKit.

## Licensing

- `firmware/patches/*` and any firmware built from them are derivative works of Keychron's QMK
  firmware and are licensed **GPLv2**. See [`firmware/NOTICE.md`](firmware/NOTICE.md).
- The macOS app sources under `Sources/` contain no copied third-party code: the protocols were
  reimplemented from documentation and observation. No licence has been chosen for them yet.
