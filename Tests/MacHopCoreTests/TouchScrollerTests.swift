import Testing
@testable import MacHopCore

@Suite("Touch scrolling")
struct TouchScrollerTests {
    let size = (width: 286.0, height: 620.0)

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
        var actions = scroller.scroll(by: Point(x: 0, y: -5))
        actions += scroller.scroll(by: Point(x: 0, y: 4))
        actions += scroller.finish()
        #expect(actions.isEmpty)
    }

    @Test("A short scroll is stretched past the tap threshold")
    func shortScroll() {
        var scroller = TouchScroller(anchor: Point(x: 140, y: 300), phoneSize: size)
        var actions = scroller.scroll(by: Point(x: 0, y: -12.5))
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
                actions += scroller.scroll(by: Point(x: direction.x * speed, y: direction.y * speed))
            }
            actions += scroller.finish()
            check(actions, scroller)
        }
    }

    @Test("A long scroll re-grips from the pointer's spot instead of running it to the top, losing no movement")
    func longScroll() {
        let anchor = Point(x: 140, y: 300)
        var scroller = TouchScroller(anchor: anchor, phoneSize: size)
        var actions: [TouchScroller.Action] = []
        for _ in 0..<100 { actions += scroller.scroll(by: Point(x: 0, y: -20)) }
        actions += scroller.finish()
        check(actions, scroller)
        // Every stroke starts where the pointer was.
        let presses = actions.compactMap { if case .press(let p) = $0 { p } else { nil } }
        #expect(presses.count > 5 && presses.allSatisfy { $0 == anchor })
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
        // All 2,000 points of finger movement reach the content.
        #expect(abs(moved + 2000) < 1)
        #expect(abs(scroller.endPoint.y - anchor.y) <= span + 0.001, "the pointer ends near where it began")
    }

    @Test("Reversing near the edge re-grips somewhere with room, never in a flurry of tiny strokes")
    func reversalNearEdge() {
        // The pointer starts low down, scrolls up (pressing near the bottom), then reverses.
        var scroller = TouchScroller(anchor: Point(x: 140, y: 560), phoneSize: size)
        var actions: [TouchScroller.Action] = []
        for _ in 0..<30 { actions += scroller.scroll(by: Point(x: 0, y: -20)) }
        for _ in 0..<60 { actions += scroller.scroll(by: Point(x: 0, y: 20)) }
        actions += scroller.finish()
        check(actions, scroller)
        let presses = actions.filter { if case .press = $0 { true } else { false } }.count
        #expect(presses < 20, "\(presses) strokes for 1,800 points of movement")
    }

    @Test("The drag starts exactly at the pointer whenever there is room")
    func startsAtPointer() {
        for anchor in [Point(x: 100, y: 200), Point(x: 200, y: 450), Point(x: 143, y: 310)] {
            var scroller = TouchScroller(anchor: anchor, phoneSize: size)
            let actions = scroller.scroll(by: Point(x: 0, y: -20)) + scroller.scroll(by: Point(x: 0, y: 30))
            #expect(actions.first == .press(anchor))
        }
    }
}
