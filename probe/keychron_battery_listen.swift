// keychron_battery_listen.swift — read the battery reports the patched K5 Max pushes over 2.4 GHz.
//
// The patched firmware sends raw-HID report 0xA4 every ~2 s while connected through the dongle:
//   [0] 0xA4
//   [1] battery percentage (0-100)
//   [2..3] battery voltage in mV, little endian
//   [4] charging state: 0 = not charging, 1 = charging, 2 = full
//   [5] transport, from get_transport()
//
// The dongle does not bridge host -> keyboard raw HID, so this only ever listens; it never writes.
//
//   swift probe/keychron_battery_listen.swift [seconds]
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let seconds = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 15) : 15

var inbox: [[UInt8]] = []
let callback: IOHIDReportCallback = { _, _, _, _, _, report, length in
    inbox.append(Array(UnsafeBufferPointer(start: report, count: length)))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0x3434,
    kIOHIDPrimaryUsagePageKey as String: 0xFF60,
    kIOHIDPrimaryUsageKey as String: 0x61,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerRegisterInputReportCallback(manager, callback, nil)
_ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    print("no Keychron raw-HID interface (0xFF60/0x61) — dongle plugged in?")
    exit(2)
}
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
print("listening \(Int(seconds)) s for 0xA4 battery pushes… (keyboard must be on 2.4 GHz)")

let deadline = Date().addingTimeInterval(seconds)
func timeStamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}
let started = Date()
var seen = 0
while Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    while !inbox.isEmpty {
        let report = inbox.removeFirst()
        guard report.count > 5 else { continue }
        if report[0] == 0xA4 {
            seen += 1
            let percent = Int(report[1])
            let millivolts = Int(report[2]) | Int(report[3]) << 8
            let charging = report[4]
            let transport = report[5]
            let state = charging == 0 ? "not charging" : (charging == 1 ? "charging" : "full")
            print(String(format: "%@ t+%3.0fs  0xA4  %3d%%  %4d mV  %@  transport=0x%02x",
                         timeStamp(), Date().timeIntervalSince(started), percent, millivolts, state, transport))
        } else if report[0] == 0xA6, report.count > 6 {
            // wakey_debug_push: idle timeout + live state machine, pushed over 2.4 GHz
            let idle = Int(report[1]) | Int(report[2]) << 8
            let keyEvents = Int(report[7]) | Int(report[8]) << 8
            print(String(format: "%@ t+%3.0fs  0xA6  idle=%3ds  sinceKey=%3ds  matrixEnabled=%d  dimmedByUs=%d  transport=0x%02x  keyEvents=%d  lastKey=0x%02x  sleepPath=%d  lpmPath=%d  drvOff=%d",
                         timeStamp(), Date().timeIntervalSince(started),
                         idle, Int(report[3]), Int(report[4]), Int(report[5]), Int(report[6]),
                         keyEvents, Int(report[9]), Int(report[10]), Int(report[11]), Int(report[12])))
        } else if seen == 0 {
            print("(other report: \(hx(Array(report.prefix(12)))))")
        }
    }
}

print(seen == 0 ? "no 0xA4 report seen" : "received \(seen) battery report(s)")
