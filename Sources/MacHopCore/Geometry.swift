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

    /// A point given relative to an edge on `side`: `along` it and `across` it.
    public init(along: Double, across: Double, side: Side) {
        self = side.isHorizontal ? Point(x: along, y: across) : Point(x: across, y: along)
    }

    /// The coordinate along an edge on `side`: y beside the screen, x above it.
    public func along(_ side: Side) -> Double { side.isHorizontal ? x : y }
    /// The coordinate across an edge on `side`: x beside the screen, y above it.
    public func across(_ side: Side) -> Double { side.isHorizontal ? y : x }

    /// This point moved `distance` outward through an edge on `side` (negative moves inward).
    public func offset(outward distance: Double, through side: Side) -> Point {
        Point(along: along(side), across: across(side) + distance * side.outward, side: side)
    }
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

    /// The rectangle's extent along an edge on `side` (its y range beside the screen, x range above it).
    public func along(_ side: Side) -> (min: Double, max: Double) { side.isHorizontal ? (minX, maxX) : (minY, maxY) }
    /// The rectangle's extent across an edge on `side`.
    public func across(_ side: Side) -> (min: Double, max: Double) { side.isHorizontal ? (minY, maxY) : (minX, maxX) }

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

/// The display edge the iPhone sits against.
public enum Side: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom

    /// +1 when moving outward through this side increases the coordinate across
    /// the edge (x beside the screen, y above or below it); -1 when it decreases it.
    public var outward: Double { self == .right || self == .bottom ? 1 : -1 }
    /// True for the top and bottom edges, which run left to right.
    public var isHorizontal: Bool { self == .top || self == .bottom }
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
    /// Centre of the phone along the shared edge: 0 = its top (or left) end, 1 = its bottom (or right) end.
    public var edgePosition: Double
    /// Length of the phone's long side in Mac points.
    public var size: Double
    public var orientation: Orientation
    /// Turned around: the Dynamic Island at the bottom in portrait, on the right in
    /// landscape (instead of the top, or the left).
    public var flipped: Bool
    /// Short side divided by long side of the phone screen (iPhone 15 Pro: 393/852).
    public var aspectRatio: Double

    public static let sizeRange: ClosedRange<Double> = 240...1600
    /// The default size; at pointer speed 1 the phone pointer moves as it always
    /// did at this size, whatever size is chosen.
    public static let referenceSize = 620.0
    public static let defaultAspectRatio = 393.0 / 852.0

    enum CodingKeys: String, CodingKey {
        // Saved before the top edge existed, when the position was always vertical.
        case edgePosition = "verticalPosition"
        case displayID, side, size, orientation, flipped, aspectRatio
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decode(UInt32.self, forKey: .displayID)
        side = try values.decode(Side.self, forKey: .side)
        edgePosition = try values.decode(Double.self, forKey: .edgePosition)
        size = try values.decode(Double.self, forKey: .size)
        orientation = try values.decode(Orientation.self, forKey: .orientation)
        // Absent in settings saved before the iPhone could be turned around.
        flipped = try values.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        aspectRatio = try values.decode(Double.self, forKey: .aspectRatio)
    }

    public init(displayID: UInt32, side: Side = .right, edgePosition: Double = 0.5,
                size: Double = 620, orientation: Orientation = .portrait, flipped: Bool = false,
                aspectRatio: Double = PhoneLayout.defaultAspectRatio) {
        self.displayID = displayID
        self.side = side
        self.edgePosition = edgePosition
        self.size = size
        self.orientation = orientation
        self.flipped = flipped
        self.aspectRatio = aspectRatio
    }

    /// Where a point on the phone as it sits (fractions of its width and height, as
    /// drawn) lies on the iPhone's own screen. iOS places the pointer in its screen's
    /// native frame, upright portrait, whichever way the phone is turned.
    public func screenFraction(x: Double, y: Double) -> (x: Double, y: Double) {
        switch (orientation, flipped) {
        case (.portrait, false): (x, y)
        case (.portrait, true): (1 - x, 1 - y)
        // Turned anticlockwise, the Dynamic Island on the left: its top is the phone's left.
        case (.landscape, false): (1 - y, x)
        case (.landscape, true): (y, 1 - x)
        }
    }

    /// The phone screen's size in Mac points for the current orientation.
    public var phoneSize: (width: Double, height: Double) {
        let long = size, short = size * aspectRatio
        return orientation == .portrait ? (short, long) : (long, short)
    }

    /// Clamps every field to a usable range. Saved settings pass through this.
    public func sanitized() -> PhoneLayout {
        var copy = self
        copy.edgePosition = edgePosition.isFinite ? min(1, max(0, edgePosition)) : 0.5
        copy.size = size.isFinite ? min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size)) : 620
        copy.aspectRatio = aspectRatio.isFinite ? min(1, max(0.3, aspectRatio)) : Self.defaultAspectRatio
        return copy
    }
}

/// The resolved relationship between one Mac display and the virtual phone.
///
/// Edge positions are given `along` the shared edge (y beside the screen, x above
/// it) and `across` it, so the same rules serve the side and top edges.
public struct ScreenLink: Equatable, Sendable {
    public let display: Rect
    public let phone: Rect
    public let side: Side
    /// The part of the edge the phone shares with the display, as ranges along it.
    /// Segments covered by another real display stay with that display.
    public let openSpans: [ClosedRange<Double>]
    /// Where pushing against the edge crosses: the shared edge plus a margin past
    /// each end, so a push that just misses the phone enters it at its nearest
    /// corner instead of meeting a wall.
    public let crossingSpans: [ClosedRange<Double>]

    /// How far past each end of the phone a push still crosses.
    public static let snapMargin = 80.0
    /// The margin never reaches this close to either end of the edge, which belong
    /// to the menu bar, the Dock and the hot corners.
    public static let cornerGuard = 40.0

    /// Across the edge: the display's outermost row or column of pixels at the shared edge.
    public var edgeLine: Double { side.outward > 0 ? display.across(side).max - 1 : display.across(side).min }

    /// The phone's size along the shared edge, and away from it.
    public var phoneLength: Double { phone.along(side).max - phone.along(side).min }
    public var phoneDepth: Double { phone.across(side).max - phone.across(side).min }
    /// The display's size away from the shared edge.
    public var displayDepth: Double { display.across(side).max - display.across(side).min }

    public init?(layout: PhoneLayout, displays: [Display]) {
        let layout = layout.sanitized()
        guard let target = displays.first(where: { $0.id == layout.displayID }), target.frame.isValid else {
            return nil
        }
        let display = target.frame, side = layout.side
        let (width, height) = layout.phoneSize
        let length = side.isHorizontal ? width : height, depth = side.isHorizontal ? height : width
        let edge = display.along(side), bounds = display.across(side)
        // Keep at least a quarter of the phone (or the whole edge) overlapping the edge.
        let centre = edge.min + layout.edgePosition * (edge.max - edge.min)
        let overlap = min(length, edge.max - edge.min) / 4
        let start = min(max(centre - length / 2, edge.min - length + overlap), edge.max - overlap)
        let origin = Point(along: start, across: side.outward > 0 ? bounds.max : bounds.min - depth, side: side)
        let phone = Rect(x: origin.x, y: origin.y, width: width, height: height)

        let low = max(edge.min, start), high = min(edge.max, start + length)
        guard high - low >= 1 else { return nil }
        // Remove the parts of the edge where another display continues the desktop.
        let probe = side.outward > 0 ? bounds.max + 0.5 : bounds.min - 0.5
        let neighbours = displays.filter {
            $0.id != target.id && $0.frame.isValid && probe >= $0.frame.across(side).min && probe < $0.frame.across(side).max
        }
        let spans = Self.uncovered(low...high, by: neighbours, side: side)
        guard !spans.isEmpty else { return nil }
        let reachLow = min(low, max(edge.min + Self.cornerGuard, start - Self.snapMargin))
        let reachHigh = max(high, min(edge.max - Self.cornerGuard, start + length + Self.snapMargin))
        self.display = display
        self.phone = phone
        self.side = side
        self.openSpans = spans
        // Margins only extend the shared edge; they never stand alone beyond another display.
        self.crossingSpans = Self.uncovered(reachLow...reachHigh, by: neighbours, side: side)
            .filter { reach in spans.contains { $0.overlaps(reach) } }
    }

    private static func uncovered(_ range: ClosedRange<Double>, by displays: [Display], side: Side) -> [ClosedRange<Double>] {
        var spans = [range]
        for f in displays.map({ $0.frame.along(side) }) {
            spans = spans.flatMap { span -> [ClosedRange<Double>] in
                if f.max <= span.lowerBound || f.min >= span.upperBound { return [span] }
                var pieces: [ClosedRange<Double>] = []
                if f.min > span.lowerBound { pieces.append(span.lowerBound...f.min) }
                if f.max < span.upperBound { pieces.append(f.max...span.upperBound) }
                return pieces
            }
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= 1 }
    }

    /// The arrangement a dragged phone snaps to: the exposed display edge nearest to
    /// where its centre was dropped (global coordinates), at that position. Edges a
    /// neighbouring display covers are never offered. Nil if no edge is usable.
    public static func snappedLayout(centre: Point, base: PhoneLayout, displays: [Display]) -> PhoneLayout? {
        var best: (layout: PhoneLayout, distance: Double)?
        for display in displays where display.frame.isValid {
            for side in Side.allCases {
                let edge = display.frame.along(side), bounds = display.frame.across(side)
                var layout = base
                layout.displayID = display.id
                layout.side = side
                layout.edgePosition = min(1, max(0, (centre.along(side) - edge.min) / (edge.max - edge.min)))
                guard let link = ScreenLink(layout: layout, displays: displays) else { continue }
                // Distance from where the phone's centre would sit on this edge.
                let home = side.outward > 0 ? bounds.max + link.phoneDepth / 2 : bounds.min - link.phoneDepth / 2
                let off = centre.across(side) - home
                let beyond = max(0, abs(centre.along(side) - (edge.min + edge.max) / 2) - (edge.max - edge.min) / 2)
                let distance = (off * off + beyond * beyond).squareRoot()
                if best == nil || distance < best!.distance { best = (layout, distance) }
            }
        }
        return best?.layout
    }

    /// True where pushing against the edge at `position` along it crosses onto the phone.
    public func isOpen(along position: Double) -> Bool {
        crossingSpans.contains { position >= $0.lowerBound && position < $0.upperBound }
    }

    /// Mac location where the cursor reappears when leaving the phone at phone-local
    /// position `phoneAlong` along the shared edge.
    public func returnPoint(phoneAlong: Double) -> Point {
        let position = phone.along(side).min + phoneAlong
        // Snap into the nearest open span so the cursor lands on the shared edge.
        let clamped = openSpans
            .map { min(max(position, $0.lowerBound), $0.upperBound - 1) }
            .min(by: { abs($0 - position) < abs($1 - position) })
            ?? (display.along(side).min + display.along(side).max) / 2
        return Point(along: clamped, across: edgeLine, side: side)
    }

    /// Phone-local position for a cursor that crossed the edge at Mac position
    /// `macAlong`, `inset` points in from the phone's edge facing the Mac.
    public func entryPoint(macAlong: Double, inset: Double) -> Point {
        let along = min(max(macAlong - phone.along(side).min, 0), phoneLength - 1)
        return Point(along: along, across: side.outward > 0 ? inset : phoneDepth - inset, side: side)
    }
}
