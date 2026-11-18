import Foundation
import ServiceManagement

/// Start-at-login, preferring the modern `SMAppService` API and falling back to a LaunchAgent
/// plist when ServiceManagement refuses (which happens for apps outside /Applications or with an
/// ad-hoc signature).
enum LoginItem {

    private static let agentLabel = "nl.sortedbits.wakey"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "enabled"
            case .requiresApproval: return "awaiting approval in System Settings › General › Login Items"
            case .notRegistered: break
            case .notFound: break
            @unknown default: break
            }
        }
        if FileManager.default.fileExists(atPath: agentURL.path) { return "enabled (LaunchAgent)" }
        return "not registered"
    }

    /// Returns a human-readable note on failure, nil on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if !enabled {
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.unregister()
            }
            removeAgent()
            log("login item: disabled")
            return nil
        }

        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                removeAgent()
                log("login item: registered via SMAppService (status: \(statusDescription))")
                return nil
            } catch {
                log("login item: SMAppService refused (\(error.localizedDescription)) — trying a LaunchAgent")
            }
        }

        if let failure = writeAgent() {
            log("login item: LaunchAgent fallback failed — \(failure)")
            return failure
        }
        log("login item: registered via LaunchAgent at \(agentURL.path)")
        return nil
    }

    private static func writeAgent() -> String? {
        let executable = Bundle.main.executableURL
        guard let exe = executable else { return "cannot locate the app executable" }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "KeepAlive": false,
        ]

        do {
            let dir = agentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
        } catch {
            return error.localizedDescription
        }

        // Best-effort load into the current session.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", "-w", agentURL.path]
        try? task.run()
        task.waitUntilExit()
        return nil
    }

    private static func removeAgent() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", "-w", agentURL.path]
        try? task.run()
        task.waitUntilExit()
        try? FileManager.default.removeItem(at: agentURL)
    }
}
