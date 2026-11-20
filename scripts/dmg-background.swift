// Draws the DMG window background: an arrow from the app icon to Applications.
// Run: swift scripts/dmg-background.swift  → Resources/dmg-background.tiff (1x + 2x)
import AppKit

let size = NSSize(width: 540, height: 340)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    // Icon pictures are centred at y=150 from the top (Finder coordinates);
    // AppKit counts from the bottom.
    let y = size.height - 150
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 216, y: y))
    arrow.line(to: NSPoint(x: 306, y: y))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 1).setStroke()   // the app icon's purple
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 294, y: y + 12))
    head.line(to: NSPoint(x: 312, y: y))
    head.line(to: NSPoint(x: 294, y: y - 12))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    let text = "Drag to Applications to install" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
    ]
    let t = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: (size.width - t.width) / 2, y: 48), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)],
                                                          using: .lzw, factor: 0)!
try! tiff.write(to: URL(fileURLWithPath: "Resources/dmg-background.tiff"))
print("Wrote Resources/dmg-background.tiff")
