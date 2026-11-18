// dock_calibration.swift — M0 of the Wakey plan, corrected.
//
// Feature 0x1001 is BATTERY_VOLTAGE (not battery level). Per the Linux kernel's
// hid-logitech-hidpp.c, getBatteryVoltage (function 0x00) returns 3 params:
//
//   params[0..1]  voltage in millivolts, big endian
//   params[2]     flags:
//                   bit 7      charging indicator
//                   bit 0..2   when bit7 set: 0=charging 1=full 2=not-charging
//                   bit 3      fast charge
//                   bit 4      trickle charge
//                   bit 5      critical level
//
//   swift probe/dock_calibration.swift          # 75 s
//   swift probe/dock_calibration.swift 600 out  # 10 min, CSV to out/charge.csv
//
// Read-only: never touches your displays. Needs no permissions.

import Foundation
import IOKit.hid

// MARK: - helpers

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}
func log(_ s: String) { print("[\(stamp())] \(s)"); fflush(stdout) }

let args = CommandLine.arguments
let duration = args.count > 1 ? (Double(args[1]) ?? 75) : 75
var csvHandle: FileHandle?

// MARK: - HID++ transport

let hidpp = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hidpp, [
    kIOHIDVendorIDKey as String: 0x046d,
    kIOHIDPrimaryUsagePageKey as String: 0xFF00,
    kIOHIDPrimaryUsageKey as String: 0x0001,
] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(hidpp, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

var inbox: [[UInt8]] = []
let hidppCB: IOHIDReportCallback = { _, _, _, _, _, report, length in
    inbox.append(Array(UnsafeBufferPointer(start: report, count: length)))
}
IOHIDManagerRegisterInputReportCallback(hidpp, hidppCB, nil)
_ = IOHIDManagerOpen(hidpp, IOOptionBits(kIOHIDOptionsTypeNone))

guard let dev = (IOHIDManagerCopyDevices(hidpp) as? Set<IOHIDDevice>)?.first else {
    print("No Lightspeed receiver with a HID++ interface found. Is the mouse on?")
    exit(2)
}
let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
log("receiver pid=0x\(String(pid, radix: 16))")

func spin(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

enum Reply {
    case params([UInt8])
    case hidppError(UInt8)      // 0x8f error code
    case timeout
}

var swId: UInt8 = 0
func call(_ devIdx: UInt8, _ feature: UInt8, _ function: UInt8, params: [UInt8] = []) -> Reply {
    swId = (swId % 15) + 1
    var req: [UInt8] = [0x10, devIdx, feature, (function << 4) | swId]
    req += params
    while req.count < 7 { req.append(0) }
    let before = inbox.count
    guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x10, &req, req.count) == kIOReturnSuccess else {
        return .hidppError(0xEE)
    }
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        while inbox.count > before, let r = inbox.first {
            inbox.removeFirst()
            guard r.count >= 7, r[1] == devIdx, (r[3] & 0x0f) == swId else { continue }
            if r[2] == 0x8F { return .hidppError(r[4]) }
            return .params(Array(r[4...]))
        }
    }
    return .timeout
}

// MARK: - find device + feature

func featureIndex(_ devIdx: UInt8, _ id: UInt16) -> UInt8? {
    if case .params(let p) = call(devIdx, 0x00, 0x00, params: [UInt8(id >> 8), UInt8(id & 0xff), 0x00]), p[0] != 0 {
        return p[0]
    }
    return nil
}

var deviceIndex: UInt8?
var feature: UInt8?
for candidate: UInt8 in [0x01, 0x02, 0x03, 0x04, 0x05, 0x06] {
    if let f = featureIndex(candidate, 0x1001) { deviceIndex = candidate; feature = f; break }
}
guard let devIdx = deviceIndex, let feat = feature else {
    print("No device exposing 0x1001 BATTERY_VOLTAGE."); exit(3)
}
log("device index 0x\(String(devIdx, radix: 16)), BATTERY_VOLTAGE at feature index 0x\(String(feat, radix: 16))")

// MARK: - interpretation

struct Reading {
    let voltage: Int
    let flags: UInt8
    var charging: Bool { flags & 0x80 != 0 }
    var state: String {
        guard charging else { return "discharging" }
        switch flags & 0x07 {
        case 0: return "charging"
        case 1: return "full"
        case 2: return "not-charging"
        default: return "error"
        }
    }
    var extras: String {
        var xs: [String] = []
        if flags & 0x08 != 0 { xs.append("fast") }
        if flags & 0x10 != 0 { xs.append("trickle") }
        if flags & 0x20 != 0 { xs.append("critical") }
        return xs.joined(separator: "+")
    }
    var line: String {
        String(format: "%d mV  flags=0x%02x  %@%@", voltage, flags, state,
               extras.isEmpty ? "" : " (\(extras))")
    }
    var isDock: Bool { charging }
}

// MARK: - CSV

if args.count > 2 {
    let path = args[2]
    try? "timestamp,epoch,voltage_mv,flags,charging,state,result\n".write(toFile: path, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: path, contents: nil)
    csvHandle = FileHandle(forWritingAtPath: path)
    csvHandle?.seekToEndOfFile()
    log("CSV → \(path)")
}

// MARK: - poll loop

var previous: Reading?
var lastState: String?
let start = Date()
log("watching \(Int(duration)) s — dock the mouse, wait, pick it up, dock it again")
print("")

let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
    let result: String
    var reading: Reading?
    switch call(devIdx, feat, 0x00) {
    case .params(let p) where p.count >= 3:
        reading = Reading(voltage: Int(p[0]) << 8 | Int(p[1]), flags: p[2])
        result = "ok"
    case .params:
        result = "short"
    case .hidppError(let code):
        result = String(format: "error 0x%02x", code)
    case .timeout:
        result = "timeout"
    }

    if let r = reading {
        let changed = previous?.flags != r.flags
        if changed || lastState == nil {
            log("POLL  \(r.line)")
            if let old = previous, old.state != r.state {
                log("      >>> STATE \(old.state) -> \(r.state)")
            }
        } else if Int(Date().timeIntervalSince(start)) % 10 < 2 {
            log("      steady: \(r.state)\(r.extras.isEmpty ? "" : " (\(r.extras))"), \(r.voltage) mV")
        }
        previous = r
        lastState = r.state
    } else {
        log("POLL  \(result) — no state change (errors are expected occasionally; RESOURCE_ERROR is normal)")
    }

    if let h = csvHandle {
        let epoch = Date().timeIntervalSince1970
        let row = "\(stamp()),\(epoch),\(reading?.voltage ?? -1),\(reading.map { String(format: "0x%02x", $0.flags) } ?? ""),\(reading?.charging ?? false),\(reading?.state ?? ""),\(result)\n"
        h.write(row.data(using: .utf8)!)
    }
}
RunLoop.current.add(timer, forMode: .default)

spin(duration)
timer.invalidate()
csvHandle?.closeFile()

print("")
log("=== summary ===")
if let p = previous {
    print("Final: \(p.line)")
    print(p.isDock ? "Verdict: ON the charger → flags bit 7 is set." : "Verdict: OFF the charger.")
} else {
    print("Never got a reading.")
}
