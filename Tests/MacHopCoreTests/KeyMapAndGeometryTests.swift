import Testing
@testable import MacHopCore
@testable import VirtualPhone

@Suite("Key mapping")
struct KeyMapTests {
    @Test("No two Mac keys produce the same HID usage")
    func usagesAreUnique() {
        var seen: [UInt8: UInt16] = [:]
        for code in UInt16(0)...127 {
            guard let usage = KeyMap.usage(forKeyCode: code) else { continue }
            #expect(seen[usage] == nil, "key codes \(seen[usage] ?? 0) and \(code) both map to \(usage)")
            seen[usage] = code
            #expect(!(0xE0...0xE7).contains(usage), "modifiers travel as bits, not array usages")
        }
        #expect(seen.count >= 100)
    }

    @Test("All printable ASCII can be typed and reads back identically")
    func printableASCIIRoundTrips() {
        for value in UInt8(32)...126 {
            let character = Character(Unicode.Scalar(value))
            let stroke = KeyMap.keystroke(for: character)
            #expect(stroke != nil, "no keystroke for \(character)")
            if let stroke {
                #expect(VirtualPhone.character(for: stroke.usage, shift: stroke.shift) == character)
                #expect(Simulation.keyCode(forUsage: stroke.usage) != nil, "no Mac key types \(character)")
            }
        }
    }

    @Test("Modifier keys report bits and side-specific held flags")
    func modifiers() {
        let expected: [(UInt16, UInt8)] = [(59, 0x01), (56, 0x02), (58, 0x04), (55, 0x08),
                                           (62, 0x10), (60, 0x20), (61, 0x40), (54, 0x80)]
        for (code, bit) in expected {
            #expect(KeyMap.modifierBit(forKeyCode: code) == bit)
            #expect(KeyMap.heldFlag(forKeyCode: code).map { ModifierFlags.sideSpecific.contains($0) } == true)
        }
        #expect(KeyMap.modifierBit(forKeyCode: KeyMap.functionKeyCode) == nil)
        #expect(KeyMap.heldFlag(forKeyCode: KeyMap.functionKeyCode) == .function)
    }
}

@Suite("Screen geometry")
struct GeometryTests {
    let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))

    @Test("The phone sits beside the chosen side edge, centred by default")
    func phonePlacement() throws {
        for side in [Side.left, .right] {
            let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, side: side), displays: [main]))
            #expect(link.phone.height == 620)
            #expect(abs(link.phone.width - 620 * 393 / 852) < 0.001)
            #expect(abs(link.phone.midY - main.frame.midY) < 0.001)
            #expect(side == .right ? link.phone.minX == main.frame.maxX : link.phone.maxX == main.frame.minX)
            #expect(link.openSpans == [link.phone.minY...link.phone.maxY])
        }
    }

    @Test("Extreme positions keep part of the phone on the edge", arguments: [0.0, 1.0])
    func extremePositions(position: Double) throws {
        let layout = PhoneLayout(displayID: 1, edgePosition: position, size: 1600)
        let link = try #require(ScreenLink(layout: layout, displays: [main]))
        #expect(link.openSpans.reduce(0) { $0 + $1.upperBound - $1.lowerBound } >= 200)
    }

    @Test("A push just past either end of the phone still crosses, but never by the menu bar or a corner")
    func crossingMargins() throws {
        // Ben's arrangement: the phone spans about 53…673 of a 982-point-high edge.
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, edgePosition: 0.37), displays: [main]))
        #expect(link.openSpans == [link.phone.minY...link.phone.maxY])
        #expect(link.isOpen(along: link.phone.maxY + 5), "the wall Ben hit, 5 points below the phone")
        #expect(link.isOpen(along: link.phone.maxY + ScreenLink.snapMargin - 1))
        #expect(!link.isOpen(along: link.phone.maxY + ScreenLink.snapMargin + 1))
        #expect(link.isOpen(along: ScreenLink.cornerGuard + 1))
        #expect(!link.isOpen(along: ScreenLink.cornerGuard - 1), "menu bar")
        // Entering through a margin lands on the phone's nearest edge.
        #expect(link.entryPoint(macAlong: link.phone.maxY + 30, inset: 2).y == link.phone.height - 1)
        #expect(link.entryPoint(macAlong: link.phone.minY - 10, inset: 2).y == 0)
        // A phone near the bottom gets no margin into the bottom corner.
        let low = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, edgePosition: 0.6), displays: [main]))
        #expect(low.phone.maxY < main.frame.maxY && low.phone.maxY + ScreenLink.snapMargin > main.frame.maxY - ScreenLink.cornerGuard)
        #expect(!low.isOpen(along: main.frame.maxY - ScreenLink.cornerGuard + 1))
    }

    @Test("iPhone models give the real screen shape and a proportional size")
    func iPhoneModels() throws {
        let pro = try #require(IPhoneModels.model(for: "iPhone16,1"))
        #expect(pro.name == "iPhone 15 Pro" && pro.width == 393 && pro.height == 852)
        #expect(IPhoneModels.model(for: "iPhone99,9") == nil)
        let layout = PhoneLayout(displayID: 1, size: 900)
        // A 15 Pro (and Standard) keeps the long-standing default exactly.
        let standard = layout.sized(for: IPhoneScreen.standard.points)
        #expect(standard.size == 620 && standard.aspectRatio == 393.0 / 852)
        #expect(abs(layout.sized(for: IPhoneScreen.large.points).size - 620.0 * 932 / 852) < 1e-9)
        // The SE's older 16:9 shape.
        #expect(layout.sized(for: IPhoneScreen.se.points).aspectRatio == 375.0 / 667)
    }

    @Test("Dragging the phone snaps it to the nearest exposed display edge, at the height it was dropped")
    func dragSnapping() throws {
        let base = PhoneLayout(displayID: 1)
        // Dropped right of the display, a third of the way down.
        let right = try #require(ScreenLink.snappedLayout(centre: Point(x: 1700, y: 327), base: base, displays: [main]))
        #expect(right.side == .right && right.displayID == 1)
        #expect(abs(right.edgePosition - 327.0 / 982) < 0.001)
        // Dropped over the left half: the left edge.
        let left = try #require(ScreenLink.snappedLayout(centre: Point(x: 200, y: 900), base: base, displays: [main]))
        #expect(left.side == .left && abs(left.edgePosition - 900.0 / 982) < 0.001)
        // Far above the display, past its right end: the right end of the top edge,
        // size and orientation kept.
        var big = base
        big.size = 900
        big.orientation = .landscape
        let high = try #require(ScreenLink.snappedLayout(centre: Point(x: 1600, y: -800), base: big, displays: [main]))
        #expect(high.side == .top && high.edgePosition == 1 && high.size == 900 && high.orientation == .landscape)
        // Two displays side by side: the shared edge is covered, so dropping between
        // them picks an outer edge; dropping right of the second picks that display.
        let second = Display(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080))
        let between = try #require(ScreenLink.snappedLayout(centre: Point(x: 1512, y: 400), base: base, displays: [main, second]))
        #expect(!(between.displayID == 1 && between.side == .right) && !(between.displayID == 2 && between.side == .left))
        let outer = try #require(ScreenLink.snappedLayout(centre: Point(x: 3600, y: 500), base: base, displays: [main, second]))
        #expect(outer.displayID == 2 && outer.side == .right)
    }

    @Test("An adjacent display removes its part of the edge")
    func adjacentDisplay() throws {
        let side = Display(id: 2, frame: Rect(x: 1512, y: 300, width: 1000, height: 300))
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, size: 900), displays: [main, side]))
        #expect(!link.isOpen(along: 450))
        #expect(link.isOpen(along: 200))
        #expect(link.isOpen(along: 700))
        // The margins never reach past a neighbouring display.
        let below = Display(id: 4, frame: Rect(x: 1512, y: 802, width: 800, height: 600))
        let blocked = try #require(ScreenLink(layout: PhoneLayout(displayID: 1), displays: [main, below]))
        #expect(!blocked.isOpen(along: 820))
        #expect(blocked.isOpen(along: 120), "the free end keeps its margin")
        // A display covering the whole edge leaves nowhere to cross.
        let wall = Display(id: 3, frame: Rect(x: 1512, y: -500, width: 1000, height: 2000))
        #expect(ScreenLink(layout: PhoneLayout(displayID: 1), displays: [main, wall]) == nil)
    }

    @Test("Entry, return and parking points stay where they should")
    func points() throws {
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, side: .right), displays: [main]))
        let entry = link.entryPoint(macAlong: 500, inset: 2)
        #expect(entry.x == 2)
        #expect(abs(entry.y - (500 - link.phone.minY)) < 0.001)
        let back = link.returnPoint(phoneAlong: entry.y)
        #expect(back == Point(x: main.frame.maxX - 1, y: 500))
        // Leaving from beyond the display's vertical extent snaps onto the open edge.
        let low = link.returnPoint(phoneAlong: link.phone.height + 500)
        #expect(low.y <= main.frame.maxY - 1 && low.y >= main.frame.minY)
    }

    @Test("Missing display or invalid settings are handled")
    func invalid() {
        #expect(ScreenLink(layout: PhoneLayout(displayID: 99), displays: [main]) == nil)
        let wild = PhoneLayout(displayID: 1, edgePosition: .nan, size: .infinity, aspectRatio: .nan).sanitized()
        #expect(wild.edgePosition == 0.5)
        #expect(wild.size == 620)
        #expect(wild.aspectRatio == PhoneLayout.defaultAspectRatio)
        #expect(PhoneLayout(displayID: 1, size: 10, aspectRatio: -3).sanitized().aspectRatio == 0.3)
        #expect(PhoneLayout(displayID: 1, size: 10).sanitized().size == PhoneLayout.sizeRange.lowerBound)
    }
}

@Suite("Scroll conversion")
struct ScrollConverterTests {
    @Test("Trackpad points become whole steps with the remainder carried")
    func remainderCarried() {
        var converter = ScrollConverter()
        let settings = ScrollSettings(speed: 1)
        var total = 0
        // 150 points in 1-point events = 5 steps at 30 points per step.
        for _ in 0..<150 {
            total += converter.convert(ScrollInput(dy: -1, continuous: true, phase: .changed), settings: settings).wheel
        }
        #expect(total == 5)
    }

    @Test("Direction follows the Mac by default and can be reversed")
    func direction() {
        var converter = ScrollConverter()
        let up = ScrollInput(dy: 30, continuous: true, phase: .changed)
        #expect(converter.convert(up, settings: ScrollSettings()).wheel == -1)
        #expect(converter.convert(up, settings: ScrollSettings(reversed: true)).wheel == 1)
        #expect(converter.convert(ScrollInput(dy: 3, continuous: false), settings: ScrollSettings()).wheel == -3)
    }

    @Test("Reversing direction discards the opposite remainder")
    func reversal() {
        var converter = ScrollConverter()
        let settings = ScrollSettings()
        _ = converter.convert(ScrollInput(dy: 29, continuous: true, phase: .changed), settings: settings)
        // Without the reset, 29 points of earlier movement would cancel this.
        #expect(converter.convert(ScrollInput(dy: -30, continuous: true, phase: .changed), settings: settings).wheel == 1)
    }

    @Test("Momentum can be turned off, horizontal follows its setting")
    func options() {
        var converter = ScrollConverter()
        let momentum = ScrollInput(dx: 120, dy: 120, continuous: true, momentum: .changed)
        #expect(converter.convert(momentum, settings: ScrollSettings(momentum: false)).isZero)
        let both = converter.convert(momentum, settings: ScrollSettings(horizontal: false))
        #expect(both.wheel == -1 && both.pan == 0)
        #expect(converter.convert(momentum, settings: ScrollSettings()).pan == 1)
    }

    @Test("Momentum passes on a quarter of the glide, so a flick doesn't run away")
    func momentumShare() {
        var converter = ScrollConverter()
        var total = 0
        // 1,200 points of momentum in 30-point events: a quarter is 300 points, 10 steps.
        for _ in 0..<40 {
            total += converter.convert(ScrollInput(dy: -30, continuous: true, momentum: .changed), settings: ScrollSettings()).wheel
        }
        #expect(total == 10)
    }

    @Test("Trackpad scrolling sends one step per event; a burst waits its turn, then the excess is dropped")
    func oneStepPerEvent() {
        var converter = ScrollConverter()
        let settings = ScrollSettings()
        // One event worth 10 steps: 1 now, 3 carried over the next events, the rest dropped.
        var steps = [converter.convert(ScrollInput(dy: -300, continuous: true, phase: .changed), settings: settings).wheel]
        for _ in 0..<6 { steps.append(converter.convert(ScrollInput(dy: 0, continuous: true, phase: .changed), settings: settings).wheel) }
        #expect(steps == [1, 1, 1, 1, 0, 0, 0])
        // A mouse wheel's lines aren't limited.
        #expect(converter.convert(ScrollInput(dy: -5, continuous: false), settings: settings).wheel == 5)
    }

    @Test("Absurd input is dropped rather than overflowing")
    func absurdInput() {
        var converter = ScrollConverter()
        #expect(converter.convert(ScrollInput(dy: .infinity, continuous: true), settings: ScrollSettings()).isZero)
        #expect(converter.convert(ScrollInput(dy: 1e12, continuous: true), settings: ScrollSettings()).isZero)
    }

    // MARK: Top edge

    @Test("An iPhone above the screen shares the top edge, with the same margins as the sides")
    func topEdge() throws {
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let layout = PhoneLayout(displayID: 1, side: .top, edgePosition: 0.25, orientation: .landscape)
        let link = try #require(ScreenLink(layout: layout, displays: [main]))
        #expect(link.phone.maxY == 0 && abs(link.phone.midX - 378) < 0.5)
        #expect(link.edgeLine == 0)
        #expect(link.openSpans == [link.phone.minX...link.phone.maxX])
        #expect(link.isOpen(along: link.phone.maxX + ScreenLink.snapMargin - 1))
        #expect(!link.isOpen(along: ScreenLink.cornerGuard - 1), "the Apple menu corner")
        #expect(link.returnPoint(phoneAlong: 100) == Point(x: link.phone.minX + 100, y: 0))
        #expect(link.entryPoint(macAlong: 400, inset: 2) == Point(x: 400 - link.phone.minX, y: link.phone.height - 2))
    }

    @Test("A display above covers the top edge; the iPhone only gets what's left")
    func topEdgeUnderAnotherDisplay() throws {
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let above = Display(id: 2, frame: Rect(x: -200, y: -1080, width: 1920, height: 1080))
        #expect(ScreenLink(layout: PhoneLayout(displayID: 1, side: .top), displays: [main, above]) == nil)
        let partly = Display(id: 2, frame: Rect(x: 800, y: -1080, width: 1920, height: 1080))
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, side: .top, edgePosition: 0.4, orientation: .landscape),
                                           displays: [main, partly]))
        #expect(link.openSpans.allSatisfy { $0.upperBound <= 800 })
        // Dragged above the covered part, it snaps to a free edge instead.
        let base = PhoneLayout(displayID: 1, side: .top, orientation: .landscape)
        let snapped = try #require(ScreenLink.snappedLayout(centre: Point(x: 1200, y: -150), base: base, displays: [main, partly]))
        #expect(!(snapped.displayID == 1 && snapped.side == .top))
    }

    @Test("Dropping the iPhone above a display puts it on the top edge, at that place")
    func snapToTop() throws {
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let base = PhoneLayout(displayID: 1, orientation: .landscape)
        let top = try #require(ScreenLink.snappedLayout(centre: Point(x: 900, y: -150), base: base, displays: [main]))
        #expect(top.side == .top && abs(top.edgePosition - 900.0 / 1512) < 0.001)
        let side = try #require(ScreenLink.snappedLayout(centre: Point(x: 1700, y: 300), base: base, displays: [main]))
        #expect(side.side == .right)
    }

    // MARK: Bottom edge

    @Test("An iPhone below the screen shares the bottom edge, with the same margins")
    func bottomEdge() throws {
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let layout = PhoneLayout(displayID: 1, side: .bottom, edgePosition: 0.75)
        let link = try #require(ScreenLink(layout: layout, displays: [main]))
        #expect(link.phone.minY == 982 && abs(link.phone.midX - 1134) < 0.5)
        #expect(link.phone.height > link.phone.width, "portrait, standing below the screen")
        #expect(link.edgeLine == 981)
        #expect(link.openSpans == [link.phone.minX...link.phone.maxX])
        #expect(!link.isOpen(along: 1512 - ScreenLink.cornerGuard + 1), "the bottom-right hot corner")
        #expect(link.returnPoint(phoneAlong: 50) == Point(x: link.phone.minX + 50, y: 981))
        #expect(link.entryPoint(macAlong: 1100, inset: 2) == Point(x: 1100 - link.phone.minX, y: 2))
    }

    @Test("Dropping the iPhone below a display puts it on the bottom edge; a display below covers it")
    func snapToBottom() throws {
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let base = PhoneLayout(displayID: 1)
        let bottom = try #require(ScreenLink.snappedLayout(centre: Point(x: 600, y: 1300), base: base, displays: [main]))
        #expect(bottom.side == .bottom && abs(bottom.edgePosition - 600.0 / 1512) < 0.001)
        let below = Display(id: 2, frame: Rect(x: -100, y: 982, width: 1800, height: 1000))
        #expect(ScreenLink(layout: PhoneLayout(displayID: 1, side: .bottom), displays: [main, below]) == nil)
    }

    // MARK: Orientation

    @Test("The Dynamic Island's end of the phone, as drawn, is the top of the iPhone's own screen")
    func screenFractionFollowsTheIsland() {
        // Where the Dynamic Island sits in the drawing, for each way the phone can be turned.
        let island: [(Orientation, Bool, (x: Double, y: Double))] = [
            (.portrait, false, (0.5, 0)), (.portrait, true, (0.5, 1)),
            (.landscape, false, (0, 0.5)), (.landscape, true, (1, 0.5)),
        ]
        for (orientation, flipped, point) in island {
            let layout = PhoneLayout(displayID: 1, orientation: orientation, flipped: flipped)
            let screen = layout.screenFraction(x: point.x, y: point.y)
            #expect(abs(screen.x - 0.5) < 1e-9 && abs(screen.y) < 1e-9, "\(orientation), flipped \(flipped)")
            // The four corners stay four corners.
            let corners = [(0.0, 0.0), (1, 0), (0, 1), (1, 1)].map { layout.screenFraction(x: $0.0, y: $0.1) }
            #expect(Set(corners.map { "\($0.x),\($0.y)" }) == ["0.0,0.0", "1.0,0.0", "0.0,1.0", "1.0,1.0"])
        }
    }

    @Test("Turning the phone around reverses every direction")
    func flippedReverses() {
        for orientation in Orientation.allCases {
            let upright = PhoneLayout(displayID: 1, orientation: orientation)
            let flipped = PhoneLayout(displayID: 1, orientation: orientation, flipped: true)
            let a = upright.screenFraction(x: 0.2, y: 0.7), b = flipped.screenFraction(x: 0.2, y: 0.7)
            #expect(abs(a.x + b.x - 1) < 1e-9 && abs(a.y + b.y - 1) < 1e-9)
        }
    }
}
