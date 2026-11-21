import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics

/// Optional media-key bridge: volume keys drive the TV when it is the current audio output, and
/// brightness keys drive whichever controlled display the pointer is on. A session event tap is the
/// only way to see (and consume) the system-defined keys, so this is opt-in and needs Accessibility
/// — everything else in Wakey stays permission-free.
final class TVMediaKeys {

    var canHandleVolume: (() -> Bool)?
    var canHandleBrightness: (() -> Bool)?
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMute: (() -> Void)?
    var onBrightnessUp: (() -> Void)?
    var onBrightnessDown: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trustTimer: Timer?
    private var lastFire: [Int32: Date] = [:]

    var isRunning: Bool { tap != nil }

    /// Returns false when Accessibility has not been granted. With `prompt`, macOS shows the
    /// “add Wakey to Accessibility” sheet; the user has to flip the switch in System Settings.
    @discardableResult
    func start(prompt: Bool = true) -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else {
            if prompt {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                log("media keys: Accessibility not granted — enable Wakey in System Settings → Privacy & Security → Accessibility")
            } else {
                log("media keys: enabled but Accessibility is not granted")
            }
            if prompt { waitForAccessibility() }
            return false
        }

        let mask = CGEventMask(1 << 14) // kCGEventSystemDefined / NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("media keys: could not create the event tap")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("media keys: volume and brightness keys now drive the LG displays")
        return true
    }

    /// macOS does not restart the process when the switch is flipped in System Settings, so watch
    /// for the grant and create the tap as soon as it lands.
    private func waitForAccessibility() {
        trustTimer?.invalidate()
        let started = Date()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.trustTimer = nil
                log("media keys: Accessibility granted")
                _ = self.start(prompt: false)
            } else if Date().timeIntervalSince(started) > 120 {
                timer.invalidate()
                self.trustTimer = nil
                log("media keys: Accessibility still not granted — toggle the setting again after enabling it")
            }
        }
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        log("media keys: stopped")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == 14,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF0000) >> 16)
        let keyFlags = data & 0x0000FFFF
        let isDown = (keyFlags & 0x0100) == 0x0100

        guard let action = action(for: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // Swallow both edges so macOS does not also act on the key (volume HUD, brightness OSD).
        if isDown {
            let now = Date()
            if let last = lastFire[keyCode], now.timeIntervalSince(last) < 0.08 { return nil }
            lastFire[keyCode] = now
            action()
        }
        return nil
    }

    private func action(for keyCode: Int32) -> (() -> Void)? {
        switch keyCode {
        case 0: // NX_KEYTYPE_SOUND_UP
            guard isTVAudioOutput(), canHandleVolume?() == true else { return nil }
            return { [weak self] in self?.onVolumeUp?() }
        case 1: // NX_KEYTYPE_SOUND_DOWN
            guard isTVAudioOutput(), canHandleVolume?() == true else { return nil }
            return { [weak self] in self?.onVolumeDown?() }
        case 7: // NX_KEYTYPE_MUTE
            guard isTVAudioOutput(), canHandleVolume?() == true else { return nil }
            return { [weak self] in self?.onMute?() }
        case 2: // NX_KEYTYPE_BRIGHTNESS_UP
            guard canHandleBrightness?() == true else { return nil }
            return { [weak self] in self?.onBrightnessUp?() }
        case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
            guard canHandleBrightness?() == true else { return nil }
            return { [weak self] in self?.onBrightnessDown?() }
        default:
            return nil
        }
    }

    private func isTVAudioOutput() -> Bool {
        guard let name = Self.defaultOutputDeviceName() else { return false }
        return name.localizedCaseInsensitiveContains("LG TV")
            || name.localizedCaseInsensitiveContains("SSCR")
    }

    private static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        return status == noErr ? (name as String) : nil
    }
}

private func mediaKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<TVMediaKeys>.fromOpaque(refcon).takeUnretainedValue()
    return keys.handle(type: type, event: event)
}
