// keychron_rawhid.swift — talk to the keyboard through its QMK raw-HID interface (0xFF60/0x61),
// the same channel Keychron Launcher uses: 32-byte reports, report id 0, command in byte 0.
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
func ascii(_ b: [UInt8]) -> String {
    String(bytes: b.filter { $0 >= 0x20 && $0 < 0x7f }, encoding: .ascii) ?? ""
}

var gInbox: [[UInt8]] = []
let cb: IOHIDReportCallback = { _, _, _, _, _, r, n in
    gInbox.append(Array(UnsafeBufferPointer(start: r, count: n)))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0x3434,
    kIOHIDPrimaryUsagePageKey as String: 0xFF60,
    kIOHIDPrimaryUsageKey as String: 0x61,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerRegisterInputReportCallback(manager, cb, nil)
_ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let dev = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    print("no QMK raw HID interface (0xFF60/0x61) — is the dongle in?")
    exit(2)
}
_ = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
print("raw HID opened; max in=\(IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1) max out=\(IOHIDDeviceGetProperty(dev, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? -1)")

func spin(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

func send(_ command: UInt8, args: [UInt8] = []) -> [[UInt8]] {
    gInbox.removeAll()
    var payload = [UInt8](repeating: 0, count: 32)
    payload[0] = command
    for (i, b) in args.enumerated() where i + 1 < 32 { payload[i + 1] = b }

    let result = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &payload, payload.count)
    spin(0.7)
    if result != kIOReturnSuccess { print(String(format: "cmd 0x%02x: write failed (%d)", command, result)) }
    return gInbox
}

// Commands Launcher actually used, plus their neighbours.
for command: UInt8 in [0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB0] {
    let replies = send(command)
    if replies.isEmpty {
        print(String(format: "cmd 0x%02x → no reply", command))
        continue
    }
    for reply in replies {
        print(String(format: "cmd 0x%02x → %@   |ascii: %@|", command, hx(reply), ascii(reply)))
    }
}
