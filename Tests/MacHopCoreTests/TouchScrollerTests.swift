import Testing
@testable import MacHopCore

/// Trackpad event times: each call is 16 ms after the last.
final class EventClock {
    private var time = 0.0
    func next() -> Double { time += 0.016; return time }
}

@Suite("Touch scrolling")
struct TouchScrollerTests {
    let size = (width: 286.0, height: 620.0)
    let clock = EventClock()

    /// Replays actions and checks the touch rules: presses and releases alternate,
    /// every stroke stays in the safe area, and no stroke ends as a tap.
    func check(_ actions: [TouchScroller.Action], _ scroller: TouchScroller,
               sourceLocation: SourceLocation = #_sourceLocation) {
        var pressedAt: Point?
        var at = Point.zero
        for action in actions {
            switch action {
            case .press(let p):
                #expect(pressedAt == nil, "press while pressed", sourceLocation: sourceLocation)
                pressedAt = p
                at = p
            case .move(let p):
                #expect(pressedAt != nil, "move without a press", sourceLocation: sourceLocation)
                at = p
            case .release(let p):
                guard let start = pressedAt else {
                    Issue.record("release without a press", sourceLocation: sourceLocation)
                    continue
                }
                let moved = ((p.x - start.x) * (p.x - start.x) + (p.y - start.y) * (p.y - start.y)).squareRoot()
                #expect(moved >= TouchScroller.slop - 0.001, "released \(moved) pt from its press: a tap",
                        sourceLocation: sourceLocation)
                pressedAt = nil
                at = p
            case .hop(let p):
                #expect(pressedAt == nil, "hop while pressed", sourceLocation: sourceLocation)
                at = p
            }
            #expect(scroller.safeArea.contains(at) || at.x == scroller.safeArea.maxX - 1 || at.y == scroller.safeArea.maxY - 1,
                    "touch at \(at) outside the safe area", sourceLocation: sourceLocation)
        }
        #expect(pressedAt == nil, "a stroke was left pressed", sourceLocation: sourceLocation)
    }

    @Test("Resting fingers never press")
    func smallMovementNoPress() {
        var scroller = TouchScroller(anchor: Point(x: 140, y: 300), phoneSize: size)
        var actions = scroller.scroll(by: Point(x: 0, y: -5), at: clock.next())
        actions += scroller.scroll(by: Point(x: 0, y: 4), at: clock.next())
        actions += scroller.finish()
        #expect(actions.isEmpty)
    }

    @Test("A short scroll is stretched past the tap threshold")
    func shortScroll() {
        var scroller = TouchScroller(anchor: Point(x: 140, y: 300), phoneSize: size)
        var actions = scroller.scroll(by: Point(x: 0, y: -12.5), at: clock.next())
        actions += scroller.finish()
        check(actions, scroller)
        #expect(actions.first == .press(Point(x: 140, y: 300)))
    }

    @Test("Never a tap and never outside the safe area, from any start, in any direction",
          arguments: [Point(x: 0, y: 0), Point(x: 286, y: 620), Point(x: 143, y: 90), Point(x: 143, y: 530),
                      Point(x: 20, y: 310), Point(x: 270, y: 310), Point(x: 143, y: 310)])
    func randomScrolls(anchor: Point) {
        var seed: UInt64 = 0x5EED
        func random(_ range: ClosedRange<Double>) -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Double(seed >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
        }
        for _ in 0..<300 {
            var scroller = TouchScroller(anchor: anchor, phoneSize: size)
            var actions: [TouchScroller.Action] = []
            let direction = Point(x: random(-1...1), y: random(-1...1))
            for _ in 0..<Int(random(1...40)) {
                let speed = random(0.5...60)
                actions += scroller.scroll(by: Point(x: direction.x * speed, y: direction.y * speed), at: clock.next())
            }
            actions += scroller.finish()
            check(actions, scroller)
        }
    }

    @Test("By default a long scroll is one drag: it lets go at the edge once and never hops back")
    func longScrollOneDrag() {
        let anchor = Point(x: 140, y: 300)
        var scroller = TouchScroller(anchor: anchor, phoneSize: size)
        var timed: [(Double, TouchScroller.Action)] = []
        var time = 0.0
        for _ in 0..<100 {
            time += 0.016
            timed += scroller.scroll(by: Point(x: 0, y: -20), at: time).map { (time, $0) }
        }
        timed += scroller.finish().map { (time, $0) }
        let actions = timed.map(\.1)
        check(actions, scroller)
        let presses = actions.filter { if case .press = $0 { true } else { false } }
        #expect(presses == [.press(anchor)], "one drag, starting exactly at the pointer")
        #expect(!actions.contains { if case .hop = $0 { true } else { false } }, "the pointer never hops back")
        // It let go at the top of the safe area, where the pointer now stays.
        #expect(scroller.endPoint.y == scroller.safeArea.minY)
        #expect(actions.last == .release(scroller.endPoint))
        // Held long enough not to read as a tap.
        let pressedAt = timed.first { if case .press = $0.1 { true } else { false } }!.0
        let releasedAt = timed.first { if case .release = $0.1 { true } else { false } }!.0
        #expect(releasedAt - pressedAt >= TouchScroller.minimumHold - 1e-9)
    }

    @Test("Even a hard flick moves the touch over several events, never press and release at once")
    func hardFlickStaysADrag() {
        var scroller = TouchScroller(anchor: Point(x: 140, y: 500), phoneSize: size)
        var timed: [(Double, TouchScroller.Action)] = []
        var time = 0.0
        for _ in 0..<10 {
            time += 0.008
            timed += scroller.scroll(by: Point(x: 0, y: -300), at: time).map { (time, $0) }
        }
        timed += scroller.finish().map { (time, $0) }
        check(timed.map(\.1), scroller)
        let pressedAt = timed.first { if case .press = $0.1 { true } else { false } }!.0
        let releasedAt = timed.first { if case .release = $0.1 { true } else { false } }!.0
        #expect(releasedAt - pressedAt >= TouchScroller.minimumHold - 1e-9)
    }

    @Test("A long scroll re-grips from the pointer's spot instead of running it to the top, losing no movement")
    func longScroll() {
        let anchor = Point(x: 140, y: 300)
        var scroller = TouchScroller(anchor: anchor, phoneSize: size, regrip: true)
        var actions: [TouchScroller.Action] = []
        // A steady scroll: 8 points every 16 ms.
        for _ in 0..<100 { actions += scroller.scroll(by: Point(x: 0, y: -8), at: clock.next()) }
        actions += scroller.finish()
        check(actions, scroller)
        // Every stroke starts where the pointer was.
        let presses = actions.compactMap { if case .press(let p) = $0 { p } else { nil } }
        let strokes = Int(800 / (size.height * TouchScroller.strokeSpan))
        #expect(presses.count >= strokes && presses.allSatisfy { $0 == anchor }, "\(presses.count) strokes")
        // No stroke carries the pointer further than its span from where it pressed.
        let span = size.height * TouchScroller.strokeSpan
        var pressed = anchor, moved = 0.0
        for action in actions {
            switch action {
            case .press(let p): pressed = p
            case .move(let p): #expect(abs(p.y - pressed.y) <= span + 0.001)
            case .release(let p): moved += p.y - pressed.y
            case .hop: break
            }
        }
        // The 800 points of finger movement reach the content, except what was still
        // waiting for a re-grip when the fingers lifted.
        #expect(moved <= -800 + 2 * span + 0.001 && moved >= -800 - 0.001, "moved \(moved)")
        #expect(abs(scroller.endPoint.y - anchor.y) <= span + 0.001, "the pointer ends near where it began")
    }

    @Test("A re-grip lets go, waits for the iPhone to see the lift, then presses again; a fast flick re-grips once per event")
    func regripWaits() {
        var scroller = TouchScroller(anchor: Point(x: 140, y: 300), phoneSize: size, regrip: true)
        var timed: [(Double, TouchScroller.Action)] = []
        // A hard flick: 80 points every 8 ms.
        var time = 0.0
        for _ in 0..<40 {
            time += 0.008
            timed += scroller.scroll(by: Point(x: 0, y: -80), at: time).map { (time, $0) }
        }
        timed += scroller.finish().map { (time, $0) }
        check(timed.map(\.1), scroller)
        var releasedAt: Double?
        for (when, action) in timed {
            switch action {
            case .release: releasedAt = when
            case .press:
                if let releasedAt { #expect(when - releasedAt >= 0.04, "pressed again too soon for the iPhone to see the lift") }
            default: break
            }
        }
        // Every stroke is held long enough not to read as a tap.
        var pressedTime: Double?
        for (when, action) in timed {
            if case .press = action { pressedTime = when }
            if case .release = action, let pressedTime { #expect(when - pressedTime >= TouchScroller.minimumHold - 1e-9) }
        }
        // Never more than one release per event.
        let releasesPerEvent = Dictionary(grouping: timed.filter { if case .release = $0.1 { true } else { false } }, by: \.0)
        #expect(releasesPerEvent.values.allSatisfy { $0.count == 1 })
        // The content still went one way only: every stroke dragged upwards.
        var pressed = Point.zero
        for (_, action) in timed {
            if case .press(let p) = action { pressed = p }
            if case .release(let p) = action { #expect(p.y <= pressed.y) }
        }
    }

    @Test("Reversing near the edge re-grips somewhere with room, never in a flurry of tiny strokes")
    func reversalNearEdge() {
        // The pointer starts low down, scrolls up (pressing near the bottom), then reverses.
        var scroller = TouchScroller(anchor: Point(x: 140, y: 560), phoneSize: size, regrip: true)
        var actions: [TouchScroller.Action] = []
        for _ in 0..<30 { actions += scroller.scroll(by: Point(x: 0, y: -20), at: clock.next()) }
        for _ in 0..<60 { actions += scroller.scroll(by: Point(x: 0, y: 20), at: clock.next()) }
        actions += scroller.finish()
        check(actions, scroller)
        let presses = actions.filter { if case .press = $0 { true } else { false } }.count
        let span = size.height * TouchScroller.strokeSpan
        #expect(presses <= Int(1800 / span) + 6, "\(presses) strokes for 1,800 points of movement")
    }

    @Test("The drag starts exactly at the pointer whenever there is room")
    func startsAtPointer() {
        for anchor in [Point(x: 100, y: 200), Point(x: 200, y: 450), Point(x: 143, y: 310)] {
            var scroller = TouchScroller(anchor: anchor, phoneSize: size)
            let actions = scroller.scroll(by: Point(x: 0, y: -20), at: clock.next()) + scroller.scroll(by: Point(x: 0, y: 30), at: clock.next())
            #expect(actions.first == .press(anchor))
        }
    }
}
