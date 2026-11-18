// Throwaway probe: can we talk HID++ 2.0 to the Logitech receiver and read battery/charging?
// Build/run:  swift probe/hidpp_probe.swift
import Foundation
import IOKit.hid

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

var responses: [[UInt8]] = []

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let match: [String: Any] = [
    kIOHIDVendorIDKey as String: 0x046d,
    kIOHIDPrimaryUsagePageKey as String: 0xFF00,
    kIOHIDPrimaryUsageKey as String: 0x0001,
]
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let inputCb: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    responses.append(bytes)
    print("  IN  id=\(reportID) len=\(length): \(hex(bytes))")
}
IOHIDManagerRegisterInputReportCallback(manager, inputCb, nil)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen -> \(openResult)")

guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devs.isEmpty else {
    print("RESULT: no 0x046d/0xFF00/1 HID++ interface present (mouse off? receiver unplugged?)")
    exit(2)
}

for dev in devs {
    let p = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "(?)"
    let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
    print("HID++ interface: product=\(p) pid=0x\(String(pid, radix: 16))")
}

guard let dev = devs.first else { exit(3) }

func send(_ payload: [UInt8], reportID: CFIndex) -> Bool {
    var buf = payload
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, &buf, buf.count)
    return r == kIOReturnSuccess
}

func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

// HID++ 2.0 short report: [0x10, devIndex, featureIndex, function<<4|swId, p0,p1,p2]
print("\n-- getProtocolVersion across device indexes --")
for idx: UInt8 in [0xFF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06] {
    let before = responses.count
    // root feature index 0x00, function 0x0 = getProtocolVersion
    let ok = send([0x10, idx, 0x00, 0x00, 0x00, 0x00, 0x00], reportID: 0x10)
    spin(0.4)
    let got = responses.count > before
    print(String(format: "idx 0x%02x setReport=%d reply=%d", idx, ok ? 1 : 0, got ? 1 : 0))
    if ok, !got {
        // some stacks expect the report ID inside the buffer
        var buf: [UInt8] = [0x10, idx, 0x00, 0x00, 0x00, 0x00, 0x00]
        let r2 = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x00, &buf, buf.count)
        spin(0.4)
        if responses.count > before {
            print(String(format: "  -> works with reportID=0 arg (ret=%d)", r2))
            break
        }
    }
}

print("\n-- dump: enumerate root features present --")
if let firstReply = responses.first, firstReply.count >= 7 {
    print("first reply parsed: devIndex=\(firstReply[1]) featureIndex=\(firstReply[2]) func=\(firstReply[3]>>4) swId=\(firstReply[3]&0x0f) params=\(hex(Array(firstReply[4...])))")
}

print("\nRESULT: replies=\(responses.count)")
exit(0)
