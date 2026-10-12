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
///   opening Notification/Control Centre or going Home. A drag that reaches that
///   boundary lets go there (iOS carries the flick on) and the rest of the
///   gesture is ignored.
public struct TouchScroller: Sendable {
    public enum Action: Equatable, Sendable {
        case press(Point), move(Point), release(Point)
    }

    /// Where the pointer was when scrolling began (phone points).
    public let anchor: Point
    /// Area drags stay inside.
    public let safeArea: Rect
    /// Minimum distance between press and release (phone points; iOS's tap slop is about 10).
    public static let slop = 12.0
    /// Room a drag needs ahead of it before it may start where the pointer is.
    static let minimumRoom = 40.0

    private var pending = Point.zero
    private var pressedAt: Point?
    private var touch: Point?
    private var exhausted = false
    private var lastDirection = Point(x: 0, y: -1)

    public var isPressed: Bool { pressedAt != nil }
    /// Where the pointer is left: the end of the drag, or the anchor if none happened.
    public var endPoint: Point { touch ?? anchor }

    public init(anchor: Point, phoneSize: (width: Double, height: Double)) {
        self.anchor = anchor
        safeArea = Rect(x: phoneSize.width * 0.04, y: phoneSize.height * 0.08,
                        width: phoneSize.width * 0.92, height: phoneSize.height * 0.84)
    }

    /// Fingers moved by `delta` (already in phone points, signed as the touch should move).
    public mutating func scroll(by delta: Point) -> [Action] {
        guard delta.isFinite, delta != .zero, !exhausted else { return [] }
        lastDirection = delta
        guard let current = touch, isPressed else {
            pending = Point(x: pending.x + delta.x, y: pending.y + delta.y)
            guard length(pending) >= Self.slop else { return [] }
            let start = startPoint(towards: pending)
            pressedAt = start
            touch = start
            let first = pending
            pending = .zero
            return [.press(start)] + step(from: start, by: first)
        }
        return step(from: current, by: delta)
    }

    /// Fingers lifted: let go (never as a tap). Returns nothing if no drag started.
    public mutating func finish() -> [Action] {
        pending = .zero
        return isPressed ? release() : []
    }

    private mutating func step(from current: Point, by delta: Point) -> [Action] {
        let target = Point(x: current.x + delta.x, y: current.y + delta.y)
        guard !safeArea.contains(target) else {
            touch = target
            return [.move(target)]
        }
        // Reached the boundary: let go here so iOS flicks the content onwards.
        let edge = clamp(target)
        touch = edge
        exhausted = true
        return [.move(edge)] + release()
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
