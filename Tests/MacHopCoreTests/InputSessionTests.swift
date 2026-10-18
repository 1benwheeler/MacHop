import Testing
@testable import MacHopCore
@testable import VirtualPhone

@MainActor
@Suite("Input session")
struct InputSessionTests {
    let sim = Simulation()

    // MARK: Crossing

    @Test("Pushing through the edge hands input to the phone; resistance prevents grazing")
    func crossing() throws {
        let link = try #require(sim.session.screenLink)
        sim.move(dx: link.edgeLine - sim.cursor.location.x, dy: 0, step: 40)
        #expect(sim.session.owner == .mac)
        // A push smaller than the resistance stays on the Mac.
        sim.move(dx: sim.session.settings.edgeResistance - 1, dy: 0, step: 1)
        #expect(sim.session.owner == .mac)
        sim.move(dx: 2, dy: 0, step: 1)
        #expect(sim.session.owner == .phone)
        #expect(sim.cursor.isHidden)
        #expect(sim.cursor.location == Point(x: 756, y: 491), "the hidden cursor starts in the middle")
        sim.settle()
        // The phone pointer appears at the matching height on its near edge.
        let expectedY = 491.0 - link.phone.minY
        #expect(abs(sim.phone.pointer.y / 852 * link.phone.height - expectedY) < 1)
        #expect(sim.phone.pointer.x < 5)
    }

    @Test("Right after crossing, the phone pointer follows the user's movement in every direction")
    func followsMovementAfterCrossing() throws {
        // The bug seen on the real Mac (12 Oct 2026): cursor warps were read as movement,
        // bouncing input straight back or sending the pointer running to the right.
        #expect(sim.crossToPhone())
        let link = try #require(sim.session.screenLink)
        sim.move(dx: 120, dy: 0, step: 4)
        let start = try #require(sim.session.phonePointer)
        sim.move(dx: -60, dy: -150, step: 4)
        let after = try #require(sim.session.phonePointer)
        #expect(sim.session.owner == .phone)
        #expect(abs((after.x - start.x) - -60) < 1, "moved left by \(after.x - start.x)")
        #expect(abs((after.y - start.y) - -150) < 1, "moved up by \(after.y - start.y)")
        sim.move(dx: 0, dy: 400, step: 4)
        #expect(abs(sim.session.phonePointer!.y - min(link.phone.height, after.y + 400)) < 1)
    }

    @Test("The hidden Mac cursor never reaches a screen edge or hot corner while the phone has input")
    func hiddenCursorStaysClear() {
        #expect(sim.crossToPhone())
        let frame = sim.displays[0].frame
        // Long sweeps in every direction, including into the bottom-right corner.
        for (dx, dy) in [(900.0, 900.0), (-1500, 0), (0, -1200), (700, 700), (300, 2000)] {
            sim.move(dx: dx, dy: dy, step: 7)
            #expect(sim.session.owner == .phone || sim.ownerChanges.last?.1 == .edge)
            if sim.session.owner == .mac { #expect(sim.crossToPhone()) }
            let p = sim.cursor.location
            #expect(p.x > frame.minX + 20 && p.x < frame.maxX - 20 && p.y > frame.minY + 20 && p.y < frame.maxY - 20,
                    "hidden cursor at \(p)")
        }
    }

    @Test("Moving inward resets edge pressure")
    func inwardResetsPressure() throws {
        let link = try #require(sim.session.screenLink)
        sim.move(dx: link.edgeLine - sim.cursor.location.x, dy: 0, step: 40)
        for _ in 0..<10 {
            sim.move(dx: 4, dy: 0, step: 4)
            sim.move(dx: -4, dy: 0, step: 4)
        }
        #expect(sim.session.owner == .mac)
    }

    @Test("No crossing while a Mac button is held, while disabled, or outside the phone's span")
    func crossingBlocked() throws {
        sim.deliver(.button(.left, down: true, location: sim.cursor.location))
        #expect(!sim.crossToPhone())
        sim.deliver(.button(.left, down: false, location: sim.cursor.location))

        sim.session.setEnabled(false, reason: "paused")
        #expect(!sim.crossToPhone())
        sim.session.setEnabled(true)

        let link = try #require(sim.session.screenLink)
        sim.move(dx: link.edgeLine - sim.cursor.location.x, dy: 950 - sim.cursor.location.y, step: 40)
        sim.move(dx: 80, dy: 0, step: 4)   // below the phone (span ends at 801)
        #expect(sim.session.owner == .mac)
        #expect(sim.crossToPhone())
    }

    @Test("Returning through the phone's near edge restores the Mac at the matching height")
    func returning() throws {
        #expect(sim.crossToPhone(atFraction: 0.3))
        sim.move(dx: 100, dy: 120, step: 5)
        let link = try #require(sim.session.screenLink)
        let phoneY = try #require(sim.session.phonePointer?.y)
        #expect(sim.returnToMac())
        #expect(!sim.cursor.isHidden)
        #expect(abs(sim.cursor.location.y - (link.phone.minY + phoneY)) <= 1)
        // At the edge, plus at most the last step's movement past the resistance.
        #expect(abs(sim.cursor.location.x - link.edgeLine) <= 6)
        #expect(sim.ownerChanges.last?.1 == .edge)
    }

    @Test("Fast movement right after entering is not mistaken for the hidden cursor's jump", arguments: [40.0, 90.0, 180.0])
    func fastMovementAfterEntering(speed: Double) throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        #expect(sim.crossToPhone())
        let start = try #require(sim.session.phonePointer)
        // The first event after entering carries the cursor warp plus this movement.
        sim.move(dx: speed * out, dy: 0, step: speed)
        #expect(sim.session.owner == .phone, "no bounce back to the Mac")
        let end = try #require(sim.session.phonePointer)
        #expect(abs((end.x - start.x) * out - min(speed, link.phone.width - start.x)) < 1)
    }

    @Test("A fast flick keeps going across the edge in both directions; a slow push lands at the edge")
    func flickCarriesMomentum() throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        let y = link.phone.midY
        // Slow push: lands at the phone's edge.
        sim.move(dx: link.edgeLine - 40 * out - sim.cursor.location.x, dy: y - sim.cursor.location.y, step: 40)
        sim.move(dx: 60 * out, dy: 0, step: 2, stopOnOwnerChange: true)
        let slow = try #require(sim.session.phonePointer)
        #expect(abs(slow.x - (out > 0 ? 2 : link.phone.width - 2)) <= 3)
        sim.session.returnToMac(.requested)
        sim.settle(InputSession.exitCooldown)
        // Flick: one 140-point event from 100 points away. 40 points pass the edge,
        // 6 of them are the resistance, and the rest carry onto the phone.
        sim.move(dx: link.edgeLine - 100 * out - sim.cursor.location.x, dy: 0, step: 40)
        sim.move(dx: 140 * out, dy: 0, step: 140)
        #expect(sim.session.owner == .phone)
        let fast = try #require(sim.session.phonePointer)
        let inward = out > 0 ? fast.x : link.phone.width - fast.x
        #expect(abs(inward - (2 + 34)) < 1)
        // A flick back carries onto the Mac too.
        sim.move(dx: -(inward + 60) * out, dy: 0, step: inward + 60)
        #expect(sim.session.owner == .mac)
        #expect(abs((link.edgeLine - sim.cursor.location.x) * out - 54) < 1)
    }

    @Test("Returning releases a held button where it is and leaves the phone's pointer there")
    func pointerLeftInPlace() throws {
        let link = try #require(sim.session.screenLink)
        #expect(sim.crossToPhone(atFraction: 0.4))
        sim.move(dx: 80 * link.side.outward, dy: 60, step: 5)
        sim.buttonDown(.left)
        sim.settle()
        let held = sim.phone.pointer
        // The shortcut returns with the button held.
        sim.pressModifier(59)   // Control
        sim.pressModifier(58)   // Option
        sim.pressModifier(55)   // Command
        sim.keyDown(KeyMap.escapeKeyCode)
        sim.settle()
        #expect(sim.session.owner == .mac)
        #expect(sim.phone.buttons.isEmpty)
        let click = try #require(sim.phone.clicks.last)
        #expect(abs(click.location.x - held.x) < 1 && abs(click.location.y - held.y) < 1, "released where it was held")
        #expect(abs(sim.phone.pointer.x - held.x) < 1 && abs(sim.phone.pointer.y - held.y) < 1, "pointer stays put")
    }

    @Test("Flicking back and forth quickly crosses every time, without being held at the edge")
    func fastBackAndForth() throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        sim.move(dx: link.edgeLine - 60 * out - sim.cursor.location.x, dy: link.phone.midY - sim.cursor.location.y, step: 40)
        for trip in 1...10 {
            // About 40 points per event, as in Ben's flicks; back on the Mac 0.1 s after returning.
            sim.move(dx: 160 * out, dy: 0, step: 40, stopOnOwnerChange: true)
            #expect(sim.session.owner == .phone, "trip \(trip): entered")
            sim.move(dx: -(link.phone.width + 80) * out, dy: 0, step: 40, stopOnOwnerChange: true)
            #expect(sim.session.owner == .mac, "trip \(trip): returned")
            sim.settle(0.1)
        }
        #expect(sim.ownerChanges.count == 20)
    }

    // MARK: iPhone above the screen

    /// A landscape iPhone above the middle of the default 1512 × 982 display.
    private func phoneAbove(resistance: Double = 6) -> Simulation {
        Simulation(settings: SessionSettings(layout: PhoneLayout(displayID: 1, side: .top, orientation: .landscape),
                                             edgeResistance: resistance))
    }

    @Test("An iPhone above the screen: push up to cross, come back down at the matching place")
    func phoneAboveRoundTrip() throws {
        let sim = phoneAbove()
        let link = try #require(sim.session.screenLink)
        #expect(link.phone.maxY == 0 && link.phone.width > link.phone.height, "landscape, sitting on the top edge")
        sim.move(dx: 600 - sim.cursor.location.x, dy: 200 - sim.cursor.location.y, step: 40)
        sim.move(dx: 0, dy: -400, step: 4, stopOnOwnerChange: true)
        #expect(sim.session.owner == .phone)
        let entry = try #require(sim.session.phonePointer)
        #expect(abs(link.phone.minX + entry.x - 600) < 1, "enters at the same x")
        #expect(entry.y > link.phone.height - 5, "on the phone's bottom edge, facing the Mac")
        // Along the phone, then back down through its bottom edge.
        sim.move(dx: 150, dy: -40, step: 5)
        let phoneX = try #require(sim.session.phonePointer?.x)
        sim.move(dx: 0, dy: link.phone.height + 100, step: 4, stopOnOwnerChange: true)
        #expect(sim.session.owner == .mac)
        #expect(abs(sim.cursor.location.x - (link.phone.minX + phoneX)) <= 1)
        #expect(sim.cursor.location.y < 10, "lands at the top of the screen")
    }

    @Test("Flinging the pointer at the menu bar doesn't land on an iPhone above; pushing on does")
    func menuBarFlingStaysOnMac() throws {
        let sim = phoneAbove(resistance: 0)
        sim.move(dx: 756 - sim.cursor.location.x, dy: 500 - sim.cursor.location.y, step: 40)
        // One fast event that would carry the pointer 300 points past the top.
        sim.move(dx: 0, dy: -800, step: 800)
        #expect(sim.cursor.location.y == 0)
        #expect(sim.session.owner == .mac, "arriving movement doesn't count at the top")
        // With resistance None, the top edge still needs a medium push.
        sim.move(dx: 0, dy: -(InputSession.menuBarResistance - 2), step: 2)
        #expect(sim.session.owner == .mac)
        sim.move(dx: 0, dy: -4, step: 2)
        #expect(sim.session.owner == .phone)
    }

    @Test("A landscape iPhone gets the pointer in its own upright frame, so up on the Mac is up on the phone")
    func landscapePointerFollowsHand() throws {
        let sim = phoneAbove()
        let link = try #require(sim.session.screenLink)
        // Up into the phone near its right end, as Ben did.
        sim.move(dx: link.phone.maxX - 60 - sim.cursor.location.x, dy: 200 - sim.cursor.location.y, step: 40)
        sim.move(dx: 0, dy: -400, step: 4, stopOnOwnerChange: true)
        sim.settle()
        // iOS measures in upright portrait (393 × 852 here). With the Dynamic Island on the
        // left, the landscape phone's bottom edge is its screen's left edge, and its right end
        // is the screen's bottom.
        #expect(sim.phone.pointer.x < 10)
        #expect(sim.phone.pointer.y > 852 * 0.8)
        let before = sim.phone.pointer
        sim.move(dx: 0, dy: -60, step: 5)
        sim.settle()
        #expect(sim.phone.pointer.x > before.x + 20, "up on the Mac is towards the top of the landscape phone")
        #expect(abs(sim.phone.pointer.y - before.y) < 2, "and not along it")
        sim.move(dx: -100, dy: 0, step: 5)
        sim.settle()
        #expect(sim.phone.pointer.y < before.y - 20, "left on the Mac is towards the Dynamic Island")
    }

    // MARK: The home indicator, with wheel scrolling

    /// On the iPhone (right of the default display), pointer at the bottom of its screen.
    private func atHomeIndicator(style: ScrollStyle = .wheel) -> Simulation {
        let sim = Simulation(settings: SessionSettings(layout: PhoneLayout(displayID: 1), scroll: ScrollSettings(style: style)))
        #expect(sim.crossToPhone())
        sim.move(dx: 100, dy: 2000, step: 20)
        sim.settle()
        return sim
    }

    @Test("With wheel scrolling, a swipe up from the home indicator becomes the Home key, not a drag")
    func homeSwipeBecomesHomeKey() throws {
        let sim = atHomeIndicator()
        sim.buttonDown(.left)
        sim.move(dx: 0, dy: -80, step: 4)
        sim.buttonUp(.left)
        sim.settle()
        #expect(sim.phone.consumerPresses == [ConsumerReport.menu])
        #expect(sim.phone.drags.isEmpty && sim.phone.clicks.isEmpty, "iOS never sees the drag")
        #expect(sim.phone.isIdle)
    }

    @Test("A click on the home indicator is still a click, and sideways is still a drag")
    func homeIndicatorClicksAndSideways() throws {
        let click = atHomeIndicator()
        click.buttonDown(.left)
        click.buttonUp(.left)
        click.settle()
        #expect(click.phone.clicks.count == 1 && click.phone.consumerPresses.isEmpty)
        #expect(click.phone.clicks.first.map { $0.location.y > 852 * 0.96 } == true)
        let sideways = atHomeIndicator()
        sideways.buttonDown(.left)
        sideways.move(dx: 120, dy: 0, step: 4)
        sideways.buttonUp(.left)
        sideways.settle()
        #expect(!sideways.phone.drags.isEmpty, "switching apps along the bottom still drags")
        #expect(sideways.phone.consumerPresses.isEmpty)
        #expect(sideways.phone.isIdle)
    }

    @Test("Without wheel scrolling the home indicator drags as before; leaving mid-press holds nothing")
    func homeIndicatorOtherwiseUnchanged() throws {
        let drag = atHomeIndicator(style: .drag)
        drag.buttonDown(.left)
        drag.move(dx: 0, dy: -80, step: 4)
        drag.buttonUp(.left)
        drag.settle()
        #expect(!drag.phone.drags.isEmpty && drag.phone.consumerPresses.isEmpty)
        let away = atHomeIndicator()
        away.buttonDown(.left)
        away.session.returnToMac(.requested)
        away.buttonUp(.left)
        away.settle()
        #expect(away.phone.isIdle && away.phone.clicks.isEmpty && away.phone.consumerPresses.isEmpty)
        #expect(!away.macEvents.contains { if case .button = $0 { true } else { false } }, "the release stays off the Mac")
    }

    @Test("Moving along the menu bar never crosses onto an iPhone above")
    func slidingAlongMenuBar() throws {
        let sim = phoneAbove()
        let link = try #require(sim.session.screenLink)
        sim.move(dx: link.phone.minX - 100 - sim.cursor.location.x, dy: -sim.cursor.location.y, step: 40)
        // Mostly sideways, drifting up: the pointer slides along under the iPhone.
        sim.move(dx: link.phone.width + 200, dy: -60, step: 6)
        #expect(sim.session.owner == .mac)
    }

    @Test("After ⌃⌥⌘⎋, a hand still moving towards the phone doesn't carry input straight back")
    func shortcutExitStaysOut() throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        #expect(sim.crossToPhone())
        sim.pressModifier(59); sim.pressModifier(58); sim.pressModifier(55)
        sim.keyDown(KeyMap.escapeKeyCode)
        sim.keyUp(KeyMap.escapeKeyCode)
        sim.releaseModifier(55); sim.releaseModifier(58); sim.releaseModifier(59)
        #expect(sim.session.owner == .mac)
        #expect(abs((link.edgeLine - sim.cursor.location.x) * out - InputSession.exitInset) < 1, "lands inside the screen")
        // Still pushing towards the phone, 0.15 s later.
        sim.settle(0.15)
        sim.move(dx: 80 * out, dy: 0, step: 4)
        #expect(sim.session.owner == .mac)
        // A deliberate push after the hold-off crosses normally.
        sim.settle(InputSession.exitCooldown)
        sim.move(dx: 60 * out, dy: 0, step: 4, stopOnOwnerChange: true)
        #expect(sim.session.owner == .phone)
    }

    @Test("While the phone has input, the session keeps the Mac cursor hidden; never while the Mac has input")
    func keepsCursorHidden() {
        sim.move(dx: -200, dy: 50)
        #expect(sim.cursor.keepHiddenRequests == 0)
        #expect(sim.crossToPhone())
        let before = sim.cursor.keepHiddenRequests
        sim.move(dx: 0, dy: 120, step: 10)
        #expect(sim.cursor.keepHiddenRequests > before, "checked as the pointer moves on the phone")
        #expect(sim.returnToMac())
        let afterReturn = sim.cursor.keepHiddenRequests
        sim.move(dx: -100, dy: 0)
        #expect(sim.cursor.keepHiddenRequests == afterReturn)
        #expect(!sim.cursor.isHidden)
    }

    @Test("Jitter right after returning cannot bounce input straight back")
    func cooldown() {
        #expect(sim.crossToPhone())
        #expect(sim.returnToMac())
        sim.move(dx: 30, dy: 0, step: 3, interval: 0.001)   // within the cooldown
        #expect(sim.session.owner == .mac)
        sim.settle(InputSession.crossingCooldown)
        sim.move(dx: 30, dy: 0, step: 3)
        #expect(sim.session.owner == .phone)
    }

    @Test("A phone drag cannot leave through the edge")
    func dragBlocksReturn() {
        #expect(sim.crossToPhone())
        sim.deliver(.button(.left, down: true, location: sim.cursor.location))
        sim.move(dx: -400, dy: 0, step: 6)
        #expect(sim.session.owner == .phone)
        sim.deliver(.button(.left, down: false, location: sim.cursor.location))
        sim.move(dx: -40, dy: 0, step: 6)
        #expect(sim.session.owner == .mac)
    }

    @Test("Control-Option-Command-Escape returns immediately and swallows the whole chord")
    func emergencyShortcut() {
        #expect(sim.crossToPhone())
        sim.pressModifier(59)
        sim.pressModifier(58)
        sim.pressModifier(55)
        sim.keyDown(KeyMap.escapeKeyCode)
        #expect(sim.session.owner == .mac)
        #expect(sim.ownerChanges.last?.1 == .shortcut)
        sim.keyUp(KeyMap.escapeKeyCode)
        sim.releaseModifier(55)
        sim.releaseModifier(58)
        sim.releaseModifier(59)
        sim.settle()
        #expect(sim.macEvents.allSatisfy { if case .pointerMoved = $0 { true } else { false } },
                "\(sim.macEvents.filter { if case .pointerMoved = $0 { false } else { true } })")
        #expect(sim.phone.isIdle)
    }

    // MARK: Ownership of keys and buttons

    @Test("A key held across the edge is released on the side that saw it pressed")
    func keyHeldAcrossEdge() {
        // Pressed on the Mac, released while the phone owns input.
        sim.keyDown(0)
        #expect(sim.crossToPhone())
        sim.keyDown(0, isRepeat: true)   // Mac repeat must not continue while the phone has input
        sim.keyUp(0)
        #expect(sim.macKeysDown.isEmpty)
        #expect(sim.macEvents.filter { if case .key(_, true, true, _) = $0 { true } else { false } }.isEmpty)

        // Pressed on the phone, released after returning.
        sim.keyDown(1)
        sim.settle()
        #expect(sim.phone.pressedKeys == [0x16])
        #expect(sim.returnToMac())
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty, "phone must not keep a held key")
        sim.keyUp(1)
        #expect(!sim.macEvents.contains(.key(code: 1, down: false, isRepeat: false, modifiers: [])))
    }

    @Test("A modifier held for the phone is hidden from Mac events until released")
    func hiddenModifiers() {
        #expect(sim.crossToPhone())
        sim.pressModifier(55)   // Command on the phone
        #expect(sim.session.hidesModifiers)
        #expect(sim.returnToMac())
        let flags: ModifierFlags = [.command, .leftCommand]
        #expect(sim.session.macVisibleModifiers(flags).isEmpty)
        // A Command held on the Mac's own behalf stays visible.
        sim.pressModifier(54)
        #expect(sim.session.macVisibleModifiers([.command, .leftCommand, .rightCommand]) == [.command, .rightCommand])
        sim.releaseModifier(55)
        sim.releaseModifier(54)
        #expect(!sim.session.hidesModifiers)
    }

    @Test("Caps Lock toggles the phone with a press and release")
    func capsLock() {
        #expect(sim.crossToPhone())
        sim.deliver(.modifierChanged(code: KeyMap.capsLockKeyCode, modifiers: [.capsLock]))
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty)
        #expect(sim.radio.deliveryLog.contains { $0.reportID == 2 && $0.bytes[2] == KeyMap.capsLockUsage })
    }

    @Test("Mouse buttons follow the side that saw the press")
    func buttonOwnership() {
        #expect(sim.crossToPhone())
        sim.deliver(.button(.right, down: true, location: sim.cursor.location))
        sim.session.returnToMac(.requested)
        sim.settle()
        #expect(sim.phone.buttons.isEmpty)
        #expect(sim.deliver(.button(.right, down: false, location: sim.cursor.location)) == .suppress)
        #expect(sim.macButtonsDown.isEmpty)
    }

    @Test("Extra mouse buttons go to the phone (for AssistiveTouch actions), never the Mac")
    func extraButtons() {
        #expect(sim.crossToPhone())
        let back = MouseButton(number: 3)
        #expect(sim.buttonDown(back) == .suppress)
        sim.settle()
        #expect(sim.phone.buttons == [4], "the Mac's button 3 (zero-based) is the phone's button 4")
        #expect(sim.buttonUp(back) == .suppress)
        sim.settle()
        #expect(sim.phone.buttons.isEmpty)
        #expect(sim.returnToMac())
        #expect(sim.buttonDown(back) == .pass)
        #expect(sim.buttonUp(back) == .pass)
    }

    @Test("An entry guard refuses the crossing, says why, and does not nag")
    func entryGuard() {
        var refusals: [String] = []
        sim.session.entryGuard = { "Secure Input is on" }
        sim.session.onEntryRefused = { refusals.append($0) }
        #expect(!sim.crossToPhone())
        #expect(refusals == ["Secure Input is on"], "one push, one notice")
        #expect(!sim.cursor.isHidden)
        sim.session.entryGuard = nil
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
    }

    @Test("Reconcile releases a key whose release was missed")
    func reconcile() {
        #expect(sim.crossToPhone())
        sim.keyDown(0)
        sim.settle()
        #expect(!sim.phone.pressedKeys.isEmpty)
        sim.session.reconcile(keysDown: [], buttonsDown: [])
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty)
        // A later press works normally on the Mac.
        sim.session.returnToMac(.requested)
        #expect(sim.deliver(.key(code: 0, down: true, isRepeat: false, modifiers: [])) == .pass)
    }

    // MARK: Scrolling and gestures

    @Test("Two-finger scrolling drags the phone's content like click-and-hold, never taps")
    func scrolling() throws {
        #expect(sim.crossToPhone())
        sim.move(dx: 100, dy: 0)
        sim.settle()
        let before = sim.phone.pointer
        sim.trackpadScroll(dy: -160, steps: 10)
        sim.settle()
        // Fingers up: the touch (and so the content) moves up, scaled to the phone's screen.
        let link = try #require(sim.session.screenLink)
        #expect(abs(sim.phone.dragScroll.y - -160 * 852 / link.phone.height) < 2)
        #expect(sim.phone.clicks.isEmpty, "a scroll must never tap")
        #expect(sim.phone.buttons.isEmpty)
        // Like a click-and-hold drag, the pointer stays where the drag ended…
        #expect(abs(sim.phone.pointer.x - before.x) < 0.5)
        #expect(abs((sim.phone.pointer.y - before.y) - sim.phone.dragScroll.y) < 1)
        // …and the session agrees, so moving on continues from there.
        let pointer = try #require(sim.session.phonePointer)
        #expect(abs(pointer.y / link.phone.height * 852 - sim.phone.pointer.y) < 1)
        #expect(!sim.macEvents.contains { if case .scroll = $0 { true } else { false } })
    }

    @Test("Wheel style still sends wheel steps")
    func wheelStyle() {
        var settings = sim.session.settings
        settings.scroll.style = .wheel
        sim.session.configure(settings: settings, displays: sim.displays)
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
        sim.trackpadScroll(dy: -160, steps: 10)
        sim.settle()
        // 160 points at 30 points per step.
        #expect(sim.phone.scrollSteps.y == 5)
        #expect(sim.phone.dragScroll == .zero)
    }

    @Test("Pointer speed sets how far the phone pointer moves; the phone's size no longer does",
          arguments: [(620.0, 1.0), (400.0, 1.0), (900.0, 1.0), (620.0, 2.0), (400.0, 0.5)])
    func pointerSpeed(size: Double, speed: Double) throws {
        let settings = SessionSettings(layout: PhoneLayout(displayID: 1, size: size), pointerSpeed: speed)
        let sim = Simulation(settings: settings)
        #expect(sim.crossToPhone())
        let link = try #require(sim.session.screenLink)
        let start = try #require(sim.session.phonePointer)
        sim.move(dx: 0, dy: 100, step: 5)
        let end = try #require(sim.session.phonePointer)
        // Fraction of the phone's height travelled for 100 points of hand movement.
        let fraction = (end.y - start.y) / link.phone.height
        #expect(abs(fraction - speed * 100 / PhoneLayout.referenceSize) < 0.002)
    }

    @Test("Pushing just past the end of the phone's edge enters at its nearest corner; far past it is still a wall")
    func crossingMargin() throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        let farY = link.phone.maxY + ScreenLink.snapMargin + 20
        try #require(farY < link.display.maxY - 1 && !link.isOpen(along: farY))
        sim.move(dx: link.edgeLine - 40 * out - sim.cursor.location.x, dy: farY - sim.cursor.location.y, step: 40)
        sim.move(dx: 80 * out, dy: 0, step: 4)
        #expect(sim.session.owner == .mac, "a wall well below the phone")
        // Ben's case: pushing a few points below the bottom of the phone.
        sim.move(dx: -40 * out, dy: link.phone.maxY + 6 - sim.cursor.location.y, step: 40)
        sim.move(dx: 80 * out, dy: 0, step: 4, stopOnOwnerChange: true)
        #expect(sim.session.owner == .phone)
        #expect(try #require(sim.session.phonePointer).y == link.phone.height - 1)
    }

    @Test("Moving down along the phone's edge while drifting towards the Mac stays on the phone (trace, 12 Oct)")
    func slideAlongPhoneEdge() throws {
        #expect(sim.crossToPhone(atFraction: 0.8))
        let out = try #require(sim.session.screenLink).side.outward
        // The recorded movement: mostly down, one or two points towards the Mac per event.
        for (dx, dy) in [(0.0, 4.0), (-1, 3), (-1, 5), (0, 6), (-2, 11), (-2, 12), (-2, 12), (-1, 7), (-2, 9), (-1, 6)] {
            sim.move(dx: dx * out, dy: dy, step: 20)
        }
        #expect(sim.session.owner == .phone, "no bounce back to the Mac")
        // A sideways push still goes back.
        #expect(sim.returnToMac())
    }

    @Test("Sliding along the Mac's edge while drifting towards the phone does not cross; a push does")
    func slideAlongMacEdge() throws {
        let link = try #require(sim.session.screenLink)
        let out = link.side.outward
        sim.move(dx: link.edgeLine - sim.cursor.location.x, dy: link.phone.minY + 60 - sim.cursor.location.y, step: 40)
        for _ in 0..<20 { sim.move(dx: 2 * out, dy: 10, step: 20) }
        #expect(sim.session.owner == .mac)
        sim.move(dx: 30 * out, dy: 0, step: 4, stopOnOwnerChange: true)
        #expect(sim.session.owner == .phone)
    }

    @Test("Media keys stay with the Mac unless chosen; then they control the phone and release where they were pressed")
    func mediaKeys() throws {
        func isVolumeUp(_ event: InputEvent) -> Bool { if case .mediaKey(.volumeUp, _, _) = event { true } else { false } }
        #expect(sim.crossToPhone())
        // Off (the default): the Mac keeps its volume keys even while on the phone.
        #expect(sim.mediaKey(.volumeUp, down: true) == .pass)
        #expect(sim.mediaKey(.volumeUp, down: false) == .pass)
        #expect(sim.phone.consumerUsage == 0)
        // On.
        var settings = sim.session.settings
        settings.mediaKeysToPhone = true
        sim.session.configure(settings: settings, displays: sim.displays)
        sim.settle(InputSession.exitCooldown)
        #expect(sim.crossToPhone())
        let macEvents = sim.macEvents.count
        #expect(sim.mediaKey(.volumeUp, down: true) == .suppress)
        sim.settle()
        #expect(sim.phone.consumerUsage == MediaKey.volumeUp.consumerUsage)
        #expect(sim.mediaKey(.volumeUp, down: true, isRepeat: true) == .suppress)
        #expect(sim.mediaKey(.volumeUp, down: false) == .suppress)
        sim.settle()
        #expect(sim.phone.consumerUsage == 0)
        #expect(sim.macEvents.count == macEvents, "nothing reached the Mac")
        // Held while input returns: released on the phone, the late release swallowed.
        sim.mediaKey(.playPause, down: true)
        sim.settle()
        #expect(sim.phone.consumerUsage == MediaKey.playPause.consumerUsage)
        #expect(sim.returnToMac())
        sim.settle()
        #expect(sim.phone.consumerUsage == 0)
        #expect(sim.mediaKey(.playPause, down: false) == .suppress)
        // Pressed on the Mac, released after crossing: the release goes to the Mac.
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.mediaKey(.volumeUp, down: true) == .pass)
        #expect(sim.crossToPhone())
        #expect(sim.mediaKey(.volumeUp, down: true, isRepeat: true) == .pass)
        #expect(sim.mediaKey(.volumeUp, down: false) == .pass)
        #expect(sim.phone.consumerUsage == 0)
        #expect(sim.macEvents.contains(where: isVolumeUp))
    }

    @Test("Three-finger swipes become iPhone actions: up = Home (the Menu key), up and hold = App Switcher, down = Notification Centre")
    func phoneGestures() {
        var actions: [InputSession.PhoneAction] = []
        sim.session.onPhoneAction = { actions.append($0) }
        #expect(sim.crossToPhone())
        let macEvents = sim.macEvents.count
        sim.dockSwipe(.vertical, to: -0.34)
        sim.dockSwipe(.vertical, to: -0.4, hold: 0.5)
        sim.dockSwipe(.vertical, to: 0.33)
        sim.dockSwipe(.horizontal, to: 0.31)       // no action assigned
        sim.dockSwipe(.vertical, to: -0.05)        // too small to count
        sim.settle()
        #expect(actions == [.home, .appSwitcher, .notificationCentre])
        // Home is the Menu key (no setup); the others press pointer buttons 5 and 6.
        #expect(sim.phone.consumerPresses == [ConsumerReport.menu])
        #expect(sim.phone.consumerUsage == 0, "the Menu key is released")
        #expect(sim.phone.clicks.map(\.button) == [5, 6], "pointer buttons pressed on the phone")
        #expect(sim.phone.buttons.isEmpty, "every button released")
        #expect(sim.macEvents.count == macEvents, "none of it reached the Mac (no Mission Control)")
    }

    @Test("On the Mac, three-finger swipes stay Mac gestures; with gestures off, nothing happens on the phone")
    func phoneGesturesScope() {
        var actions: [InputSession.PhoneAction] = []
        sim.session.onPhoneAction = { actions.append($0) }
        sim.dockSwipe(.vertical, to: -0.34)
        #expect(sim.macEvents.contains { if case .dockSwipe = $0 { true } else { false } }, "Mission Control works on the Mac")
        var settings = sim.session.settings
        settings.phoneGestures = false
        sim.session.configure(settings: settings, displays: sim.displays)
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
        let macEvents = sim.macEvents.count
        sim.dockSwipe(.vertical, to: -0.34)
        #expect(actions.isEmpty && sim.phone.clicks.isEmpty)
        #expect(sim.macEvents.count == macEvents, "still blocked from the Mac")
    }

    @Test("A zero-movement pointer event (MacHop moving the hidden cursor) doesn't cut a drag-scroll short")
    func zeroMovementKeepsStroke() {
        #expect(sim.crossToPhone())
        sim.deliver(.scroll(ScrollInput(dx: 0, dy: 0, continuous: true, phase: .mayBegin)))
        for index in 0..<5 {
            sim.deliver(.scroll(ScrollInput(dx: 0, dy: -12, continuous: true, phase: index == 0 ? .began : .changed)))
            sim.settle(0.012)
        }
        #expect(sim.phone.buttons.contains(1), "drag in progress")
        sim.deliver(.pointerMoved(location: sim.cursor.location, delta: .zero))
        sim.settle(0.012)
        #expect(sim.phone.buttons.contains(1), "still dragging")
        sim.deliver(.pointerMoved(location: sim.cursor.location, delta: Point(x: 3, y: 0)))
        sim.settle()
        #expect(sim.phone.buttons.isEmpty, "real movement ends it")
    }

    @Test("With scrolling off, two-finger scrolling does nothing on the phone or the Mac")
    func scrollingOff() {
        var settings = sim.session.settings
        settings.scroll.style = .off
        sim.session.configure(settings: settings, displays: sim.displays)
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
        let macEvents = sim.macEvents.count
        sim.trackpadScroll(dy: -160, steps: 10, momentumSteps: 5)
        sim.wheel(lines: 3)
        sim.settle()
        #expect(sim.phone.dragScroll == .zero && sim.phone.scrollSteps == .zero && sim.phone.clicks.isEmpty)
        #expect(sim.macEvents.count == macEvents)
    }

    @Test("A scroll that never ends is released after a moment")
    func strokeTimeout() {
        #expect(sim.crossToPhone())
        sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .mayBegin)))
        sim.deliver(.scroll(ScrollInput(dy: -30, continuous: true, phase: .began)))
        sim.settle(0.05)
        #expect(sim.phone.buttons == [1])
        sim.settle(InputSession.strokeTimeout + 0.05)
        #expect(sim.phone.buttons.isEmpty)
        #expect(sim.phone.clicks.isEmpty)
    }

    @Test("Momentum stays with the side where the gesture began")
    func momentumOwnership() {
        // Gesture starts on the Mac; its momentum continues while the user crosses.
        sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .mayBegin)))
        sim.deliver(.scroll(ScrollInput(dy: 10, continuous: true, phase: .began)))
        sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .ended)))
        #expect(sim.crossToPhone())
        let before = sim.phone.scrollSteps
        for _ in 0..<10 {
            #expect(sim.deliver(.scroll(ScrollInput(dy: 30, continuous: true, momentum: .changed))) == .suppress)
        }
        sim.settle()
        #expect(sim.phone.scrollSteps == before, "a Mac momentum tail must not scroll the phone")

        // Gesture starts on the phone; its momentum after returning stays off the Mac.
        sim.trackpadScroll(dy: -64, steps: 4)
        sim.session.returnToMac(.requested)
        let macScrolls = sim.macEvents.count
        for _ in 0..<10 { sim.deliver(.scroll(ScrollInput(dy: -30, continuous: true, momentum: .changed))) }
        #expect(sim.macEvents.count == macScrolls)
    }

    @Test("A mouse wheel goes wherever input currently is")
    func wheelFollowsOwner() {
        #expect(sim.deliver(.scroll(ScrollInput(dy: 1, continuous: false))) == .pass)
        #expect(sim.crossToPhone())
        sim.wheel(lines: -3)
        sim.settle()
        #expect(sim.phone.scrollSteps.y == 3)
    }

    @Test("Mission Control and other phased gestures stay off the Mac while the phone has input")
    func gestures() {
        #expect(sim.crossToPhone())
        let before = sim.macEvents.count
        sim.gesture(.gesture)
        sim.gesture(.magnify)
        sim.gesture(.swipe)
        #expect(sim.deliver(.gesture(.smartMagnify, phase: .none)) == .suppress)
        #expect(sim.deliver(.gesture(.quickLook, phase: .none)) == .suppress)
        #expect(sim.macEvents.count == before)
        // A gesture that began on the Mac finishes on the Mac.
        #expect(sim.returnToMac())
        sim.deliver(.gesture(.magnify, phase: .began))
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
        #expect(sim.deliver(.gesture(.magnify, phase: .changed)) == .pass)
        #expect(sim.deliver(.gesture(.magnify, phase: .ended)) == .pass)
    }

    // MARK: Availability

    @Test("Losing the phone mid-session returns input and releases everything")
    func disconnectReturns() {
        #expect(sim.crossToPhone())
        sim.keyDown(0)
        sim.radio.disconnect()
        #expect(sim.session.owner == .mac)
        #expect(!sim.cursor.isHidden)
        sim.keyUp(0)
        #expect(sim.macKeysDown.isEmpty)
        sim.radio.connect()
        sim.settle(InputSession.exitCooldown)
        #expect(sim.session.owner == .mac, "reconnecting never takes input by itself")
        #expect(sim.crossToPhone())
    }

    @Test("Changing settings or displays while on the phone returns to the Mac first")
    func reconfigure() {
        #expect(sim.crossToPhone())
        var settings = sim.session.settings
        settings.layout.side = .left
        sim.session.configure(settings: settings, displays: sim.displays)
        #expect(sim.session.owner == .mac)
        #expect(!sim.cursor.isHidden)
        sim.settle(InputSession.exitCooldown)
        #expect(sim.crossToPhone())
        #expect(sim.cursor.isHidden)
    }
}
