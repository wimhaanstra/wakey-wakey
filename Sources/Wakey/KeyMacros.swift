import AppKit
import ApplicationServices
import Carbon

/// A recorded key combination, stored as the virtual key code plus the modifiers that matter.
/// The key name is captured at record time so the settings row can show exactly what will be sent.
struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var keyName: String

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += keyName.isEmpty ? "Key \(keyCode)" : keyName
        return text
    }

    /// Sends the shortcut to whatever is frontmost. Used when a macro key is pressed.
    func post() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cgFlags = CGEventFlags(rawValue: UInt64(modifiers))

        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        down?.flags = cgFlags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        up?.flags = cgFlags
        up?.post(tap: .cghidEventTap)
    }

    static func keyName(for event: NSEvent) -> String {
        if let special = specialKeyName(event.keyCode) { return special }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return "Key \(event.keyCode)"
        }
        if characters == " " { return "Space" }
        return characters.uppercased()
    }

    static func specialKeyName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 76: return "Enter"
        case 96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122:
            let numbers: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
                                          98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12]
            return "F\(numbers[keyCode] ?? 0)"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }
}

/// The K5 Max's four PlayStation keys emit F13–F16 and its microphone key emits F17 once the
/// matching firmware image is flashed. Carbon hotkeys register those keys with the window server, so
/// they are consumed before any app sees them and we do not need Input Monitoring. Posting the
/// replacement shortcut does need Accessibility, which the TV media-key bridge already asks for.
final class MacroKeys {
    /// F13–F16 are the four PlayStation-symbol keys in the top-right cluster; F17 is the
    /// microphone key once the matching firmware image is flashed (it used to send Siri).
    static let keyCodes: [CGKeyCode] = [105, 107, 113, 106, 64]
    private static let signature: OSType = 0x57414B59 // 'WAKY'

    static func macroIndex(for keyCode: CGKeyCode) -> Int? {
        keyCodes.firstIndex(of: keyCode).map { $0 + 1 }
    }

    static func isMacroKey(_ keyCode: UInt16) -> Bool {
        keyCodes.contains(CGKeyCode(keyCode))
    }

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var trustTimer: Timer?
    private var lastFire: [UInt32: Date] = [:]

    var isRunning: Bool { !hotKeyRefs.isEmpty }

    @discardableResult
    func start(prompt: Bool = true) -> Bool {
        guard Preferences.shared.hasMacroShortcuts else {
            stop()
            return true
        }

        guard AXIsProcessTrusted() else {
            if prompt {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                log("macro keys: Accessibility not granted — enable Wakey in System Settings → Privacy & Security → Accessibility")
            } else {
                log("macro keys: enabled but Accessibility is not granted")
            }
            if prompt { waitForAccessibility() }
            return false
        }

        installHandlerIfNeeded()
        guard handlerRef != nil else { return false }

        unregisterHotKeys()
        for index in 1...5 where Preferences.shared.macroShortcut(for: index) != nil {
            registerHotKey(index: index)
        }

        guard !hotKeyRefs.isEmpty else {
            log("macro keys: no hot keys could be registered")
            return false
        }
        log("macro keys: F13–F17 now send their recorded shortcuts")
        return true
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), macroHotKeyCallback,
                                         1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &handlerRef)
        if status != noErr {
            log("macro keys: could not install the hot-key handler (\(status))")
            handlerRef = nil
        }
    }

    private func registerHotKey(index: Int) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index))
        let status = RegisterEventHotKey(UInt32(Self.keyCodes[index - 1]), 0, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            log("macro keys: could not register F\(12 + index) (\(status))")
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func waitForAccessibility() {
        trustTimer?.invalidate()
        let started = Date()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.trustTimer = nil
                log("macro keys: Accessibility granted")
                _ = self.start(prompt: false)
            } else if Date().timeIntervalSince(started) > 120 {
                timer.invalidate()
                self.trustTimer = nil
                log("macro keys: Accessibility still not granted — toggle a mapping again after enabling it")
            }
        }
    }

    func stop() {
        guard !hotKeyRefs.isEmpty || handlerRef != nil || trustTimer != nil else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        unregisterHotKeys()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        log("macro keys: stopped")
    }

    fileprivate func fire(id: UInt32) {
        let index = Int(id)
        guard (1...4).contains(index),
              let shortcut = Preferences.shared.macroShortcut(for: index),
              !Self.isMacroKey(shortcut.keyCode) else { return }

        let now = Date()
        if let last = lastFire[id], now.timeIntervalSince(last) < 0.2 { return }
        lastFire[id] = now
        log("macro keys: F\(12 + index) → \(shortcut.display)")
        shortcut.post()
    }
}

private func macroHotKeyCallback(callRef: EventHandlerCallRef?, event: EventRef?,
                                 userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let keys = Unmanaged<MacroKeys>.fromOpaque(userData).takeUnretainedValue()
    keys.fire(id: hotKeyID.id)
    return noErr
}

/// A settings-window button that records the next key combination. The local monitor is used
/// rather than `keyDown` so Command-based shortcuts are captured before the menu sees them.
final class ShortcutRecorderButton: NSButton {
    var shortcut: KeyShortcut? {
        didSet {
            if !isRecording { updateTitle() }
        }
    }
    var onChange: (() -> Void)?
    private(set) var isRecording = false

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        font = .systemFont(ofSize: 12)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMonitors()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        if isRecording { cancelRecording() }
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        if isRecording {
            cancelRecording()
            return
        }

        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.capture(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(point) { self.cancelRecording() }
            return event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.cancelRecording()
            }
        }
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // Escape cancels.
            cancelRecording()
            return nil
        }

        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = event.modifierFlags.intersection(relevant)

        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty {
            finish(nil, changed: true)
            return nil
        }

        if MacroKeys.isMacroKey(event.keyCode) {
            NSSound.beep()
            return nil
        }

        let recorded = KeyShortcut(keyCode: event.keyCode,
                                   modifiers: modifiers.rawValue,
                                   keyName: KeyShortcut.keyName(for: event))
        finish(recorded, changed: true)
        return nil
    }

    private func finish(_ value: KeyShortcut?, changed: Bool) {
        removeMonitors()
        isRecording = false
        if changed {
            shortcut = value
            updateTitle()
            onChange?()
        } else {
            updateTitle()
        }
    }

    private func cancelRecording() {
        finish(nil, changed: false)
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private func updateTitle() {
        title = isRecording ? "Type shortcut…" : (shortcut?.display ?? "Record Shortcut")
    }
}
