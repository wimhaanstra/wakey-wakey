import AppKit

/// Menu and menu-bar icons for the mouse and keyboard.
///
/// Two rendering modes, chosen by the menu bar's appearance:
///
///  - **coloured** (dark bar): green badge, white glyphs. Colour can't adapt, but on a dark bar the
///    tint is unambiguous.
///  - **template** (light bar): everything black and rendered as a template image. This is the safe
///    mode — the menu bar's tint follows the *wallpaper*, not the system appearance (measured: the
///    status item reported `VibrantLight` while its neighbours were drawn light-on-dark), and only a
///    template image tracks whatever macOS decides. A baked-in colour would vanish there.
enum DeviceIcons {

    private static let height: CGFloat = 16
    private static let glyphWidth: CGFloat = 13

    private static var cache: [String: NSImage] = [:]

    /// Symbols we rely on, for the self-test — a missing one would leave a blank row icon.
    static let requiredSymbols = ["computermouse", "keyboard", "bolt.fill"]

    static func missingSymbols() -> [String] {
        requiredSymbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
    }

    // MARK: - menu row icons

    static func mouse(charging: Bool, colored: Bool) -> NSImage? {
        icon(glyph: "mouse", charging: charging, colored: colored, ink: mouseInk) { ink in
            guard let mouse = symbol("computermouse", pointSize: 12),
                  let fitted = fittedRect(mouse, in: ink) else { return }
            tinted(mouse, glyphColor(colored)).draw(in: fitted)
        }
    }

    static func keyboard(charging: Bool, colored: Bool) -> NSImage? {
        icon(glyph: "keyboard", charging: charging, colored: colored, ink: keyboardInk) { ink in
            drawHalfKeyboard(in: ink, colored: colored)
        }
    }

    private static func icon(glyph name: String, charging: Bool, colored: Bool,
                             ink: (NSRect) -> NSRect,
                             draw: @escaping (NSRect) -> Void) -> NSImage? {
        let key = "row|\(name)|\(charging)|\(colored)"
        if let cached = cache[key] { return cached }

        let box = NSRect(x: 0, y: 0, width: glyphWidth, height: height)
        let inkRect = ink(box)

        // Reserve the badge space even when idle, so menu titles don't shift as charge starts.
        let width = max(16, inkRect.maxX + 4.5)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            draw(box)
            if charging { drawChargingBadge(centreX: inkRect.maxX, colored: colored) }
            return true
        }
        image.isTemplate = !colored
        cache[key] = image
        return image
    }

    // MARK: - glyph geometry

    private static func mouseInk(_ box: NSRect) -> NSRect {
        guard let mouse = symbol("computermouse", pointSize: 12),
              let fitted = fittedRect(mouse, in: box) else { return box }
        return fitted
    }

    /// The keyboard symbol is ~2:1, so fitted whole it collapses to ~6 pt tall next to the mouse.
    /// Instead it is scaled to the full icon height and cut exactly through its middle, keeping the
    /// right half: close to square, keeps the height, and still reads as a keyboard.
    private static func keyboardInk(_ box: NSRect) -> NSRect {
        guard let keyboard = symbol("keyboard", pointSize: 12) else { return box }
        let scale = (box.height - 1) / keyboard.size.height
        let sliceWidth = keyboard.size.width * scale / 2
        return NSRect(x: box.midX - sliceWidth / 2, y: 0, width: sliceWidth, height: box.height)
    }

    private static func drawHalfKeyboard(in slice: NSRect, colored: Bool) {
        guard let keyboard = symbol("keyboard", pointSize: 12) else { return }
        let scale = (slice.height - 1) / keyboard.size.height
        let scaledWidth = keyboard.size.width * scale

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: slice).addClip()
        tinted(keyboard, glyphColor(colored)).draw(in: NSRect(x: slice.maxX - scaledWidth, y: 0,
                                                             width: scaledWidth, height: slice.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - charging badge

    /// Teams-style status badge overlapping the glyph's bottom-right:
    /// green disc with a white bolt when coloured, otherwise a solid disc with the bolt knocked out
    /// so it inherits the menu bar tint.
    private static func drawChargingBadge(centreX: CGFloat, colored: Bool) {
        let diameter: CGFloat = 9.5
        let rect = NSRect(x: centreX - diameter / 2, y: 0.5, width: diameter, height: diameter)

        guard let bolt = symbol("bolt.fill", pointSize: diameter * 0.62) else { return }
        let inset = rect.insetBy(dx: diameter * 0.19, dy: diameter * 0.19)
        let scale = min(inset.width / bolt.size.width, inset.height / bolt.size.height)
        let boltRect = NSRect(x: inset.midX - bolt.size.width * scale / 2,
                              y: inset.midY - bolt.size.height * scale / 2,
                              width: bolt.size.width * scale,
                              height: bolt.size.height * scale)

        if colored {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
            tinted(bolt, .white).draw(in: boltRect)
        } else {
            // Template mode: a ring with the bolt inside. Knock-on effects (destinationOut) do not
            // survive drawing a symbol image into the same context, so this needs no compositing.
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.35, dy: 0.35))
            NSColor.black.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            NSColor.black.setFill()
            boltRect.isEmpty ? () : tinted(bolt, .black).draw(in: boltRect)
        }
    }

    // MARK: - menu bar strip

    /// `[mouse] 76%  [keyboard] 75%` as one image. Either device may be omitted; both omitted returns
    /// nil so the caller can fall back to a plain status icon.
    static func statusBar(mouse: (percent: Int?, charging: Bool)?,
                          keyboard: (percent: Int?, charging: Bool)?,
                          colored: Bool) -> NSImage? {
        guard mouse != nil || keyboard != nil else { return nil }

        let key = "status|\(mouse.map { "\($0.percent.map(String.init) ?? "–")\($0.charging)" } ?? "off")"
            + "|\(keyboard.map { "\($0.percent.map(String.init) ?? "–")\($0.charging)" } ?? "off")"
            + "|\(colored)"
        if let cached = cache[key] { return cached }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font,
                                                         .foregroundColor: glyphColor(colored)]
        let badgeOverhang: CGFloat = 4
        let glyphToText: CGFloat = 1.5
        let separator: CGFloat = 8

        func text(for percent: Int?) -> (String, NSSize) {
            let value = percent.map { "\($0)%" } ?? "—"
            return (value, (value as NSString).size(withAttributes: attributes))
        }

        let mouseText = text(for: mouse?.percent)
        let keyboardText = text(for: keyboard?.percent)

        var width: CGFloat = 0
        if mouse != nil {
            width += glyphWidth + badgeOverhang + glyphToText + mouseText.1.width
            if keyboard != nil { width += separator }
        }
        if keyboard != nil {
            width += glyphWidth + badgeOverhang + glyphToText + keyboardText.1.width
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0

            if let mouse {
                if let device = symbol("computermouse", pointSize: 11),
                   let rect = fittedRect(device, in: NSRect(x: x, y: 0, width: glyphWidth, height: height)) {
                    tinted(device, glyphColor(colored)).draw(in: rect)
                }
                if mouse.charging { drawChargingBadge(centreX: x + glyphWidth - 1, colored: colored) }
                x += glyphWidth + badgeOverhang + glyphToText
                (mouseText.0 as NSString).draw(at: NSPoint(x: x, y: (height - mouseText.1.height) / 2),
                                               withAttributes: attributes)
                x += mouseText.1.width + separator
            }

            if let keyboard {
                drawHalfKeyboard(in: keyboardInk(NSRect(x: x, y: 0, width: glyphWidth, height: height)),
                                 colored: colored)
                if keyboard.charging { drawChargingBadge(centreX: x + glyphWidth - 1, colored: colored) }
                x += glyphWidth + badgeOverhang + glyphToText
                (keyboardText.0 as NSString).draw(at: NSPoint(x: x, y: (height - keyboardText.1.height) / 2),
                                                  withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = !colored
        cache[key] = image
        return image
    }

    // MARK: - helpers

    private static func glyphColor(_ colored: Bool) -> NSColor {
        colored ? .white : .black
    }

    /// Recolours a template symbol so it can be composited in colour.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)) ?? image
    }

    private static func fittedRect(_ image: NSImage, in rect: NSRect) -> NSRect? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let fittedHeight = size.height * scale
        return NSRect(x: rect.midX - width / 2, y: rect.midY - fittedHeight / 2,
                      width: width, height: fittedHeight)
    }
}
