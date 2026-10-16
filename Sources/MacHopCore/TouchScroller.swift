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
/// the edge of the safe area), it lets go there, and after `regripGap` the pointer
/// hops back to where the scroll began and a new stroke carries on with the movement
/// made meanwhile. The gap lets the iPhone see the lift: pressed again within the same
/// moment, it would read one touch dragged back to the start.
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
    public static let strokeSpan = 0.12
    /// How long a re-grip waits between letting go and pressing again (seconds). iOS's
    /// own glide carries the content on meanwhile.
    public static let regripGap = 0.05
    /// The shortest a stroke is held before it lets go, so the iPhone never reads it as a tap.
    public static let minimumHold = 0.05

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
    /// After letting go to re-grip: when the next stroke may press.
    private var regripAt: Double?
    /// When the current stroke pressed.
    private var pressTime = 0.0
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

    /// Fingers moved by `delta` at `time` (seconds; phone points, signed as the touch should move).
    public mutating func scroll(by delta: Point, at time: Double) -> [Action] {
        guard delta.isFinite, delta != .zero, !exhausted else { return [] }
        lastDirection = delta
        pending = Point(x: pending.x + delta.x, y: pending.y + delta.y)
        // At most two strokes' worth waits its turn, so a hard flick can't queue a long tail.
        if regrip { pending = capped(pending, to: span * 2) }
        var actions: [Action] = []
        if let due = regripAt {
            // Re-gripping: the movement waits until the lift has had time to register.
            guard time >= due else { return [] }
            regripAt = nil
            let restart = restartPoint(towards: pending)
            pressedAt = restart
            touch = restart
            pressTime = time
            actions += [.hop(restart), .press(restart)]
        } else if !isPressed {
            guard length(pending) >= Self.slop else { return [] }
            let start = startPoint(towards: pending)
            grip = start
            pressedAt = start
            touch = start
            pressTime = time
            actions.append(.press(start))
        }
        return actions + advance(at: time)
    }

    /// Fingers lifted: let go (never as a tap). Returns nothing if no drag started.
    public mutating func finish() -> [Action] {
        pending = .zero
        regripAt = nil
        return isPressed ? release() : []
    }

    /// Moves the touch along the waiting movement, at most a third of a stroke per event,
    /// so every stroke spreads over several events. A stroke that reaches its limit lets
    /// go there once it has been held long enough; the rest waits for the re-grip.
    private mutating func advance(at time: Double) -> [Action] {
        guard let current = touch, let pressed = pressedAt, length(pending) > 0.001 else { return [] }
        let move = regrip ? capped(pending, to: span / 3) : pending
        let target = Point(x: current.x + move.x, y: current.y + move.y)
        let travelled = Point(x: target.x - pressed.x, y: target.y - pressed.y)
        if safeArea.contains(target) && length(travelled) <= span {
            touch = target
            pending = Point(x: pending.x - move.x, y: pending.y - move.y)
            return [.move(target)]
        }
        let limit = furthest(from: current, by: move, pressedAt: pressed)
        pending = Point(x: pending.x - (limit.x - current.x), y: pending.y - (limit.y - current.y))
        touch = limit
        var actions: [Action] = [.move(limit)]
        guard regrip else {
            actions += release()
            exhausted = true
            return actions
        }
        if time - pressTime >= Self.minimumHold {
            actions += release()
            regripAt = time + Self.regripGap
        }
        return actions
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

    private func capped(_ p: Point, to maximum: Double) -> Point {
        let l = length(p)
        return l > maximum ? Point(x: p.x / l * maximum, y: p.y / l * maximum) : p
    }

    private func normalized(_ p: Point) -> Point {
        let l = length(p)
        return l > 0 ? Point(x: p.x / l, y: p.y / l) : Point(x: 0, y: -1)
    }
}
