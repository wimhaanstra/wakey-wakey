# Flashing the Keychron K5 Max (K5M-H3)

K5M-H3 = **ANSI layout, RGB backlight**, so the firmware target is
`keychron/k5_max/ansi/rgb:keychron`.

## What the stock image is

`stock/keychron_k5_max_ansi_rgb_keychron.bin` is an unmodified rebuild of Keychron's own
`2025q3` source — **no battery patch yet**. It exists so the toolchain and the flashing
procedure can be proven separately from any code we add.

| | |
|---|---|
| Size | 108,020 bytes (`0x1A5F4`) |
| SHA-256 | `bba5b54bd6358f95e1b2e3ec1475461ee0a71ef6e904bf9c65bf60dda15ce22d` |
| Vector table | SP `0x20000400`, reset `0x0800811d` |

If this boots and the keyboard behaves, our build chain is known-good and the only new
variable in the next flash is the battery patch.

A rebuild is byte-identical **except** for an embedded build timestamp
(`2026-11-18-19:15:06`) and the CRC over it — 7 bytes in total. QMK has no
`SOURCE_DATE_EPOCH` support, so this is expected; the image in `stock/` is the canonical one.

## Before you start

- A USB-C **data** cable (charge-only cables are the usual cause of "device not found").
- The side switch set to **Cable**.
- `dfu-util` — installed at `/opt/homebrew/bin/dfu-util`.

## Optional: back up the firmware that is on the keyboard now

Enter the bootloader (below), then:

```bash
dfu-util -a 0 -s 0x08000000:0x20000 -U k5max-backup.bin
```

This fails if read-out protection is enabled, which is common. If it fails, the stock
image above is your fallback — it's built from the same source your keyboard shipped with
(firmware string `d.3.0 Jun  7 2024`).

## 1. Enter the bootloader

Per Keychron's own board notes: *toggle the mode switch to "Cable", hold down Esc (or press
the reset button underneath the spacebar) while connecting the USB cable.*

1. Switch to **Cable**.
2. Unplug the USB cable.
3. Hold **Esc** (or press and hold the reset button under the spacebar).
4. Plug the cable back in, keep holding for ~2 seconds.

Confirm the bootloader is up:

```bash
dfu-util -l
```

You want a line like:

```
Found DFU: [0483:df11] ver=2200, devnum=…, cfg=1, intf=0, path=…, alt=0,
name="@Internal Flash  /0x08000000/…", serial="…"
```

No such line means it's still booted normally — replug and try again, or use the reset
button.

## 2. Flash

```bash
dfu-util -a 0 -s 0x08000000:leave -D firmware/stock/keychron_k5_max_ansi_rgb_keychron.bin
```

Expect `Download done.` and `dfu-util: Leaving DFU mode...`, after which the keyboard
re-enumerates and boots into the new firmware.

Equivalent through QMK:

```bash
QMK_HOME=/tmp/qmk_firmware qmk flash -kb keychron/k5_max/ansi/rgb -km keychron
```

## 3. Verify

- **Typing** — all keys, both Shift/Enter variants of your layout.
- **RGB** — lighting keys work (this build is the RGB variant; a white-backlight image on an
  RGB board will misbehave).
- **2.4 GHz** — remove the cable, switch to 2.4G; the dongle should still type.
- **Bluetooth** — pair to something to confirm the BT module still works.
- **VIA / Launcher** — should still detect the keyboard; this is stock firmware.

## 4. If it goes wrong

The STM32 DFU bootloader lives in protected memory, so a bad application flash does not
remove it:

1. Unplug, switch to Cable, hold Esc, plug back in.
2. Re-run the `dfu-util` command above.

If the board isn't detected at all: different USB port, a known-good data cable, and try the
reset button under the spacebar instead of Esc.

## The battery-push image (the actual feature)

`builds/battery-push.bin` adds one raw-HID command to the stock image:

| | |
|---|---|
| Size | 108,220 bytes (+200 over stock) |
| SHA-256 | `9c4042ca2249da98476005057fad931c4acb8c14bc1faa74b5f74f14af6b28f1` |
| Patch | `patches/k5max-battery-rawhid.patch` — 73 insertions, 5 files |
| Protocol | `0xA4` → `[0xA4, percent, mV lo, mV hi, charging, transport]` |

Two behaviours, because the dongle only bridges traffic *from* the keyboard:

- **USB (wired)**: the host pulls it — command `0xA4` gets the report back.
- **2.4 GHz**: the keyboard *pushes* the same report every 2 s while connected, since a pull
  would never arrive.

Flash it exactly like the stock image:

```bash
dfu-util -a 0 -s 0x08000000:leave -D firmware/builds/battery-push.bin
```

Then verify over 2.4 GHz (cable out, switch to 2.4G):

```bash
swift probe/keychron_battery_listen.swift 15
```

Expected, once every ~2 s:

```
0xA4   87%  4021 mV  not charging  transport=0x02
```

Nothing printed means either the flash didn't take, the keyboard is not on 2.4 GHz, or the push is
not firing — reflash `stock/` to get back to a known state.

Rollback is always the stock image above.

## Licence

These patches modify Keychron's QMK firmware and are GPLv2; the battery approach is ported from
[OutersGIT/k10he-battery-firmware](https://github.com/OutersGIT/k10he-battery-firmware). If you
distribute a built image, the corresponding source has to travel with it. Details in
[NOTICE.md](NOTICE.md) and [../CREDITS.md](../CREDITS.md).

## Rebuilding

```bash
./firmware/build.sh                    # ANSI + RGB, default target
./firmware/build.sh keychron/k5_max/ansi/white keychron   # other variants
```

Outputs `firmware/builds/last-built.bin` plus its SHA-256. Prerequisites (QMK checkout,
submodules, `qmk` CLI, ARM toolchain) are documented at the top of the script.

Note: Homebrew's `arm-none-eabi-gcc` formula ships without newlib, so the build fails with
`stdint.h: No such file or directory`. The official ARM GNU toolchain tarball (13.3.rel1)
does work and needs no `sudo`.
