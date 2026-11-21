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

## The battery-push + F17 image (the actual feature)

`builds/f17-mic.bin` is the current image: the battery push, the idle LED timeout, and the
microphone-key remap.

| | |
|---|---|
| Size | 108,888 bytes (+868 over stock) |
| SHA-256 | `2833ccc7dbd41ad9e4641f205a8405115519bc03c7e8539ea3b278a138b54103` |
| Patch | `patches/k5max-wakey.patch` — 323 insertions, 4 deletions, 7 files |
| Protocol | `0xA4` → `[0xA4, percent, mV lo, mV hi, charging, transport]` |

The microphone/Siri key is remapped from `KC_SIRI` to `KC_F17` on the Mac layer (and from
`KC_CTANA` to `KC_F17` on the Windows layer), so it no longer sends ⌘Space. The four PlayStation
keys remain F13–F16; Wakey's **Settings → Keyboard → Macro keys** lists all five keys.

Two behaviours, because the dongle only bridges traffic *from* the keyboard:

- **USB (wired)**: the host pulls it — command `0xA4` gets the report back.
- **2.4 GHz**: the keyboard *pushes* the same report every 2 s while connected, since a pull
  would never arrive.

Flash it exactly like the stock image:

```bash
dfu-util -a 0 -s 0x08000000:leave -D firmware/builds/f17-mic.bin
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

## Battery saving: LEDs off when idle

the current image turns the RGB matrix **off after 60 s without a keypress** and brings it back
on the next one — no host involvement, so it works over 2.4 GHz, Bluetooth and USB alike (on USB the
timeout is not applied, since there is no battery to save).

**The obvious approach does not work.** QMK's `RGB_MATRIX_TIMEOUT` can be configured, but Keychron's
indicator code re-arms it to `RGB_MATRIX_TIMEOUT_INFINITE` every time the wireless link connects:

```c
// wireless/indicator.c, case WT_CONNECTED
indicator_set_backlit_timeout(DECIDE_TIME(backlit_disable_time * 1000, indicator_config.duration));
// DECIDE_TIME(t, duration) → duration == 0 ? RGB_MATRIX_TIMEOUT_INFINITE : max(t, duration)
```

`indicator_config.duration` defaults to 0, so any configured timeout is overwritten within seconds of
connecting — measured on hardware: the LEDs stayed on indefinitely.

**What the patch does instead** ([`patches/k5max-wakey.patch`](patches/k5max-wakey.patch)) drives the
matrix directly from the board's periodic task, which no indicator can override:

- `wireless_enter_sleep_kb()` → `rgb_matrix_disable_noeeprom()` — the module's own suspend, the
  reliable trigger
- our own `wakey_last_key_time` (fed from `process_record_user`) older than the timeout →
  `rgb_matrix_disable_noeeprom()`
- next keypress → `rgb_matrix_enable_noeeprom()`
- only acts when `rgb_matrix_is_enabled()`, so it never fights a deliberate `Fn+Tab`
- skipped entirely on `TRANSPORT_USB`

**Verified on hardware, repeatedly**: on 2.4 GHz the board goes dark after the idle period, the first
keypress restores it, and it dims again on every subsequent cycle. Measured over a two-cycle run with
the instrumented build: `lpmPath` 1 → 2 → 3 with `matrixEnabled` 1 → 0 → 1 and the idle clock re-arming
each time.

### Changing the timeout without a computer — Fn+Y

The timeout lives in EEPROM and cycles on the keyboard itself, so it is adjustable over 2.4 GHz where
no host command can reach it. **Fn+Y** steps through 90 → 60 → 30 → 15 s and back, and the **digits of the value light up on the
number row**:

| Keys lit | Timeout |
|---|---|
| `9` `0` | 90 s |
| `6` `0` | 60 s |
| `3` `0` | 30 s |
| `1` `5` | 15 s |

The digits are green for 2.5 s and **the rest of the board dims to near-black** for that window, so
the value is unmistakable. Everything returns to your normal effect afterwards. They are found by matrix
coordinate — `rgb_matrix_map_row_column_to_led(1, col, …)`, since the number row is matrix row 1 and
columns 1–10 are the keys 1–0 — rather than by hardcoded LED index.

(`Fn+T` was the obvious choice but it is already "speed up" on the RGB layer; `Fn+Y` is free on both
FN layers.)

### Reading the setting over 2.4 GHz

A request cannot cross the link, but the answer can. The timeout therefore rides along with the battery
push `0xA4`:

| Byte | Meaning |
|---|---|
| `[6..7]` | idle timeout in seconds, little-endian (`0` = never) |
| `[8]` | `1` = the field is present |

Byte `[8]` matters: without it an old firmware's zero-filled bytes would read as *never*, which is a
legitimate value. The app only trusts `[6..7]` when `[8] == 1`.

In the app this shows up as three distinct states in **Settings → Keyboard LEDs off after**:

| Situation | Row shows |
|---|---|
| cable in | the value, picker enabled — reading and writing both work |
| 2.4 GHz only | the pushed value, picker disabled, *read over 2.4 GHz — connect USB to change* |
| firmware without the field | *connect USB to change* — no invented value |

Underneath the row the panel also points at the keyboard route: *"Wakey firmware: Fn+Y on the keyboard
also cycles this over 2.4 GHz."* That hint exists because the write path needs a cable and the read path
does not — the one thing a one-way link allows.

A temporary diagnostic build pushed an `0xA6` state report over 2.4 GHz; it has been removed from this
image (battery pushes are back to every 2 s).

The same value is readable and writable from the host over USB as raw-HID command `0xA5`: `0x01` get,
`0x02` set (seconds little-endian at `data[3..4]`).

### Where the value is stored — and a trap worth recording

It lives in QMK's **legacy 32-bit user value** (`eeconfig_read_user` / `eeconfig_update_user`): high
half is a magic tag `0x5741`, low half the seconds.

The first attempt used QMK's user *datablock* (`EECONFIG_USER_DATA_SIZE`). That silently corrupts the
keyboard: reserving bytes there **shifts every EEPROM offset after it**, so Keychron's custom-RGB and
wireless config regions are read from the wrong addresses. Measured symptom: the idle timeout stopped
working entirely — the firmware misread its own transport state and never considered the board idle.
The fixed user slot has no such side effect because it already exists in the layout.

### Why it tracked key presses itself

`last_input_activity_elapsed()` looks like the obvious idle clock, but Keychron's indicator code calls
`rgb_matrix_disable_time_reset()` — which resets that very timestamp — on wireless events. Measured
symptom: the board slept once, then never again after being woken, because it permanently looked
active. The patch therefore keeps its own `wakey_last_key_time`, updated from `process_record_user`,
so only real keystrokes defer the sleep.

Change `IDLE_LED_TIMEOUT_MS` in `keyboards/keychron/k5_max/k5_max.c` and rebuild to adjust.

## The suspend race — why the timer alone was not enough

Measured on hardware: with the timeout at 15 s and nothing touched, the `0xA6` diagnostics stopped at
`t+13 s` and **the LEDs stayed on**. The MCU had already gone to sleep, so the timer branch never ran.
Keychron's module suspends itself when the host goes quiet:

```c
static void wireless_enter_sleep(void) {      // wireless/wireless.c
    wireless_state = WT_SUSPEND;
    wireless_enter_sleep_kb();                // weak hook
}
```

There is a second sleep path, and it explains the "only works once" behaviour exactly: the generic
`lpm_enter_low_power()` stops SPI for the LED driver **before** it calls its own hooks, so anything done
after that point never reaches the LEDs — they simply freeze lit. The trap is that
`lpm_pre_enter_low_power()` (called just before) is the last moment the driver can be told anything.

Measured over the final runs, `sleepPath` (the wireless-suspend hook) never fired at all — every sleep
went through the generic path. So the patch:

- shuts the LED driver down in `lpm_pre_enter_low_power()` — a hardware "all off" that survives the SPI
  stop, and the mechanism that actually makes the second and subsequent cycles work
- also dims from `wireless_enter_sleep_kb()` (harmless, covers the other path on other boards)
- restores everything in `wireless_enter_connected_kb()` and on the next keypress, leaving the idle clock
  alone — resetting it there was a bug of its own, since that hook fires on every reconnect (which deliberately does not touch the idle clock — it fires on
every reconnect, and resetting the clock there postponed the timeout forever after the first wake),
so the saving no longer depends on winning a race against the scheduler.

Note this suspend is inherent, not something the patch introduced: the app's own log shows 69 gaps of
28–50 s in 3,208 keyboard readings from before any of this work. While the board is suspended it
reports nothing, so the keyboard's menu-bar reading goes stale — that is the cost of the sleep, and the
reason the reading can be older than the mouse's.

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
