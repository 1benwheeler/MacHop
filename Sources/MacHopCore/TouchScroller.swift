// SPDX-License-Identifier: AGPL-3.0-only

/// Turns a two-finger trackpad scroll into a press-and-drag on the phone that
/// behaves like holding the button and dragging.
///
/// iOS on iPhone offers no reliable way to scroll with the pointer standing still:
/// AssistiveTouch applies mouse-wheel reports only intermittently, and it ignores
/// touchpad and touchscreen reports (all measured on an iPhone 15 Pro, 12 Oct 2026).
/// A pointer drag scrolls every time, like a finger. So the drag starts at the
/// pointer, follows the fingers, and lets go where they stop; iOS adds its own
/// momentum, and the pointer stays where the drag ended.
///
/// Rules that keep this safe:
/// - Nothing is pressed until the fingers have actually moved, so resting two
///   fingers on the trackpad never taps.
/// - A press is never released close to where it started, which iOS would read
///   as a tap.
/// - Drags stay clear of the top and bottom edges, where iOS treats a drag as
///   opening Notification/Control Centre or going Home.
///
/// A long scroll re-grips instead of running the pointer to the top of the screen:
/// once a stroke has carried the pointer `strokeSpan` from where it pressed (or to
/// the edge of the safe area), it lets go there, the pointer hops back to where the
/// scroll began, and a new stroke carries on with the rest of the movement.
public struct TouchScroller: Sendable {
    public enum Action: Equatable, Sendable {
        /// Press, move while pressed, release; `hop` moves the pointer with nothing pressed.
        case press(Point), move(Point), release(Point), hop(Point)
    }

    /// Where the pointer was when scrolling began (phone points).
    public let anchor: Point
    /// Area drags stay inside.
    public let safeArea: Rect
    /// Minimum distance between press and release (phone points; iOS's tap slop is about 10).
    public static let slop = 12.0
    /// Room a drag needs ahead of it before it may start where the pointer is.
    static let minimumRoom = 40.0
    /// The furthest one stroke carries the pointer before re-gripping, as a share of
    /// the screen's height.
    public static let strokeSpan = 0.3

    private var pending = Point.zero
    private var pressedAt: Point?
    private var touch: Point?
    /// Where the first stroke pressed; later strokes re-grip here.
    private var grip: Point?
    private let span: Double
    /// Without re-gripping (a relative pointer can't hop back exactly), a drag that
    /// reaches the edge lets go there and the rest of the gesture is ignored.
    private let regrip: Bool
    private var exhausted = false
    private var lastDirection = Point(x: 0, y: -1)

    public var isPressed: Bool { pressedAt != nil }
    /// Where the pointer is left: the end of the drag, or the anchor if none happened.
    public var endPoint: Point { touch ?? anchor }

    public init(anchor: Point, phoneSize: (width: Double, height: Double), regrip: Bool = true) {
        self.anchor = anchor
        self.regrip = regrip
        safeArea = Rect(x: phoneSize.width * 0.04, y: phoneSize.height * 0.08,
                        width: phoneSize.width * 0.92, height: phoneSize.height * 0.84)
        span = regrip ? max(Self.minimumRoom, phoneSize.height * Self.strokeSpan) : .infinity
    }

    /// Fingers moved by `delta` (already in phone points, signed as the touch should move).
    public mutating func scroll(by delta: Point) -> [Action] {
        guard delta.isFinite, delta != .zero, !exhausted else { return [] }
        lastDirection = delta
        guard isPressed else {
            pending = Point(x: pending.x + delta.x, y: pending.y + delta.y)
            guard length(pending) >= Self.slop else { return [] }
            let start = startPoint(towards: pending)
            grip = start
            pressedAt = start
            touch = start
            let first = pending
            pending = .zero
            return [.press(start)] + step(by: first)
        }
        return step(by: delta)
    }

    /// Fingers lifted: let go (never as a tap). Returns nothing if no drag started.
    public mutating func finish() -> [Action] {
        pending = .zero
        return isPressed ? release() : []
    }

    /// Moves the touch by `delta`, re-gripping whenever a stroke reaches its limit.
    private mutating func step(by delta: Point) -> [Action] {
        var actions: [Action] = []
        var remaining = delta
        for _ in 0..<16 {
            guard let current = touch, let pressed = pressedAt, length(remaining) > 0.001 else { break }
            let target = Point(x: current.x + remaining.x, y: current.y + remaining.y)
            let travelled = Point(x: target.x - pressed.x, y: target.y - pressed.y)
            if safeArea.contains(target) && length(travelled) <= span {
                touch = target
                actions.append(.move(target))
                break
            }
            // This stroke can't go further: move as far as it may, let go there (never
            // as a tap), then hop back to the grip and press again for the rest.
            let limit = furthest(from: current, by: remaining, pressedAt: pressed)
            let used = Point(x: limit.x - current.x, y: limit.y - current.y)
            touch = limit
            actions.append(.move(limit))
            actions += release()
            guard regrip else {
                exhausted = true
                break
            }
            remaining = Point(x: remaining.x - used.x, y: remaining.y - used.y)
            let restart = restartPoint(towards: remaining)
            pressedAt = restart
            touch = restart
            actions += [.hop(restart), .press(restart)]
        }
        return actions
    }

    /// Where the next stroke presses: back at the grip, moved just far enough from the
    /// edge to leave a full stroke of room this way (the fingers may have reversed).
    private func restartPoint(towards direction: Point) -> Point {
        var start = clamp(grip ?? anchor)
        let total = abs(direction.x) + abs(direction.y)
        let roomY = min(span, safeArea.height - 2), roomX = min(span, safeArea.width / 2 - 1)
        if abs(direction.y) >= total * 0.25 {
            if direction.y < 0 { start.y = max(start.y, safeArea.minY + roomY) }
            if direction.y > 0 { start.y = min(start.y, safeArea.maxY - 1 - roomY) }
        }
        if abs(direction.x) >= total * 0.25 {
            if direction.x < 0 { start.x = max(start.x, safeArea.minX + roomX) }
            if direction.x > 0 { start.x = min(start.x, safeArea.maxX - 1 - roomX) }
        }
        return start
    }

    /// The furthest point along `delta` from `current` that stays in the safe area and
    /// within `span` of the press.
    private func furthest(from current: Point, by delta: Point, pressedAt pressed: Point) -> Point {
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let t = (low + high) / 2
            let p = Point(x: current.x + delta.x * t, y: current.y + delta.y * t)
            let travelled = Point(x: p.x - pressed.x, y: p.y - pressed.y)
            if safeArea.contains(p) && length(travelled) <= span { low = t } else { high = t }
        }
        return Point(x: current.x + delta.x * low, y: current.y + delta.y * low)
    }

    /// Releases at least `slop` from the press point; a drag that has not travelled
    /// that far first moves just past the threshold.
    private mutating func release() -> [Action] {
        guard let start = pressedAt, var end = touch else { return [] }
        var actions: [Action] = []
        if length(Point(x: end.x - start.x, y: end.y - start.y)) < Self.slop {
            let unit = normalized(lastDirection)
            let candidates = [Point(x: start.x + unit.x * Self.slop, y: start.y + unit.y * Self.slop)] +
                [(1.0, 0.0), (-1, 0), (0, 1), (0, -1)].map { Point(x: start.x + $0.0 * Self.slop, y: start.y + $0.1 * Self.slop) }
            end = candidates.first { safeArea.contains($0) }
                ?? Point(x: start.x, y: start.y + (start.y > safeArea.midY ? -Self.slop : Self.slop))
            touch = end
            actions.append(.move(end))
        }
        actions.append(.release(end))
        pressedAt = nil
        return actions
    }

    /// The pointer's position, moved just far enough to have room to drag in this
    /// direction (a drag that cannot move would be a tap).
    private func startPoint(towards direction: Point) -> Point {
        var start = clamp(anchor)
        let room = Self.minimumRoom
        let total = abs(direction.x) + abs(direction.y)
        if abs(direction.y) >= total * 0.25 {
            if direction.y < 0 { start.y = max(start.y, safeArea.minY + room) }
            if direction.y > 0 { start.y = min(start.y, safeArea.maxY - 1 - room) }
        }
        if abs(direction.x) >= total * 0.25 {
            if direction.x < 0 { start.x = max(start.x, safeArea.minX + room) }
            if direction.x > 0 { start.x = min(start.x, safeArea.maxX - 1 - room) }
        }
        return start
    }

    private func clamp(_ point: Point) -> Point {
        Point(x: min(max(point.x, safeArea.minX), safeArea.maxX - 1),
              y: min(max(point.y, safeArea.minY), safeArea.maxY - 1))
    }

    private func length(_ p: Point) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }

    private func normalized(_ p: Point) -> Point {
        let l = length(p)
        return l > 0 ? Point(x: p.x / l, y: p.y / l) : Point(x: 0, y: -1)
    }
}
