import Foundation

/// Tiny append-only logger: stderr + ~/Library/Logs/Wakey/wakey.log + in-memory tail
/// for the diagnostics window.
final class Log {
    static let shared = Log()

    private let queue = DispatchQueue(label: "nl.sortedbits.wakey.log")
    private let fileURL: URL
    private var recent: [String] = []
    private let maxRecent = 500

    /// Called on the main queue for every new line.
    var onLine: ((String) -> Void)?

    private init() {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Wakey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("wakey.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    var logPath: String { fileURL.path }

    func lines() -> [String] { queue.sync { recent } }

    func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))

        queue.async {
            self.recent.append(line)
            if self.recent.count > self.maxRecent { self.recent.removeFirst(self.recent.count - self.maxRecent) }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
            DispatchQueue.main.async { self.onLine?(line) }
        }
    }
}

/// Convenience: Log.write("…")
func log(_ message: String) { Log.shared.write(message) }
