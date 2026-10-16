// SPDX-License-Identifier: AGPL-3.0-only

public enum ScrollStyle: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    /// Press and drag at the pointer, like a finger. Reliable on iPhone; the
    /// AssistiveTouch pointer moves with the content while scrolling.
    case drag
    /// Mouse-wheel reports: the pointer stays still and iPhone moves the page in steps
    /// (it jumps per step rather than gliding). A pointer swipe up from the bottom edge
    /// would stop iPhone acting on the wheel, so in this mode that swipe becomes Home.
    case wheel
    /// Two-finger scrolling does nothing on the phone (and never reaches the Mac).
    case off
}

public struct ScrollSettings: Equatable, Hashable, Sendable, Codable {
    public var style: ScrollStyle
    /// Distance multiplier: 1 sends one wheel step per `ScrollConverter.pointsPerStep`
    /// points of trackpad movement, or one step per wheel line.
    public var speed: Double
    /// Inverts the direction relative to the Mac's own scrolling direction.
    public var reversed: Bool
    /// Sends horizontal scrolling (only when the active HID profile supports it).
    public var horizontal: Bool
    /// Forwards trackpad momentum after the fingers lift.
    public var momentum: Bool

    public static let speedRange: ClosedRange<Double> = 0.25...4

    public init(style: ScrollStyle = .drag, speed: Double = 1, reversed: Bool = false, horizontal: Bool = true,
                momentum: Bool = true) {
        self.style = style
        self.speed = speed
        self.reversed = reversed
        self.horizontal = horizontal
        self.momentum = momentum
    }

    private enum CodingKeys: String, CodingKey { case style, speed, reversed, horizontal, momentum }

    /// Settings saved before `style` existed decode with the default style.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(ScrollStyle.self, forKey: .style) ?? .drag
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        reversed = try container.decodeIfPresent(Bool.self, forKey: .reversed) ?? false
        horizontal = try container.decodeIfPresent(Bool.self, forKey: .horizontal) ?? true
        momentum = try container.decodeIfPresent(Bool.self, forKey: .momentum) ?? true
    }

    public func sanitized() -> ScrollSettings {
        var copy = self
        copy.speed = speed.isFinite ? min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed)) : 1
        return copy
    }
}

/// Turns Mac scroll deltas into whole HID wheel/pan steps.
///
/// The Mac reports trackpad scrolling in points (already adjusted for the user's
/// natural-scrolling preference); the phone only accepts whole wheel steps, so the
/// fractional remainder is carried between events. A new gesture or a change of
/// direction drops the remainder so reversing never fights earlier movement.
public struct ScrollConverter: Sendable {
    /// Trackpad points per wheel step at speed 1: about how far iPhone moves content
    /// per step (20–35 points, measured in Settings), so the page follows the fingers.
    public static let pointsPerStep: Double = 30
    /// The share of the trackpad's momentum (after the fingers lift) passed on: a flick
    /// coasts a little instead of running to the end of a long page.
    public static let momentumShare = 0.25
    /// Trackpad scrolling sends at most one step per event, so iPhone animates a steady
    /// stream instead of jumping; up to this many steps wait their turn, and more is dropped.
    public static let carriedSteps = 3.0

    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    public mutating func convert(_ input: ScrollInput, settings: ScrollSettings) -> ScrollReport {
        let settings = settings.sanitized()
        if input.phase == .began || input.phase == .mayBegin { reset() }
        if input.momentum != .none && !settings.momentum { return ScrollReport() }
        // iOS treats a positive wheel value as "content moves up", the opposite of the
        // Mac's delta sign, so the default flips the sign to keep both screens alike.
        let sign: Double = settings.reversed ? 1 : -1
        var scale = settings.speed / (input.continuous ? Self.pointsPerStep : 1)
        if input.momentum != .none { scale *= Self.momentumShare }
        let limit = input.continuous ? 1 : nil as Int?
        let wheel = Self.steps(input.dy * sign * scale, remainder: &remainderY, limit: limit)
        let pan = settings.horizontal ? Self.steps(-input.dx * sign * scale, remainder: &remainderX, limit: limit) : 0
        return ScrollReport(wheel: wheel, pan: pan)
    }

    private static func steps(_ amount: Double, remainder: inout Double, limit: Int?) -> Int {
        guard amount.isFinite, abs(amount) < 100_000 else {
            remainder = 0
            return 0
        }
        if amount * remainder < 0 { remainder = 0 }
        remainder += amount
        // Absorb floating-point noise at whole-step boundaries (e.g. 0.9999999).
        let nearest = remainder.rounded()
        if abs(remainder - nearest) < 1e-9 { remainder = nearest }
        var whole = remainder.rounded(.towardZero)
        if let limit { whole = max(-Double(limit), min(Double(limit), whole)) }
        remainder -= whole
        if limit != nil { remainder = max(-carriedSteps, min(carriedSteps, remainder)) }
        return Int(whole)
    }
}
