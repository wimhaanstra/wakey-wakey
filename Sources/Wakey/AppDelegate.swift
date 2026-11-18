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
    private var heartbeat: Timer?

    private let receiverMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let mouseMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keyboardMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let displayMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let automationItem = NSMenuItem(title: "Automate while charging", action: nil, keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "Keep Mac awake while blanked", action: nil, keyEquivalent: "")

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
        keyboard.onReading = { [weak self] reading in
            guard let self else { return }
            if reading.summary != self.lastKeyboardSummary {
                self.lastKeyboardSummary = reading.summary
                log("KEYBOARD: \(reading.summary) (transport 0x\(String(format: "%02x", reading.transport)))")
            }
            self.keyboardTrigger.ingest(charging: reading.charging != .notCharging)
            self.settings?.keyboardSummary = reading.summary
            self.updateStatusBar()
            self.refresh()
        }
        keyboard.start()

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
        hidpp.stop()
        keyboard.stop()
        displays.releaseAssertions()
    }

    // MARK: - sensor wiring

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

    func menuWillOpen(_ menu: NSMenu) { refresh() }

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

        if let reading = keyboard.latest, reading.isFresh {
            keyboardMenuItem.title = "Keyboard: \(reading.summary)"
            keyboardMenuItem.image = DeviceIcons.keyboard(charging: reading.charging != .notCharging, colored: colored)
        } else {
            keyboardMenuItem.title = "Keyboard: no data"
            keyboardMenuItem.image = DeviceIcons.keyboard(charging: false, colored: colored)
        }

        displayMenuItem.title = asleep
            ? "Displays: off\(displays.blankedByUs ? " (blanked by Wakey)" : "")"
            : "Displays: on"

        automationItem.state = automationEnabled ? .on : .off
        keepAwakeItem.state = keepAwake ? .on : .off

        updateStatusBar()
    }

    /// Both devices' charge in the menu bar: `[mouse] 76% [keyboard] 75%`.
    private func updateStatusBar() {
        let mousePercent = sensor.lastReading?.estimatedPercent
        let keyboardPercent = keyboard.latest.flatMap { $0.isFresh ? $0.percent : nil }

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
            settings = controller
        }
        settings?.inventory = inventory
        settings?.liveSummary = sensor.summary
        settings?.keyboardSummary = keyboard.latest?.summary ?? "no data"
        settings?.showWindow(nil)
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
        refresh()
    }

    @objc private func screensDidWake() {
        log("system: displays woke")
        if displays.blankedByUs { displays.noteExternallyWoken() }
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
