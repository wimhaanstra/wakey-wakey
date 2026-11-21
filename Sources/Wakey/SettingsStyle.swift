import AppKit

/// Shared visual language for the settings window, modelled on System Settings: a translucent
/// source-list sidebar and grouped, rounded cards in the detail pane.
enum SettingsStyle {

    static let sidebarWidth: CGFloat = 230
    static let sidebarTopInset: CGFloat = 46
    static let detailTopInset: CGFloat = 46
    static let detailHeaderHeight: CGFloat = 58
    static let headerSpacing: CGFloat = 14
    static let contentInset: CGFloat = 40
    static let cardRadius: CGFloat = 10
    static let rowInsets = NSEdgeInsets(top: 11, left: 16, bottom: 11, right: 16)

    /// Symbols used by the sidebar; `--selftest` reports any that are unavailable.
    static let sectionSymbols = [
        "slider.horizontal.3",
        "menubar.rectangle",
        "person.crop.circle",
        "antenna.radiowaves.left.and.right",
        "keyboard",
        "tv",
        "wrench.and.screwdriver",
        "mic.fill",
        "arrow.left.arrow.right",
    ]

    static func missingSymbols() -> [String] {
        sectionSymbols.filter {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    /// A white SF Symbol on a coloured rounded square, the way System Settings marks its panes.
    static func sidebarIcon(symbol: String, color: NSColor) -> NSImage {
        let key = "\(symbol)|\(color.description)"
        if let cached = iconCache[key] { return cached }

        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5).fill()

            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (side - size.width) / 2,
                                      y: (side - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
        iconCache[key] = image
        return image
    }

    /// Slightly darker than the detail background in light mode, slightly lighter in dark mode.
    static func cardFill(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0.955, alpha: 1)
    }
}

/// Rounded background shared by every settings card.
final class SettingsCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SettingsStyle.cardFill(for: effectiveAppearance).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: SettingsStyle.cardRadius,
                     yRadius: SettingsStyle.cardRadius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Hairline between two rows, inset so it starts under the row text rather than at the card edge.
final class SettingsSeparatorView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 16, y: 0, width: max(0, bounds.width - 16), height: 1).fill()
    }
}

/// The detail pane: opaque so the translucent sidebar reads as a separate column.
final class SettingsDetailView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Document views live in a flipped coordinate space so content starts at the top and scrolling
/// does not put short panes at the bottom.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
