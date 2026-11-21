import AppKit

/// Small brightness HUD shown when a brightness key changes the TV or the DDC monitor.
///
/// It is a non-activating panel: it appears over whatever is frontmost without stealing focus,
/// follows the pointer's screen, and the slider is grabbable so a key press can be fine-tuned.
final class BrightnessHUD {

    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = BrightnessSlider()

    private var hideTimer: Timer?
    private var onChange: ((Int) -> Void)?
    private(set) var targetKey = ""
    private(set) var currentValue = 0
    private(set) var isVisible = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        build()
    }

    private func build() {
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = NSRect(x: 0, y: 0, width: 300, height: 76)
        panel.contentView = effect

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .right

        slider.minValue = 0
        slider.maxValue = 100
        slider.integerValue = 50
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.onDragStart = { [weak self] in
            self?.hideTimer?.invalidate()
            self?.hideTimer = nil
        }
        slider.onDragEnd = { [weak self] in
            self?.scheduleHide()
        }

        for view in [titleLabel, valueLabel, slider] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),

            valueLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            valueLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),

            slider.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
        ])
    }

    func show(key: String, title: String, value: Int, onChange: @escaping (Int) -> Void) {
        targetKey = key
        self.onChange = onChange
        titleLabel.stringValue = title
        setValue(value)
        positionOnPointerScreen()

        if !isVisible {
            log("HUD: \(title) \(value)%")
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        isVisible = true
        scheduleHide()
    }

    func setValue(_ value: Int) {
        currentValue = min(100, max(0, value))
        slider.integerValue = currentValue
        valueLabel.stringValue = "\(currentValue)%"
    }

    @objc private func sliderChanged() {
        currentValue = slider.integerValue
        valueLabel.stringValue = "\(currentValue)%"
        onChange?(currentValue)
        scheduleHide()
    }

    private func positionOnPointerScreen() {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = panel.frame.width
        let x = min(max(visible.minX + 12, visible.midX - width / 2), visible.maxX - width - 12)
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        guard isVisible else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) || self.slider.isDragging {
                self.scheduleHide()
                return
            }
            self.hide()
        }
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        hideTimer?.invalidate()
        hideTimer = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}

/// First click should grab the thumb, not merely focus the window.
private final class BrightnessSlider: NSSlider {
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onDragStart?()
        super.mouseDown(with: event)
        isDragging = false
        onDragEnd?()
    }
}
