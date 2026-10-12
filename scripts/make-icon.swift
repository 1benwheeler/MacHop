// SPDX-License-Identifier: AGPL-3.0-only
// Draws MacHop's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repository root)
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // Squircle background (macOS icon grid: 824 pt body on a 1024 canvas), sky to indigo to violet.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 22 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(red: 0.33, green: 0.36, blue: 0.98, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1),
                        NSColor(red: 0.33, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(red: 0.50, green: 0.30, blue: 0.95, alpha: 1)])!.draw(in: body, angle: -70)

    // The mark: a lowercase m drawn as two hops, a big one (the Mac) and a smaller one
    // (the iPhone), landing on a dot (the iPhone's pointer). Same geometry as MenuBarIcon.swift.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let width: CGFloat = 112 * s, base: CGFloat = 318
    let first = NSBezierPath()
    first.move(to: NSPoint(x: 292 * s, y: base * s))
    first.line(to: NSPoint(x: 292 * s, y: 560 * s))
    first.appendArc(withCenter: NSPoint(x: 426 * s, y: 560 * s), radius: 134 * s, startAngle: 180, endAngle: 0, clockwise: true)
    first.line(to: NSPoint(x: 560 * s, y: base * s))
    let second = NSBezierPath()
    second.move(to: NSPoint(x: 560 * s, y: 460 * s))
    second.appendArc(withCenter: NSPoint(x: 652 * s, y: 460 * s), radius: 92 * s, startAngle: 180, endAngle: 0, clockwise: true)
    for path in [first, second] {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    NSBezierPath(ovalIn: NSRect(x: 744 * s - width / 2, y: (base + 6) * s - width / 2, width: width, height: width)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! drawIcon(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/images/icon.png"))
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
