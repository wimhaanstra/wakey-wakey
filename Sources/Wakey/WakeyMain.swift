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
            let scanner = TVScannerWindowController()
            print("scanner window: \(scanner.window?.title ?? "nil") — \(scanner.layoutReport())")
            let missing = DeviceIcons.missingSymbols()
            print("menu icons: \(missing.isEmpty ? "all symbols present" : "MISSING \(missing)")")
            let missingSettings = SettingsStyle.missingSymbols()
            print("settings icons: \(missingSettings.isEmpty ? "all symbols present" : "MISSING \(missingSettings)")")
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

        if args.contains(where: { $0.hasPrefix("--tv") }) {
            runTVCommand(args)
            return
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

    /// Headless TV control, used to verify the protocol without the menu bar app.
    /// Every command waits for the socket to register (the first one shows the TV prompt).
    private static func runTVCommand(_ args: [String]) {
        if let index = args.firstIndex(of: "--tv-host"), args.count > index + 1 {
            Preferences.shared.tvHost = args[index + 1]
        }

        let commands = ["status", "pair", "volume", "mute", "backlight", "screen", "power", "detect"]
        let command = commands.first { args.contains("--tv-\($0)") } ?? "status"
        var value: String?
        if let index = args.firstIndex(of: "--tv-\(command)"), args.count > index + 1 {
            value = args[index + 1]
        }

        if command == "detect" {
            TVController.discover { devices in
                if devices.isEmpty {
                    print("no LG TV answered SSDP")
                }
                for device in devices {
                    print("\(device.host)  \(device.name ?? "?")  \(device.model ?? "?")")
                }
                exit(devices.isEmpty ? 1 : 0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(8))
            print("discovery timed out")
            exit(1)
        }

        guard !Preferences.shared.tvHost.isEmpty else {
            print("no TV address configured — pass --tv-host <ip> or set it in Settings")
            exit(1)
        }
        Preferences.shared.tvControl = true

        print("TV: host \(Preferences.shared.tvHost), command \(command)")
        let tv = TVController()
        var performed = false
        var sawReady = false
        let immediatePowerOn = command == "power" && (value ?? "off") == "on"

        if immediatePowerOn {
            tv.onSnapshot = { snapshot in
                if snapshot.powerState == "Active" {
                    print("TV snapshot: model=\(snapshot.model ?? "?") power=\(snapshot.powerState ?? "?") "
                          + "volume=\(snapshot.volume.map(String.init) ?? "?") "
                          + "backlight=\(snapshot.backlight.map(String.init) ?? "?") "
                          + "app=\(snapshot.currentApp ?? "?")")
                    exit(0)
                }
            }
        }

        tv.onStateChange = { state in
            print("TV: state \(state.rawValue)")
            guard state == .ready else { return }
            sawReady = true
            guard !immediatePowerOn, !performed else { return }
            performed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                switch command {
                case "volume":
                    tv.setVolume(Int(value ?? "20") ?? 20)
                case "mute":
                    tv.setMute((value ?? "on") == "on")
                case "backlight":
                    tv.setBacklight(Int(value ?? "50") ?? 50)
                case "screen":
                    (value ?? "off") == "off" ? tv.screenOff() : tv.screenOn()
                case "power":
                    (value ?? "off") == "off" ? tv.powerOff() : tv.powerOn()
                case "pair":
                    break
                default:
                    break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let snapshot = tv.snapshot
                    print("TV snapshot: model=\(snapshot.model ?? "?") power=\(snapshot.powerState ?? "?") "
                          + "volume=\(snapshot.volume.map(String.init) ?? "?") "
                          + "backlight=\(snapshot.backlight.map(String.init) ?? "?") "
                          + "app=\(snapshot.currentApp ?? "?")")
                    if command == "power" && (value ?? "off") == "off" { exit(0) }
                    if command == "pair" { exit(0) }
                    if command == "screen" || command == "volume" || command == "mute"
                        || command == "backlight" || command == "status" || command == "power" {
                        exit(0)
                    }
                }
            }
        }

        if command == "pair" {
            tv.forgetPairing()
        } else if immediatePowerOn {
            tv.start()
            tv.powerOn()
        } else {
            tv.start()
        }

        let wait: TimeInterval = (command == "status" || command == "pair") ? 120 : 45
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        print("timed out (ready=\(sawReady))")
        exit(1)
    }

}
