// Identifies the paired device: name (feature 0x0005) and type, per the Linux kernel's
// HIDPP_PAGE_GET_DEVICE_NAME_TYPE protocol.
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

var swId: UInt8 = 0
enum Reply { case params([UInt8]); case hidppError(UInt8); case timeout }

func call(_ devIdx: UInt8, _ feature: UInt8, _ function: UInt8, params: [UInt8] = []) -> Reply {
    swId = (swId % 15) + 1
    var req: [UInt8] = [0x10, devIdx, feature, (function << 4) | swId] + params
    while req.count < 7 { req.append(0) }
    inbox.removeAll()
    guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x10, &req, req.count) == kIOReturnSuccess else { return .timeout }
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        while !inbox.isEmpty {
            let r = inbox.removeFirst()
            guard r.count >= 7, r[1] == devIdx, r[3] & 0x0f == swId else { continue }
            if r[2] == 0x8F { return .hidppError(r[4]) }
            guard r[2] == feature else { continue }
            return .params(Array(r[4...]))
        }
    }
    return .timeout
}

func featureIndex(_ devIdx: UInt8, _ id: UInt16) -> UInt8? {
    if case .params(let p) = call(devIdx, 0x00, 0x00, params: [UInt8(id >> 8), UInt8(id & 0xff), 0x00]), p[0] != 0 {
        return p[0]
    }
    return nil
}

for devIdx: UInt8 in [1, 2, 3, 4, 5, 6] {
    guard let battery = featureIndex(devIdx, 0x1001) else { continue }
    print("device index \(devIdx): battery feature 0x\(String(battery, radix: 16))")

    guard let nameFeature = featureIndex(devIdx, 0x0005) else {
        print("  no 0x0005 name feature")
        continue
    }
    print("  name feature index 0x\(String(nameFeature, radix: 16))")

    guard case .params(let countReply) = call(devIdx, nameFeature, 0x00), let length = countReply.first, length > 0 else {
        print("  name length unavailable")
        continue
    }
    print("  name length: \(length)")

    var name: [UInt8] = []
    var index = 0
    while index < Int(length) {
        guard case .params(let chunk) = call(devIdx, nameFeature, 0x10, params: [UInt8(index)]), !chunk.isEmpty else { break }
        name.append(contentsOf: chunk.prefix(Int(length) - index))
        index += chunk.count
    }
    print("  NAME: '\(String(decoding: name, as: UTF8.self))'")

    if case .params(let t) = call(devIdx, nameFeature, 0x20) {
        print("  type: \(hx(t))  (first byte \(t.first ?? 0))")
    } else {
        print("  type: unavailable")
    }
}
