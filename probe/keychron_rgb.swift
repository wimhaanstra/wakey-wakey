// keychron_rgb.swift — talk to the keyboard's RGB command group (raw HID 0xA8).
//
// Protocol from Keychron's firmware (keyboards/keychron/common/rgb/keychron_rgb.c):
//   report: [0xA8, <subcommand>, ...params]   (32-byte raw HID report, id 0)
//   reply:  same buffer, data[2] = 0 on success / 1 on failure, payload from data[3]
//
//   0x01 RGB_GET_PROTOCOL_VER   -> version lo/hi
//   0x05 RGB_GET_LED_COUNT      -> LED count
//   0x07 PER_KEY_RGB_GET_TYPE   -> current per-key effect type
//   0x08 PER_KEY_RGB_SET_TYPE   -> 0 solid, 1 breathing, 2 reactive, 3 reactive wide, 4 splash
//   0x09 PER_KEY_RGB_GET_COLOR  -> start/count then HSV triples
//   0x0A PER_KEY_RGB_SET_COLOR  -> data[2]=start, data[3]=count (<=9), then HSV triples
//   0x02 RGB_SAVE               -> persist to EEPROM
//
// IMPORTANT: this only works with the keyboard connected by USB. Over the 2.4 GHz dongle the link
// is one-way (keyboard -> host); host commands are never forwarded and time out silently.
//
//   swift probe/keychron_rgb.swift info
//   swift probe/keychron_rgb.swift set 10 1 0 255 200    # LED 10 -> red
//   swift probe/keychron_rgb.swift type 0                # per-key solid
//   swift probe/keychron_rgb.swift save
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

var inbox: [[UInt8]] = []
let callback: IOHIDReportCallback = { _, _, _, _, _, r, n in
    inbox.append(Array(UnsafeBufferPointer(start: r, count: n)))
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

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
    print("no Keychron raw-HID interface found"); exit(2)
}

// Prefer the wired keyboard (0x0a50) over the dongle (0xd030): only the wired link is two-way.
let donglePID = 0xd030
let sorted = devices.sorted { a, b in
    let pa = IOHIDDeviceGetProperty(a, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let pb = IOHIDDeviceGetProperty(b, kIOHIDProductIDKey as CFString) as? Int ?? 0
    return (pa == donglePID ? 1 : 0) < (pb == donglePID ? 1 : 0)
}
for device in devices {
    let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    print("candidate: \(product) pid=0x\(String(pid, radix: 16))\(pid == donglePID ? " (dongle — one-way)" : "")")
}
let device = sorted[0]
_ = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))

func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// Sends a 0xA8 command and returns the reply payload, ignoring battery pushes.
@discardableResult
func rgb(_ subcommand: UInt8, _ params: [UInt8] = [], wait: TimeInterval = 1.0) -> [UInt8]? {
    inbox.removeAll()
    var report = [UInt8](repeating: 0, count: 32)
    report[0] = 0xA8
    report[1] = subcommand
    for (i, byte) in params.enumerated() where i + 2 < 32 { report[i + 2] = byte }

    let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &report, report.count)
    guard result == kIOReturnSuccess else {
        print("  write failed (\(result))")
        return nil
    }

    let deadline = Date().addingTimeInterval(wait)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        while !inbox.isEmpty {
            let reply = inbox.removeFirst()
            if reply.first == 0xA4 { continue }          // battery push, not a reply
            if reply.first == 0xA8 { return reply }      // our answer
        }
    }
    return nil
}

func describe(_ reply: [UInt8]?) {
    guard let reply else { print("  no reply (keyboard not on USB?)"); return }
    print("  reply: \(hx(Array(reply.prefix(12))))  ok=\(reply.count > 2 && reply[2] == 0)")
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "info" : args.removeFirst()

switch command {
case "info":
    print("RGB protocol version:")
    if let reply = rgb(0x01) {
        describe(reply)
        if reply.count > 4 { print("  version \(UInt16(reply[3]) | UInt16(reply[4]) << 8)") }
    } else {
        print("  no reply")
    }
    print("LED count:")
    if let reply = rgb(0x05) {
        describe(reply)
        if reply.count > 3 { print("  LEDs: \(reply[3])") }
    } else {
        print("  no reply")
    }

case "get":
    guard args.count >= 2, let start = UInt8(args[0]), let count = UInt8(args[1]) else {
        print("usage: get <start> <count 1-9>"); exit(1)
    }
    if let reply = rgb(0x09, [start, count]) {
        describe(reply)
        for i in 0..<Int(count) where reply.count > 4 + i * 3 {
            print(String(format: "  LED %d: h=%d s=%d v=%d", Int(start) + i,
                         reply[3 + i * 3], reply[4 + i * 3], reply[5 + i * 3]))
        }
    } else {
        print("  no reply")
    }

case "get-type":
    if let reply = rgb(0x07) {
        describe(reply)
        if reply.count > 3 { print("  per-key type: \(reply[3])") }
    } else {
        print("  no reply")
    }

case "type":
    guard let value = args.first.flatMap({ UInt8($0) }) else { print("usage: type <0-4>"); exit(1) }
    describe(rgb(0x08, [value]))

case "set":
    // set <start> <count 1-9> <hue> <sat> <val>
    guard args.count >= 5,
          let start = UInt8(args[0]), let count = UInt8(args[1]),
          let h = UInt8(args[2]), let s = UInt8(args[3]), let v = UInt8(args[4])
    else { print("usage: set <start> <count 1-9> <hue 0-255> <sat 0-255> <val 0-255>"); exit(1) }
    var params: [UInt8] = [start, count]
    for _ in 0..<Int(count) { params += [h, s, v] }
    describe(rgb(0x0A, params))

case "save":
    describe(rgb(0x02))

default:
    print("commands: info | type <0-4> | set <idx> <h> <s> <v> | save")
}
