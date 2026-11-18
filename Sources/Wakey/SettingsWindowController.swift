import AppKit

/// The settings panel. Deliberately plain AppKit: one column, no scroll view, no SwiftUI lifecycle
/// to fight with in a `swiftc`-built bundle.
final class SettingsWindowController: NSWindowController {

    private let automateToggle = NSButton(checkboxWithTitle: "Automate while the mouse is on its charger",
                                          target: nil, action: nil)
    private let keepAwakeToggle = NSButton(checkboxWithTitle: "Keep this Mac awake while the displays are off",
                                           target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Start Wakey at login",
                                       target: nil, action: nil)
    private let badgeToggle = NSButton(checkboxWithTitle: "Green charging badge (may be hard to see on some wallpapers)",
                                       target: nil, action: nil)
    private let showMouseToggle = NSButton(checkboxWithTitle: "Show mouse battery",
                                           target: nil, action: nil)
    private let showKeyboardToggle = NSButton(checkboxWithTitle: "Show keyboard battery",
                                              target: nil, action: nil)
    private let triggerLabel = NSTextField(labelWithString: "Blank the displays when this device charges:")
    private let triggerPicker = NSPopUpButton(frame: .zero, pullsDown: false)

    private let receiverLabel = NSTextField(labelWithString: "Receiver: —")
    private let listeningLabel = NSTextField(labelWithString: "Listening to: —")
    private let sensorLabel = NSTextField(labelWithString: "")
    private let keyboardLabel = NSTextField(labelWithString: "Keyboard: no data")
    private let slotPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    /// Pushed in by the app delegate.
    var inventory: HIDPPClient.Inventory? {
        didSet { refreshDevice() }
    }
    var liveSummary: String = "" {
        didSet { sensorLabel.stringValue = liveSummary }
    }
    var keyboardSummary: String = "no data" {
        didSet { keyboardLabel.stringValue = "Keyboard: \(keyboardSummary)" }
    }

    var onRescan: (() -> Void)?
    var onSelectSlot: ((UInt8?) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wakey Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
        refresh()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Wakey")
        title.font = NSFont.systemFont(ofSize: 21, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Turns your displays off while the mouse sits on its charging dock, and lets them come back "
            + "when you pick it up.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 500

        for toggle in [automateToggle, keepAwakeToggle, loginToggle] {
            toggle.target = self
        }
        badgeToggle.target = self
        badgeToggle.action = #selector(badgeChanged)
        showMouseToggle.target = self
        showMouseToggle.action = #selector(visibilityChanged)
        showKeyboardToggle.target = self
        showKeyboardToggle.action = #selector(visibilityChanged)
        triggerPicker.target = self
        triggerPicker.action = #selector(triggerChanged)
        triggerPicker.addItems(withTitles: ["The mouse (on its dock)", "The keyboard (charging)"])
        triggerLabel.font = NSFont.systemFont(ofSize: 12)
        automateToggle.action = #selector(automateChanged)
        keepAwakeToggle.action = #selector(keepAwakeChanged)
        loginToggle.action = #selector(loginChanged)

        // Device section -------------------------------------------------------
        let deviceHeader = NSTextField(labelWithString: "Device")
        deviceHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        deviceHeader.textColor = .secondaryLabelColor

        for label in [receiverLabel, listeningLabel] {
            label.font = NSFont.systemFont(ofSize: 12)
        }

        keyboardLabel.font = NSFont.systemFont(ofSize: 12)

        sensorLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        sensorLabel.textColor = .tertiaryLabelColor
        sensorLabel.lineBreakMode = .byTruncatingMiddle

        slotPicker.target = self
        slotPicker.action = #selector(slotChanged)
        slotPicker.isHidden = true

        rescanButton.target = self
        rescanButton.action = #selector(rescanNow)
        rescanButton.bezelStyle = .rounded

        let deviceRow = NSStackView(views: [slotPicker, rescanButton])
        deviceRow.orientation = .horizontal
        deviceRow.spacing = 8

        // Footer ---------------------------------------------------------------
        let note = NSTextField(wrappingLabelWithString:
            "Displays are switched off with “pmset displaysleepnow”, so both screens go to standby and "
            + "the Mac stays awake to keep listening for the mouse. Your screen-lock delay is 5 minutes: "
            + "shorter charges wake straight back to your desktop, longer ones ask for your password.")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 500

        let buttons = NSStackView(views: [
            makeButton("Blank displays now", #selector(blankNow)),
            makeButton("Wake displays now", #selector(wakeNow)),
            makeButton("Reveal log in Finder", #selector(revealLog)),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(16, after: subtitle)
        stack.addArrangedSubview(automateToggle)
        stack.addArrangedSubview(keepAwakeToggle)
        stack.addArrangedSubview(loginToggle)
        stack.addArrangedSubview(badgeToggle)
        stack.setCustomSpacing(18, after: badgeToggle)
        stack.addArrangedSubview(showMouseToggle)
        stack.addArrangedSubview(showKeyboardToggle)
        stack.addArrangedSubview(triggerLabel)
        stack.addArrangedSubview(triggerPicker)
        stack.setCustomSpacing(18, after: loginToggle)
        stack.addArrangedSubview(deviceHeader)
        stack.addArrangedSubview(receiverLabel)
        stack.addArrangedSubview(listeningLabel)
        stack.addArrangedSubview(keyboardLabel)
        stack.addArrangedSubview(sensorLabel)
        stack.addArrangedSubview(deviceRow)
        stack.setCustomSpacing(18, after: deviceRow)
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(16, after: note)
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(14, after: buttons)
        stack.addArrangedSubview(statusLabel)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func refresh() {
        let prefs = Preferences.shared
        automateToggle.state = prefs.automate ? .on : .off
        keepAwakeToggle.state = prefs.keepAwake ? .on : .off
        loginToggle.state = LoginItem.isEnabled ? .on : .off
        badgeToggle.state = prefs.coloredBadge ? .on : .off
        showMouseToggle.state = prefs.showMouse ? .on : .off
        showKeyboardToggle.state = prefs.showKeyboard ? .on : .off
        triggerPicker.selectItem(at: prefs.trigger == .keyboard ? 1 : 0)
        statusLabel.stringValue = "login item: \(LoginItem.statusDescription)   log: \(Log.shared.logPath)"
        refreshDevice()
    }

    private func refreshDevice() {
        guard let inventory else {
            receiverLabel.stringValue = "Receiver: not found"
            listeningLabel.stringValue = "Listening to: —"
            slotPicker.isHidden = true
            return
        }

        receiverLabel.stringValue = "Receiver: \(inventory.receiverLabel)"

        if let active = inventory.active {
            let others = inventory.responders.count - 1
            let suffix = others > 0 ? " (\(others) other slot\(others == 1 ? "" : "s") also answering)" : " (only slot answering)"
            listeningLabel.stringValue = String(
                format: "Listening to: slot 0x%02x, battery feature 0x%02x%@",
                active.slot, active.batteryFeature, suffix)
        } else {
            listeningLabel.stringValue = "Listening to: nothing — the mouse is not answering"
        }

        // Only offer a chooser when there is a real choice to make.
        let multi = inventory.responders.count > 1
        slotPicker.isHidden = !multi
        if multi {
            slotPicker.removeAllItems()
            slotPicker.addItem(withTitle: "Automatic")
            for responder in inventory.responders {
                slotPicker.addItem(withTitle: String(format: "Slot 0x%02x (feature 0x%02x)",
                                                     responder.slot, responder.batteryFeature))
            }
            let preferred = Preferences.shared.deviceSlot
            if preferred > 0,
               let index = inventory.responders.firstIndex(where: { $0.slot == UInt8(preferred) }) {
                slotPicker.selectItem(at: index + 1)
            } else {
                slotPicker.selectItem(at: 0)
            }
        }
    }

    /// Used by `--selftest` to catch a layout that overflows the window.
    func layoutReport() -> String {
        guard let content = window?.contentView else { return "no content view" }
        content.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        let available = content.bounds.size
        let fits = fitting.height <= available.height + 1 && fitting.width <= available.width + 1
        return String(format: "stack %.0fx%.0f in %.0fx%.0f — %@",
                      fitting.width, fitting.height, available.width, available.height,
                      fits ? "fits" : "OVERFLOWS")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - actions

    @objc private func automateChanged() {
        Preferences.shared.automate = (automateToggle.state == .on)
        log("settings: automation = \(Preferences.shared.automate)")
        refresh()
    }

    @objc private func badgeChanged() {
        Preferences.shared.coloredBadge = (badgeToggle.state == .on)
        log("settings: coloredBadge = \(Preferences.shared.coloredBadge)")
        refresh()
    }

    @objc private func visibilityChanged() {
        Preferences.shared.showMouse = (showMouseToggle.state == .on)
        Preferences.shared.showKeyboard = (showKeyboardToggle.state == .on)
        log("settings: showMouse = \(Preferences.shared.showMouse), showKeyboard = \(Preferences.shared.showKeyboard)")
        refresh()
    }

    @objc private func triggerChanged() {
        Preferences.shared.trigger = triggerPicker.indexOfSelectedItem == 1 ? .keyboard : .mouse
        log("settings: trigger = \(Preferences.shared.trigger == .keyboard ? "keyboard" : "mouse")")
        refresh()
    }

    @objc private func keepAwakeChanged() {
        Preferences.shared.keepAwake = (keepAwakeToggle.state == .on)
        log("settings: keepAwake = \(Preferences.shared.keepAwake)")
    }

    @objc private func loginChanged() {
        let wants = (loginToggle.state == .on)
        if let failure = LoginItem.setEnabled(wants) {
            loginToggle.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = failure
            alert.alertStyle = .warning
            alert.runModal()
        }
        refresh()
    }

    @objc private func slotChanged() {
        let index = slotPicker.indexOfSelectedItem
        if index <= 0 {
            Preferences.shared.deviceSlot = 0
            onSelectSlot?(nil)
        } else {
            let responder = inventory?.responders[index - 1]
            Preferences.shared.deviceSlot = Int(responder?.slot ?? 0)
            onSelectSlot?(responder?.slot)
        }
        log("settings: device slot preference = \(Preferences.shared.deviceSlot)")
    }

    @objc private func rescanNow() {
        log("settings: rescan requested")
        onRescan?()
    }

    @objc private func blankNow() {
        NotificationCenter.default.post(name: .wakeyBlankNow, object: nil)
    }

    @objc private func wakeNow() {
        NotificationCenter.default.post(name: .wakeyWakeNow, object: nil)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Log.shared.logPath)])
    }
}

extension Notification.Name {
    static let wakeyBlankNow = Notification.Name("nl.sortedbits.wakey.blankNow")
    static let wakeyWakeNow = Notification.Name("nl.sortedbits.wakey.wakeNow")
}
