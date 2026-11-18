import CoreGraphics
import Foundation

/// Turns a stream of battery-voltage readings into a debounced dock state.
///
/// Rules, each one earned from a measurement:
///
///  1. The charging bit is the only trigger into `docked` (`.dockOnly` mode).
///  2. A failed poll never changes state. HID++ resource errors are intermittent and silence is not
///     evidence that the mouse was picked up.
///  3. Two agreeing readings are required, so one glitchy reply can't flap the displays.
///  4. **Leaving `docked` requires positive evidence of use.** At 100 % the dock stops charging and
///     the device reports `discharging` while still parked (measured: `0x91` → `0x00` at 4.123 V,
///     2026-11-18 18:00). Charging state alone cannot distinguish that from being picked up, so
///     `away` needs pointer motion — or a long discharge that proves the mouse is running on battery.
final class DockSensor {

    enum State: String {
        case unknown, docked, away
    }

    struct Transition {
        let from: State
        let to: State
        let reading: HIDPPClient.Reading?
        let reason: String
        let at: Date
    }

    var onStateChange: ((Transition) -> Void)?
    /// Fires the first time a given flags byte is observed.
    var onNewFlagsValue: ((UInt8, HIDPPClient.Reading) -> Void)?

    private(set) var state: State = .unknown
    private(set) var lastReading: HIDPPClient.Reading?
    private(set) var lastSuccessAt: Date?
    private(set) var failureCount = 0
    private(set) var lastMotionAt: Date?

    private var pendingTarget: State?
    private var pendingCount = 0
    private var flagsSeen: [UInt8: Date] = [:]
    private var dischargingSince: Date?
    private var motionProbe = MotionProbe()

    /// Consecutive agreeing readings required to enter a state.
    var dockConfirmSamples = 2
    var awayConfirmSamples = 2
    /// Without any successful reading for this long, drop to `.unknown` (passive, no automation).
    var silenceTimeout: TimeInterval = 60
    /// Discharging for this long counts as proof the mouse is off the dock, even without motion.
    var batteryEvidenceTimeout: TimeInterval = 600

    func ingest(_ result: Result<HIDPPClient.Reading, HIDPPClient.Failure>, now: Date = Date()) {
        switch result {
        case .failure:
            failureCount += 1
            if let last = lastSuccessAt,
               now.timeIntervalSince(last) >= silenceTimeout,
               state != .unknown {
                pendingTarget = nil
                pendingCount = 0
                dischargingSince = nil
                move(to: .unknown, reading: lastReading,
                     reason: "no successful reading for \(Int(now.timeIntervalSince(last)))s — passive",
                     at: now)
            }

        case .success(let reading):
            failureCount = 0
            lastSuccessAt = now
            lastReading = reading

            if flagsSeen[reading.flags] == nil {
                flagsSeen[reading.flags] = now
                onNewFlagsValue?(reading.flags, reading)
            }

            let moved = motionProbe.motionSinceLastCheck()
            if moved { lastMotionAt = now }

            let target: State
            if reading.isCharging {
                dischargingSince = nil
                target = .docked
            } else {
                if dischargingSince == nil { dischargingSince = now }
                let dischargingFor = now.timeIntervalSince(dischargingSince!)

                // A mouse parked on a full dock reports "discharging" too, so only believe it when
                // the pointer moved (proof the mouse is in hand) or the battery has been draining
                // long enough that it cannot still be sitting on a powered dock.
                let hasEvidence = moved
                    || dischargingFor >= batteryEvidenceTimeout
                    || state == .unknown

                if hasEvidence {
                    target = .away
                } else {
                    target = state
                }
            }

            if target == state {
                pendingTarget = nil
                pendingCount = 0
                return
            }

            if pendingTarget == target {
                pendingCount += 1
            } else {
                pendingTarget = target
                pendingCount = 1
            }

            let needed = target == .docked ? dockConfirmSamples : awayConfirmSamples
            guard pendingCount >= needed else { return }

            pendingTarget = nil
            pendingCount = 0

            var reason = String(format: "%@ at %.3f V", reading.chargeState, reading.volts)
            if !reading.isCharging {
                if moved {
                    reason += " (pointer moved)"
                } else if state == .unknown {
                    reason += " (initial reading)"
                } else {
                    reason += " (battery draining)"
                }
            }

            if target == .docked { dischargingSince = nil }
            move(to: target, reading: reading, reason: reason, at: now)
        }
    }

    private func move(to newState: State, reading: HIDPPClient.Reading?, reason: String, at date: Date) {
        let transition = Transition(from: state, to: newState, reading: reading, reason: reason, at: date)
        state = newState
        onStateChange?(transition)
    }

    /// One-line snapshot for the menu and the log.
    var summary: String {
        let flags = flagsSeen.keys.sorted().map { String(format: "0x%02x", $0) }.joined(separator: " ")
        var parts = ["state=\(state.rawValue)"]
        if let r = lastReading {
            var reading = String(format: "%.3f V", r.volts)
            if let percent = r.estimatedPercent { reading += " ≈\(percent)%" }
            reading += " \(r.chargeState)"
            parts.append(reading)
        }
        if failureCount > 0 { parts.append("failures=\(failureCount)") }
        parts.append("flags seen: \(flags.isEmpty ? "none" : flags)")
        return parts.joined(separator: " ")
    }
}

/// Permission-free "is the user moving the pointer?" probe.
///
/// `CGEventSource.secondsSinceLastEventType` reads a system counter; it needs no Accessibility or
/// Input Monitoring grant. The counter only ever grows, so a value lower than the previous sample
/// means a mouse-move event happened in between.
struct MotionProbe {
    private var previousIdle: CFTimeInterval?
    private var lastCheck: Date?

    mutating func motionSinceLastCheck() -> Bool {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let now = Date()
        defer {
            previousIdle = idle
            lastCheck = now
        }

        guard let previous = previousIdle else { return false }
        // Reset of the counter, or an event within the last half second.
        return idle < previous - 0.01 || idle < 0.5
    }
}
