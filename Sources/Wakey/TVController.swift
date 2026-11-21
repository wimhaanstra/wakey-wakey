import CryptoKit
import Darwin
import Foundation
import Security

enum TVControlError: Error, CustomStringConvertible {
    case disabled
    case noHost
    case notConnected
    case timedOut
    case rejected(String)
    case transport(String)

    var description: String {
        switch self {
        case .disabled: return "TV control is off"
        case .noHost: return "no TV address configured"
        case .notConnected: return "not connected to the TV"
        case .timedOut: return "the TV did not answer"
        case .rejected(let message): return message
        case .transport(let message): return message
        }
    }
}

struct TVSnapshot {
    var model: String?
    var powerState: String?
    var volume: Int?
    var muted: Bool?
    var backlight: Int?
    var currentApp: String?
    var inputLabel: String?

    var isScreenOff: Bool { powerState == "Screen Off" }
    var isPoweredOff: Bool { powerState == "Power Off" || powerState == "Suspend" }
}

enum TVConnectionState: String {
    case off, connecting, pairing, ready, unreachable
}

/// One LG webOS TV, reached the way every third-party remote reaches one: SSAP over the
/// TV's secure WebSocket. Port 3000 (plain `ws`) is refused by webOS 24; only 3001 answers.
///
/// Two firmware quirks are encoded here because they are not obvious:
///  * picture settings cannot be written over SSAP any more — `ssap://settings/setSystemSettings`
///    answers 401 even with `WRITE_SETTINGS`. The established workaround is to create an alert
///    whose `onclose` handler is a luna call, then close the alert ourselves.
///  * the TV presents a self-signed LG certificate, so the trust challenge is answered by hand.
///    The leaf fingerprint is pinned on first use (TOFU) and a change is refused.
final class TVController: NSObject {

    // MARK: - public state

    private(set) var state: TVConnectionState = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private(set) var snapshot = TVSnapshot() {
        didSet { onSnapshot?(snapshot) }
    }

    var onStateChange: ((TVConnectionState) -> Void)?
    var onSnapshot: ((TVSnapshot) -> Void)?

    var host: String { Preferences.shared.tvHost.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isReady: Bool { state == .ready }
    var isConfigured: Bool { Preferences.shared.tvControl && !host.isEmpty }

    /// `HDMI_2` → `com.webos.app.hdmi2`, the app id the TV reports while that input is on screen.
    var macInputID: String { Preferences.shared.tvInput }
    var macAppID: String {
        "com.webos.app." + macInputID.lowercased().replacingOccurrences(of: "_", with: "")
    }
    var isShowingMacInput: Bool { snapshot.currentApp == macAppID }

    // MARK: - private state

    private struct Stored: Codable {
        var clientKey: String?
        var fingerprint: String?
        var wifiMAC: String?
        var wiredMAC: String?
    }

    private var stored = Stored()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var openTimeout: DispatchWorkItem?
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var suppressReconnect = false
    private var didRetryPairing = false

    private var lastRefresh = Date.distantPast
    private var refreshTimer: Timer?
    private var wakeTimer: Timer?
    private var wakeAttempts = 0
    private var wakeQueryInFlight = false
    private var screenOffInFlight = false
    private var screenOnInFlight = false
    private var lastScreenOffAt = Date.distantPast
    private var lastScreenOnAt = Date.distantPast

    /// Set when this app blanked/powered the TV, so a matching wake only undoes our own action.
    private var weScreenOff = false
    private var wePowerOff = false

    // MARK: - lifecycle

    override init() {
        super.init()
        stored = Self.loadStored()
    }

    deinit {
        refreshTimer?.invalidate()
        wakeTimer?.invalidate()
        reconnectWork?.cancel()
        session?.invalidateAndCancel()
    }

    func start() {
        guard Preferences.shared.tvControl else {
            log("TV: control is off")
            state = .off
            return
        }
        guard !host.isEmpty else {
            log("TV: no address configured")
            state = .off
            return
        }
        suppressReconnect = false
        didRetryPairing = false
        connect()
    }

    func stop() {
        suppressReconnect = true
        reconnectWork?.cancel()
        refreshTimer?.invalidate()
        wakeTimer?.invalidate()
        cleanupSocket()
        state = .off
    }

    func reconnect() {
        stop()
        suppressReconnect = false
        reconnectAttempts = 0
        start()
    }

    /// Forget the pairing key and pinned certificate. The next connection shows the TV prompt again.
    func forgetPairing() {
        stored.clientKey = nil
        stored.fingerprint = nil
        saveStored()
        log("TV: pairing forgotten")
        reconnect()
    }

    // MARK: - connection

    private func connect() {
        guard Preferences.shared.tvControl else { state = .off; return }
        let host = self.host
        guard !host.isEmpty else { state = .off; return }
        guard task == nil else { return }

        guard let url = URL(string: "wss://\(host):3001") else {
            log("TV: bad address \(host)")
            state = .unreachable
            return
        }

        log("TV: connecting to \(host):3001")
        state = .connecting
        didRetryPairing = false

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.waitsForConnectivity = false
        session?.invalidateAndCancel()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let socket = session.webSocketTask(with: request)
        task = socket
        isOpen = false
        socket.resume()
        receive(on: socket)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.task === socket, !self.isOpen else { return }
            log("TV: opening the socket timed out")
            self.handleDisconnect(reason: "connect timeout")
        }
        openTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket, socket === self.task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive(on: socket)

            case .failure(let error):
                self.handleDisconnect(reason: error.localizedDescription)
            }
        }
    }

    private func cleanupSocket() {
        openTimeout?.cancel()
        openTimeout = nil
        isOpen = false
        let closing = task
        task = nil
        closing?.cancel(with: .goingAway, reason: nil)
        failPending(TVControlError.transport("connection closed"))
    }

    private func handleDisconnect(reason: String) {
        guard task != nil else { return }
        log("TV: disconnected — \(reason)")
        cleanupSocket()
        state = suppressReconnect ? .off : .unreachable
        refreshTimer?.invalidate()
        if !suppressReconnect {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard Preferences.shared.tvControl, !suppressReconnect else { return }
        reconnectWork?.cancel()
        reconnectAttempts = min(reconnectAttempts + 1, 6)
        let delay = min(30, 2 * pow(2, Double(reconnectAttempts - 1)))
        log(String(format: "TV: reconnecting in %.0fs", delay))
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - registration

    private func sendRegister(withKey: Bool) {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": Self.manifest,
        ]
        if withKey, let key = stored.clientKey {
            payload["client-key"] = key
        }
        state = withKey ? .connecting : .pairing
        log("TV: registering\(withKey ? " with stored key" : " — accept the prompt on the TV")")
        sendRaw(["id": "register", "type": "register", "payload": payload])
    }

    private func handleRegisterError(_ message: String) {
        log("TV: registration rejected — \(message)")
        // A stale client-key is the common cause after a TV firmware reset; retry once as a
        // fresh pairing instead of making the user find the “forget” button.
        if stored.clientKey != nil && !didRetryPairing {
            didRetryPairing = true
            stored.clientKey = nil
            saveStored()
            sendRegister(withKey: false)
        } else {
            state = .pairing
        }
    }

    // MARK: - messages

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "registered":
            let payload = object["payload"] as? [String: Any] ?? [:]
            if let key = payload["client-key"] as? String {
                stored.clientKey = key
                saveStored()
            }
            state = .ready
            reconnectAttempts = 0
            log("TV: registered; client key \(stored.clientKey == nil ? "missing" : "stored")")
            bootstrap()

        case "response":
            guard let id = object["id"] as? Int, let completion = pending.removeValue(forKey: id) else { return }
            completion(.success(object["payload"] as? [String: Any] ?? [:]))

        case "error":
            if let id = object["id"] as? Int, let completion = pending.removeValue(forKey: id) {
                completion(.failure(TVControlError.rejected(object["error"] as? String ?? "TV error")))
            } else if (object["id"] as? String) == "register" {
                handleRegisterError(object["error"] as? String ?? "registration failed")
            }

        default:
            break
        }
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let task, isOpen else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { log("TV: send failed — \(error.localizedDescription)") }
        }
    }

    private func request(_ uri: String, _ payload: [String: Any] = [:],
                         timeout: TimeInterval = 8,
                         _ completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard isOpen, task != nil else {
            completion(.failure(TVControlError.notConnected))
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = completion
        sendRaw(["id": id, "type": "request", "uri": uri, "payload": payload])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
            waiting(.failure(TVControlError.timedOut))
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, completion) in waiting { completion(.failure(error)) }
    }

    // MARK: - bootstrap and refresh

    private func bootstrap() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        request("ssap://system/getSystemInfo") { [weak self] result in
            guard case .success(let payload) = result else { return }
            self?.snapshot.model = payload["modelName"] as? String
        }
        request("ssap://com.webos.service.connectionmanager/getinfo") { [weak self] result in
            guard let self, case .success(let payload) = result else { return }
            if let wifi = payload["wifiInfo"] as? [String: Any],
               let mac = wifi["macAddress"] as? String, mac != self.stored.wifiMAC {
                self.stored.wifiMAC = mac
                log("TV: Wi-Fi MAC \(mac)")
            }
            if let wired = payload["wiredInfo"] as? [String: Any],
               let mac = wired["macAddress"] as? String, mac != self.stored.wiredMAC {
                self.stored.wiredMAC = mac
                log("TV: wired MAC \(mac)")
            }
            self.saveStored()
        }
        refresh(force: true)
    }

    /// Cheap state poll. Called when the menu opens and every 20 s so the sleep decision has a
    /// fresh picture of which input the TV is on.
    func refresh(force: Bool = false) {
        guard state == .ready else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastRefresh) > 2 else { return }
        lastRefresh = now

        request("ssap://audio/getVolume") { [weak self] result in
            guard case .success(let payload) = result,
                  let status = payload["volumeStatus"] as? [String: Any] else { return }
            self?.snapshot.volume = status["volume"] as? Int
            self?.snapshot.muted = status["muteStatus"] as? Bool
            if let output = status["soundOutput"] as? String { self?.snapshot.inputLabel = output }
        }
        request("ssap://com.webos.service.tvpower/power/getPowerState") { [weak self] result in
            guard case .success(let payload) = result else { return }
            self?.snapshot.powerState = payload["state"] as? String
        }
        request("ssap://com.webos.applicationManager/getForegroundAppInfo") { [weak self] result in
            guard case .success(let payload) = result else { return }
            self?.snapshot.currentApp = payload["appId"] as? String
        }
        request("ssap://settings/getSystemSettings",
                ["category": "picture", "keys": ["backlight"]]) { [weak self] result in
            guard case .success(let payload) = result,
                  let settings = payload["settings"] as? [String: Any],
                  let value = settings["backlight"] as? String else { return }
            self?.snapshot.backlight = Int(value)
        }
    }

    // MARK: - volume

    func setVolume(_ value: Int) {
        let volume = min(100, max(0, value))
        request("ssap://audio/setVolume", ["volume": volume]) { [weak self] result in
            switch result {
            case .success:
                self?.snapshot.volume = volume
                self?.snapshot.muted = false
                log("TV: volume \(volume)")
            case .failure(let error):
                log("TV: set volume failed — \(error)")
            }
        }
    }

    func stepVolume(_ delta: Int) {
        guard let current = snapshot.volume else {
            request("ssap://audio/getVolume") { [weak self] result in
                guard case .success(let payload) = result,
                      let status = payload["volumeStatus"] as? [String: Any],
                      let volume = status["volume"] as? Int else { return }
                self?.setVolume(volume + delta)
            }
            return
        }
        setVolume(current + delta)
    }

    func setMute(_ muted: Bool) {
        request("ssap://audio/setMute", ["mute": muted]) { [weak self] result in
            switch result {
            case .success:
                self?.snapshot.muted = muted
                log("TV: mute \(muted)")
            case .failure(let error):
                log("TV: set mute failed — \(error)")
            }
        }
    }

    func toggleMute() { setMute(!(snapshot.muted ?? false)) }

    // MARK: - picture

    func setBacklight(_ value: Int) {
        let level = min(100, max(0, value))
        let params: [String: Any] = ["category": "picture", "settings": ["backlight": String(level)]]
        luna("com.webos.settingsservice/setSystemSettings", params) { [weak self] result in
            switch result {
            case .success:
                self?.snapshot.backlight = level
                log("TV: backlight \(level)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh(force: true) }
            case .failure(let error):
                log("TV: set backlight failed — \(error)")
            }
        }
    }

    func stepBacklight(_ delta: Int) {
        guard let current = snapshot.backlight else {
            refresh(force: true)
            return
        }
        setBacklight(current + delta)
    }

    /// webOS 24 rejects `ssap://settings/setSystemSettings` with 401. Colour control and bscpylgtv
    /// both go through an alert whose close handler is a luna call; creating and closing it is enough
    /// for the TV to run the write. The luna call's result is not observable, so callers re-read.
    private func luna(_ uri: String, _ params: [String: Any],
                      _ completion: @escaping (Result<Void, Error>) -> Void) {
        let target = "luna://\(uri)"
        let action: [String: Any] = ["uri": target, "params": params]
        let payload: [String: Any] = [
            "message": " ",
            "buttons": [["label": "", "onClick": target, "params": params]],
            "onclose": action,
            "onfail": action,
        ]
        request("ssap://system.notifications/createAlert", payload) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                guard let alertID = response["alertId"] as? String else {
                    completion(.failure(TVControlError.rejected("TV did not return an alertId")))
                    return
                }
                self.request("ssap://system.notifications/closeAlert", ["alertId": alertID]) { close in
                    switch close {
                    case .success: completion(.success(()))
                    case .failure(let error): completion(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: - screen and power

    func screenOff() {
        // Both DisplayController.blank and screensDidSleep call this; without the in-flight
        // guard the TV gets two turnOffScreen requests and answers the second with a 500, which
        // looks like a failure in the log even though the panel is already off.
        guard state == .ready, !screenOffInFlight,
              Date().timeIntervalSince(lastScreenOffAt) > 1.2 else { return }
        screenOffInFlight = true
        request("ssap://com.webos.service.tvpower/power/turnOffScreen", ["standbyMode": "active"]) { [weak self] result in
            guard let self else { return }
            self.screenOffInFlight = false
            switch result {
            case .success:
                self.snapshot.powerState = "Screen Off"
                self.weScreenOff = true
                self.lastScreenOffAt = Date()
                log("TV: screen off")
            case .failure(let error):
                log("TV: screen off failed — \(error)")
            }
        }
    }

    func screenOn() {
        guard state == .ready, !screenOnInFlight,
              Date().timeIntervalSince(lastScreenOnAt) > 1.2 else { return }
        screenOnInFlight = true
        request("ssap://com.webos.service.tvpower/power/turnOnScreen", ["standbyMode": "active"]) { [weak self] result in
            guard let self else { return }
            self.screenOnInFlight = false
            switch result {
            case .success:
                self.snapshot.powerState = "Active"
                self.weScreenOff = false
                self.lastScreenOnAt = Date()
                log("TV: screen on")
            case .failure(let error):
                log("TV: screen on failed — \(error)")
            }
        }
    }

    func powerOff() {
        guard state == .ready else { return }
        log("TV: power off")
        wePowerOff = true
        suppressReconnect = true
        request("ssap://system/turnOff") { result in
            if case .failure(let error) = result { log("TV: power off failed — \(error)") }
        }
        snapshot.powerState = "Power Off"
        state = .off
        refreshTimer?.invalidate()
    }

    /// Wake-on-LAN, then wait for the TV to accept a socket again. Retries cover Wi-Fi still
    /// re-associating when `didWake` fires.
    func powerOn() {
        guard Preferences.shared.tvControl else { return }
        guard !host.isEmpty else { return }
        wePowerOff = true
        suppressReconnect = false
        wakeAttempts = 0
        wakeQueryInFlight = false
        sendMagicPackets()
        wakeTimer?.invalidate()
        wakeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.wakeAttempts += 1

            // A TV in standby keeps its network stack up, so the socket can succeed while the
            // panel is still dark. Only the power state tells us whether the boot finished.
            if self.wakeAttempts % 2 == 1 { self.sendMagicPackets() }
            if self.wakeAttempts > 20 {
                timer.invalidate()
                log("TV: wake timed out after 40 s — is Wake on LAN enabled on the TV?")
                return
            }
            guard self.state == .ready else {
                if self.task == nil { self.connect() }
                return
            }
            guard !self.wakeQueryInFlight else { return }
            self.wakeQueryInFlight = true
            self.request("ssap://com.webos.service.tvpower/power/getPowerState") { [weak self] result in
                guard let self else { return }
                self.wakeQueryInFlight = false
                guard case .success(let payload) = result,
                      let state = payload["state"] as? String else { return }
                switch state {
                case "Active":
                    timer.invalidate()
                    self.snapshot.powerState = state
                    if self.wePowerOff {
                        self.switchToMacInput()
                        self.wePowerOff = false
                    }
                    log("TV: awake")
                case "Screen Off":
                    self.snapshot.powerState = state
                    self.screenOn()
                default:
                    break
                }
            }
        }
    }

    func switchToMacInput() {
        guard state == .ready else { return }
        request("ssap://tv/switchInput", ["inputId": macInputID]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                log("TV: switched to \(self.macInputID)")
            case .failure:
                // Some firmware only exposes input switching through the launcher.
                self.request("ssap://system.launcher/launch", ["id": self.macAppID]) { launch in
                    if case .failure(let error) = launch {
                        log("TV: switch input failed — \(error)")
                    }
                }
            }
        }
    }

    // MARK: - sleep / wake hooks

    /// Called when the Mac is about to sleep. Only touch the TV if it is showing this Mac:
    /// someone watching broadcast TV on another input should not lose the picture.
    func prepareForSystemSleep() {
        guard Preferences.shared.tvControl else { return }
        guard state == .ready else { log("TV: sleeping but TV is not connected — nothing to do"); return }
        guard isShowingMacInput else {
            log("TV: sleeping; TV is on \(snapshot.currentApp ?? "another input") — leaving it on")
            return
        }
        if Preferences.shared.tvPowerOffOnSleep {
            powerOff()
        } else if !snapshot.isScreenOff {
            // The display-sleep notification normally got here first; this is the fallback for
            // a sleep that skipped it. Panel off keeps the TV reachable for an instant wake.
            screenOff()
        }
    }

    func handleSystemWake() {
        guard Preferences.shared.tvControl else { return }
        guard wePowerOff || weScreenOff else { return }
        log("TV: Mac woke — reconnecting")
        powerOn()
    }

    /// The displays went dark because of Wakey (dock/manual). Panel off, not full standby:
    /// the TV stays on the network and the Mac still sees the HDMI sink, so windows do not move.
    func followDisplayBlank() {
        guard Preferences.shared.tvControl, Preferences.shared.tvFollowDisplays else { return }
        guard state == .ready else { return }
        guard isShowingMacInput else {
            log("TV: displays blanked, TV is on \(snapshot.currentApp ?? "another input") — leaving it alone")
            return
        }
        guard !snapshot.isScreenOff else { return }
        screenOff()
    }

    func followDisplayWake() {
        guard Preferences.shared.tvControl, Preferences.shared.tvFollowDisplays, weScreenOff else { return }
        screenOn()
    }

    // MARK: - Wake-on-LAN

    private static func magicPacket(for mac: String) -> Data? {
        let hex = mac.replacingOccurrences(of: "-", with: ":").split(separator: ":")
        guard hex.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in hex {
            guard let value = UInt8(part, radix: 16) else { return nil }
            bytes.append(value)
        }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    private func sendMagicPackets() {
        let macs = [stored.wifiMAC, stored.wiredMAC].compactMap { $0 }
        guard !macs.isEmpty else {
            log("TV: no MAC address known yet — cannot send Wake-on-LAN")
            return
        }
        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return }
        defer { close(socketFD) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        let destinations = Self.localBroadcasts()
        for mac in macs {
            guard let packet = Self.magicPacket(for: mac) else { continue }
            for destination in destinations {
                for port in [9, 7] {
                    var address = sockaddr_in()
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = in_port_t(port).bigEndian
                    address.sin_addr.s_addr = inet_addr(destination)
                    packet.withUnsafeBytes { raw in
                        withUnsafePointer(to: &address) { pointer in
                            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                                _ = sendto(socketFD, raw.baseAddress, packet.count, 0,
                                           sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            log("TV: Wake-on-LAN sent to \(mac)")
        }
    }

    private static func localBroadcasts() -> [String] {
        var result = ["255.255.255.255"]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return result }
        defer { freeifaddrs(interfaces) }
        var pointer = first
        while true {
            let flags = Int32(pointer.pointee.ifa_flags)
            if let address = pointer.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_BROADCAST) != 0,
               let broadcast = pointer.pointee.ifa_dstaddr {
                let socketAddress = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = socketAddress.sin_addr
                inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
                let text = String(cString: buffer)
                if !text.isEmpty && !result.contains(text) { result.append(text) }
            }
            guard let next = pointer.pointee.ifa_next else { break }
            pointer = next
        }
        return result
    }

    // MARK: - discovery

    struct DiscoveredTV {
        let host: String
        let model: String?
        let name: String?
    }

    /// SSDP search narrowed to LG's `urn:lge:device:tv:1`, then a fetch of the device
    /// description for a human-readable name. Runs off the main queue.
    static func discover(timeout: TimeInterval = 2.5,
                         completion: @escaping ([DiscoveredTV]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [String: DiscoveredTV] = [:]
            let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
            if socketFD >= 0 {
                var tv = timeval(tv_sec: 0, tv_usec: 500_000)
                setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = in_port_t(1900).bigEndian
                target.sin_addr.s_addr = inet_addr("239.255.255.250")
                let search = "M-SEARCH * HTTP/1.1\r\n"
                    + "HOST: 239.255.255.250:1900\r\n"
                    + "MAN: \"ssdp:discover\"\r\n"
                    + "MX: 2\r\n"
                    + "ST: urn:lge:device:tv:1\r\n\r\n"

                search.withCString { pointer in
                    withUnsafePointer(to: &target) { address in
                        address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(socketFD, pointer, strlen(pointer), 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }

                let deadline = Date().addingTimeInterval(timeout)
                var buffer = [UInt8](repeating: 0, count: 4096)
                while Date() < deadline {
                    var from = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let received = withUnsafeMutablePointer(to: &from) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(socketFD, &buffer, buffer.count, 0, $0, &length)
                        }
                    }
                    guard received > 0 else { continue }
                    let text = String(decoding: buffer.prefix(received), as: UTF8.self)
                    guard let location = header("location", in: text),
                          let url = URL(string: location),
                          let host = url.host else { continue }
                    if found[host] != nil { continue }
                    let description = fetchDescription(location)
                    found[host] = DiscoveredTV(host: host, model: description.model, name: description.name)
                }
                close(socketFD)
            }
            let devices = found.values.sorted { $0.host < $1.host }
            DispatchQueue.main.async { completion(devices) }
        }
    }

    private static func header(_ name: String, in text: String) -> String? {
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func fetchDescription(_ location: String) -> (model: String?, name: String?) {
        guard let url = URL(string: location) else { return (nil, nil) }
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        let task = URLSession.shared.dataTask(with: url) { body, _, _ in
            data = body
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        task.cancel()
        guard let data, let xml = String(data: data, encoding: .utf8) else { return (nil, nil) }
        return (tag("modelName", in: xml), tag("friendlyName", in: xml))
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - stored state

    private static var stateURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wakey", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("tv.json")
    }

    private static func loadStored() -> Stored {
        guard let data = try? Data(contentsOf: stateURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private func saveStored() {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.stateURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.stateURL.path)
    }

    // MARK: - manifest

    private static let permissions: [String] = [
        "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
        "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
        "CONTROL_POWER", "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
        "READ_NETWORK_STATE", "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST",
        "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE", "READ_COUNTRY_INFO", "READ_SETTINGS",
        "CONTROL_TV_SCREEN", "CONTROL_TV_STANBY", "CONTROL_FAVORITE_GROUP", "CONTROL_USER_INFO",
        "CHECK_BLUETOOTH_DEVICE", "CONTROL_BLUETOOTH", "CONTROL_TIMER_INFO",
        "STB_INTERNAL_CONNECTION", "CONTROL_RECORDING", "READ_RECORDING_STATE",
        "WRITE_RECORDING_LIST", "READ_RECORDING_LIST", "READ_RECORDING_SCHEDULE",
        "WRITE_RECORDING_SCHEDULE", "READ_STORAGE_DEVICE_LIST", "READ_TV_PROGRAM_INFO",
        "READ_TV_CURRENT_TIME", "READ_TV_CONTENT_STATE", "READ_UPDATE_INFO",
        "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD", "WRITE_SETTINGS",
    ]

    private static let manifest: [String: Any] = [
        "manifestVersion": 1,
        "appVersion": "1.0",
        "signed": [
            "created": "20261119",
            "appId": "com.sortedbits.wakey",
            "vendorId": "com.sortedbits",
            "localizedAppNames": ["": "Wakey"],
            "localizedVendorNames": ["": "Sorted Bits"],
            "permissions": permissions,
        ],
        "permissions": permissions,
    ]
}

// MARK: - URLSession delegate

extension TVController: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        openTimeout?.cancel()
        openTimeout = nil
        isOpen = true
        log("TV: socket open")
        sendRegister(withKey: stored.clientKey != nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        handleDisconnect(reason: "closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, task === self.task else { return }
        handleDisconnect(reason: error.localizedDescription)
    }
}

extension TVController: URLSessionDelegate {

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              challenge.protectionSpace.port == 3001,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let fingerprint = Self.fingerprint(of: trust)
        if let expected = stored.fingerprint, expected != fingerprint {
            log("TV: certificate fingerprint changed — refusing the connection")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if stored.fingerprint == nil {
            stored.fingerprint = fingerprint
            saveStored()
            log("TV: pinned certificate \(fingerprint.prefix(16))…")
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func fingerprint(of trust: SecTrust) -> String {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return "unknown" }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
