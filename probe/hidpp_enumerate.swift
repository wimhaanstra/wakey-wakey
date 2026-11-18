// Probe v3: full feature enumeration + device identity + charging-relevant extras.
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

/// params may be 3 bytes (short) or up to 16 (long, report 0x11)
func request(feature: UInt8, function: UInt8, params: [UInt8] = []) -> [UInt8]? {
    swId = (swId % 15) + 1
    let isLong = params.count > 3
    let reportID: CFIndex = isLong ? 0x11 : 0x10
    var req: [UInt8] = [UInt8(reportID), DEV, feature, (function << 4) | swId]
    req += params
    let total = isLong ? 20 : 7
    while req.count < total { req.append(0) }
    let before = inbox.count
    guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, &req, req.count) == kIOReturnSuccess else {
        print("setReport failed"); return nil
    }
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        while inbox.count > before {
            let r = inbox.removeFirst()
            guard r.count >= 7, r[1] == DEV, (r[3] & 0x0f) == swId else { continue }
            if r[2] == 0x8F { return nil }
            return Array(r[4...])
        }
    }
    return nil
}

func idx(_ id: UInt16) -> UInt8? {
    guard let p = request(feature: 0x00, function: 0x00, params: [UInt8(id >> 8), UInt8(id & 0xff), 0x00]) else { return nil }
    return p[0] == 0 ? nil : p[0]
}

// ---- 1. Enumerate ALL features via FEATURE_SET ----
print("=== FEATURE_SET enumeration ===")
var allFeatures: [(UInt8, UInt16)] = []
if let fs = idx(0x0001) {
    if let p = request(feature: fs, function: 0x00) {
        let count = Int(p[0])
        print("feature count: \(count)")
        for i in 1...max(count, 1) {
            guard let q = request(feature: fs, function: 0x01, params: [UInt8(i), 0x00, 0x00]) else { continue }
            let fid = UInt16(q[0]) << 8 | UInt16(q[1])
            let typ = q.count > 2 ? q[2] : 0
            allFeatures.append((UInt8(i), fid))
            print(String(format: "  index 0x%02x  feature 0x%04x  type 0x%02x  visible=%d", i, fid, typ, typ & 1))
        }
    }
}

// ---- 2. Device identity ----
print("\n=== identity ===")
if let dn = idx(0x0003) {
    if let p = request(feature: dn, function: 0x00, params: [0x20, 0x00, 0x00]) {
        let s = String(bytes: p.filter { $0 != 0 }, encoding: .utf8) ?? ""
        print("device name: '\(s)'   raw=\(hx(p))")
    }
    if let p = request(feature: dn, function: 0x01, params: [0x00, 0x00, 0x00]) {
        print("device type: \(hx(p))")
    }
}

print("\n=== battery (0x1001) live ===")
if let b = idx(0x1001), let p = request(feature: b, function: 0x00) {
    print("  level=\(p[0]) next=\(p[1]) status=0x\(String(p[2], radix: 16))")
}

// ---- 3. 0x1e00 exploration (unknown, at index from earlier run) ----
print("\n=== 0x1e00 exploration ===")
if let u = idx(0x1e00) {
    print("  index 0x\(String(u, radix: 16))")
    for f: UInt8 in 0...3 {
        if let p = request(feature: u, function: f) {
            print("  func \(f) -> \(hx(p))")
        } else {
            print("  func \(f) -> error")
        }
    }
}

// ---- 4. firmware / unit id, for sanity ----
print("\n=== 0x0007 / 0x0003 extras ===")
for fid: UInt16 in [0x0000, 0x0003, 0x1001] {
    if let i = idx(fid), let p = request(feature: i, function: 0x01) {
        print(String(format: "  feat 0x%04x idx 0x%02x func1 -> %@", fid, i, hx(p)))
    }
}
print("\nDONE")
