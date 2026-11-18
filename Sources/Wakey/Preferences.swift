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

    var hasSeenWelcome: Bool {
        get { defaults.bool(forKey: Key.welcomed) }
        set { defaults.set(newValue, forKey: Key.welcomed) }
    }
}
