import Foundation

/// Single source of truth for user settings.
final class Preferences {
    static let shared = Preferences()

    /// Called on the main queue when any value changes from the settings window.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard

    private enum Key {
        static let automate = "automationEnabled"
        static let keepAwake = "keepAwakeWhileBlanked"
        static let welcomed = "hasSeenWelcome"
        static let coloredBadge = "coloredChargingBadge"
        static let showMouse = "showMouseBattery"
        static let showKeyboard = "showKeyboardBattery"
        static let triggerDevice = "triggerDevice"
        static let deviceSlot = "deviceSlot"
        static let tvControl = "tvControl"
        static let tvHost = "tvHost"
        static let tvFollowDisplays = "tvFollowDisplays"
        static let tvPowerOffOnSleep = "tvPowerOffOnSleep"
        static let tvInput = "tvInput"
        static let tvMediaKeys = "tvMediaKeys"
        static let cursorFinder = "cursorFinder"
    }

    private init() {}

    var automate: Bool {
        get { defaults.object(forKey: Key.automate) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Key.automate)
            onChange?()
        }
    }

    var keepAwake: Bool {
        get { defaults.object(forKey: Key.keepAwake) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.keepAwake)
            onChange?()
        }
    }

    /// Paired-device slot to follow. 0 means "the first slot that answers".
    var deviceSlot: Int {
        get { defaults.integer(forKey: Key.deviceSlot) }
        set {
            defaults.set(newValue, forKey: Key.deviceSlot)
            onChange?()
        }
    }

    /// Green badge + white glyphs, versus a template image that always matches the menu bar tint.
    /// The menu bar's tint follows the wallpaper, so neither choice is right everywhere; this is why
    /// it is a preference rather than an automatic decision.
    var coloredBadge: Bool {
        get { defaults.object(forKey: Key.coloredBadge) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.coloredBadge)
            onChange?()
        }
    }

    /// Which devices contribute to the menu bar readout.
    var showMouse: Bool {
        get { defaults.object(forKey: Key.showMouse) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showMouse); onChange?() }
    }

    var showKeyboard: Bool {
        get { defaults.object(forKey: Key.showKeyboard) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showKeyboard); onChange?() }
    }

    /// Which device's charging state drives the displays. Only one can be the trigger: two sources
    /// acting on the same displays would fight each other.
    enum Trigger: Int { case mouse = 0, keyboard = 1 }

    var trigger: Trigger {
        get { Trigger(rawValue: defaults.integer(forKey: Key.triggerDevice)) ?? .mouse }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerDevice); onChange?() }
    }

    // MARK: - TV

    /// Master switch: connect to the LG TV at all.
    var tvControl: Bool {
        get { defaults.object(forKey: Key.tvControl) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.tvControl); onChange?() }
    }

    /// IPv4 address or host name of the TV on the LAN.
    var tvHost: String {
        get { defaults.string(forKey: Key.tvHost) ?? "" }
        set { defaults.set(newValue, forKey: Key.tvHost); onChange?() }
    }

    /// Panel off (not full standby) whenever Wakey blanks the displays, and back on when they wake.
    var tvFollowDisplays: Bool {
        get { defaults.object(forKey: Key.tvFollowDisplays) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.tvFollowDisplays); onChange?() }
    }

    /// Full standby when the Mac sleeps (needs the TV's Wake on LAN setting), otherwise panel off.
    var tvPowerOffOnSleep: Bool {
        get { defaults.object(forKey: Key.tvPowerOffOnSleep) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.tvPowerOffOnSleep); onChange?() }
    }

    /// HDMI input the Mac is plugged into, e.g. `HDMI_2`.
    var tvInput: String {
        get { defaults.string(forKey: Key.tvInput) ?? "HDMI_2" }
        set { defaults.set(newValue, forKey: Key.tvInput); onChange?() }
    }

    /// Route the Mac's volume keys (when the TV is the audio output) and brightness keys
    /// (when the TV is the main display) to the TV. Needs Accessibility.
    var tvMediaKeys: Bool {
        get { defaults.object(forKey: Key.tvMediaKeys) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.tvMediaKeys); onChange?() }
    }

    /// Double-tap Control to draw the find-my-cursor pulse.
    var cursorFinder: Bool {
        get { defaults.object(forKey: Key.cursorFinder) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.cursorFinder); onChange?() }
    }

    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }

    // MARK: - Macro keys

    /// The four top-right keys on the K5 Max emit F13–F16; each can send a recorded shortcut.
    /// Stored as JSON data so a key name containing punctuation survives the round trip.
    func macroShortcut(for index: Int) -> KeyShortcut? {
        guard (1...5).contains(index),
              let data = defaults.data(forKey: "macroShortcut\(index)") else { return nil }
        return try? JSONDecoder().decode(KeyShortcut.self, from: data)
    }

    func setMacroShortcut(_ shortcut: KeyShortcut?, for index: Int) {
        guard (1...5).contains(index) else { return }
        let key = "macroShortcut\(index)"
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        onChange?()
    }

    var hasMacroShortcuts: Bool {
        (1...5).contains { macroShortcut(for: $0) != nil }
    }

    // MARK: - System key remapping

    var keyRemapEnabled: Bool {
        get { defaults.object(forKey: "keyRemapEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "keyRemapEnabled"); onChange?() }
    }

    var keyRemappings: [KeyRemap] {
        guard let data = defaults.data(forKey: "keyRemappings"),
              let mappings = try? JSONDecoder().decode([KeyRemap].self, from: data) else {
            return []
        }
        return mappings
    }

    func setKeyRemappings(_ mappings: [KeyRemap]) {
        if mappings.isEmpty {
            defaults.removeObject(forKey: "keyRemappings")
        } else if let data = try? JSONEncoder().encode(mappings) {
            defaults.set(data, forKey: "keyRemappings")
        }
        onChange?()
    }
}
