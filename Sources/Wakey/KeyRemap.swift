import AppKit

/// One physical key, described by both its macOS virtual key code (what AppKit records) and its
/// USB HID keyboard-page usage (what `hidutil` needs).
struct KeyChoice: Codable, Equatable {
    var keyCode: UInt16
    var usage: UInt32
    var name: String
}

/// A system-wide remap: pressing `source` sends `target` instead.
struct KeyRemap: Codable, Equatable {
    var source: KeyChoice
    var target: KeyChoice
}

/// The ANSI key set of the K5 Max, mapped from macOS virtual key codes to HID usage IDs.
enum KeyCatalog {
    private struct Entry {
        let usage: UInt32
        let name: String
    }

    private static let entries: [UInt16: Entry] = [
        0: Entry(usage: 0x04, name: "A"),
        1: Entry(usage: 0x16, name: "S"),
        2: Entry(usage: 0x07, name: "D"),
        3: Entry(usage: 0x09, name: "F"),
        4: Entry(usage: 0x0B, name: "H"),
        5: Entry(usage: 0x0A, name: "G"),
        6: Entry(usage: 0x1D, name: "Z"),
        7: Entry(usage: 0x1B, name: "X"),
        8: Entry(usage: 0x06, name: "C"),
        9: Entry(usage: 0x19, name: "V"),
        11: Entry(usage: 0x05, name: "B"),
        12: Entry(usage: 0x14, name: "Q"),
        13: Entry(usage: 0x1A, name: "W"),
        14: Entry(usage: 0x08, name: "E"),
        15: Entry(usage: 0x15, name: "R"),
        16: Entry(usage: 0x1C, name: "Y"),
        17: Entry(usage: 0x17, name: "T"),
        18: Entry(usage: 0x1E, name: "1"),
        19: Entry(usage: 0x1F, name: "2"),
        20: Entry(usage: 0x20, name: "3"),
        21: Entry(usage: 0x21, name: "4"),
        22: Entry(usage: 0x23, name: "6"),
        23: Entry(usage: 0x22, name: "5"),
        24: Entry(usage: 0x2E, name: "="),
        25: Entry(usage: 0x26, name: "9"),
        26: Entry(usage: 0x24, name: "7"),
        27: Entry(usage: 0x2D, name: "-"),
        28: Entry(usage: 0x25, name: "8"),
        29: Entry(usage: 0x27, name: "0"),
        30: Entry(usage: 0x30, name: "]"),
        31: Entry(usage: 0x12, name: "O"),
        32: Entry(usage: 0x18, name: "U"),
        33: Entry(usage: 0x2F, name: "["),
        34: Entry(usage: 0x0C, name: "I"),
        35: Entry(usage: 0x13, name: "P"),
        36: Entry(usage: 0x28, name: "Return"),
        37: Entry(usage: 0x0F, name: "L"),
        38: Entry(usage: 0x0D, name: "J"),
        39: Entry(usage: 0x34, name: "'"),
        40: Entry(usage: 0x0E, name: "K"),
        41: Entry(usage: 0x33, name: ";"),
        42: Entry(usage: 0x31, name: "\\"),
        43: Entry(usage: 0x36, name: ","),
        44: Entry(usage: 0x38, name: "/"),
        45: Entry(usage: 0x11, name: "N"),
        46: Entry(usage: 0x10, name: "M"),
        47: Entry(usage: 0x37, name: "."),
        48: Entry(usage: 0x2B, name: "Tab"),
        49: Entry(usage: 0x2C, name: "Space"),
        50: Entry(usage: 0x35, name: "`"),
        51: Entry(usage: 0x2A, name: "Delete"),
        53: Entry(usage: 0x29, name: "Escape"),
        54: Entry(usage: 0xE7, name: "Right Command"),
        55: Entry(usage: 0xE3, name: "Left Command"),
        56: Entry(usage: 0xE1, name: "Left Shift"),
        57: Entry(usage: 0x39, name: "Caps Lock"),
        58: Entry(usage: 0xE2, name: "Left Option"),
        59: Entry(usage: 0xE0, name: "Left Control"),
        60: Entry(usage: 0xE5, name: "Right Shift"),
        61: Entry(usage: 0xE6, name: "Right Option"),
        62: Entry(usage: 0xE4, name: "Right Control"),
        64: Entry(usage: 0x6C, name: "F17"),
        65: Entry(usage: 0x63, name: "Keypad ."),
        67: Entry(usage: 0x55, name: "Keypad *"),
        69: Entry(usage: 0x57, name: "Keypad +"),
        71: Entry(usage: 0x53, name: "Keypad Clear"),
        75: Entry(usage: 0x54, name: "Keypad /"),
        76: Entry(usage: 0x58, name: "Keypad Enter"),
        78: Entry(usage: 0x56, name: "Keypad -"),
        79: Entry(usage: 0x6D, name: "F18"),
        80: Entry(usage: 0x6E, name: "F19"),
        81: Entry(usage: 0x67, name: "Keypad ="),
        82: Entry(usage: 0x62, name: "Keypad 0"),
        83: Entry(usage: 0x59, name: "Keypad 1"),
        84: Entry(usage: 0x5A, name: "Keypad 2"),
        85: Entry(usage: 0x5B, name: "Keypad 3"),
        86: Entry(usage: 0x5C, name: "Keypad 4"),
        87: Entry(usage: 0x5D, name: "Keypad 5"),
        88: Entry(usage: 0x5E, name: "Keypad 6"),
        89: Entry(usage: 0x5F, name: "Keypad 7"),
        90: Entry(usage: 0x6F, name: "F20"),
        91: Entry(usage: 0x60, name: "Keypad 8"),
        92: Entry(usage: 0x61, name: "Keypad 9"),
        96: Entry(usage: 0x3E, name: "F5"),
        97: Entry(usage: 0x3F, name: "F6"),
        98: Entry(usage: 0x40, name: "F7"),
        99: Entry(usage: 0x3C, name: "F3"),
        100: Entry(usage: 0x41, name: "F8"),
        101: Entry(usage: 0x42, name: "F9"),
        103: Entry(usage: 0x44, name: "F11"),
        105: Entry(usage: 0x68, name: "F13"),
        106: Entry(usage: 0x6B, name: "F16"),
        107: Entry(usage: 0x69, name: "F14"),
        109: Entry(usage: 0x43, name: "F10"),
        111: Entry(usage: 0x45, name: "F12"),
        113: Entry(usage: 0x6A, name: "F15"),
        114: Entry(usage: 0x49, name: "Insert"),
        115: Entry(usage: 0x4A, name: "Home"),
        116: Entry(usage: 0x4B, name: "Page Up"),
        117: Entry(usage: 0x4C, name: "Forward Delete"),
        118: Entry(usage: 0x3D, name: "F4"),
        119: Entry(usage: 0x4D, name: "End"),
        120: Entry(usage: 0x3B, name: "F2"),
        121: Entry(usage: 0x4E, name: "Page Down"),
        122: Entry(usage: 0x3A, name: "F1"),
        123: Entry(usage: 0x50, name: "←"),
        124: Entry(usage: 0x4F, name: "→"),
        125: Entry(usage: 0x51, name: "↓"),
        126: Entry(usage: 0x52, name: "↑"),
    ]

    static func choice(for keyCode: UInt16) -> KeyChoice? {
        guard let entry = entries[keyCode] else { return nil }
        return KeyChoice(keyCode: keyCode, usage: entry.usage, name: entry.name)
    }
}

/// Owns the system `UserKeyMapping`. `hidutil` applies it to every keyboard, has no TCC prompt,
/// and makes Caps Lock behave like a normal remappable key.
final class KeyRemapService {
    private(set) var isApplied = false

    @discardableResult
    func apply(_ mappings: [KeyRemap]) -> Bool {
        let usable = mappings.filter { $0.source.usage != $0.target.usage }
        guard !usable.isEmpty else { return clear() }

        var seen = Set<UInt32>()
        var entries: [String] = []
        for mapping in usable.reversed() {
            guard seen.insert(mapping.source.usage).inserted else { continue }
            let source = 0x700000000 | UInt64(mapping.source.usage)
            let target = 0x700000000 | UInt64(mapping.target.usage)
            entries.append("{\"HIDKeyboardModifierMappingSrc\":\(source),"
                           + "\"HIDKeyboardModifierMappingDst\":\(target)}")
        }
        let json = "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
        let ok = run(json)
        isApplied = ok
        if ok { log("key remap: applied \(entries.count) mapping(s)") }
        return ok
    }

    @discardableResult
    func clear() -> Bool {
        let ok = run("{\"UserKeyMapping\":[]}")
        isApplied = false
        if ok { log("key remap: cleared") }
        return ok
    }

    private func run(_ json: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("key remap: could not run hidutil: \(error)")
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            log("key remap: hidutil failed (\(process.terminationStatus)): \(output)")
            return false
        }
        return true
    }
}

/// Records one physical key for the remap editor. It deliberately does not reserve Escape or Delete,
/// so every key can be used as a source or target; click the button again (or outside) to cancel.
final class KeyRecorderButton: NSButton {
    var choice: KeyChoice? {
        didSet { if !isRecording { updateTitle() } }
    }
    var onChange: ((KeyChoice) -> Void)?
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
        widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeMonitors()
    }

    @objc private func beginRecording() {
        if isRecording {
            cancelRecording()
            return
        }

        isRecording = true
        title = "Press key…"
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.capture(event)
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
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
        guard let choice = KeyCatalog.choice(for: event.keyCode) else {
            NSSound.beep()
            return nil
        }
        finish(choice)
        return nil
    }

    private func finish(_ value: KeyChoice) {
        removeMonitors()
        isRecording = false
        choice = value
        updateTitle()
        onChange?(value)
    }

    private func cancelRecording() {
        removeMonitors()
        isRecording = false
        updateTitle()
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
        title = isRecording ? "Press key…" : (choice?.name ?? "Record Key")
    }
}
