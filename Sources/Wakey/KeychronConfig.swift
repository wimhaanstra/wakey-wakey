import Foundation
import IOKit.hid

/// Reads and writes the keyboard's LED idle timeout with raw-HID command `0xA5`.
///
/// This only works over **USB**. On 2.4 GHz the dongle does not bridge host → keyboard traffic at all
/// (see `KeychronBattery`), so there is nothing to send: the keyboard is configured by wire, and the
/// value then applies on every transport because it lives in EEPROM.
enum KeychronConfigResult {
    case ok(Int)
    /// No wired keyboard on the raw-HID interface — only the one-way dongle.
    case noDevice
    /// A keyboard was present but did not answer; usually the firmware predates command 0xA5.
    case noReply
}

enum KeychronConfig {
    private static let vendorID = 0x3434

    /// "Keychron Link" — receives nothing, so it is never the device we ask.
    private static let donglePID = 0xd030

    private static let command: UInt8 = 0xA5
    private static let replyTimeout: TimeInterval = 0.6

    static func readIdleTimeout() -> KeychronConfigResult { request(seconds: nil) }

    static func writeIdleTimeout(_ seconds: Int) -> KeychronConfigResult {
        request(seconds: max(0, min(seconds, 3600)))
    }

    /// Command framing matches the RGB group: status in `data[2]`, payload from `data[3]`.
    private static func request(seconds: Int?) -> KeychronConfigResult {
        var result = KeychronConfigResult.noReply
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = requestSync(seconds: seconds)
            done.signal()
        }
        done.wait()
        return result
    }

    private final class Box {
        var reply: [UInt8]?
        var status: UInt8 = 0xFF
    }

    private static func requestSync(seconds: Int?) -> KeychronConfigResult {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDPrimaryUsagePageKey as String: 0xFF60,
            kIOHIDPrimaryUsageKey as String: 0x61,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let box = Box()
        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            guard bytes.count > 4, bytes[0] == 0xA5 else { return }
            box.reply = bytes
            box.status = bytes[2]
        }
        IOHIDManagerRegisterInputReportCallback(manager, callback, Unmanaged.passUnretained(box).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return .noDevice }
        let wired = devices.first { device in
            let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            return pid != donglePID
        }
        guard let wired else { return .noDevice }

        IOHIDDeviceOpen(wired, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDDeviceClose(wired, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var report = [UInt8](repeating: 0, count: 32)
        report[0] = command
        report[1] = seconds == nil ? 0x01 : 0x02
        if let seconds {
            report[3] = UInt8(seconds & 0xFF)
            report[4] = UInt8((seconds >> 8) & 0xFF)
        }

        let sent = IOHIDDeviceSetReport(wired, kIOHIDReportTypeOutput, 0, &report, report.count)
        guard sent == kIOReturnSuccess else { return .noReply }

        let deadline = Date().addingTimeInterval(replyTimeout)
        while box.reply == nil && Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, true)
        }

        guard let reply = box.reply, box.status == 0 else { return .noReply }
        return .ok(Int(reply[3]) | Int(reply[4]) << 8)
    }
}
