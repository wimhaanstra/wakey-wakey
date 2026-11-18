import AppKit
import CoreGraphics

@main
enum WakeyMain {

    /// NSApplication.delegate is a weak reference, so keep ours alive here.
    private static var delegate: AppDelegate?

    static func main() {
        let args = CommandLine.arguments

        // Headless hooks, used for scripted verification of the display path.
        if args.contains("--status") {
            print("displays asleep: \(CGDisplayIsAsleep(CGMainDisplayID()))")
            exit(0)
        }
        if args.contains("--blank") {
            do {
                try DisplayController().blank(keepSystemAwake: true)
                print("blank ok")
                exit(0)
            } catch {
                print("blank failed: \(error)")
                exit(1)
            }
        }
        if let index = args.firstIndex(of: "--sensor") {
            let seconds = args.count > index + 1 ? (Double(args[index + 1]) ?? 15) : 15
            let client = HIDPPClient()
            let sensor = DockSensor()
            var samples = 0
            var failures = 0
            client.onDeviceEvent = { print("HID++: \($0)") }
            client.onInventory = { inventory in
                let slots = inventory.responders.map { $0.label }.joined(separator: ", ")
                print("inventory: \(inventory.receiverLabel) | responding: [\(slots)] | active: \(inventory.active?.label ?? "none")")
            }
            client.onReading = { result in
                if case .success = result { samples += 1 } else { failures += 1 }
                DispatchQueue.main.async { sensor.ingest(result) }
            }
            sensor.onNewFlagsValue = { flags, reading in
                print(String(format: "flags 0x%02x first seen: %.3f V %@", flags, reading.volts, reading.chargeState))
            }
            sensor.onStateChange = { transition in
                print("SENSOR \(transition.from.rawValue) -> \(transition.to.rawValue): \(transition.reason)")
            }
            client.start()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            client.stop()
            print("summary: \(sensor.summary)")
            print(String(format: "polls: %d ok / %d failed in %.0fs (%.2f/s)",
                         samples, failures, seconds, Double(samples + failures) / seconds))
            exit(0)
        }

        if args.contains("--selftest") {
            _ = NSApplication.shared
            let settings = SettingsWindowController()
            let settingsTitle = settings.window?.title ?? "nil"
            print("settings window: \(settingsTitle) — \(settings.layoutReport())")
            let diagnostics = DiagnosticsWindowController()
            print("diagnostics window: \(diagnostics.window?.title ?? "nil") — \(diagnostics.layoutReport())")
            let missing = DeviceIcons.missingSymbols()
            print("menu icons: \(missing.isEmpty ? "all symbols present" : "MISSING \(missing)")")
            print("mouse icon: \(DeviceIcons.mouse(charging: true, colored: true) != nil ? "ok" : "nil")  keyboard icon: \(DeviceIcons.keyboard(charging: true, colored: true) != nil ? "ok" : "nil")")
            let status = DeviceIcons.statusBar(mouse: (percent: 76, charging: false),
                                               keyboard: (percent: 75, charging: true),
                                               colored: true)
            print(String(format: "status bar image: %.0fx%.0f %@ template=%@", status?.size.width ?? 0,
                         status?.size.height ?? 0, status == nil ? "(nil)" : "ok",
                         (status?.isTemplate ?? true) ? "YES (bad)" : "no"))
            print("login item: \(LoginItem.statusDescription)")
            print("preferences: automate=\(Preferences.shared.automate) keepAwake=\(Preferences.shared.keepAwake)")
            print("log: \(Log.shared.logPath)")
            exit(0)
        }

        if args.contains("--wake") {
            DisplayController().wake()
            print("wake sent")
            exit(0)
        }

        // Refuse to run twice: a second copy would fight the first over the HID++ interface.
        let me = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != me }) {
            print("Wakey is already running (pid \(existing.processIdentifier)) — exiting")
            exit(0)
        }

        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
