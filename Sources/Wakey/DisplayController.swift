import CoreGraphics
import Foundation
import IOKit.pwr_mgt

enum DisplayError: Error, CustomStringConvertible {
    case pmsetFailed(Int32)

    var description: String {
        switch self {
        case .pmsetFailed(let code): return "pmset displaysleepnow exited with status \(code)"
        }
    }
}

/// The only place that touches display power. Everything user-visible goes through here so a
/// future private-API fallback (if `pmset displaysleepnow` ever disappears) is a one-file change.
final class DisplayController {

    /// Assertions we hold so a clamshell MacBook doesn't idle-suspend and kill the USB receiver.
    private var assertions: [IOPMAssertionID] = []

    private(set) var blankedByUs = false

    /// Called after a blank/wake so the TV can follow the displays without DisplayController
    /// knowing anything about webOS.
    var onBlank: (() -> Void)?
    var onWake: (() -> Void)?

    /// Ground truth, independent of our own bookkeeping.
    var displaysAreAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

    // MARK: - blank

    func blank(keepSystemAwake: Bool = true) throws {
        if displaysAreAsleep {
            log("blank: displays already asleep, nothing to do")
            blankedByUs = true
            if keepSystemAwake { holdAssertions() }
            onBlank?()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DisplayError.pmsetFailed(process.terminationStatus)
        }

        blankedByUs = true
        log("blank: pmset displaysleepnow ok (asleep=\(displaysAreAsleep))")
        if keepSystemAwake { holdAssertions() }
        onBlank?()
    }

    // MARK: - wake

    func wake() {
        releaseAssertions()

        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "Wakey: mouse picked up" as CFString,
            kIOPMUserActiveLocal,
            &assertion
        )
        if result == kIOReturnSuccess {
            log("wake: DeclareUserActivity ok (asleep=\(displaysAreAsleep))")
        } else {
            log("wake: DeclareUserActivity returned 0x\(String(result, radix: 16)), falling back to caffeinate")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-u", "-t", "1"]
            try? process.run()
        }

        blankedByUs = false
        onWake?()
    }

    /// The screens came back on their own (user input). Drop our assertions and forget our claim.
    func noteExternallyWoken() {
        releaseAssertions()
        blankedByUs = false
        onWake?()
    }

    // MARK: - assertions

    private func holdAssertions() {
        guard assertions.isEmpty else { return }

        var idle: IOPMAssertionID = 0
        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Wakey: displays are off on purpose, keep the Mac awake" as CFString,
            &idle
        )
        if idleResult == kIOReturnSuccess {
            assertions.append(idle)
            log("assertion: PreventUserIdleSystemSleep held (#\(idle))")
        } else {
            log("assertion: PreventUserIdleSystemSleep FAILED 0x\(String(idleResult, radix: 16))")
        }

        var system: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Wakey: displays are off on purpose, keep the Mac awake" as CFString,
            &system
        )
        if systemResult == kIOReturnSuccess {
            assertions.append(system)
            log("assertion: PreventSystemSleep held (#\(system))")
        } else {
            log("assertion: PreventSystemSleep FAILED 0x\(String(systemResult, radix: 16))")
        }
    }

    func releaseAssertions() {
        guard !assertions.isEmpty else { return }
        for id in assertions { IOPMAssertionRelease(id) }
        log("assertion: released \(assertions.count)")
        assertions.removeAll()
    }
}
