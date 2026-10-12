// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// MacHop's mark: a lowercase m drawn as two hops, a big one (the Mac) and a smaller
/// one (the iPhone), landing on a dot (the iPhone's pointer). Same geometry as the
/// app icon (scripts/make-icon.swift), in its 1024-point space.
enum MacHopMark {
    static func paths(lineWidth width: CGFloat) -> (strokes: [NSBezierPath], dot: NSBezierPath) {
        let base: CGFloat = 318
        let first = NSBezierPath()
        first.move(to: NSPoint(x: 292, y: base))
        first.line(to: NSPoint(x: 292, y: 560))
        first.appendArc(withCenter: NSPoint(x: 426, y: 560), radius: 134, startAngle: 180, endAngle: 0, clockwise: true)
        first.line(to: NSPoint(x: 560, y: base))
        let second = NSBezierPath()
        second.move(to: NSPoint(x: 560, y: 460))
        second.appendArc(withCenter: NSPoint(x: 652, y: 460), radius: 92, startAngle: 180, endAngle: 0, clockwise: true)
        let dot = NSBezierPath(ovalIn: NSRect(x: 744 - width / 2, y: base + 6 - width / 2, width: width, height: width))
        return ([first, second], dot)
    }

    /// The mark as a menu-bar template image (black on clear; macOS tints it).
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { rect in
            let width: CGFloat = 92   // lighter than the icon's 112, to sit with other menu-bar glyphs
            let minX = 292 - width / 2, maxX = 744 + width / 2
            let minY = 324 - width / 2, maxY = 694 + width / 2
            let scale = min((rect.width - 2) / (maxX - minX), (rect.height - 2) / (maxY - minY))
            let transform = AffineTransform(translationByX: rect.midX - (minX + maxX) / 2 * scale,
                                            byY: rect.midY - (minY + maxY) / 2 * scale)
                .scaledBy(scale)
            let (strokes, dot) = paths(lineWidth: width)
            NSColor.black.set()
            for path in strokes {
                path.transform(using: transform)
                path.lineWidth = width * scale
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            dot.transform(using: transform)
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension AffineTransform {
    func scaledBy(_ factor: CGFloat) -> AffineTransform {
        var copy = self
        copy.scale(factor)
        return copy
    }
}
