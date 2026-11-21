import AppKit
import CoreGraphics
import QuartzCore

/// Double-tap Control → a brief “find my cursor” pulse around the pointer.
///
/// The overlay is a non-activating, click-through window at screenSaver level. It dims everything
/// except a soft radius around the cursor, draws three expanding rings, and puts a frosted lens over
/// the content below. No Screen Recording permission is involved: the lens is an NSVisualEffectView,
/// not a captured image, so it blurs rather than refracts.
final class CursorFinder {

    private var pollTimer: Timer?
    private var controlDown = false
    private var lastControlDown = Date.distantPast
    private var window: CursorHighlightWindow?
    private var hideWork: DispatchWorkItem?

    func start() {
        guard pollTimer == nil else { return }
        // Reading the session modifier state needs no Input Monitoring, unlike a key event tap.
        controlDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        log("CURSOR: double-Control listener active (modifier polling)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        hideWork?.cancel()
        window?.orderOut(nil)
        window = nil
    }

    func trigger() {
        guard let screen = screenUnderPointer() else { return }
        let pointer = NSEvent.mouseLocation
        let window = ensureWindow()
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 1
        window.orderFrontRegardless()

        if let view = window.contentView as? CursorHighlightView {
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            let local = window.convertPoint(fromScreen: pointer)
            view.pulse(at: local)
        }

        log("CURSOR: highlight at \(Int(pointer.x)),\(Int(pointer.y))")
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let down = flags.contains(.maskControl)
        guard down != controlDown else { return }
        controlDown = down
        guard down else { return }
        log("CURSOR: control down")

        let chord = flags.intersection([.maskCommand, .maskAlternate, .maskShift])
        guard chord.isEmpty else {
            lastControlDown = .distantPast
            return
        }

        let now = Date()
        if now.timeIntervalSince(lastControlDown) < 0.35 {
            lastControlDown = .distantPast
            trigger()
        } else {
            lastControlDown = now
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func ensureWindow() -> CursorHighlightWindow {
        if let window { return window }
        let window = CursorHighlightWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = CursorHighlightView(frame: .zero)
        self.window = window
        return window
    }
}

private final class CursorHighlightWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CursorHighlightView: NSView {

    private let lens = NSVisualEffectView()
    private let ringHost = NSView()
    private let dimLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        lens.material = .underWindowBackground
        lens.blendingMode = .behindWindow
        lens.state = .active
        lens.wantsLayer = true
        lens.layer?.cornerRadius = 46
        lens.layer?.masksToBounds = true
        lens.layer?.borderWidth = 1
        lens.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        lens.alphaValue = 0
        addSubview(lens)

        ringHost.wantsLayer = true
        ringHost.frame = bounds
        ringHost.autoresizingMask = [.width, .height]
        addSubview(ringHost)
    }

    override func layout() {
        super.layout()
        ringHost.frame = bounds
    }

    func pulse(at point: NSPoint) {
        guard let host = ringHost.layer else { return }
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        lens.layer?.removeAllAnimations()
        lens.alphaValue = 0
        lens.frame = NSRect(x: point.x - 46, y: point.y - 46, width: 92, height: 92)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            lens.animator().alphaValue = 0.95
        }

        // Dim everything outside a soft radius around the pointer.
        dimLayer.removeFromSuperlayer()
        dimLayer.frame = bounds
        dimLayer.type = .radial
        dimLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.42).cgColor,
        ]
        dimLayer.locations = [0, 1]
        dimLayer.startPoint = CGPoint(x: point.x / max(bounds.width, 1),
                                      y: point.y / max(bounds.height, 1))
        dimLayer.endPoint = CGPoint(x: (point.x + 340) / max(bounds.width, 1),
                                    y: point.y / max(bounds.height, 1))
        dimLayer.opacity = 0
        layer?.insertSublayer(dimLayer, at: 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        dimLayer.add(fade, forKey: "fade")
        dimLayer.opacity = 1

        let colors = [
            NSColor.white,
            NSColor.systemTeal,
            NSColor.white.withAlphaComponent(0.7),
        ]
        for index in 0..<3 {
            let radius: CGFloat = 28 + CGFloat(index) * 18
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            ring.position = point
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            ring.fillColor = nil
            ring.strokeColor = colors[index].withAlphaComponent(0.85).cgColor
            ring.lineWidth = 2.5 - CGFloat(index) * 0.5
            ring.shadowColor = colors[index].cgColor
            ring.shadowOpacity = 0.8
            ring.shadowRadius = 10
            ring.shadowOffset = .zero
            ring.opacity = 0
            host.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.35
            scale.toValue = 1.9
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 0.9, 0]
            opacity.keyTimes = [0, 0.2, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 0.95
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.1
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "pulse")
        }

        let dot = CAShapeLayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        dot.position = point
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
        dot.fillColor = NSColor.white.cgColor
        dot.shadowColor = NSColor.white.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 8
        dot.shadowOffset = .zero
        host.addSublayer(dot)

        let dotPulse = CABasicAnimation(keyPath: "transform.scale")
        dotPulse.fromValue = 0.7
        dotPulse.toValue = 1.25
        dotPulse.duration = 0.45
        dotPulse.autoreverses = true
        dotPulse.repeatCount = 2
        dotPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(dotPulse, forKey: "pulse")
    }
}
