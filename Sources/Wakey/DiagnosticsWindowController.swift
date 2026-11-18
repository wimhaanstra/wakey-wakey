import AppKit

/// Read-only log viewer.
final class DiagnosticsWindowController: NSWindowController {
    private let textView = NSTextView()
    private let footerHeight: CGFloat = 18

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wakey — diagnostics"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)

        guard let content = window.contentView else { return }
        let bounds = content.bounds
        let scrollFrame = NSRect(x: 0, y: footerHeight, width: bounds.width, height: bounds.height - footerHeight)

        let scroll = NSScrollView(frame: scrollFrame)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let textViewFrame = NSRect(origin: .zero, size: scrollFrame.size)
        textView.frame = textViewFrame
        textView.minSize = NSSize(width: 0, height: textViewFrame.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true

        scroll.documentView = textView
        content.addSubview(scroll)

        let footer = NSTextField(labelWithString: "log: \(Log.shared.logPath)")
        footer.frame = NSRect(x: 8, y: 3, width: bounds.width - 16, height: 14)
        footer.autoresizingMask = [.width]
        footer.font = NSFont.systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingMiddle
        content.addSubview(footer)

        reload()

        Log.shared.onLine = { [weak self] _ in
            self?.reload()
        }
    }

    /// Used by `--selftest` to make sure the text view got a real frame.
    func layoutReport() -> String {
        let size = textView.frame.size
        return String(format: "text view %.0fx%.0f — %@", size.width, size.height,
                      size.width > 0 && size.height > 0 ? "ok" : "ZERO FRAME")
    }

    private func reload() {
        textView.string = Log.shared.lines().joined(separator: "\n")
        textView.scrollToEndOfDocument(nil)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reload()
        window?.makeKeyAndOrderFront(sender)
    }
}
