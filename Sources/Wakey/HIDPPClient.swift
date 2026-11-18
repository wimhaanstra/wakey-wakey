import Foundation
import IOKit.hid

/// HID++ 2.0 transport for the Logitech Lightspeed receiver.
///
/// Runs its own thread with its own RunLoop: the manager, its callbacks and the poll loop all live
/// there, so the main run loop never blocks on a HID round trip.
///
/// The only feature we rely on is 0x1001 BATTERY_VOLTAGE, function 0x00:
///   params[0..1] = voltage in mV (big endian)
///   params[2]    = flags, bit 7 set means charging
final class HIDPPClient {

    struct Reading {
        let voltageMV: Int
        let flags: UInt8

        var isCharging: Bool { flags & 0x80 != 0 }

        var chargeState: String {
            guard isCharging else { return "discharging" }
            switch flags & 0x07 {
            case 0: return "charging"
            case 1: return "full"
            case 2: return "not charging"
            default: return "charge error"
            }
        }

        var extras: [String] {
            var out: [String] = []
            if flags & 0x08 != 0 { out.append("fast") }
            if flags & 0x10 != 0 { out.append("trickle") }
            if flags & 0x20 != 0 { out.append("critical") }
            return out
        }

        var volts: Double { Double(voltageMV) / 1000.0 }

        /// Derived from voltage — this device has no capacity feature. See BatteryEstimator.
        var estimatedPercent: Int? {
            BatteryEstimator.percent(forMillivolts: voltageMV, flags: flags)
        }
    }

    enum Failure: String, Error {
        case noDevice = "no device"
        case timeout = "timeout"
        case protocolError = "hid++ error"
        case reportFailed = "setReport failed"
    }

    struct DeviceSummary: Equatable {
        let slot: UInt8
        let batteryFeature: UInt8
        var label: String { String(format: "slot 0x%02x", slot) }
    }

    struct Inventory: Equatable {
        let receiverProduct: String
        let vendorID: Int
        let productID: Int
        let responders: [DeviceSummary]
        let active: DeviceSummary?

        private static func hex(_ value: Int) -> String {
            String(format: "%04x", value & 0xffff)
        }

        var receiverLabel: String {
            "\(receiverProduct) (\(Self.hex(vendorID)):\(Self.hex(productID)))"
        }
    }

    /// Delivered on the HID thread — hop to main before touching UI.
    var onReading: ((Result<Reading, Failure>) -> Void)?
    /// Which receiver and which paired-device slot we are listening to.
    var onInventory: ((Inventory) -> Void)?
    /// Human-readable receiver/device lifecycle events.
    var onDeviceEvent: ((String) -> Void)?

    private let pollInterval: TimeInterval

    private var thread: Thread?
    private var stopped = false
    private var cfRunLoop: CFRunLoop?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var devIndex: UInt8?
    private var featureIndex: UInt8?
    private var inbox: [[UInt8]] = []
    private var swId: UInt8 = 0
    private let stateLock = NSLock()
    private var preferredSlotValue: UInt8?
    private var rescanRequested = false
    private var fullScanRequested = false
    private var lastInventory: Inventory?
    private var discoveryFailures = 0
    private var pairedDeviceMisses = 0
    private var implausibleReadings = 0
    private var foreignReportsLogged = 0

    init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = pollInterval
    }

    /// User-selected paired-device slot. `nil` means "the first slot that answers".
    var preferredSlot: UInt8? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return preferredSlotValue }
        set { stateLock.lock(); preferredSlotValue = newValue; stateLock.unlock() }
    }

    /// Forces the next poll to re-enumerate the receiver and its paired slots.
    func rescan() {
        stateLock.lock()
        rescanRequested = true
        fullScanRequested = true
        stateLock.unlock()
    }

    private func consumeRescanRequest() -> (rescan: Bool, fullScan: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        let result = (rescanRequested, fullScanRequested)
        rescanRequested = false
        fullScanRequested = false
        return result
    }

    // MARK: - lifecycle

    func start() {
        guard thread == nil else { return }
        stopped = false
        let t = Thread { [weak self] in self?.runLoopMain() }
        t.name = "nl.sortedbits.wakey.hidpp"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    func stop() {
        stopped = true
        if let loop = cfRunLoop {
            CFRunLoopStop(loop)
            CFRunLoopWakeUp(loop)
        }
        thread = nil
    }

    private func runLoopMain() {
        cfRunLoop = CFRunLoopGetCurrent()
        setup()
        var nextPoll = Date()
        while !stopped {
            if Date() >= nextPoll {
                let started = Date()
                poll()
                // Schedule from the start of the cycle: a slow reply must not stretch the interval.
                nextPoll = max(started.addingTimeInterval(pollInterval),
                               Date().addingTimeInterval(0.2))
                continue
            }
            // Wait until the next poll, waking early only to service HID reports. Without this the
            // loop would poll on every inbound report, making the effective rate far higher than
            // pollInterval and shortening every debounce window.
            RunLoop.current.run(mode: .default, before: nextPoll)
        }
        teardown()
    }

    private func setup() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey as String: 0x046d,
            kIOHIDPrimaryUsagePageKey as String: 0xFF00,
            kIOHIDPrimaryUsageKey as String: 0x0001,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(m, hidppInput, context)
        IOHIDManagerRegisterDeviceMatchingCallback(m, hidppMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, hidppRemoved, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let opened = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        reportDeviceEvent("HID++ manager opened (result \(opened))")
        discover(fullScan: false)
    }

    private func teardown() {
        if let m = manager {
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        device = nil
        devIndex = nil
    }

    // MARK: - callbacks (invoked on the HID thread)

    fileprivate func handleInput(_ bytes: [UInt8]) {
        // We always use client ids 1…15, so a report with client id 0 is not ours. In practice it is
        // G HUB's own HID++ traffic (it polls the same receiver), which we must not mistake for a
        // device notification or let accumulate in the reply queue.
        guard bytes.count >= 4, bytes[3] & 0x0f != 0 else {
            if foreignReportsLogged < 10 {
                foreignReportsLogged += 1
                let feature = bytes.count > 2 ? bytes[2] : 0
                let note = feature == 0x8F ? "error reply" : "reply/notification"
                reportDeviceEvent(String(format: "foreign HID++ report (client id 0, %@) feature 0x%02x — ignoring",
                                         note, feature))
            }
            return
        }
        inbox.append(bytes)
        if inbox.count > 32 { inbox.removeFirst(inbox.count - 32) }
    }

    fileprivate func deviceAdded(_ dev: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? -1
        reportDeviceEvent("receiver attached (pid 0x\(String(pid, radix: 16)))")
        discover(fullScan: true)
    }

    fileprivate func deviceRemoved(_ dev: IOHIDDevice) {
        reportDeviceEvent("receiver detached — pausing until it comes back")
        device = nil
        devIndex = nil
        featureIndex = nil
    }

    // MARK: - discovery

    private func discover(fullScan: Bool) {
        guard let m = manager,
              let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let dev = devices.first
        else {
            discoveryFailures += 1
            if discoveryFailures == 3 {
                reportDeviceEvent("no HID++ interface found (receiver unplugged?)")
            }
            return
        }

        discoveryFailures = 0
        device = dev

        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "Logitech receiver"
        let vendorID = IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int ?? 0

        // A full scan costs a timeout per empty slot, so the common path only checks the slot we
        // already know about (plus one neighbour for a second paired device).
        let slots: [UInt8]
        if fullScan {
            slots = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        } else if let preferred = preferredSlot {
            slots = [preferred, preferred == 0x01 ? 0x02 : 0x01]
        } else {
            slots = [0x01, 0x02]
        }

        var responders: [DeviceSummary] = []
        for slot in slots {
            if let feature = resolveFeature(on: dev, deviceIndex: slot, id: 0x1001),
               plausibleVoltage(at: feature, on: dev, deviceIndex: slot) {
                responders.append(DeviceSummary(slot: slot, batteryFeature: feature))
            }
        }

        guard !responders.isEmpty else {
            // No answer this time. Keep any working pairing we already have — the mouse goes quiet
            // on its own and rediscovering from scratch on every gap just adds traffic.
            pairedDeviceMisses += 1
            if pairedDeviceMisses == 3 || pairedDeviceMisses.isMultiple(of: 15) {
                reportDeviceEvent("paired device did not answer (attempt \(pairedDeviceMisses)) — mouse idle or off?")
            }
            // Don't blank the UI just because one attempt went unanswered; only report "nothing
            // there" when it is the first answer we ever got, or when the user explicitly rescanned.
            if fullScan || lastInventory == nil {
                let empty = Inventory(receiverProduct: product, vendorID: vendorID, productID: productID,
                                      responders: [], active: nil)
                lastInventory = empty
                publish(empty)
            }
            return
        }

        pairedDeviceMisses = 0
        implausibleReadings = 0

        let wanted = preferredSlot
        let active = responders.first(where: { $0.slot == wanted }) ?? responders[0]
        devIndex = active.slot
        featureIndex = active.batteryFeature

        let slotList = responders.map { $0.label }.joined(separator: ", ")
        reportDeviceEvent("listening to \(active.label) on \(product) — BATTERY_VOLTAGE at feature 0x\(String(format: "%02x", active.batteryFeature)); slot(s) answering: \(slotList)")

        let inventory = Inventory(receiverProduct: product, vendorID: vendorID, productID: productID,
                                  responders: responders, active: active)
        lastInventory = inventory
        publish(inventory)
    }

    private func publish(_ inventory: Inventory) {
        onInventory?(inventory)
    }

    // MARK: - HID++ request

    /// Root feature index 0x00, function 0x00 = getFeature(id) -> index (0 = absent).
    private func resolveFeature(on dev: IOHIDDevice, deviceIndex: UInt8, id: UInt16) -> UInt8? {
        guard case .params(let p) = call(dev, device: deviceIndex, feature: 0x00, function: 0x00,
                                         params: [UInt8(id >> 8), UInt8(id & 0xff), 0x00], timeout: 0.35),
              let first = p.first, first != 0
        else { return nil }
        return first
    }

    /// Confirms a feature index is really BATTERY_VOLTAGE before we commit to it: a single
    /// misparsed reply during discovery previously produced a wrong index and garbage readings.
    private func plausibleVoltage(at feature: UInt8, on dev: IOHIDDevice, deviceIndex: UInt8) -> Bool {
        guard case .params(let p) = call(dev, device: deviceIndex, feature: feature, function: 0x00, timeout: 0.35),
              p.count >= 3
        else { return false }
        let millivolts = Int(p[0]) << 8 | Int(p[1])
        return (2500...4500).contains(millivolts)
    }

    private enum Reply {
        case params([UInt8])
        case hidppError(UInt8)
        case timeout
        case failed
    }

    private func call(_ dev: IOHIDDevice, device devIdx: UInt8, feature: UInt8, function: UInt8,
                      params: [UInt8] = [], timeout: TimeInterval = 1.0) -> Reply {
        swId = (swId % 15) + 1
        var request: [UInt8] = [0x10, devIdx, feature, (function << 4) | swId]
        request += params
        while request.count < 7 { request.append(0) }

        // Forget anything left over from earlier requests so a late reply can't be matched twice.
        inbox.removeAll()

        guard IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x10, &request, request.count) == kIOReturnSuccess else {
            return .failed
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            while !inbox.isEmpty {
                let report = inbox.removeFirst()
                guard report.count >= 7, report[1] == devIdx, (report[3] & 0x0f) == swId else { continue }
                // The feature index must match too: another client's reply can share a client id,
                // and parsing it as battery data produces garbage readings.
                if report[2] == 0x8F { return .hidppError(report[4]) }
                guard report[2] == feature else { continue }
                return .params(Array(report[4...]))
            }
        }
        return .timeout
    }

    // MARK: - poll

    private func poll() {
        let request = consumeRescanRequest()
        if request.rescan {
            device = nil
            devIndex = nil
            featureIndex = nil
            reportDeviceEvent("rescan requested\(request.fullScan ? " (all slots)" : "")")
        }

        if device == nil || devIndex == nil || featureIndex == nil {
            // At launch the receiver can take a moment to answer; retry once rather than waiting a
            // full poll interval. More attempts than this would stall the poll loop while the
            // device is asleep.
            discover(fullScan: request.fullScan)
            if device == nil || devIndex == nil {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
                discover(fullScan: request.fullScan)
            }
        }

        guard let dev = device, let di = devIndex, let fi = featureIndex else {
            onReading?(.failure(.noDevice))
            return
        }

        switch call(dev, device: di, feature: fi, function: 0x00) {
        case .params(let p) where p.count >= 3:
            let millivolts = Int(p[0]) << 8 | Int(p[1])
            // A mouse battery lives between roughly 3.0 and 4.3 V. Anything outside that is a
            // misparsed reply, and must never be allowed to drive the display state.
            guard (2500...4500).contains(millivolts) else {
                implausibleReadings += 1
                if implausibleReadings >= 3 {
                    // The feature index we cached is answering with something else — rediscover.
                    reportDeviceEvent(String(format: "implausible reading %d mV — cached feature index looks wrong, rediscovering", millivolts))
                    featureIndex = nil
                    implausibleReadings = 0
                }
                onReading?(.failure(.protocolError))
                return
            }
            implausibleReadings = 0
            onReading?(.success(Reading(voltageMV: millivolts, flags: p[2])))
        case .params:
            onReading?(.failure(.protocolError))
        case .hidppError:
            onReading?(.failure(.protocolError))
        case .timeout:
            onReading?(.failure(.timeout))
        case .failed:
            onReading?(.failure(.reportFailed))
        }
    }

    private func reportDeviceEvent(_ message: String) {
        onDeviceEvent?(message)
    }
}

// MARK: - C callbacks

private func hidppInput(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                        type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                        reportLength: CFIndex) {
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    Unmanaged<HIDPPClient>.fromOpaque(context).takeUnretainedValue().handleInput(bytes)
}

private func hidppMatched(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                          device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDPPClient>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
}

private func hidppRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
                          device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<HIDPPClient>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}
