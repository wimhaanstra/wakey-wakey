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
| **M5** LG TV control | ✅ built — volume, OLED light, panel/power, sleep/wake, optional media keys |
| **M6** macro keys | ✅ built — the four PlayStation keys and the mic key (F13–F17) send recorded shortcuts |
| **M7** key remapping | ✅ built — system-wide key-to-key remaps via `hidutil`, e.g. Caps Lock → Escape |

## Build and run

```bash
make app          # builds, signs, and refreshes /Applications/Wakey.app
make run          # builds/installs, then opens /Applications/Wakey.app
make selftest     # constructs the windows and also refreshes /Applications/Wakey.app
make clean
```

There is deliberately no compile-only target: every build replaces `/Applications/Wakey.app`, so the
installed copy can never be stale. `make app` calls `swiftc` directly: SwiftPM's build system writes
outside the workspace and fails in sandboxed environments, so `Package.swift` is kept only for opening
the folder in Xcode. It signs with an installed **Apple Development** identity when one is available,
which keeps the Accessibility grant (TV media keys and macro keys) across rebuilds; otherwise it falls
back to ad-hoc signing.

## Settings

Menu → **Settings…** (shown automatically on first launch). The window follows macOS System Settings:
a sidebar for **General**, **Menu Bar**, **Login**, **Receiver**, **Keyboard**, **TV** and
**Advanced**, and a detail pane of grouped cards. The search field filters the sidebar:

| Setting | Effect |
|---|---|
| **Automate while the mouse is on its charger** | blanks on dock, releases on pickup |
| **Keep this Mac awake while the displays are off** | holds sleep-preventing assertions so a clamshell Mac doesn't suspend and drop the USB receiver |
| **Start Wakey at login** | `SMAppService.mainApp`, falling back to a LaunchAgent if ServiceManagement refuses |
| **Show mouse battery** / **Show keyboard battery** | which devices appear in the menu bar and which menu rows exist; both off leaves a plain status icon so the menu stays reachable |
| **Blank the displays when this device charges** | the mouse on its dock (default) or the keyboard while charging |
| **Green charging badge** | colour badge vs a template image that always matches the menu bar tint |
| **Rescan** / slot picker | re-enumerates the Logitech receiver's six paired slots; the picker is enabled when more than one answers |
| **Control the TV over the network** | master switch for the LG TV section |
| **TV address / Detect / Connect** | SSDP discovery or a typed IPv4 address; Connect pairs and stores the key |
| **Turn the TV screen off when Wakey blanks the displays** | panel follows display sleep, and comes back on display wake |
| **Fully power off when the Mac sleeps (requires Wake on LAN)** | off by default; see the TV section below |
| **Mac volume and brightness keys control the TV** | opt-in; needs Accessibility |
| **Keyboard LEDs off after** | the Keychron's LED idle timeout — *Never / 15 / 30 / 60 / 90 s*. Read over 2.4 GHz from the battery push; **writing needs the cable** (`0xA5`), since the dongle cannot carry host → keyboard traffic |
| **Macro keys** | record a shortcut for each of the K5 Max's five macro keys (○ △ □ ✕ + mic, F13–F17), e.g. ⇧⌘M for Teams mute; clearing a row disables it |
| **Key remapping** | system-wide key-to-key remaps through macOS `hidutil` (Caps Lock → Escape, etc.); applies to every keyboard while Wakey runs, not media keys |

The **Advanced** pane also has *Blank now*, *Wake now*, and *Reveal log in Finder*.

### Macro keys

The four PlayStation keys at the top-right of the K5 Max emit **F13–F16**, and the microphone key
emits **F17** once the matching firmware image is flashed (stock firmware makes it send ⌘Space for
Siri). Open **Settings → Keyboard → Macro keys**, click a **Record Shortcut** button and press the
combination you want; that key afterwards sends the combination to the frontmost app. The rows show
the key's own symbol: ○ △ □ ✕ and a microphone. Teams mute is ⇧⌘M. Press Delete to clear a mapping,
Escape to cancel recording. With no mappings the key is left alone; with any mapping set, Wakey needs
the same Accessibility grant as the TV media keys.

### System key remapping

**Settings → Remapping** changes what a key sends using macOS's `hidutil` HID mapping. It applies to
every connected keyboard — including the built-in one — while Wakey is running, and is cleared when
Wakey quits. It needs no Accessibility or Input Monitoring permission.

1. Turn on **Remap keys for all keyboards**.
2. **Add Mapping**, click the source button and press the key to change (for example **Caps Lock**).
3. Click the target button and press what it should send (for example **Escape**).
4. Remove a row with the minus button.

This is key-to-key only: media keys and Fn are outside the HID keyboard page, and arbitrary
key→shortcut targets belong in **Macro keys** or Keychron Launcher. If another key remapper is using
macOS's `UserKeyMapping`, Wakey replaces it while enabled.

**Install to `/Applications` first** if you want login-at-startup to survive: the login item points at
the app bundle's current path, so an app left on an external volume will not come back after a reboot.

## Which device it listens to

The menu carries a `Receiver: …` line; **Settings → Receiver** shows the receiver, its slot and the
dock sensor, while **Settings → Keyboard** shows the battery and LED timeout:

```
Receiver:      USB Receiver (046d:c539)
Listening to:  slot 0x01, battery feature 0x06 (only slot answering)
Keyboard:      87% · 4.02 V · not charging
Sensor:        state=away 3.98 V discharging failures=0 flags seen: 0x00
```

**Rescan** re-enumerates all six receiver slots. If more than one slot answers, the **Device slot**
picker is enabled and the choice is remembered.

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
more than one answers **Settings → Receiver** shows a picker (automatic, or a specific slot).

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

## TV control (LG webOS)

The LG OLED on HDMI is reachable over the LAN, so Wakey drives it directly instead of relying on
HDMI-CEC (which Apple Silicon does not expose over its HDMI port).

| Action | How |
|---|---|
| Volume / mute | `ssap://audio/setVolume` and `setMute` |
| OLED light (the useful “brightness”) | `ssap://settings/getSystemSettings` to read; writes use the alert/luna bridge because webOS 24 answers `401` to `setSystemSettings` |
| Panel off / on | `com.webos.service.tvpower/power/turnOffScreen` / `turnOnScreen` |
| Full power off | `ssap://system/turnOff` |
| Power on | Wake-on-LAN magic packets to both the Wi-Fi and the wired MAC (verified over Ethernet) |
| Sleep / wake | `screensDidSleep`/`screensDidWake` plus `NSWorkspace.willSleep`/`didWake` |

Setup: menu → **Settings…** → TV → **Detect** opens a scanner window (SSDP) that lists every LG TV
it finds and floats above other windows; pick one and **Connect**, or type an address there. The TV shows
a pairing prompt once; the client key and the TV's self-signed certificate fingerprint are pinned in
`~/Library/Application Support/Wakey/tv.json` (mode `0600`). macOS asks for Local Network access the
first time. Port 3000 resets on this firmware; the control socket is `wss://<ip>:3001`.

**Sleep defaults to panel-off, not full standby.** The panel goes dark with the displays, the TV
stays on the network, and it is back about a second after the Mac wakes. Full power-off is the
*“Fully power off when the Mac sleeps”* toggle, and only works when the TV has **Mobile TV On →
Turn on via Wi-Fi** (or **Support → IP Control Settings → Wake on LAN** on newer firmware) enabled.
Over Ethernet that path is verified: `turnOff`, 15 s later the magic packet, panel back on. Over
Wi-Fi the access point also has to forward the magic packet, which is why panel-off stays the default.

Wakey only touches the TV while it is showing this Mac's HDMI input, so someone watching broadcast TV
on another input is left alone. Blanking puts the panel in `Screen Off`; the first mouse or keyboard
input wakes macOS and the panel comes back with it — that is the wake path, not a failed blank.

**Keyboard:** *“Mac volume and brightness keys control the TV”* is opt-in and needs Accessibility.
Volume keys act only while the LG is the current audio output; brightness keys only while it is the
main display. Everything else stays menu/Settings-only. The TV pane's **Permissions** card shows
whether Accessibility is currently granted and opens the pane directly. `make app` prefers an Apple
Development identity so the grant survives rebuilds; if you only have ad-hoc signing, run
`tccutil reset Accessibility nl.sortedbits.wakey` and flip the toggle again after each rebuild,
otherwise macOS keeps matching an older binary and `AXIsProcessTrusted()` stays false.

Volume, mute and brightness are also in the menu bar's **TV** submenu. The panel's OLED light is what
the UI calls brightness; the TV's own *brightness* control is black level and is deliberately untouched.

### The other LG monitor (31.5″ 4K on HDMI)

That panel has no webOS and no network API; the only control path is DDC/CI. Wakey uses the optional
[`m1ddc`](https://github.com/waydabber/m1ddc) (`brew install m1ddc`) for VCP `0x10` luminance.
Writes are dependable — verified `64 → 40 → 64` — while reads over the built-in HDMI are noisy
(about half return `0` or `0x1000`), so the app retries and caches the last good value.

When `m1ddc` and the display are present, the menu grows a **Monitor** section with Brighter/Dimmer.
Brightness keys follow the **pointer**: put the mouse on the 4K and plain brightness up/down adjusts
its DDC luminance; put it on the TV and the same keys adjust the TV's OLED light. Put it on the
built-in display and macOS handles that key itself. No chord, no menu, no Input Monitoring.

Each key press also shows a small non-activating HUD at the bottom of the pointer's screen: the
target name, a percentage, and a slider you can grab to fine-tune. It follows the live value while
dragging and fades after 2.5 s (or stays while the pointer is over it). Volume,
input and power are not exposed reliably by this panel, and macOS already handles its display sleep. If `m1ddc` is missing the Monitor section stays hidden and the TV half is unaffected.

The audio transports report the 4K on **HDMI** and the TV on a **DisplayPort/alt-mode** path (likely
a USB-C→HDMI adapter). For the TV's 4K144, CEC and link training, the Mac's built-in HDMI is the
better port if you can swap the two displays.

### Why the TV can be slow to wake

macOS 14.4+ on Apple Silicon drives HDMI-CEC. Its WindowServer log shows
`CoreRCPlugin: Putting TV to standby` whenever the displays sleep, and LG's *Auto Power Sync* obeys:
the set does a cold boot instead of a panel wake, then retrains the 4K120 link. The DisplayPort
monitor has no CEC and resumes immediately. That is why the TV lagged before Wakey existed.

Fix it in this order:

1. **TV:** Settings → General → Devices → HDMI Settings → **Auto Power Sync = Off**
   (or **Simplink (HDMI-CEC) = Off** if Auto Power Sync is not listed).
   **macOS:** System Settings → Displays → select the LG → disable **HDMI-CEC**.
2. **Wakey:** leave *“Fully power off when the Mac sleeps”* **off**. Panel-off keeps the HDMI sink
   and the TV's network stack alive, so the next wake is a `turnOnScreen`, not a boot.
3. **TV:** Quick Start+ = On, firmware current.
4. If it is still slow, switch the Mac to 4K60 for a test. If the picture then appears quickly, the
   remaining delay is HDMI 2.1 link training rather than TV boot time.

Timings to compare: the app log's `system: did wake` → `TV: screen on` → `TV: awake`, the
WindowServer `Display 3 set to previous mode`, and `pmset -g log`'s `Display is turned on`.

## Find cursor

Double-tap **Control** and Wakey pulses a “find my cursor” overlay around the pointer: it dims the
screen outside a soft radius, draws three expanding rings, and puts a frosted lens over the content
below. It is a non-activating, click-through window at screen-saver level, so it never steals focus
or a click, and it disappears after about a second.

The double-tap is detected by polling `CGEventSource.flagsState` at 30 Hz — no Input Monitoring
needed. The lens is an `NSVisualEffectView`, so it blurs rather than refracts; true displacement
would require Screen Recording, which Wakey does not ask for. Toggle it, or fire it manually, from
the **Find cursor** / **Double-tap Control to find cursor** menu items.

## Verifying by hand

```bash
make status                                     # is the display asleep?
./Wakey.app/Contents/MacOS/Wakey --sensor 30    # watch dock detection for 30 s
pmset -g assertions | grep -i wakey             # held assertions while blanked

./Wakey.app/Contents/MacOS/Wakey --tv-status            # model, power, volume, OLED light, input
./Wakey.app/Contents/MacOS/Wakey --tv-volume 20
./Wakey.app/Contents/MacOS/Wakey --tv-backlight 60
./Wakey.app/Contents/MacOS/Wakey --tv-screen off        # panel only
./Wakey.app/Contents/MacOS/Wakey --tv-power off         # standby; needs Wake on LAN to come back
./Wakey.app/Contents/MacOS/Wakey --tv-detect            # SSDP scan
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

So the repo carries a firmware patch — [`firmware/patches/k5max-wakey.patch`](firmware/patches/k5max-wakey.patch),
323 insertions, 4 deletions over 7 files — that adds the battery push and remaps the microphone key
from Siri (`⌘Space`) to **F17**:

| Byte | Meaning |
|---|---|
| `[0]` | `0xA4` |
| `[1]` | battery percentage |
| `[2..3]` | voltage, mV little-endian |
| `[4]` | 0 not charging · 1 charging · 2 full |
| `[5]` | transport: `0x01` USB · `0x02` Bluetooth · `0x04` 2.4 GHz |
| `[6..7]` | LED idle timeout in seconds, little-endian (`0` = never) |
| `[8]` | `1` when `[6..7]` is meaningful |

Two transports, two directions, because the dongle only bridges traffic *from* the keyboard:

- **2.4 GHz** — the keyboard *pushes* the report every ~2 s; Wakey only listens.
- **USB** — the host *pulls* by writing `0xA4`, which Wakey does every 5 s on any raw-HID interface
  that is not the dongle (PID `0xd030`). Same report comes back, so the parser is shared.

Both directions need the patched firmware. Stock Keychron firmware answers only `0xA0`–`0xA3` and
`0xA7`–`0xAB`, and exposes no battery value through VIA either — so plugging the cable in does **not**
produce a percentage on its own. Wakey detects that case: a wired keyboard that ignores `0xA4` for
~30 s produces one log line saying battery reporting needs the firmware, rather than an unexplained
`no data`.

That matters in practice: plugging the cable in stops the dongle's pushes, and without the pull the
reading would go stale within 30 s. The menu line now also names the link — `82% · 3.9 V · charging ·
USB` versus `· 2.4G` — so it's obvious which path is live.

With that firmware flashed, the menu shows `Keyboard: 87% · 4.02 V · not charging` and the Settings
panel repeats it. On stock firmware it shows `Keyboard: no data`.

### The LED idle timeout

108 RGB LEDs are by far the largest load on a wireless board, so the firmware turns the matrix off
after a period without a keypress and restores it on the next one. Keychron's wireless builds cannot do
this themselves: `wireless.mk` pins `RGB_MATRIX_TIMEOUT` to `RGB_MATRIX_TIMEOUT_INFINITE`, and the
indicator code re-arms it to infinite on every connect.

The timeout is stored in the keyboard's **EEPROM**, is adjustable from `Never` to 90 s, and applies on
every transport:

| Way to set it | Works on | Notes |
|---|---|---|
| **Fn+Y** on the keyboard | 2.4 GHz, Bluetooth, USB | steps 90 → 60 → 30 → 15 s; the value's digits light green on the number row while the rest of the board dims. It is **Y**, not T — `Fn+T` is already RGB speed-up |
| **Settings → Keyboard → LEDs off after** | USB only | writes raw-HID `0xA5`; the same command reads it back |
| Battery push | 2.4 GHz, Bluetooth | bytes `[6..8]`, so the app can *show* the value from anywhere |

That last row is the important asymmetry: **reading works everywhere, writing needs the cable.** A
request cannot cross the dongle, but the answer can ride along with a report the keyboard already
sends. When the keyboard is on 2.4 GHz the **Settings → Keyboard** picker is disabled and says so, rather than
pretending it can be changed from there.

Implementation detail worth knowing if you touch the patch: the reliable trigger is *not* an idle timer.
The board suspends itself, and `lpm_enter_low_power()` stops SPI for the LED driver **before** running
its own hooks — so anything done after that point never reaches the LEDs and they simply freeze lit.
The patch therefore shuts the driver down in `lpm_pre_enter_low_power()`, the last moment that bus is
alive, and restores on reconnect or the next keypress.

Building, flashing and rollback are covered in [firmware/FLASHING.md](firmware/FLASHING.md); the stock
image is kept alongside the patched one for a one-command revert.

## Credits

The keyboard half of this project exists because of
**[k10he-battery-firmware](https://github.com/OutersGIT/k10he-battery-firmware)** by OutersGIT
(GPLv2): the `0xA4` command, the payload layout and the push-over-2.4-GHz model are all its design,
ported here to the K5 Max. The firmware we patch is
[Keychron's QMK tree](https://github.com/Keychron/qmk_firmware) (GPLv2), and the mouse percentage uses
the voltage curve from the Linux kernel's `hid-logitech-hidpp.c`.

The TV half leans on the webOS reverse-engineering community: **[openRemote](https://github.com/Harshsanket/open-remote)**
for the Swift wss/pairing shape, **[bscpylgtv](https://github.com/chros73/bscpylgtv)** for the
alert/luna picture-setting bridge and the screen-off endpoints, and
**[lgtv2](https://github.com/hobbyquaker/lgtv2)** for the permission manifest and the LG certificate
notes. Full attribution: **[CREDITS.md](CREDITS.md)**.
Firmware-specific notice: [firmware/NOTICE.md](firmware/NOTICE.md).

## Notes

- **G HUB** polls the same receiver using HID++ client id 0. Wakey ignores those reports entirely and
  never acts on an error, so both can run side by side.
- The mouse goes quiet on its own; silence is treated as "no news", never as "picked up".
- Nothing here is sandboxed and nothing needs a privileged helper.
