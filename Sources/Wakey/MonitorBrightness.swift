import Foundation

/// Brightness for the non-webOS LG monitor (31.5" 4K on the Mac's HDMI port).
///
/// The set has no network API, so the only path is DDC/CI. `m1ddc` is the small MIT-licensed
/// Apple-Silicon DDC client that actually works here; it is optional — if it is not installed the
/// monitor section stays hidden and the TV half is unaffected.
///
/// DDC reads on the built-in HDMI path are noisy (roughly half return 0 or 0x1000), while writes
/// are dependable. So the model keeps a cached value, retries reads, and never trusts a zero.
final class MonitorBrightness {

    struct Display {
        let index: Int
        let name: String
        let uuid: String
    }

    private(set) var display: Display?
    private(set) var value: Int?
    private var announced = false

    private let queue = DispatchQueue(label: "nl.sortedbits.wakey.monitor")
    private let toolPaths = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]

    var toolPath: String? {
        toolPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { toolPath != nil && display != nil }
    var displayName: String { display?.name ?? "LG monitor" }

    func refresh(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let tool = self.toolPath else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let list = self.run(tool, ["display", "list"])
            self.display = Self.parseDisplayList(list.output)
            if let display = self.display {
                let reading = self.readLuminance(display, tool: tool)
                if !self.announced {
                    self.announced = true
                    log("MONITOR: \(display.name) at index \(display.index), DDC luminance "
                        + "\(reading.map(String.init) ?? "unreadable")")
                }
                if let reading { self.value = reading }
            } else {
                self.value = nil
                if !self.announced {
                    self.announced = true
                    log("MONITOR: m1ddc found but no non-TV display was listed")
                }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    func set(_ newValue: Int, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let tool = self.toolPath, let display = self.display else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let level = min(100, max(0, newValue))
            for attempt in 0..<3 {
                let result = self.run(tool, ["display", "\(display.index)", "set", "luminance", "\(level)"])
                if result.status == 0 { break }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
            }
            self.value = level
            log("MONITOR: brightness \(level)")
            DispatchQueue.main.async { completion?() }
        }
    }

    func step(_ delta: Int, completion: (() -> Void)? = nil) {
        if let value {
            // Advance the cached value immediately so a held key accumulates steps instead of
            // queuing several commands that all target the same starting brightness.
            let target = min(100, max(0, value + delta))
            self.value = target
            set(target, completion: completion)
        } else {
            refresh { [weak self] in
                guard let self else { return }
                self.set((self.value ?? 50) + delta, completion: completion)
            }
        }
    }

    // MARK: - parsing

    private static func parseDisplayList(_ output: String) -> Display? {
        var candidates: [Display] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let indexText = line[line.index(after: line.startIndex)..<close]
            guard let index = Int(indexText) else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard let open = rest.lastIndex(of: "("), rest.hasSuffix(")") else { continue }
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let uuid = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
            candidates.append(Display(index: index, name: name, uuid: String(uuid)))
        }
        return candidates.first { $0.name.localizedCaseInsensitiveContains("HDR 4K") }
            ?? candidates.first { !$0.name.localizedCaseInsensitiveContains("TV") }
    }

    private func readLuminance(_ display: Display, tool: String) -> Int? {
        for attempt in 0..<8 {
            let result = run(tool, ["display", "\(display.index)", "get", "luminance"])
            if result.status == 0, let value = Self.firstInteger(result.output),
               value > 0, value <= 100 {
                return value
            }
            if attempt < 7 { Thread.sleep(forTimeInterval: 0.04) }
        }
        return nil
    }

    private static func firstInteger(_ text: String) -> Int? {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        for part in digits {
            if let value = Int(part) { return value }
        }
        return nil
    }

    // MARK: - process

    private struct Result {
        let status: Int32
        let output: String
    }

    private func run(_ tool: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self))
    }
}
