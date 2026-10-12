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

    @Test("The phone sits beside the chosen edge, centred by default")
    func phonePlacement() throws {
        for side in Side.allCases {
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
        let layout = PhoneLayout(displayID: 1, verticalPosition: position, size: 1600)
        let link = try #require(ScreenLink(layout: layout, displays: [main]))
        #expect(link.openSpans.reduce(0) { $0 + $1.upperBound - $1.lowerBound } >= 200)
    }

    @Test("A push just past either end of the phone still crosses, but never by the menu bar or a corner")
    func crossingMargins() throws {
        // Ben's arrangement: the phone spans about 53…673 of a 982-point-high edge.
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, verticalPosition: 0.37), displays: [main]))
        #expect(link.openSpans == [link.phone.minY...link.phone.maxY])
        #expect(link.isOpen(atY: link.phone.maxY + 5), "the wall Ben hit, 5 points below the phone")
        #expect(link.isOpen(atY: link.phone.maxY + ScreenLink.snapMargin - 1))
        #expect(!link.isOpen(atY: link.phone.maxY + ScreenLink.snapMargin + 1))
        #expect(link.isOpen(atY: ScreenLink.cornerGuard + 1))
        #expect(!link.isOpen(atY: ScreenLink.cornerGuard - 1), "menu bar")
        // Entering through a margin lands on the phone's nearest edge.
        #expect(link.entryPoint(macY: link.phone.maxY + 30, inset: 2).y == link.phone.height - 1)
        #expect(link.entryPoint(macY: link.phone.minY - 10, inset: 2).y == 0)
        // A phone near the bottom gets no margin into the bottom corner.
        let low = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, verticalPosition: 0.6), displays: [main]))
        #expect(low.phone.maxY < main.frame.maxY && low.phone.maxY + ScreenLink.snapMargin > main.frame.maxY - ScreenLink.cornerGuard)
        #expect(!low.isOpen(atY: main.frame.maxY - ScreenLink.cornerGuard + 1))
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
        #expect(abs(right.verticalPosition - 327.0 / 982) < 0.001)
        // Dropped over the left half: the left edge.
        let left = try #require(ScreenLink.snappedLayout(centre: Point(x: 200, y: 900), base: base, displays: [main]))
        #expect(left.side == .left && abs(left.verticalPosition - 900.0 / 982) < 0.001)
        // Far above the display: clamped to the top, size and orientation kept.
        var big = base
        big.size = 900
        big.orientation = .landscape
        let high = try #require(ScreenLink.snappedLayout(centre: Point(x: 1600, y: -800), base: big, displays: [main]))
        #expect(high.verticalPosition == 0 && high.size == 900 && high.orientation == .landscape)
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
        #expect(!link.isOpen(atY: 450))
        #expect(link.isOpen(atY: 200))
        #expect(link.isOpen(atY: 700))
        // The margins never reach past a neighbouring display.
        let below = Display(id: 4, frame: Rect(x: 1512, y: 802, width: 800, height: 600))
        let blocked = try #require(ScreenLink(layout: PhoneLayout(displayID: 1), displays: [main, below]))
        #expect(!blocked.isOpen(atY: 820))
        #expect(blocked.isOpen(atY: 120), "the free end keeps its margin")
        // A display covering the whole edge leaves nowhere to cross.
        let wall = Display(id: 3, frame: Rect(x: 1512, y: -500, width: 1000, height: 2000))
        #expect(ScreenLink(layout: PhoneLayout(displayID: 1), displays: [main, wall]) == nil)
    }

    @Test("Entry, return and parking points stay where they should")
    func points() throws {
        let link = try #require(ScreenLink(layout: PhoneLayout(displayID: 1, side: .right), displays: [main]))
        let entry = link.entryPoint(macY: 500, inset: 2)
        #expect(entry.x == 2)
        #expect(abs(entry.y - (500 - link.phone.minY)) < 0.001)
        let back = link.returnPoint(phoneY: entry.y)
        #expect(back == Point(x: main.frame.maxX - 1, y: 500))
        // Leaving from beyond the display's vertical extent snaps onto the open edge.
        let low = link.returnPoint(phoneY: link.phone.height + 500)
        #expect(low.y <= main.frame.maxY - 1 && low.y >= main.frame.minY)
    }

    @Test("Missing display or invalid settings are handled")
    func invalid() {
        #expect(ScreenLink(layout: PhoneLayout(displayID: 99), displays: [main]) == nil)
        let wild = PhoneLayout(displayID: 1, verticalPosition: .nan, size: .infinity, aspectRatio: .nan).sanitized()
        #expect(wild.verticalPosition == 0.5)
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
        // 160 points in 1-point events = 10 steps at 16 points per step.
        for _ in 0..<160 {
            total += converter.convert(ScrollInput(dy: -1, continuous: true, phase: .changed), settings: settings).wheel
        }
        #expect(total == 10)
    }

    @Test("Direction follows the Mac by default and can be reversed")
    func direction() {
        var converter = ScrollConverter()
        let up = ScrollInput(dy: 32, continuous: true, phase: .changed)
        #expect(converter.convert(up, settings: ScrollSettings()).wheel == -2)
        #expect(converter.convert(up, settings: ScrollSettings(reversed: true)).wheel == 2)
        #expect(converter.convert(ScrollInput(dy: 3, continuous: false), settings: ScrollSettings()).wheel == -3)
    }

    @Test("Reversing direction discards the opposite remainder")
    func reversal() {
        var converter = ScrollConverter()
        let settings = ScrollSettings()
        _ = converter.convert(ScrollInput(dy: 15, continuous: true, phase: .changed), settings: settings)
        // Without the reset, 15 points of earlier movement would cancel this.
        #expect(converter.convert(ScrollInput(dy: -16, continuous: true, phase: .changed), settings: settings).wheel == 1)
    }

    @Test("Momentum can be turned off, horizontal follows its setting")
    func options() {
        var converter = ScrollConverter()
        let momentum = ScrollInput(dx: 64, dy: 64, continuous: true, momentum: .changed)
        #expect(converter.convert(momentum, settings: ScrollSettings(momentum: false)).isZero)
        let both = converter.convert(momentum, settings: ScrollSettings(horizontal: false))
        #expect(both.wheel == -4 && both.pan == 0)
        #expect(converter.convert(momentum, settings: ScrollSettings()).pan == 4)
    }

    @Test("Absurd input is dropped rather than overflowing")
    func absurdInput() {
        var converter = ScrollConverter()
        #expect(converter.convert(ScrollInput(dy: .infinity, continuous: true), settings: ScrollSettings()).isZero)
        #expect(converter.convert(ScrollInput(dy: 1e12, continuous: true), settings: ScrollSettings()).isZero)
    }
}
