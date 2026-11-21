import Foundation
import IOKit.hid

/// Reads the battery state that the patched K5 Max firmware pushes over 2.4 GHz.
///
/// The keyboard sends raw-HID report 0xA4 every ~2 s while connected through its dongle:
///
///     [0] 0xA4
///     [1] battery percentage
///     [2..3] battery voltage in mV, little endian
///     [4] charging state: 0 not charging, 1 charging, 2 full
///     [5] transport flags (0x01 USB, 0x02 Bluetooth, 0x04 2.4 GHz)
///     [6..7] LED idle timeout in seconds (little-endian), added by the Wakey firmware
///
/// Nothing is ever written to the device: the dongle does not bridge host → keyboard raw HID, which
/// is exactly why the firmware pushes instead.
final class KeychronBattery {

    enum Charging: UInt8 {
        case notCharging = 0
        case charging = 1
        case full = 2

        var label: String {
            switch self {
            case .notCharging: return "not charging"
            case .charging: return "charging"
            case .full: return "full"
            }
        }
    }

    struct Reading {
        let percent: Int
        let voltageMV: Int
        let charging: Charging
        let transport: UInt8
        /// The keyboard's LED idle timeout, carried along with the push because a host → keyboard
        /// request cannot cross the 2.4 GHz link. `nil` on firmware that predates it.
        let idleTimeoutSeconds: Int?
        let at: Date

        /// The keyboard only pushes while awake; the board suspends when idle, so gaps are normal.
        var age: TimeInterval { Date().timeIntervalSince(at) }

        /// Fresh enough to trust for state that changes quickly, such as "charging".
        var isFresh: Bool { age < 30 }

        /// Still worth showing: the last percentage stays meaningful for a while, and dropping it to
        /// "no data" the moment the board sleeps made the menu bar look broken. Beyond half an hour we
        /// assume the keyboard is off rather than asleep.
        var isUsable: Bool { age < 1800 }

        var ageDescription: String {
            let seconds = Int(age)
            if seconds < 60 { return "just now" }
            if seconds < 3600 { return "\(seconds / 60)m ago" }
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m ago"
        }

        /// Summary with the age appended once the value is no longer live.
        var menuDescription: String {
            isFresh ? summary : "\(summary) — last seen \(ageDescription)"
        }

        var transportLabel: String {
            if transport & 0x01 != 0 { return "USB" }
            if transport & 0x04 != 0 { return "2.4G" }
            if transport & 0x02 != 0 { return "BT" }
            return String(format: "link 0x%02x", transport)
        }

        var summary: String {
            String(format: "%d%% · %.2f V · %@ · %@", percent, Double(voltageMV) / 1000.0,
                   charging.label, transportLabel)
        }
    }

    var onReading: ((Reading) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Fired when a *wired* keyboard appears: the only moment a host → keyboard request can land,
    /// so it is when the app refreshes settings that only exist on the device (the LED timeout).
    var onWiredKeyboard: (() -> Void)?

    private(set) var latest: Reading?

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var pullTimer: Timer?
    /// Counts pulls that produced no reply, so a stock keyboard can be reported as unpatched rather
    /// than silently showing nothing.
    private var pullsSinceReply = 0
    private var warnedUnpatched = false
    private var pullCount = 0

    /// The "Keychron Link" dongle: one-way, so pulling on it is pointless.
    private static let donglePID = 0xd030

    /// True when a Keychron is present but only as a plain keyboard — i.e. connected over Bluetooth,
    /// which exposes neither the raw-HID interface nor the vendor page the battery needs.
    private(set) var bluetoothOnly = false
    private var sawRawHID = false

    // MARK: - lifecycle

    func start() {
        guard manager == nil else { return }

        // Seed from the last run: the board sleeps when idle, so a freshly launched app can otherwise
        // show "no data" until you happen to touch a key.
        latest = Self.restoreLastReading()

        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Two matchers: the raw-HID interface we actually use, plus the plain keyboard interface so a
        // Bluetooth connection can be recognised and explained rather than looking like a dead app.
        IOHIDManagerSetDeviceMatchingMultiple(hid, [
            [
                kIOHIDVendorIDKey as String: 0x3434,
                kIOHIDPrimaryUsagePageKey as String: 0xFF60,
                kIOHIDPrimaryUsageKey as String: 0x61,
            ],
            [
                kIOHIDVendorIDKey as String: 0x3434,
                kIOHIDPrimaryUsagePageKey as String: 1,
                kIOHIDPrimaryUsageKey as String: 6,
            ],
        ] as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(hid, keychronInput, context)
        IOHIDManagerRegisterDeviceMatchingCallback(hid, keychronMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, keychronRemoved, context)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let opened = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid

        // Wired keyboards answer a pull; the dongle only pushes. Polling costs one 32-byte report.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.pullWired() }
        RunLoop.main.add(timer, forMode: .common)
        pullTimer = timer
        onStatus?(opened == kIOReturnSuccess
                  ? "raw-HID listener opened"
                  : "raw-HID listener failed to open (\(opened))")
    }

    func stop() {
        pullTimer?.invalidate()
        pullTimer = nil
        if let hid = manager {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        devices.removeAll()
    }

    /// Asks each wired keyboard for the battery state; replies arrive on the input-report callback.
    private func pullWired() {
        var pulled = 0
        for device in devices {
            let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            guard pid != Self.donglePID else { continue }

            var report = [UInt8](repeating: 0, count: 32)
            report[0] = 0xA4
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &report, report.count)
            pulled += 1
        }

        if pulled > 0 {
            pullsSinceReply += 1
            // ~30 s of silence from a keyboard that is plainly plugged in: it does not know 0xA4.
            if pullsSinceReply == 6 && !warnedUnpatched {
                warnedUnpatched = true
                onStatus?("wired keyboard is not answering 0xA4 — battery reporting needs the Wakey firmware")
            }
        }

        // One line a minute, and only when a wired keyboard actually exists: proves the poll is alive
        // without drowning the log. On 2.4 GHz there is nothing to pull — the keyboard pushes instead.
        if pulled > 0 {
            pullCount += 1
            if pullCount % 12 == 0 { onStatus?("polled \(pulled) wired keyboard(s)") }
        }
    }

    // MARK: - callbacks

    // MARK: - persistence

    private static func persist(_ reading: Reading) {
        let defaults = UserDefaults.standard
        defaults.set(reading.percent, forKey: "keyboard.percent")
        defaults.set(reading.voltageMV, forKey: "keyboard.mV")
        defaults.set(Int(reading.charging.rawValue), forKey: "keyboard.charging")
        defaults.set(Int(reading.transport), forKey: "keyboard.transport")
        defaults.set(reading.at.timeIntervalSince1970, forKey: "keyboard.at")
        if let idle = reading.idleTimeoutSeconds {
            defaults.set(idle, forKey: "keyboard.idle")
        }
    }

    private static func restoreLastReading() -> Reading? {
        let defaults = UserDefaults.standard
        guard let stamp = defaults.object(forKey: "keyboard.at") as? Double else { return nil }
        let percent = defaults.integer(forKey: "keyboard.percent")
        guard percent > 0 else { return nil }
        return Reading(
            percent: percent,
            voltageMV: defaults.integer(forKey: "keyboard.mV"),
            charging: Charging(rawValue: UInt8(defaults.integer(forKey: "keyboard.charging"))) ?? .notCharging,
            transport: UInt8(defaults.integer(forKey: "keyboard.transport")),
            idleTimeoutSeconds: defaults.object(forKey: "keyboard.idle") as? Int,
            at: Date(timeIntervalSince1970: stamp))
    }

    fileprivate func handleInput(_ bytes: [UInt8]) {
        guard bytes.count >= 6, bytes[0] == 0xA4 else { return }

        let percent = min(100, Int(bytes[1]))
        let millivolts = Int(bytes[2]) | Int(bytes[3]) << 8
        let charging = Charging(rawValue: bytes[4]) ?? .notCharging
        // `bytes[8]` marks the field as present, so a legitimate 0 (never) is distinguishable from
        // firmware that simply does not send it yet.
        let idleTimeout = bytes.count > 8 && bytes[8] == 1 ? Int(bytes[6]) | Int(bytes[7]) << 8 : nil
        let reading = Reading(percent: percent, voltageMV: millivolts,
                              charging: charging, transport: bytes[5],
                              idleTimeoutSeconds: idleTimeout, at: Date())
        latest = reading
        Self.persist(reading)
        pullsSinceReply = 0
        warnedUnpatched = false
        onReading?(reading)
    }

    fileprivate func deviceAdded(_ device: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0

        // Presence-only matcher: no raw HID, so nothing to query — just explain why.
        guard usagePage == 0xFF60 else {
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            if !sawRawHID && transport.contains("Bluetooth") {
                bluetoothOnly = true
                onStatus?("\(product) is on Bluetooth — battery reporting needs 2.4 GHz or USB")
            }
            return
        }
        sawRawHID = true
        bluetoothOnly = false
        devices.append(device)
        pullsSinceReply = 0
        warnedUnpatched = false
        onStatus?(String(format: "keyboard interface present: %@ (pid 0x%02x)%@", product, pid,
                         pid == Self.donglePID ? " — dongle, push only" : " — wired, pull available"))
        if pid != Self.donglePID {
            var report = [UInt8](repeating: 0, count: 32)
            report[0] = 0xA4
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &report, report.count)
            onWiredKeyboard?()
        }
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        if usagePage != 0xFF60 { return }
        devices.removeAll { $0 == device }
        sawRawHID = false
        onStatus?("keyboard interface removed")
        if devices.isEmpty { latest = nil }
    }
}

// MARK: - C callbacks

private func keychronInput(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                           type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                           reportLength: CFIndex) {
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    Unmanaged<KeychronBattery>.fromOpaque(context).takeUnretainedValue().handleInput(bytes)
}

private func keychronMatched(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                             device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<KeychronBattery>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
}

private func keychronRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                             device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<KeychronBattery>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}
