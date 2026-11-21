import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let displays = DisplayController()
    private let hidpp = HIDPPClient()
    private let sensor = DockSensor()
    private let keyboard = KeychronBattery()
    private let keyboardTrigger = KeyboardTrigger()
    private var resolvedKeyboardInitial = false
    private var diagnostics: DiagnosticsWindowController?
    private var settings: SettingsWindowController?
    private var scanner: TVScannerWindowController?
    private var heartbeat: Timer?

    private let receiverMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mouseMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keyboardMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let displayMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let automationItem = NSMenuItem(title: "Automate while charging", action: nil, keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "Keep Mac awake while blanked", action: nil, keyEquivalent: "")

    private let tv = TVController()
    private let mediaKeys = TVMediaKeys()
    private let monitor = MonitorBrightness()
    private let brightnessHUD = BrightnessHUD()
    private let cursorFinder = CursorFinder()
    private var tvBrightnessWork: DispatchWorkItem?
    private var monitorBrightnessWork: DispatchWorkItem?
    private let macroKeys = MacroKeys()
    private let keyRemap = KeyRemapService()
    private let tvRootItem = NSMenuItem(title: "TV", action: nil, keyEquivalent: "")
    private let tvStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let tvVolumeUpItem = NSMenuItem(title: "Volume up", action: nil, keyEquivalent: "")
    private let tvVolumeDownItem = NSMenuItem(title: "Volume down", action: nil, keyEquivalent: "")
    private let tvMuteItem = NSMenuItem(title: "Mute", action: nil, keyEquivalent: "")
    private let tvBrighterItem = NSMenuItem(title: "Brighter", action: nil, keyEquivalent: "")
    private let tvDimmerItem = NSMenuItem(title: "Dimmer", action: nil, keyEquivalent: "")
    private let tvScreenOffItem = NSMenuItem(title: "Screen off", action: nil, keyEquivalent: "")
    private let tvScreenOnItem = NSMenuItem(title: "Screen on", action: nil, keyEquivalent: "")
    private let tvPowerOffItem = NSMenuItem(title: "Turn TV off", action: nil, keyEquivalent: "")
    private let tvPowerOnItem = NSMenuItem(title: "Turn TV on", action: nil, keyEquivalent: "")
    private let tvReconnectItem = NSMenuItem(title: "Reconnect", action: nil, keyEquivalent: "")
    private let findCursorItem = NSMenuItem(title: "Find cursor", action: nil, keyEquivalent: "")
    private let cursorFinderToggleItem = NSMenuItem(title: "Double-tap Control to find cursor",
                                                    action: nil, keyEquivalent: "")

    private let monitorRootItem = NSMenuItem(title: "Monitor", action: nil, keyEquivalent: "")
    private let monitorStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let monitorBrighterItem = NSMenuItem(title: "Brighter", action: nil, keyEquivalent: "")
    private let monitorDimmerItem = NSMenuItem(title: "Dimmer", action: nil, keyEquivalent: "")
    private let monitorRefreshItem = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")

    /// Set when the screens were woken by something other than us while the mouse sat on the dock.
    /// Automation stands down until the next dock cycle rather than fighting the user.
    private var stoodDown = false
    /// The first resolved sensor state after launch never triggers automation, so starting the app
    /// while the mouse is docked doesn't immediately blank your screens.
    private var hasResolvedInitialState = false
    private var inventory: HIDPPClient.Inventory?
    private var lastKeyboardSummary: String?

    /// The menu bar's own appearance. `NSApp.effectiveAppearance` says Aqua for a windowless
    /// menu-bar app, which would draw black glyphs on a dark bar.
    private var menuBarIsDark: Bool {
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var automationEnabled: Bool { Preferences.shared.automate }
    private var keepAwake: Bool { Preferences.shared.keepAwake }

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()

        log("Wakey \(Self.version) launched — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("automation enabled: \(automationEnabled), login item: \(LoginItem.statusDescription)")
        log("log file: \(Log.shared.logPath)")

        if Preferences.shared.deviceSlot > 0 {
            hidpp.preferredSlot = UInt8(clamping: Preferences.shared.deviceSlot)
        }

        wireSensor()
        hidpp.start()

        keyboard.onStatus = { message in
            log("KEYBOARD: \(message)")
        }
        keyboard.onWiredKeyboard = { [weak self] in
            // Cable is in, so a request actually reaches the keyboard: read its LED timeout.
            self?.fetchIdleTimeoutOverUSB()
        }
        keyboard.onReading = { [weak self] reading in
            guard let self else { return }
            if reading.summary != self.lastKeyboardSummary {
                self.lastKeyboardSummary = reading.summary
                log("KEYBOARD: \(reading.summary) (transport 0x\(String(format: "%02x", reading.transport)))")
            }
            self.keyboardTrigger.ingest(charging: reading.charging != .notCharging)
            self.settings?.keyboardSummary = reading.summary
            self.settings?.keyboardReading = reading
            self.updateStatusBar()
            self.refresh()
        }
        keyboard.start()
        wireTV()
        applyMacroKeyPreference(prompt: true)
        applyKeyRemapPreference(clearWhenDisabled: false)

        Preferences.shared.onChange = { [weak self] in
            self?.refresh()
            self?.settings?.refresh()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(blankAction),
                                               name: .wakeyBlankNow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(wakeAction),
                                               name: .wakeyWakeNow, object: nil)

        // Periodic snapshot: the only thing that makes a day-long log readable afterwards.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            log("HEARTBEAT \(self.sensor.summary) | keyboard=\(self.keyboard.latest?.summary ?? "no data") | displays_asleep=\(self.displays.displaysAreAsleep) blanked_by_us=\(self.displays.blankedByUs) stood_down=\(self.stoodDown)")
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        refresh()

        let appAppearance = NSApp.effectiveAppearance.name.rawValue
        let buttonAppearance = statusItem.button?.effectiveAppearance.name.rawValue ?? "nil"
        log("appearance: app=\(appAppearance) statusItem=\(buttonAppearance) menuBarIsDark=\(menuBarIsDark) mode=\(Preferences.shared.coloredBadge ? "coloured badge" : "template")")

        if !Preferences.shared.hasSeenWelcome {
            Preferences.shared.hasSeenWelcome = true
            log("first run — showing settings")
            showSettings()
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func applicationWillTerminate(_ notification: Notification) {
        cursorFinder.stop()
        mediaKeys.stop()
        macroKeys.stop()
        if keyRemap.isApplied { keyRemap.clear() }
        tv.stop()
        hidpp.stop()
        keyboard.stop()
        displays.releaseAssertions()
    }

    // MARK: - sensor wiring

    /// Reads a device-side setting over USB and logs it. Fails harmlessly when the keyboard is
    /// unpatched (no 0xA5 handler) or has already gone back to the dongle.
    private func fetchIdleTimeoutOverUSB() {
        DispatchQueue.global(qos: .utility).async {
            switch KeychronConfig.readIdleTimeout() {
            case .ok(let seconds):
                let text = seconds == 0 ? "never" : String(format: "%d s", seconds)
                log("keyboard: LED idle timeout is \(text) (read over USB)")
                DispatchQueue.main.async { self.settings?.adoptIdleTimeout(seconds) }
            case .noDevice:
                log("keyboard: LED idle timeout not read — no wired keyboard")
            case .noReply:
                log("keyboard: LED idle timeout not read — keyboard did not answer 0xA5")
            }
        }
    }

    private func wireSensor() {
        hidpp.onDeviceEvent = { message in
            log("HID++: \(message)")
        }

        hidpp.onInventory = { [weak self] inventory in
            DispatchQueue.main.async {
                self?.inventory = inventory
                self?.settings?.inventory = inventory
                self?.refresh()
            }
        }

        hidpp.onReading = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.sensor.ingest(result)
                self.updateStatusBar()
            }
        }

        sensor.onNewFlagsValue = { flags, reading in
            let extras = reading.extras.isEmpty ? "" : " (\(reading.extras.joined(separator: "+")))"
            log(String(format: "SENSOR new flags value 0x%02x first seen: %.3f V, %@%@",
                       flags, reading.volts, reading.chargeState, extras))
        }

        sensor.onStateChange = { [weak self] transition in
            self?.handle(transition)
        }
    }

    private func handle(_ transition: DockSensor.Transition) {
        log("SENSOR \(transition.from.rawValue) -> \(transition.to.rawValue): \(transition.reason)")

        // Only one device drives the displays, otherwise two sources would fight over them.
        guard Preferences.shared.trigger == .mouse else {
            refresh()
            return
        }

        let isInitialResolution = !hasResolvedInitialState
        hasResolvedInitialState = true

        if transition.to == .away { stoodDown = false }

        guard automationEnabled else {
            refresh()
            return
        }

        switch transition.to {
        case .docked:
            if isInitialResolution {
                log("automation: first state after launch is 'docked' — not blanking until a real dock event")
            } else if stoodDown {
                log("automation: standing down until the next dock cycle")
            } else if displays.displaysAreAsleep {
                log("automation: already asleep, nothing to do")
            } else {
                do {
                    try displays.blank(keepSystemAwake: keepAwake)
                    log("automation: displays blanked (mouse docked)")
                } catch {
                    log("automation: blank failed — \(error)")
                }
            }

        case .away:
            // Deliberately no wake here. Picking the mouse up produces HID input and macOS wakes
            // the displays itself; calling wake() from a sensor reading would have fired on the
            // full-charge case, where the dock reports "discharging" while the mouse is parked.
            if displays.displaysAreAsleep {
                log("automation: mouse away but displays still asleep — leaving them to the HID wake event")
            } else {
                log("automation: mouse away, displays already on")
            }

        case .unknown:
            log("automation: sensor passive, holding current display state")
        }

        settings?.liveSummary = sensor.summary
        refresh()
    }

    private func handleKeyboardTrigger(_ state: KeyboardTrigger.State) {
        log("KEYBOARD TRIGGER: \(state == .active ? "charging" : "not charging")")

        let isInitialResolution = !resolvedKeyboardInitial
        resolvedKeyboardInitial = true

        guard state == .active else {
            stoodDown = false
            refresh()
            return
        }

        guard Preferences.shared.trigger == .keyboard else { refresh(); return }
        guard automationEnabled else { refresh(); return }

        if isInitialResolution {
            log("automation: first keyboard state after launch is 'charging' — not blanking")
        } else if stoodDown {
            log("automation: standing down until the keyboard stops charging")
        } else if displays.displaysAreAsleep {
            log("automation: already asleep, nothing to do")
        } else {
            do {
                try displays.blank(keepSystemAwake: keepAwake)
                log("automation: displays blanked (keyboard charging)")
            } catch {
                log("automation: blank failed — \(error)")
            }
        }
        refresh()
    }

    // MARK: - TV

    private func wireTV() {
        displays.onBlank = { [weak self] in self?.tv.followDisplayBlank() }
        displays.onWake = { [weak self] in self?.tv.followDisplayWake() }

        tv.onStateChange = { [weak self] state in
            guard let self else { return }
            log("TV: state \(state.rawValue)")
            self.settings?.tvState = state
            self.refresh()
        }
        tv.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.settings?.tvSnapshot = snapshot
            self.refresh()
        }

        mediaKeys.canHandleVolume = { [weak self] in self?.tv.isReady ?? false }
        mediaKeys.canHandleBrightness = { [weak self] in
            guard let self, let screen = self.screenUnderPointer() else { return false }
            if screen.localizedName.localizedCaseInsensitiveContains("LG TV") {
                return self.tv.isReady
            }
            if self.screenIsMonitor(screen) {
                return self.monitor.isAvailable
            }
            return false
        }
        mediaKeys.onVolumeUp = { [weak self] in self?.tv.stepVolume(2) }
        mediaKeys.onVolumeDown = { [weak self] in self?.tv.stepVolume(-2) }
        mediaKeys.onMute = { [weak self] in self?.tv.toggleMute() }
        mediaKeys.onBrightnessUp = { [weak self] in self?.stepBrightness(5) }
        mediaKeys.onBrightnessDown = { [weak self] in self?.stepBrightness(-5) }

        applyMediaKeyPreference(prompt: true)

        log("MONITOR: pointer display is \(screenUnderPointer()?.localizedName ?? "none")")
        monitor.refresh { [weak self] in self?.refresh() }

        if Preferences.shared.cursorFinder { cursorFinder.start() }

        tv.start()
    }

    private func applyKeyRemapPreference(clearWhenDisabled: Bool = true) {
        let prefs = Preferences.shared
        if prefs.keyRemapEnabled {
            keyRemap.apply(prefs.keyRemappings)
        } else if clearWhenDisabled {
            keyRemap.clear()
        }
    }

    private func applyMacroKeyPreference(prompt: Bool = false, alert: Bool = false) {
        guard Preferences.shared.hasMacroShortcuts else {
            macroKeys.stop()
            return
        }
        if macroKeys.start(prompt: prompt) { return }
        guard alert else { return }
        let warning = NSAlert()
        warning.messageText = "Accessibility permission is needed for macro keys"
        warning.informativeText = "Enable Wakey under System Settings → Privacy & Security → "
            + "Accessibility, then record a macro again. Wakey starts the key tap by itself as soon "
            + "as the switch is on."
        warning.addButton(withTitle: "Open System Settings")
        warning.addButton(withTitle: "Later")
        if warning.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func applyMediaKeyPreference(prompt: Bool = false, alert: Bool = false) {
        guard Preferences.shared.tvMediaKeys else {
            mediaKeys.stop()
            return
        }
        if mediaKeys.start(prompt: prompt) { return }
        guard alert else { return }
        let warning = NSAlert()
        warning.messageText = "Accessibility permission is needed"
        warning.informativeText = "Enable Wakey under System Settings → Privacy & Security → "
            + "Accessibility, then toggle this setting off and on again. Wakey starts the key tap "
            + "by itself as soon as the switch is on."
        warning.addButton(withTitle: "Open System Settings")
        warning.addButton(withTitle: "Later")
        if warning.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func buildTVMenu() -> NSMenuItem {
        let menu = NSMenu()
        tvStatusItem.isEnabled = false
        menu.addItem(tvStatusItem)
        menu.addItem(.separator())

        for (item, action) in [(tvVolumeUpItem, #selector(tvVolumeUp)),
                               (tvVolumeDownItem, #selector(tvVolumeDown)),
                               (tvMuteItem, #selector(tvMute))] {
            item.target = self
            item.action = action
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for (item, action) in [(tvBrighterItem, #selector(tvBrighter)),
                               (tvDimmerItem, #selector(tvDimmer))] {
            item.target = self
            item.action = action
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for (item, action) in [(tvScreenOffItem, #selector(tvScreenOff)),
                               (tvScreenOnItem, #selector(tvScreenOn))] {
            item.target = self
            item.action = action
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for (item, action) in [(tvPowerOffItem, #selector(tvPowerOff)),
                               (tvPowerOnItem, #selector(tvPowerOn))] {
            item.target = self
            item.action = action
            menu.addItem(item)
        }

        menu.addItem(.separator())
        tvReconnectItem.target = self
        tvReconnectItem.action = #selector(tvReconnect)
        menu.addItem(tvReconnectItem)

        let tvSettings = NSMenuItem(title: "TV settings…", action: #selector(showTVSettings), keyEquivalent: "")
        tvSettings.target = self
        menu.addItem(tvSettings)

        tvRootItem.submenu = menu
        return tvRootItem
    }

    private func buildMonitorMenu() -> NSMenuItem {
        let menu = NSMenu()
        monitorStatusItem.isEnabled = false
        menu.addItem(monitorStatusItem)
        menu.addItem(.separator())

        for (item, action) in [(monitorBrighterItem, #selector(monitorBrighter)),
                               (monitorDimmerItem, #selector(monitorDimmer)),
                               (monitorRefreshItem, #selector(monitorRefresh))] {
            item.target = self
            item.action = action
            menu.addItem(item)
        }
        monitorRootItem.submenu = menu
        return monitorRootItem
    }

    private func refreshMonitors() {
        let available = monitor.isAvailable
        monitorRootItem.isHidden = !available
        guard available else { return }
        let value = monitor.value.map { "\($0)%" } ?? "—"
        monitorRootItem.title = "Monitor: \(value)"
        monitorStatusItem.title = "\(monitor.displayName) · \(value)"
        for item in [monitorBrighterItem, monitorDimmerItem, monitorRefreshItem] {
            item.isEnabled = true
        }
    }

    /// Whichever display the pointer is on. Brightness keys follow the pointer, so the same key
    /// pair drives the TV or the DDC monitor without a chord or a menu.
    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func screenIsMonitor(_ screen: NSScreen) -> Bool {
        let name = screen.localizedName
        let target = monitor.displayName
        return name.localizedCaseInsensitiveContains("HDR 4K")
            || (!target.isEmpty && name.localizedCaseInsensitiveContains(target))
            || (!target.isEmpty && target.localizedCaseInsensitiveContains(name))
    }

    private func stepBrightness(_ delta: Int) {
        guard let screen = screenUnderPointer() else { return }
        if screen.localizedName.localizedCaseInsensitiveContains("LG TV") {
            let current = brightnessHUD.isVisible && brightnessHUD.targetKey == "tv"
                ? brightnessHUD.currentValue
                : (tv.snapshot.backlight ?? 50)
            let target = min(100, max(0, current + delta))
            brightnessHUD.show(key: "tv", title: "TV brightness", value: target) { [weak self] value in
                self?.applyTVBrightness(value)
            }
            applyTVBrightness(target)
        } else if screenIsMonitor(screen) {
            let current = brightnessHUD.isVisible && brightnessHUD.targetKey == "monitor"
                ? brightnessHUD.currentValue
                : (monitor.value ?? 50)
            let target = min(100, max(0, current + delta))
            brightnessHUD.show(key: "monitor", title: "\(monitor.displayName) brightness", value: target) { [weak self] value in
                self?.applyMonitorBrightness(value)
            }
            applyMonitorBrightness(target)
        }
    }

    /// Slider drags are continuous; coalesce them so the TV's luna bridge and m1ddc are not flooded.
    private func applyTVBrightness(_ value: Int) {
        tvBrightnessWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tv.setBacklight(value) }
        tvBrightnessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func applyMonitorBrightness(_ value: Int) {
        monitorBrightnessWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.monitor.set(value) }
        monitorBrightnessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc private func monitorBrighter() {
        monitor.step(5) { [weak self] in self?.refresh() }
    }

    @objc private func monitorDimmer() {
        monitor.step(-5) { [weak self] in self?.refresh() }
    }

    @objc private func monitorRefresh() {
        monitor.refresh { [weak self] in self?.refresh() }

        if Preferences.shared.cursorFinder { cursorFinder.start() }
    }

    private func refreshTV() {
        let ready = tv.state == .ready
        let snapshot = tv.snapshot

        var summary: String
        switch tv.state {
        case .off:
            summary = Preferences.shared.tvControl ? "off" : "not enabled"
        case .connecting:
            summary = "connecting…"
        case .pairing:
            summary = "approve on TV"
        case .unreachable:
            summary = "unreachable"
        case .ready:
            if snapshot.isScreenOff {
                summary = "screen off"
            } else if snapshot.isPoweredOff {
                summary = "off"
            } else {
                summary = "on"
            }
            if let volume = snapshot.volume {
                summary += " · \(snapshot.muted == true ? "muted" : "\(volume)%")"
            }
            if let backlight = snapshot.backlight, !snapshot.isPoweredOff, !snapshot.isScreenOff {
                summary += " · \(backlight)%"
            }
        }
        tvRootItem.title = "TV: \(summary)"

        var details: [String] = []
        if let model = snapshot.model { details.append(model) }
        if let volume = snapshot.volume { details.append("volume \(volume)%") }
        if let backlight = snapshot.backlight { details.append("backlight \(backlight)%") }
        if let app = snapshot.currentApp {
            details.append(app.replacingOccurrences(of: "com.webos.app.", with: ""))
        }
        tvStatusItem.title = details.isEmpty ? "No state from the TV yet" : details.joined(separator: " · ")

        tvMuteItem.title = (snapshot.muted ?? false) ? "Unmute" : "Mute"
        for item in [tvVolumeUpItem, tvVolumeDownItem, tvMuteItem, tvBrighterItem, tvDimmerItem,
                     tvScreenOffItem, tvScreenOnItem, tvPowerOffItem, tvPowerOnItem] {
            item.isEnabled = ready
        }
        tvReconnectItem.isEnabled = Preferences.shared.tvControl
    }

    @objc private func tvVolumeUp() { tv.stepVolume(2) }
    @objc private func tvVolumeDown() { tv.stepVolume(-2) }
    @objc private func tvMute() { tv.toggleMute() }
    @objc private func findCursorNow() {
        cursorFinder.trigger()
    }

    @objc private func toggleCursorFinder() {
        Preferences.shared.cursorFinder.toggle()
        if Preferences.shared.cursorFinder {
            cursorFinder.start()
        } else {
            cursorFinder.stop()
        }
        log("cursor finder: \(Preferences.shared.cursorFinder ? "enabled" : "disabled")")
        refresh()
    }

    @objc private func tvBrighter() { tv.stepBacklight(5) }
    @objc private func tvDimmer() { tv.stepBacklight(-5) }
    @objc private func tvScreenOff() { tv.screenOff() }
    @objc private func tvScreenOn() { tv.screenOn() }
    @objc private func tvPowerOff() { tv.powerOff() }
    @objc private func tvPowerOn() { tv.powerOn() }
    @objc private func tvReconnect() { tv.reconnect() }

    private func connectTV(to address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            presentError("No TV address", "Enter the TV's IPv4 address, or use Detect.")
            return
        }
        Preferences.shared.tvHost = trimmed
        Preferences.shared.tvControl = true
        settings?.tvState = .connecting
        log("TV: connecting to \(trimmed) from settings")
        tv.reconnect()
    }

    private func tvPreferenceChanged() {
        if Preferences.shared.tvControl {
            tv.start()
        } else {
            tv.stop()
        }
        refresh()
    }

    private func detectTVs() {
        if scanner == nil {
            let controller = TVScannerWindowController()
            controller.onScan = { [weak self] in self?.scanTVs() }
            controller.onConnect = { [weak self] host in self?.connectTV(to: host) }
            scanner = controller
        }
        scanner?.startScan()
    }

    private func scanTVs() {
        log("TV: SSDP discovery started")
        TVController.discover { [weak self] devices in
            guard let self else { return }
            if devices.isEmpty {
                log("TV: no LG TVs answered SSDP")
            } else {
                let names = devices.map { "\($0.host) \($0.name ?? $0.model ?? "")" }.joined(separator: ", ")
                log("TV: discovered \(names)")
            }
            self.scanner?.showResults(devices)
        }
    }

    @objc private func systemWillSleep() {
        log("system: will sleep")
        tv.prepareForSystemSleep()
    }

    @objc private func systemDidWake() {
        log("system: did wake")
        tv.handleSystemWake()
        refresh()
    }

    // MARK: - menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        receiverMenuItem.isEnabled = false
        mouseMenuItem.isEnabled = false
        keyboardMenuItem.isEnabled = false
        receiverMenuItem.isHidden = !Preferences.shared.showMouse
        mouseMenuItem.isHidden = !Preferences.shared.showMouse
        keyboardMenuItem.isHidden = !Preferences.shared.showKeyboard
        displayMenuItem.isEnabled = false
        menu.addItem(receiverMenuItem)
        menu.addItem(mouseMenuItem)
        menu.addItem(keyboardMenuItem)
        menu.addItem(displayMenuItem)
        menu.addItem(.separator())

        automationItem.action = #selector(toggleAutomation)
        automationItem.target = self
        menu.addItem(automationItem)

        keepAwakeItem.action = #selector(toggleKeepAwake)
        keepAwakeItem.target = self
        menu.addItem(keepAwakeItem)

        menu.addItem(.separator())

        let blank = NSMenuItem(title: "Blank displays now", action: #selector(blankAction), keyEquivalent: "b")
        blank.target = self
        menu.addItem(blank)

        let wake = NSMenuItem(title: "Wake displays now", action: #selector(wakeAction), keyEquivalent: "w")
        wake.target = self
        menu.addItem(wake)

        findCursorItem.target = self
        findCursorItem.action = #selector(findCursorNow)
        menu.addItem(findCursorItem)

        cursorFinderToggleItem.target = self
        cursorFinderToggleItem.action = #selector(toggleCursorFinder)
        menu.addItem(cursorFinderToggleItem)

        menu.addItem(.separator())
        menu.addItem(buildTVMenu())
        menu.addItem(buildMonitorMenu())
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diag = NSMenuItem(title: "Show diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "d")
        diag.target = self
        menu.addItem(diag)

        let logItem = NSMenuItem(title: "Reveal log in Finder", action: #selector(revealLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Wakey", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Wakey", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        monitor.refresh { [weak self] in self?.refresh() }

        if Preferences.shared.cursorFinder { cursorFinder.start() }
    }

    private func refresh() {
        let asleep = displays.displaysAreAsleep

        if let inventory {
            if let active = inventory.active {
                receiverMenuItem.title = String(format: "Receiver: %@ · slot 0x%02x",
                                                inventory.receiverLabel, active.slot)
            } else {
                receiverMenuItem.title = "Receiver: \(inventory.receiverLabel) · no device answering"
            }
        } else {
            receiverMenuItem.title = "Receiver: searching…"
        }

        var mouseTitle: String
        switch sensor.state {
        case .docked:
            mouseTitle = "Mouse: docked — \(sensor.lastReading?.chargeState ?? "charging")"
        case .away:
            mouseTitle = "Mouse: away"
        case .unknown:
            mouseTitle = "Mouse: no reading yet"
        }
        if let reading = sensor.lastReading {
            var details: [String] = []
            if let percent = reading.estimatedPercent { details.append("≈\(percent)%") }
            details.append(String(format: "%.2f V", reading.volts))
            mouseTitle += " · " + details.joined(separator: " · ")
        }
        mouseMenuItem.title = mouseTitle

        let colored = Preferences.shared.coloredBadge
        let mouseCharging = sensor.lastReading?.isCharging ?? false
        mouseMenuItem.image = DeviceIcons.mouse(charging: mouseCharging, colored: colored)

        if let reading = keyboard.latest, reading.isUsable {
            keyboardMenuItem.title = "Keyboard: \(reading.menuDescription)"
            keyboardMenuItem.image = DeviceIcons.keyboard(charging: reading.isFresh && reading.charging != .notCharging, colored: colored)
        } else if keyboard.bluetoothOnly {
            keyboardMenuItem.title = "Keyboard: no data — on Bluetooth (Fn+F4 for 2.4 GHz)"
            keyboardMenuItem.image = DeviceIcons.keyboard(charging: false, colored: colored)
        } else {
            keyboardMenuItem.title = "Keyboard: no data"
            keyboardMenuItem.image = DeviceIcons.keyboard(charging: false, colored: colored)
        }

        displayMenuItem.title = asleep
            ? "Displays: off\(displays.blankedByUs ? " (blanked by Wakey)" : "")"
            : "Displays: on"

        automationItem.state = automationEnabled ? .on : .off
        keepAwakeItem.state = keepAwake ? .on : .off

        refreshTV()
        refreshMonitors()
        cursorFinderToggleItem.state = Preferences.shared.cursorFinder ? .on : .off
        updateStatusBar()
    }

    /// Both devices' charge in the menu bar: `[mouse] 76% [keyboard] 75%`.
    private func updateStatusBar() {
        let mousePercent = sensor.lastReading?.estimatedPercent
        // Keep showing the last known value: the board sleeping is not the same as no reading.
        let keyboardPercent = keyboard.latest.flatMap { $0.isUsable ? $0.percent : nil }

        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        let keyboardCharging = keyboard.latest?.isFresh == true && keyboard.latest?.charging != .notCharging
        let mouseEntry = Preferences.shared.showMouse
            ? (percent: mousePercent, charging: sensor.lastReading?.isCharging ?? false)
            : nil
        let keyboardEntry = Preferences.shared.showKeyboard
            ? (percent: keyboardPercent, charging: keyboardCharging)
            : nil

        if let image = DeviceIcons.statusBar(mouse: mouseEntry, keyboard: keyboardEntry,
                                             colored: Preferences.shared.coloredBadge) {
            statusItem.button?.image = image
        } else {
            // Nothing selected for the menu bar: keep a plain status icon so the menu stays reachable.
            let symbol = displays.displaysAreAsleep ? "moon.fill" : "display"
            statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Wakey")
            statusItem.button?.image?.isTemplate = true
        }
    }

    // MARK: - actions

    @objc private func toggleAutomation() {
        Preferences.shared.automate.toggle()
        log("automation \(automationEnabled ? "ENABLED — blanks on dock, wakes on pickup" : "disabled")")
        refresh()
    }

    @objc private func toggleKeepAwake() {
        Preferences.shared.keepAwake.toggle()
        log("keepAwakeWhileBlanked = \(keepAwake)")
        refresh()
    }

    @objc private func blankAction() {
        do {
            try displays.blank(keepSystemAwake: keepAwake)
            log("---- manual blank ----")
        } catch {
            log("blank failed: \(error)")
            presentError("Could not blank the displays", error.localizedDescription)
        }
        refresh()
    }

    @objc private func wakeAction() {
        log("---- manual wake ----")
        if sensor.state == .docked { stoodDown = true }
        displays.wake()
        refresh()
    }

    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindowController()
            controller.onRescan = { [weak self] in self?.hidpp.rescan() }
            controller.onSelectSlot = { [weak self] slot in self?.hidpp.preferredSlot = slot }
            controller.onTVConnect = { [weak self] address in self?.connectTV(to: address) }
            controller.onTVDetect = { [weak self] in self?.detectTVs() }
            controller.onTVEnabledChanged = { [weak self] in self?.tvPreferenceChanged() }
            controller.onTVVolume = { [weak self] value in self?.tv.setVolume(value) }
            controller.onTVBacklight = { [weak self] value in self?.tv.setBacklight(value) }
            controller.onTVMediaKeysChanged = { [weak self] in self?.applyMediaKeyPreference() }
            controller.onMacroKeysChanged = { [weak self] in
                self?.applyMacroKeyPreference(prompt: true, alert: true)
            }
            controller.onKeyRemapChanged = { [weak self] in
                self?.applyKeyRemapPreference()
            }
            settings = controller
        }
        settings?.inventory = inventory
        settings?.liveSummary = sensor.summary
        settings?.keyboardSummary = keyboard.latest.map { $0.isUsable ? $0.menuDescription : "no data" } ?? "no data"
        settings?.keyboardReading = keyboard.latest
        settings?.tvState = tv.state
        settings?.tvSnapshot = tv.snapshot
        settings?.showWindow(nil)
    }

    @objc private func showTVSettings() {
        showSettings()
        settings?.selectTVSection()
    }

    @objc private func showDiagnostics() {
        if diagnostics == nil { diagnostics = DiagnosticsWindowController() }
        diagnostics?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.shared.logPath)])
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Wakey",
            .applicationVersion: Self.version,
            .credits: NSAttributedString(
                string: "Displays off while the mouse charges.\nLog: \(Log.shared.logPath)",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        log("quit requested — sensor snapshot: \(sensor.summary)")
        NSApp.terminate(nil)
    }

    // MARK: - display notifications

    @objc private func screensDidSleep() {
        log("system: displays went to sleep")
        tv.followDisplayBlank()
        refresh()
    }

    @objc private func screensDidWake() {
        log("system: displays woke")
        if displays.blankedByUs { displays.noteExternallyWoken() }
        tv.followDisplayWake()
        if automationEnabled && sensor.state == .docked {
            stoodDown = true
            log("automation: woken by external input while docked — standing down until the next dock cycle")
        }
        refresh()
    }

    private func presentError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
