// Keychron dongle battery probe.
//
// Protocol reverse-engineered from voxors/KeyTray (keychronM6.go): on the dongle's vendor
// interface (usage page 0x8C) write report 0xb3 with payload [0x06, 0x00 …], then read the reply;
// byte 20 is  bit7 = charging, bits 0-6 = percentage.
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0x3434,
    kIOHIDPrimaryUsagePageKey as String: 0x8C,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

var inbound: [(UInt32, [UInt8])] = []
let cb: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    inbound.append((reportID, Array(UnsafeBufferPointer(start: report, count: length))))
}
IOHIDManagerRegisterInputReportCallback(manager, cb, nil)
let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> \(opened)")

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = devices.first else {
    print("no Keychron vendor interface at usage page 0x8C")
    exit(2)
}
let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
print("device: '\(product)' pid=0x\(String(pid, radix: 16))")

print("max output report size:", (IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int) ?? -1)
print("max input report size:", (IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? -1)

func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// Tries the two buffer conventions IOKit sees in the wild.
func attempt(reportID: CFIndex, includeIDInBuffer: Bool, label: String) {
    inbound.removeAll()
    var payload = [UInt8](repeating: 0, count: 63)
    payload[0] = 0x06
    var buffer = includeIDInBuffer ? [UInt8(truncatingIfNeeded: reportID)] + payload : payload

    let result = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, &buffer, buffer.count)
    spin(1.5)

    print("\n\(label): setReport(0x\(String(reportID, radix: 16)), \(buffer.count) bytes) -> \(result)")
    if inbound.isEmpty {
        print("  no reply")
    }
    for (id, bytes) in inbound.prefix(4) {
        print("  reply id=0x\(String(id, radix: 16)) len=\(bytes.count): \(hx(Array(bytes.prefix(28))))")
        if bytes.count > 20 {
            let status = bytes[20]
            print("  parsed: percent=\(127 & status) charging=\((status >> 7) != 0) (raw byte20=0x\(String(status, radix: 16)))")
        }
    }
}

attempt(reportID: 0xb3, includeIDInBuffer: false, label: "A: id separate")
attempt(reportID: 0xb3, includeIDInBuffer: true, label: "B: id in buffer")
attempt(reportID: 0xb3, includeIDInBuffer: false, label: "C: retry")
