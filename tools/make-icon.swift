// Generates Resources/AppIcon.icns from code — no design tools in the loop.
//   swift tools/make-icon.swift            # writes Resources/AppIcon.iconset + .icns
import AppKit
import Foundation

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(pixels)
    let hairline = max(1, s * 0.004)

    // Rounded-square background with a subtle vertical gradient.
    let inset = s * 0.055
    let background = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
        xRadius: s * 0.22, yRadius: s * 0.22
    )
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.15, green: 0.17, blue: 0.23, alpha: 1),
        ending: NSColor(srgbRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)
    )
    gradient?.draw(in: background, angle: -90)

    let screenFill = NSColor(srgbRed: 0.02, green: 0.03, blue: 0.05, alpha: 1)
    let lineColor = NSColor(srgbRed: 0.93, green: 0.95, blue: 0.99, alpha: 1)

    // Monitor: screen, neck, base.
    let screen = NSRect(x: s * 0.19, y: s * 0.36, width: s * 0.62, height: s * 0.38)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.045, yRadius: s * 0.045)
    screenFill.setFill()
    screenPath.fill()
    lineColor.setStroke()
    screenPath.lineWidth = max(hairline, s * 0.030)
    screenPath.stroke()

    let neck = NSRect(x: s * 0.47, y: s * 0.29, width: s * 0.06, height: s * 0.07)
    screenFill.setFill()
    NSBezierPath(rect: neck).fill()
    lineColor.setFill()
    NSBezierPath(rect: NSRect(x: s * 0.445, y: s * 0.27, width: s * 0.11, height: s * 0.022)).fill()
    let base = NSBezierPath(roundedRect: NSRect(x: s * 0.36, y: s * 0.235, width: s * 0.28, height: s * 0.028),
                            xRadius: s * 0.014, yRadius: s * 0.014)
    lineColor.setFill()
    base.fill()

    // Crescent moon on the screen: filled circle, then a cut-out circle in the screen colour.
    let radius = s * 0.082
    let centre = NSPoint(x: s * 0.63, y: s * 0.55)
    let moon = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                           width: 2 * radius, height: 2 * radius))
    NSColor(srgbRed: 0.46, green: 0.71, blue: 1.0, alpha: 1).setFill()
    moon.fill()

    let cutout = NSBezierPath(ovalIn: NSRect(x: centre.x - radius * 0.62, y: centre.y - radius * 0.40,
                                             width: 2 * radius, height: 2 * radius))
    screenFill.setFill()
    cutout.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let resources = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = URL(fileURLWithPath: resources).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for entry in entries {
    let pixels = entry.points * entry.scale
    guard let data = renderPNG(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(pixels)px\n".utf8))
        exit(1)
    }
    let suffix = entry.scale == 2 ? "@2x" : ""
    let name = "icon_\(entry.points)x\(entry.points)\(suffix).png"
    try data.write(to: iconset.appendingPathComponent(name))
}

print("wrote iconset \(iconset.path) — package it with: iconutil -c icns \(iconset.path) -o \(resources)/AppIcon.icns")
