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
        let at: Date

        /// The keyboard only pushes while on 2.4 GHz; anything older than this is stale.
        var isFresh: Bool { Date().timeIntervalSince(at) < 30 }

        var summary: String {
            String(format: "%d%% · %.2f V · %@", percent, Double(voltageMV) / 1000.0, charging.label)
        }
    }

    var onReading: ((Reading) -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var latest: Reading?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    // MARK: - lifecycle

    func start() {
        guard manager == nil else { return }

        let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(hid, [
            kIOHIDVendorIDKey as String: 0x3434,
            kIOHIDPrimaryUsagePageKey as String: 0xFF60,
            kIOHIDPrimaryUsageKey as String: 0x61,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(hid, keychronInput, context)
        IOHIDManagerRegisterDeviceMatchingCallback(hid, keychronMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hid, keychronRemoved, context)
        IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let opened = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = hid
        onStatus?(opened == kIOReturnSuccess
                  ? "raw-HID listener opened"
                  : "raw-HID listener failed to open (\(opened))")
    }

    func stop() {
        if let hid = manager {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        device = nil
    }

    // MARK: - callbacks

    fileprivate func handleInput(_ bytes: [UInt8]) {
        guard bytes.count >= 6, bytes[0] == 0xA4 else { return }

        let percent = min(100, Int(bytes[1]))
        let millivolts = Int(bytes[2]) | Int(bytes[3]) << 8
        let charging = Charging(rawValue: bytes[4]) ?? .notCharging
        let reading = Reading(percent: percent, voltageMV: millivolts,
                              charging: charging, transport: bytes[5], at: Date())
        latest = reading
        onReading?(reading)
    }

    fileprivate func deviceAdded() {
        onStatus?("keyboard raw HID present")
    }

    fileprivate func deviceRemoved() {
        onStatus?("keyboard raw HID gone")
        latest = nil
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
    Unmanaged<KeychronBattery>.fromOpaque(context).takeUnretainedValue().deviceAdded()
}

private func keychronRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                             device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<KeychronBattery>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
}
