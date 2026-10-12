// SPDX-License-Identifier: AGPL-3.0-only

/// A point in global display coordinates: the CoreGraphics convention used by
/// event locations, with the origin at the top-left of the main display and
/// y increasing downward.
public struct Point: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct Rect: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }
    public var midX: Double { minX + width / 2 }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
    }

    /// Half-open containment, matching how the cursor occupies pixels.
    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }
}

public struct Display: Equatable, Hashable, Sendable, Identifiable {
    public var id: UInt32
    public var frame: Rect

    public init(id: UInt32, frame: Rect) {
        self.id = id
        self.frame = frame
    }
}

public enum Side: String, Codable, Sendable, CaseIterable {
    case left, right

    /// +1 when moving outward through this side means increasing x.
    public var outward: Double { self == .right ? 1 : -1 }
}

public enum Orientation: String, Codable, Sendable, CaseIterable {
    case portrait, landscape
}

/// Where the iPhone sits beside a Mac display and how large it appears.
///
/// The phone is a virtual rectangle, never a real display. Its size in Mac points
/// sets how much of the shared edge leads to it; pointer speed on the phone is a
/// separate setting (`SessionSettings.pointerSpeed`).
public struct PhoneLayout: Equatable, Hashable, Sendable, Codable {
    public var displayID: UInt32
    public var side: Side
    /// Centre of the phone along the shared edge: 0 = top of the display, 1 = bottom.
    public var verticalPosition: Double
    /// Length of the phone's long side in Mac points.
    public var size: Double
    public var orientation: Orientation
    /// Short side divided by long side of the phone screen (iPhone 15 Pro: 393/852).
    public var aspectRatio: Double

    public static let sizeRange: ClosedRange<Double> = 240...1600
    /// The default size; at pointer speed 1 the phone pointer moves as it always
    /// did at this size, whatever size is chosen.
    public static let referenceSize = 620.0
    public static let defaultAspectRatio = 393.0 / 852.0

    public init(displayID: UInt32, side: Side = .right, verticalPosition: Double = 0.5,
                size: Double = 620, orientation: Orientation = .portrait,
                aspectRatio: Double = PhoneLayout.defaultAspectRatio) {
        self.displayID = displayID
        self.side = side
        self.verticalPosition = verticalPosition
        self.size = size
        self.orientation = orientation
        self.aspectRatio = aspectRatio
    }

    /// The phone screen's size in Mac points for the current orientation.
    public var phoneSize: (width: Double, height: Double) {
        let long = size, short = size * aspectRatio
        return orientation == .portrait ? (short, long) : (long, short)
    }

    /// Clamps every field to a usable range. Saved settings pass through this.
    public func sanitized() -> PhoneLayout {
        var copy = self
        copy.verticalPosition = verticalPosition.isFinite ? min(1, max(0, verticalPosition)) : 0.5
        copy.size = size.isFinite ? min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size)) : 620
        copy.aspectRatio = aspectRatio.isFinite ? min(1, max(0.3, aspectRatio)) : Self.defaultAspectRatio
        return copy
    }
}

/// The resolved relationship between one Mac display and the virtual phone.
public struct ScreenLink: Equatable, Sendable {
    public let display: Rect
    public let phone: Rect
    public let side: Side
    /// The part of the edge the phone shares with the display, as y ranges.
    /// Segments covered by another real display stay with that display.
    public let openSpans: [ClosedRange<Double>]
    /// Where pushing against the edge crosses: the shared edge plus a margin past
    /// each end, so a push that just misses the phone enters it at its nearest
    /// corner instead of meeting a wall.
    public let crossingSpans: [ClosedRange<Double>]

    /// How far past each end of the phone a push still crosses.
    public static let snapMargin = 80.0
    /// The margin never reaches this close to the display's top or bottom, which
    /// belong to the menu bar and the hot corners.
    public static let cornerGuard = 40.0

    /// x of the display column the cursor occupies at the shared edge.
    public var edgeColumn: Double { side == .right ? display.maxX - 1 : display.minX }

    public init?(layout: PhoneLayout, displays: [Display]) {
        let layout = layout.sanitized()
        guard let target = displays.first(where: { $0.id == layout.displayID }), target.frame.isValid else {
            return nil
        }
        let display = target.frame
        let (width, height) = layout.phoneSize
        // Keep at least a quarter of the phone (or the whole display) overlapping the edge.
        let centre = display.minY + layout.verticalPosition * display.height
        var top = centre - height / 2
        let overlap = min(height, display.height) / 4
        top = min(max(top, display.minY - height + overlap), display.maxY - overlap)
        let phoneX = layout.side == .right ? display.maxX : display.minX - width
        let phone = Rect(x: phoneX, y: top, width: width, height: height)

        let low = max(display.minY, phone.minY), high = min(display.maxY, phone.maxY)
        guard high - low >= 1 else { return nil }
        // Remove the parts of the edge where another display continues the desktop.
        let probeX = layout.side == .right ? display.maxX + 0.5 : display.minX - 0.5
        let neighbours = displays.filter {
            $0.id != target.id && $0.frame.isValid && probeX >= $0.frame.minX && probeX < $0.frame.maxX
        }
        let spans = Self.uncovered(low...high, by: neighbours)
        guard !spans.isEmpty else { return nil }
        let reachLow = min(low, max(display.minY + Self.cornerGuard, phone.minY - Self.snapMargin))
        let reachHigh = max(high, min(display.maxY - Self.cornerGuard, phone.maxY + Self.snapMargin))
        self.display = display
        self.phone = phone
        self.side = layout.side
        self.openSpans = spans
        // Margins only extend the shared edge; they never stand alone beyond another display.
        self.crossingSpans = Self.uncovered(reachLow...reachHigh, by: neighbours)
            .filter { reach in spans.contains { $0.overlaps(reach) } }
    }

    private static func uncovered(_ range: ClosedRange<Double>, by displays: [Display]) -> [ClosedRange<Double>] {
        var spans = [range]
        for f in displays.map(\.frame) {
            spans = spans.flatMap { span -> [ClosedRange<Double>] in
                if f.maxY <= span.lowerBound || f.minY >= span.upperBound { return [span] }
                var pieces: [ClosedRange<Double>] = []
                if f.minY > span.lowerBound { pieces.append(span.lowerBound...f.minY) }
                if f.maxY < span.upperBound { pieces.append(f.maxY...span.upperBound) }
                return pieces
            }
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= 1 }
    }

    /// The arrangement a dragged phone snaps to: the exposed display edge nearest to
    /// where its centre was dropped (global coordinates), at that height. Edges a
    /// neighbouring display covers are never offered. Nil if no edge is usable.
    public static func snappedLayout(centre: Point, base: PhoneLayout, displays: [Display]) -> PhoneLayout? {
        var best: (layout: PhoneLayout, distance: Double)?
        for display in displays where display.frame.isValid {
            let frame = display.frame
            for side in Side.allCases {
                var layout = base
                layout.displayID = display.id
                layout.side = side
                layout.verticalPosition = min(1, max(0, (centre.y - frame.minY) / frame.height))
                guard let link = ScreenLink(layout: layout, displays: displays) else { continue }
                let edgeX = side == .right ? frame.maxX + link.phone.width / 2 : frame.minX - link.phone.width / 2
                let beyond = max(0, abs(centre.y - frame.midY) - frame.height / 2)
                let distance = ((centre.x - edgeX) * (centre.x - edgeX) + beyond * beyond).squareRoot()
                if best == nil || distance < best!.distance { best = (layout, distance) }
            }
        }
        return best?.layout
    }

    /// True where pushing against the edge at Mac height `y` crosses onto the phone.
    public func isOpen(atY y: Double) -> Bool {
        crossingSpans.contains { y >= $0.lowerBound && y < $0.upperBound }
    }

    /// Mac location where the cursor reappears when leaving the phone at phone-local y.
    public func returnPoint(phoneY: Double) -> Point {
        let y = phone.minY + phoneY
        // Snap into the nearest open span so the cursor lands on the shared edge.
        let clampedY = openSpans
            .map { min(max(y, $0.lowerBound), $0.upperBound - 1) }
            .min(by: { abs($0 - y) < abs($1 - y) }) ?? display.midY
        return Point(x: edgeColumn, y: clampedY)
    }

    /// Phone-local position for a cursor that crossed the edge at Mac y.
    public func entryPoint(macY: Double, inset: Double) -> Point {
        let x = side == .right ? inset : phone.width - inset
        return Point(x: x, y: min(max(macY - phone.minY, 0), phone.height - 1))
    }
}
