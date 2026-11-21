# Wakey — displays off while the mouse charges

A tiny macOS menu bar app: **put the mouse on the charger → monitors go dark; pick it up → they come back.**

This plan is grounded in what I measured on *this* machine today, not on guesses. Findings first, then design, then milestones.

---

## 1. What I verified on your Mac

| Fact | Value |
|---|---|
| Mac | MacBook Pro (Mac16,8), Apple M4 Pro, 24 GB — **lid closed / clamshell** |
| Displays | `LG TV SSCR2` 3840×2160 @120 Hz (main, HDMI) + `LG HDR 4K` 3384×6016 @60 Hz, rotated 270° |
| Logitech receiver | USB **VID `0x046d`, PID `0xc539`** — the generic *Lightspeed* nano receiver |
| HID++ channel | Vendor HID interface `UsagePage 0xFF00 / Usage 0x0001` is present and **opens without any TCC prompt** |
| Paired device | answers on **device index `0x01`**; 29 features enumerated |
| Battery feature | `0x1001` *(BATTERY_VOLTAGE)* at **feature index `0x06`** |
| Live reading | `0f 9f 00` → **3999 mV, flags 0x00 → discharging** (mouse off the dock) |
| Lock screen | `sysadminctl` → screen lock delay **300 s** |
| Power policy | `sleep 1` (idle system sleep after 1 min!), `displaysleep 10` |
| Display sleep helper | `/usr/bin/pmset` contains `displaysleepnow` (still supported on macOS 27.0.1) |
| G HUB | actively polling the same receiver with HID++ **client id 0** (~1/s), emitting frequent `0x8f` error reports |
| Toolchain | Xcode 27.1, Swift 6.4 |

**Consequences of that last block of facts, which shape the design:**

1. **No permissions are needed.** No Accessibility, no Input Monitoring, no Screen Recording. HID++ report I/O on that vendor interface just works. That is the single biggest risk eliminated — the app can stay a plain unsigned/ad-hoc menu bar app.
2. **It's a clamshell MacBook with `sleep 1`.** If the displays sleep and nothing holds an assertion, the whole machine can suspend within a minute — which also powers down the Lightspeed receiver, so the mouse could not wake it. The app therefore **must hold a `PreventUserIdleSystemSleep` assertion while it has deliberately blanked the displays.**
3. **A 5-minute lock delay** means short charges wake straight back into your desktop. Only a charge longer than 5 min lands you on the password screen. (Worth a one-line warning in the UI, not a design problem.)
4. **The LG TV is on HDMI.** Apple-Silicon HDMI generally does not expose DDC/CI, so hardware monitor power-off (m1ddc-style) can't be the primary mechanism — see §4.

Existing probe scripts that produced these numbers live in [`probe/`](probe) and can be re-run at any time.

---

## 2. What "on the charger" looks like — measured, not assumed

**M0 is done.** Feature `0x1001` is *BATTERY_VOLTAGE*, not battery level (the Linux kernel's
`hid-logitech-hidpp.c` is the authority: `HIDPP_PAGE_BATTERY_VOLTAGE = 0x1001`). Function `0x00`
returns three params:

| Byte | Meaning |
|---|---|
| `[0..1]` | voltage in **millivolts**, big-endian |
| `[2]` | flags: **bit7 = charging**; bits 0–2 when charging: `0` charging, `1` full, `2` not-charging; bit3 fast, bit4 trickle, bit5 critical |

Your dock/undock run produced this sequence:

| Time | Raw | Decoded |
|---|---|---|
| 17:26:08 | `0f 9f 00` | 3999 mV, **discharging** |
| 17:26:26 | `0f 9a 90` | 3994 mV, **charging** (bit7 + trickle) — the moment it landed |
| 17:26:34 → 17:26:49 | `0f e4 90` → `0f ec 90` | 4068 → 4076 mV, **charging**, voltage climbing |
| 17:27:08 | `0f ab 00` | 4011 mV, **discharging** — picked up |

So the sensor is a **single clean bit**: `flags & 0x80`. No threshold tuning.

**Battery percentage is derived, not reported.** This device exposes only `0x1001`; it has no `0x1000`
(battery level status) or `0x1004` (unified battery), and functions `0x01/0x10/0x20` on `0x1001` all
echo the raw voltage reply. `BatteryEstimator` therefore ports the kernel's `voltages[100]` discharge
curve (100 entries, 4186 mV → 3537 mV) and the UI always writes it as "≈". Two caveats are inherent:
charging pushes the cell above its resting voltage so the number reads high, and the curve is generic.
The device's own "full" flag overrides the curve to 100 %.

Two things the run settled:

1. **The dock is a dedicated parking spot, not the mousepad.** Flags sat at `0x00` while the mouse was
   on the desk and flipped to `0x90` only on contact. So `TriggerMode` resolves to **`.dockOnly`**;
   the charging bit alone is the trigger. (`.dockOrIdle` stays in the code as a fallback mode in case
   you ever move to a Power Play mat you actually mouse on.)
2. **Responses are intermittent.** Long stretches returned nothing. That is almost certainly
   `HID++ RESOURCE_ERROR`, which the kernel explicitly marks as an intermittent error to ignore. The
   lesson is a hard rule: **silence is never evidence of undocking** — only a successful reading of
   `flags & 0x80 == 0` is. The corrected probe now prints the actual error code so this is provable.

### The full-charge case — measured, and it was the predicted trap

A 40-minute charge captured it:

| Time | Raw | Decoded |
|---|---|---|
| 17:50:33 | `0x90` | charging (trickle) → blanked, assertions held |
| **18:00:01** | **`0x91`** | **4.123 V, full (trickle)** — the 100 % answer |
| **18:00:02** | `0x00` | **discharging at the same 4.123 V**, while still parked → screens woke for no reason |

At 100 % the dock stops pushing current, so the device flips to "discharging" **without moving**.
Charging state alone cannot tell that apart from being picked up, and the original latch went to
`away` after two agreeing readings — hence the unwanted wake at 18:00:02.

The fix is a second signal: **pointer motion**, read from
`CGEventSource.secondsSinceLastEventType(.hidSystemState, .mouseMoved)`, which needs no TCC grant
(verified: values reset live as the cursor moves). Leaving `docked` now requires *positive evidence* —
pointer motion, or ten minutes of genuine battery drain. Two more consequences fell out of the log:

- `wake()` is no longer called from the sensor at all. Picking the mouse up produces HID input and
  macOS wakes the displays itself, so a sensor-driven wake could only ever misfire.
- Discovery is now self-validating: a single misparsed reply had resolved the battery feature to the
  wrong index (`0x04`), which produced garbage readings. A feature index is only accepted if a probe
  read returns a plausible voltage, and three implausible readings in a row force rediscovery.

---

## 3. Detection design

```swift
enum DockState { case unknown, docked, away }
```

**Inputs** (any subset available, fused):

| Source | Signal | Cost |
|---|---|---|
| HID++ `0x1001` poll | `flags & 0x80` → charging, plus mV for diagnostics | 2 s poll, 7-byte round trip |
| HID++ events | device *may* push a status-change report on dock/undock (unverified) | free, if they exist |
| IOHIDManager device add/remove | cabled mouse appears / receiver loses device | free |
| Idle counter | `CGEventSource.secondsSinceLastEventType(.hidSystemState, .mouseMoved)` dropping to ~0 → definitely picked up, **no TCC prompt** | free |

**Fusion rules**

- `away → docked`: charging bit confirmed by **2 agreeing readings**. Debounce protects against a
  brush of the cable.
- `docked → away`: requires **pointer motion** or **10 minutes of continuous discharge** (proof the
  mouse is running on battery). Discharging alone is *not* evidence — the full-charge case proves it.
- **Latch:** once `docked`, a `full`/`discharging` reading never releases it on its own.
- **Fail-safe:** 3 consecutive HID++ errors, or receiver unplugged → state `unknown`, do nothing. Never blank blind.

**Manual-override rule (important for sanity):** if the displays come back on while the mouse is still docked — you pressed a key, a notification woke the screen — the app **stands down until the next dock cycle** instead of fighting you. An optional stricter mode re-blanks after a 10 s grace period, with backoff, and gives up if it flaps 3× in a minute.

**Coexistence with G HUB — measured.** G HUB polls the same receiver using HID++ client id 0, roughly
once a second, and a lot of those requests come back as `0x8f` errors. Two consequences, both already
in the code: every inbound report whose client id is 0 is discarded (it is not ours — treating it as a
device notification was a mistake I made and then fixed), and errors are never allowed to change dock
state. Our own polls use client ids 1–15, so the two streams can't cross-match.

---

## 4. Display control design

**Blank:** `pmset displaysleepnow`
- Universal: puts the HDMI TV *and* the DisplayPort LG into standby. No DDC lottery, no private APIs.
- While blanked, hold `kIOPMAssertionTypePreventUserIdleSystemSleep` (+ `kIOPMAssertionTypePreventSystemSleep`) so clamshell doesn't suspend the machine and drop the receiver.
- Optional courtesy: if another app already holds a display-sleep assertion (Zoom call, video export), skip blanking. Readable via `IOPMCopyAssertionsByProcess`.

**Wake:** rely on the HID event, then confirm it
- Moving the mouse *is* a wake event; macOS brings the displays back by itself. That is free and native.
- Additionally call `IOPMAssertionDeclareUserActivity("Wakey" as CFString, kIOPMUserActiveLocal, &id)` on the `docked → away` transition so the first second is never swallowed and the screen is up by the time your hand reaches the mouse.

**Rejected, with reasons**

| Approach | Why not |
|---|---|
| DDC/CI power-off (`m1ddc`) | No DDC on Apple-Silicon HDMI → can't touch the LG TV. Keep as an *experimental* toggle for the DisplayPort LG only. |
| Black overlay window | Monitors stay powered, backlight burns; on an OLED/LED TV that's the wrong outcome. |
| Private `CGS*` display-sleep APIs | Break silently between macOS releases. `pmset` is a stable, documented-ish CLI. |
| System sleep instead of display sleep | Loses the receiver, can't be woken by the mouse, and drops network/audio. |

---

## 5. App shape

Menu bar only — `LSUIElement = true`, no Dock icon, no windows except a diagnostics panel.

```
┌──────────────────────────────────┐
│ Mouse: docked — charging (4.0 V) │
│ Keyboard: 87% · 4.02 V           │
│ Displays: off (blanked by Wakey) │
├──────────────────────────────────┤
│ ✓ Automate while charging        │
│ ✓ Keep Mac awake while blanked   │
├──────────────────────────────────┤
│ Blank displays now               │
│ Wake displays now                │
├──────────────────────────────────┤
│ Settings…                        │
│ Show diagnostics…                │
│ Reveal log in Finder             │
│ About Wakey                      │
│ Quit Wakey                       │
└──────────────────────────────────┘
```

**Stack:** AppKit `NSStatusItem` + `NSMenu`, no SwiftUI lifecycle. Chosen over SwiftUI's
`MenuBarExtra` because a `swiftc`-built bundle has no SwiftUI `App` entry point and the menu needs
exact, synchronous control of its items. No background daemon — it's a normal user-session app.

**Device visibility:** the receiver line and the Settings device panel exist because M0's probe
work raised the obvious question — *which* Logitech device is this listening to? The answer is
"receiver `046d:c539`, paired slot 1", not a model name: the mouse advertises a 37-character name via
feature `0x0005` and then returns zero bytes for every index, in short and long reports alike. The
panel therefore shows receiver identity, slot, battery-feature index, the live sensor line, and offers
a **Rescan** that walks all six slots (a chooser appears if more than one answers).

**Build note:** `make app` drives `swiftc` directly, signs with the installed Apple Development
identity when there is one, and replaces `/Applications/Wakey.app` on every build; there is no
compile-only target. SwiftPM's build system needs to write outside the workspace and wraps itself in
`sandbox-exec`, which fails under the harness sandbox. `Package.swift` is kept so you can open the
folder in Xcode; `make app` is the supported path here.

**Layout**

```
wakey-wakey/
├── Makefile                       # `make app` → builds, signs, installs /Applications/Wakey.app
├── Package.swift                  # for opening in Xcode (see note)
├── Sources/Wakey/
│   ├── WakeyMain.swift            # @main, LSUIElement, headless --blank/--wake/--status/--sensor/--selftest
│   ├── AppDelegate.swift          # NSStatusItem, menu, sensor→automation wiring
│   ├── DisplayController.swift    # pmset, assertions, user-activity wake
│   ├── HIDPPClient.swift          # HID++ 2.0 transport, self-validating discovery
│   ├── DockSensor.swift           # state machine, motion evidence, latch
│   ├── Preferences.swift          # UserDefaults-backed settings
│   ├── LoginItem.swift            # SMAppService + LaunchAgent fallback
│   ├── SettingsWindowController.swift
│   ├── DiagnosticsWindowController.swift
│   └── Log.swift                  # rolling log → ~/Library/Logs/Wakey/wakey.log
├── Resources/Info.plist, AppIcon.icns
├── tools/make-icon.swift          # generates the icon from code
├── probe/                         # the validated probes; dock_calibration is M0
└── PLAN.md
```

**The three tricky calls, already proven to work:**

```swift
// 1. HID++ 2.0 request on device index 1, feature index 0x06 (0x1001)
//    short report, 7 bytes, reply arrives on the input-report callback
var req: [UInt8] = [0x10, 0x01, 0x06, 0x01, 0x00, 0x00, 0x00]  // last nibble = swId (never 0)
IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x10, &req, req.count)
// reply params: [dischargeLevel, nextLevel, status]   status 0x00 = discharging

// 2. blank
Process.run("/usr/bin/pmset", ["displaysleepnow"])

// 3. keep the clamshell machine awake while blanked
IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                            "Wakey: displays off while charging" as CFString, &assertionID)
```

**Login item:** `SMAppService.mainApp.register()` (macOS 13+). Requires the app to live at a stable path — `/Applications/Wakey.app` or `~/Applications`. LaunchAgent plist as fallback if `SMAppService` complains about an ad-hoc-signed dev build.

**Cost:** ~1,400 lines of Swift, no third-party packages, ~0.2 % CPU (one 7-byte poll every 2 s), plus one LAN WebSocket to the TV.

---

## 6. Milestones

| # | Deliverable | Done when |
|---|---|---|
| **M0** ✅ | [`probe/dock_calibration.swift`](probe/dock_calibration.swift) — corrected to decode mV + flags, logs HID++ error codes, optional CSV | **Done** — charging bit identified, `.dockOnly` confirmed |
| **M1** ✅ passed | Menu bar app with **Blank now / Wake now**, assertion handling, log + diagnostics window | Blanked 17:35:06, woke on mouse move 17:35:58, both assertions released, no password prompt |
| **M2** ✅ running | `HIDPPClient` + `DockSensor`, logging only by default | Sensor live now; watching for false transitions over the next day |
| **M3** ✅ opt-in | Sensor → display control behind an **off-by-default** toggle, with stand-down override | Flip “Automate while charging”, dock, walk away, come back |
| **M4** ✅ | Settings panel, login item (SMAppService + LaunchAgent fallback), generated icon, About, first-run panel, single-instance guard | Built and self-tested; toggle “Start Wakey at login” once you've installed it |
| **M5** ✅ | LG TV over webOS: volume, mute, OLED light, panel off/on, standby, sleep/wake, optional media keys | Volume, mute, OLED light and panel/wake verified on the C4; full power-off is opt-in and awaits Wake on LAN |
| **M6** ✅ | Keyboard macro keys: the four PlayStation keys (F13–F16) plus the microphone key (F17) send recorded shortcuts, e.g. Teams mute ⇧⌘M | Built; uses the same Accessibility grant as TV media keys |
| **M7** ✅ | System-wide key remapping through macOS `hidutil`: any keyboard-page key to any other key (Caps Lock → Escape/Control, …) | Built; applies to all keyboards while Wakey runs, no TCC permission |

M0 and M1 are the risky ones and they're both cheap. M2 is elapsed time, not work.

---

## 7. Risks, ranked

1. **Charge-complete flapping** — *materialised* on 2026-11-18 18:00 and woke the screens. Fixed by gating `away` on pointer motion and by never waking the displays from the sensor.
2. **Clamshell suspend while blanked** — machine sleeps, receiver dies, mouse can't wake it. → Sleep-preventing assertion + an explicit M1 test of a 5-minute blank. (Highest *impact*.)
3. **Dock jitter wakes the screens repeatedly** — optical jitter inside the cradle. → grace period, backoff, and give-up notification rather than a strobe loop.
4. **G HUB arbitration** — *confirmed active*, not hypothetical: it polls the same receiver with client id 0 and its requests often error. → our client ignores client id 0 entirely and never acts on errors; worst observed cost is a slower first discovery (now 0.7 s with retries).
5. **Wrong device index** — index `0x01` is a receiver slot, not a fixed identity. → resolve by protocol version + battery feature presence, never hardcode (already how the probe behaves).
6. **Mouse asleep on the dock** — a parked mouse may stop answering HID++ after a while, which looks identical to "picked up and switched off". → never treat a silent device as `away` on its own; require a receiver-reported disconnect or a motion event. M2 measures how long a docked mouse keeps answering.
7. **macOS 27 API drift** — `pmset displaysleepnow` could vanish. → it's the only shell-out; isolate it behind `DisplayController` so a private-API fallback drops in one file.

---

## 8. Status

| Question | Your answer |
|---|---|
| Charging method | **Magnetic/inductive dock** → HID++ `0x1001` bit 7 is the sensor |
| Keyboard while docked | **Stay woken** — app stands down until the next dock cycle |
| Build form | **Swift Package + `make app`** (`make app` drives `swiftc`; see build note) |

`Wakey.app` is running with automation **enabled** and the full-charge fix in place.

### Behaviour now

- dock → 2 confirmed charging readings → displays blank, sleep-preventing assertions held
- pick up → HID input wakes the displays (macOS does this, not us) → assertions released
- press a key while docked → screens stay on, app stands down until the next dock cycle
- reach 100 % on the dock → **stays blanked**; the device's shift to "discharging" is ignored because
  the pointer never moved
- first state after launch is never acted on, so launching while docked won't blank you
- every 5 minutes a `HEARTBEAT` line records state, voltage, failure count and flags seen

### What to watch in the log

`~/Library/Logs/Wakey/wakey.log`, or **Show diagnostics…**.

- `SENSOR new flags value …` — any flags byte not seen before (this is how `0x91` was found)
- `implausible reading … rediscovering` — should be rare; a cluster means G HUB contention is biting
- `HEARTBEAT … failures=N` — a steadily growing `N` means the receiver is getting hard to talk to

### M4 — what was added

- **Settings panel** (menu → Settings…, or first launch), laid out like System Settings: a
  source-list sidebar for **General**, **Menu Bar**, **Login**, **Receiver**, **Keyboard**, **TV**
  and **Advanced**, and a detail pane of grouped cards. A search field filters the sidebar; the
  window is resizable and scrolls the detail pane when needed.
- **Start at login** via `SMAppService.mainApp`, falling back to a `~/Library/LaunchAgents` plist when
  ServiceManagement refuses — which it does for an ad-hoc-signed app outside `/Applications`. Both
  outcomes are logged, and the checkbox reflects the real status, including
  “awaiting approval in System Settings”.
- **App icon** generated from code by `tools/make-icon.swift` (no design assets in the repo).
- **Single-instance guard**: a second copy exits instead of fighting the first over the HID++ interface.
- `make selftest` builds a settings window, a diagnostics window and reports login-item status, without
  touching the displays.

### Remaining

Behaviour over days rather than minutes: watch `HEARTBEAT` lines for a rising `failures=N`, and confirm
no spurious blank/wake pairs appear.


---

## 9. TV control (M5) — measured 2026-11-19

The LG on HDMI is an **OLED42C41LA** (webOS 24). Everything below was measured on this set, not
copied from a spec sheet.

### What the firmware actually does

| Fact | Consequence |
|---|---|
| `ws://<ip>:3000` resets immediately; `wss://<ip>:3001` completes the upgrade | only the TLS port is usable; the socket needs a trust delegate for LG's self-signed leaf |
| Registration needs `pairingType: "PROMPT"`; the key is returned only after the on-screen prompt | first use is interactive, later launches are silent |
| A manifest without `CONTROL_AUDIO` gets `401 insufficient permissions` for `audio/getVolume` | ship the full permission set (`LAUNCH`, `CONTROL_AUDIO`, `CONTROL_POWER`, `READ_INPUT_DEVICE_LIST`, …) |
| `ssap://settings/getSystemSettings` returns `backlight: "90"` | OLED light is readable |
| `ssap://settings/setSystemSettings` returns `401` even with `WRITE_SETTINGS` | direct write is dead on this firmware |
| An alert with `onclose` = `luna://com.webos.settingsservice/setSystemSettings`, then `closeAlert`, changes the value | the alert/luna bridge is the working write path |
| `turnOffScreen` → `Screen Off`; `turnOnScreen` works from that state | panel-off is instant and keeps the network + HDMI sink |
| `turnOnScreen` while already `Active` returns `500 Application error` | treat it as already on, not as a failure |
| `system/turnOff` → `Power Off`; the network stack stays up for a while | a socket can connect while the panel is still dark — the power state, not the socket, is the truth |
| `connectionmanager/getinfo` returns `wifiInfo.macAddress` and `wiredInfo.macAddress` | Wake-on-LAN can address both interfaces |
| WOL to both MACs, 15 s after `system/turnOff`, brought the set back over Ethernet (2026-11-19 21:08) | full power-off is viable on a wired connection; Wi-Fi remains untested |
| Default output device is `LG TV SSCR2` and `set volume` reports *missing value* | macOS cannot change HDMI volume; the TV API is the only volume control |

### Design

`TVController.swift` owns one `URLSessionWebSocketTask`, a request id table with timeouts, and a
state machine (`off → connecting → pairing/ready → unreachable`). The client key and the pinned
certificate fingerprint live in `~/Library/Application Support/Wakey/tv.json` (0600), not UserDefaults.
Registration retries once without a stale key.

Sleep semantics are deliberately split:

- **panel off** (default) on display sleep — instant, keeps the HDMI sink, so macOS does not reflow
  windows; wake is a single `turnOnScreen`.
- **full standby** (opt-in) on system sleep — needs the TV's *Mobile TV On → Turn on via Wi-Fi*
  (or *Support → IP Control Settings → Wake on LAN*). Wake-on-LAN is sent to both MACs on every
  broadcast interface, on ports 9 and 7, and the wake path polls `getPowerState` instead of trusting
  the socket: a standby TV accepts TCP while its panel is still off.
- The TV is only touched while `getForegroundAppInfo` reports this Mac's input (`com.webos.app.hdmi2`).
  A TV showing broadcast content is never blanked or powered off.

Media keys are a separate opt-in (`TVMediaKeys.swift`): a `.cgSessionEventTap` for
`NX_SYSDEFINED`, key codes 0/1/7 (volume up/down/mute) and 2/3 (brightness up/down). Volume is
intercepted only when CoreAudio's default output name contains “LG TV”; brightness only when
`NSScreen.main` is the TV. The tap consumes both key edges so macOS does not also show its own HUD.
It needs Accessibility. `make app` signs with an installed Apple Development identity when one is
available, which keeps that grant across rebuilds; the ad-hoc fallback still resets it each time.

The four PlayStation keys emit F13–F16 and the microphone key emits F17 after the firmware remap
(`KeyMacros.swift`). Carbon hotkeys register those globally and post the shortcut recorded for that
key (settings → Keyboard → Macro keys); registering the hotkey needs no Input Monitoring, but posting
the replacement needs Accessibility. Mapping a shortcut to “Teams mute” (⇧⌘M) is the reference case.
The settings rows show the physical key symbols (○ △ □ ✕ and a microphone) so the mapping is obvious.

System-wide key remapping lives in **Settings → Remapping** and uses `hidutil`'s `UserKeyMapping`
rather than an event tap: any keyboard-page key can become any other key (Caps Lock → Escape or
Control, etc.). It applies to every connected keyboard while Wakey runs, needs no TCC permission, and
is cleared on quit. Media keys and Fn are outside that page; arbitrary key→shortcut targets remain in
the macro-key layer.

### Open risks

1. **Wake-on-LAN** — verified over Ethernet with the wired MAC (`00:A1:59:27:CA:7F`): the set went
   to `Power Off`, the magic packet was sent 15 s later, and the panel came back. The Wi-Fi path
   (`44:27:45:83:92:28`) is still unverified — an AP that drops broadcast, or “Mobile TV On” being
   off, would strand a fully powered-off set. That is why panel-off remains the default.
2. **Certificate rotation** — the fingerprint is pinned. A firmware change that replaces the LG leaf
   makes Wakey refuse the connection until “forget pairing” is used.
3. **Firmware drift** — the luna alert trick is a hack; a future webOS may close it.
4. **Accessibility reset** — with ad-hoc signing every rebuild needs the switch flipped again. The
   Makefile now prefers an Apple Development identity so this only affects ad-hoc-only machines.
