// Probe v2: locate battery/charging features on the paired device and read their current values.
import Foundation
import IOKit.hid

func hx(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [
    kIOHIDVendorIDKey as String: 0x046d,
    kIOHIDPrimaryUsagePageKey as String: 0xFF00,
    kIOHIDPrimaryUsageKey as String: 0x0001,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

var inbox: [[UInt8]] = []
let cb: IOHIDReportCallback = { _, _, _, _, _, report, length in
    inbox.append(Array(UnsafeBufferPointer(start: report, count: length)))
}
IOHIDManagerRegisterInputReportCallback(manager, cb, nil)
_ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard let dev = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else {
    print("no HID++ interface"); exit(2)
}

let DEV: UInt8 = 0x01
var swId: UInt8 = 1

func spin(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

/// Sends a HID++2.0 short request, returns the reply params (bytes 4...) or nil.
func request(feature: UInt8, function: UInt8, params: [UInt8] = []) -> (UInt8, UInt8, [UInt8])? {
    swId = (swId % 15) + 1
    var req: [UInt8] = [0x10, DEV, feature, (function << 4) | swId]
    req += Array(params.prefix(3))
    while req.count < 7 { req.append(0) }
    let before = inbox.count
    guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x10, &req, req.count) == kIOReturnSuccess else {
        print("  setReport failed"); return nil
    }
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        while inbox.count > before {
            let r = inbox.removeFirst()
            // match reply: same swId, our feature index, non-error
            guard r.count >= 7, r[1] == DEV, (r[3] & 0x0f) == swId else { continue }
            if r[2] == 0x8F {
                print("  ERR code=0x\(String(r[4], radix: 16)) feature=0x\(String(r[5], radix: 16)) for req feat 0x\(String(feature, radix: 16))")
                return nil
            }
            return (r[2], r[3] >> 4, Array(r[4...]))
        }
    }
    return nil
}

// Resolve feature index from feature ID
var featureIndex: [UInt16: UInt8] = [:]
func indexOf(_ id: UInt16) -> UInt8? {
    if let k = featureIndex[id] { return k }
    guard let (_, _, p) = request(feature: 0x00, function: 0x00, params: [UInt8(id >> 8), UInt8(id & 0xff), 0x00]) else { return nil }
    let idx = p[0]
    if idx != 0 { featureIndex[id] = idx }
    return idx != 0 ? idx : nil
}

print("=== feature discovery ===")
let wanted: [(UInt16, String)] = [
    (0x0000, "ROOT"), (0x0001, "FEATURE_SET"), (0x0002, "FEATURE_INFO"),
    (0x0003, "DEVICE_NAME"), (0x0005, "RESET"), (0x0007, "FIRMWARE"),
    (0x1000, "BATTERY_VOLTAGE"), (0x1001, "BATTERY_LEVEL_STATUS"),
    (0x1004, "UNIFIED_BATTERY"), (0x1814, "REPORT_RATE"),
    (0x1816, "??"), (0x1e00, "??"), (0x1815, "??"),
]
for (id, name) in wanted {
    let idx = indexOf(id)
    let ids = String(format: "0x%04x", id)
    let idxs = idx.map { String(format: "0x%02x", $0) } ?? "ABSENT"
    print("\(ids) \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) -> \(idxs)")
}

print("\n=== device name ===")
if let idx = indexOf(0x0003), let (_, _, p) = request(feature: idx, function: 0x00) {
    let s = String(bytes: p.filter { $0 != 0 }, encoding: .utf8) ?? "?"
    print("name: \(s)")
}

print("\n=== unified battery (0x1004) ===")
if let idx = indexOf(0x1004) {
    if let (_, _, caps) = request(feature: idx, function: 0x00) {
        print("capabilities: \(hx(caps))  (bit0 rechargeable=\(caps[0] & 1))")
    }
    if let (_, _, st) = request(feature: idx, function: 0x01) {
        print("status: \(hx(st))")
    }
}

print("\n=== battery level status (0x1001) ===")
if let idx = indexOf(0x1001) {
    if let (_, _, p) = request(feature: idx, function: 0x00) {
        print("getBatteryLevelStatus: \(hx(p))")
        print("  dischargeLevel(%%)=\(p[0])  status=0x\(String(p[1], radix: 16))  flags=0x\(p.count > 2 ? String(p[2], radix: 16) : "-")")
    }
}

print("\n=== battery voltage (0x1000) ===")
if let idx = indexOf(0x1000) {
    if let (_, _, p) = request(feature: idx, function: 0x00) {
        let mv = Int(p[0]) << 8 | Int(p[1])
        print("getBatteryVoltage: \(hx(p))  -> \(mv) mV, flags=0x\(p.count > 2 ? String(p[2], radix: 16) : "-")")
    }
}

print("\n=== report rate (0x1814) ===")
if let idx = indexOf(0x1814), let (_, _, p) = request(feature: idx, function: 0x00) {
    print("getReportRate: \(hx(p))")
}

print("\n=== generic polling test: 0x1000 twice, 2s apart (is value live?) ===")
if let idx = indexOf(0x1000) {
    for i in 0..<3 {
        if let (_, _, p) = request(feature: idx, function: 0x00) {
            print("  poll \(i): \(hx(p))")
        }
        spin(2.0)
    }
}
print("\nDONE")
