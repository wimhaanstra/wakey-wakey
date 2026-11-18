// keychron_send.swift — replay a raw report against the Keychron dongle's vendor interface.
//
// Used after capturing Keychron Launcher's WebHID traffic (tools/capture-keychron-hid.js): paste the
// bytes here to see whether Wakey can produce the same reply without a browser.
//
//   swift probe/keychron_send.swift b2 06 00 00
//   swift probe/keychron_send.swift --feature 51
//
// First argument is the report id in hex; the rest are payload bytes in hex.
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, let reportID = UInt8(args.removeFirst(), radix: 16) else {
    print("usage: keychron_send.swift <reportIdHex> [payloadHexBytes…]")
    print("example: swift probe/keychron_send.swift b2 06 00")
    exit(1)
}
var payload: [UInt8] = []
for arg in args {
    guard let byte = UInt8(arg, radix: 16) else { print("bad byte '\(arg)'"); exit(1) }
    payload.append(byte)
}

var gInbox: [[UInt8]] = []
let cb: IOHIDReportCallback = { _, _, _, _, _, r, n in
    gInbox.append(Array(UnsafeBufferPointer(start: r, count: n)))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0x3434,
    kIOHIDPrimaryUsagePageKey as String: 0x8C,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerRegisterInputReportCallback(manager, cb, nil)
_ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let dev = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    print("no Keychron vendor interface (is the dongle plugged in?)")
    exit(2)
}
_ = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))

func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

var report = payload
let result = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportID), &report, report.count)
print("→ output 0x\(String(reportID, radix: 16)) [\(hx(payload))] len=\(payload.count) -> \(result == 0 ? "ok" : "error \(result)")")

spin(2.0)
if gInbox.isEmpty {
    print("← no reply")
} else {
    for reply in gInbox {
        print("← input: \(hx(reply))")
        if reply.count > 20 {
            let status = reply[20]
            print("        byte20=0x\(String(status, radix: 16)) → percent \(127 & status), charging \((status >> 7) != 0)")
        }
    }
}
