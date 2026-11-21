#!/usr/bin/env swift
// Renders the PMail app icon at every size macOS needs.
// Usage: swift Tools/make-icons.swift PMail/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let outputFolder = URL(fileURLWithPath: arguments.first ?? ".")
/// A second argument picks another body color, for trying alternatives: sky, lavender, coral or mint.
let palette = arguments.dropFirst().first ?? "lavender"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The body's gradient (top, bottom), its base fill and the shade its shadows take.
let bodyColors: (top: UInt32, bottom: UInt32, base: UInt32, shade: UInt32) = switch palette {
case "sky": (0xE0F2FF, 0xA8D6FF, 0xC4E4FF, 0x0F4C81)
case "coral": (0xFFE6E1, 0xFFB9AE, 0xFFD0C8, 0x8A1F12)
case "mint": (0xDDF8F2, 0xA3E6D8, 0xC0EFE5, 0x0E5E52)
default: (0xEAE6FF, 0xC2B6FF, 0xD7CFFF, 0x3B2A8F)
}

func shadow(_ hex: UInt32, _ alpha: CGFloat, blur: CGFloat, y: CGFloat) -> NSShadow {
    let shadow = NSShadow()
    shadow.shadowColor = color(hex, alpha)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: y)
    return shadow
}

/// Draws the icon in a 1024x1024 design space with a top-left origin.
func drawIcon() {
    // Body: a light rounded square on the macOS icon grid (824pt body, 100pt margin).
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    shadow(bodyColors.shade, 0.30, blur: 22, y: -10).set()
    color(bodyColors.base).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(bodyColors.top), ending: color(bodyColors.bottom))!.draw(in: bodyPath, angle: 90)

    // The envelope: white, with the logo's blue flap lines.
    let envelope = NSRect(x: 228, y: 262, width: 540, height: 372)
    let envelopePath = NSBezierPath(roundedRect: envelope, xRadius: 42, yRadius: 42)
    NSGraphicsContext.saveGraphicsState()
    shadow(bodyColors.shade, 0.28, blur: 20, y: -10).set()
    NSColor.white.setFill()
    envelopePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    envelopePath.addClip()
    let blue = color(0x1557E8)
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: envelope.minX + 44, y: envelope.minY + 52))
    flap.line(to: NSPoint(x: envelope.midX, y: envelope.minY + 214))
    flap.line(to: NSPoint(x: envelope.maxX - 44, y: envelope.minY + 52))
    flap.lineWidth = 30
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    blue.setStroke()
    flap.stroke()
    let folds = NSBezierPath()
    folds.move(to: NSPoint(x: envelope.minX + 44, y: envelope.maxY - 44))
    folds.line(to: NSPoint(x: envelope.minX + 196, y: envelope.minY + 168))
    folds.move(to: NSPoint(x: envelope.maxX - 44, y: envelope.maxY - 44))
    folds.line(to: NSPoint(x: envelope.maxX - 196, y: envelope.minY + 168))
    folds.lineWidth = 22
    folds.lineCapStyle = .round
    color(0x1557E8, 0.85).setStroke()
    folds.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The calendar in front of the envelope's right side: a red header with two rings, and a grid of days.
    let calendar = NSRect(x: 540, y: 470, width: 280, height: 290)
    let calendarPath = NSBezierPath(roundedRect: calendar, xRadius: 40, yRadius: 40)
    NSGraphicsContext.saveGraphicsState()
    shadow(0x5A0B0B, 0.30, blur: 20, y: -10).set()
    NSColor.white.setFill()
    calendarPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    calendarPath.addClip()
    color(0xEA3A2F).setFill()
    NSRect(x: calendar.minX, y: calendar.minY, width: calendar.width, height: 82).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xB9BEC8).setFill()
    for x in [calendar.minX + 82, calendar.maxX - 82 - 26] {
        NSBezierPath(roundedRect: NSRect(x: x, y: calendar.minY - 30, width: 26, height: 70), xRadius: 13, yRadius: 13).fill()
    }
    let cell: CGFloat = 50, gap: CGFloat = 22
    let gridWidth = cell * 3 + gap * 2
    let gridOrigin = NSPoint(x: calendar.midX - gridWidth / 2, y: calendar.minY + 82 + (calendar.height - 82 - gridWidth) / 2)
    for row in 0..<3 {
        for column in 0..<3 {
            let isToday = row == 1 && column == 1
            (isToday ? color(0xA3120B) : color(0xEA3A2F)).setFill()
            let square = NSRect(x: gridOrigin.x + CGFloat(column) * (cell + gap), y: gridOrigin.y + CGFloat(row) * (cell + gap),
                                width: cell, height: cell)
            NSBezierPath(roundedRect: square, xRadius: 10, yRadius: 10).fill()
        }
    }

    // Paw print badge on the left, overlapping the envelope's lower-left corner, as on every PuggleSoft icon.
    let center = NSPoint(x: 322, y: 724)
    let pads: [NSRect] = [
        NSRect(x: center.x - 92, y: center.y - 30, width: 184, height: 150),
        NSRect(x: center.x - 152, y: center.y - 112, width: 70, height: 88),
        NSRect(x: center.x - 82, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 10, y: center.y - 168, width: 72, height: 92),
        NSRect(x: center.x + 82, y: center.y - 112, width: 70, height: 88),
    ]
    NSGraphicsContext.saveGraphicsState()
    shadow(0x7C2D12, 0.25, blur: 12, y: -6).set()
    NSColor.white.setFill()
    for pad in pads { NSBezierPath(ovalIn: pad.insetBy(dx: -18, dy: -18)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFB020).setFill()
    for pad in pads { NSBezierPath(ovalIn: pad).fill() }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.translateX(by: 0, yBy: CGFloat(size))
    transform.scaleX(by: CGFloat(size) / 1024, yBy: -CGFloat(size) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: points * scale).write(to: outputFolder.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outputFolder.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icons to \(outputFolder.path)")
