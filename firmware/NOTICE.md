# Firmware notice

Everything in this directory modifies **Keychron's QMK firmware for the K5 Max** and is therefore a
derivative work of it.

| | |
|---|---|
| Upstream | [Keychron/qmk_firmware](https://github.com/Keychron/qmk_firmware), branch `2025q3` |
| Licence | **GPLv2** (inherited from Keychron's tree and from QMK) |
| Approach derived from | [OutersGIT/k10he-battery-firmware](https://github.com/OutersGIT/k10he-battery-firmware) (GPLv2) |
| Files modified | `keychron_raw_hid.c/.h`, `wireless/battery.c/.h`, `k5_max/k5_max.c` |

The files we patch keep Keychron's original copyright headers. The added code — the `0xA4` command
handler, `kc_battery_push()` and the 2 s push hook — follows the design published by the
k10he-battery-firmware project, adapted to this board.

**If you distribute a firmware image built from these patches**, it is GPLv2: you must make the
complete corresponding source available. That is this repository plus the upstream Keychron tree at
the branch recorded above, which [`build.sh`](build.sh) pins in its header.

None of this affects the macOS app under `Sources/`, which is a separate program and contains no
QMK code.
