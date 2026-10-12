import Testing
@testable import MacHopCore
@testable import VirtualPhone

/// Deterministic pseudo-random numbers (SplitMix64), so every failure reproduces from its seed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
func checkInvariants(_ sim: Simulation, _ context: @autoclosure () -> String = "",
                     sourceLocation: SourceLocation = #_sourceLocation) {
    let owner = sim.session.owner
    #expect(sim.cursor.isHidden == (owner == .phone), "cursor visibility \(context())", sourceLocation: sourceLocation)
    #expect(sim.phone.errors.isEmpty, "\(sim.phone.errors) \(context())", sourceLocation: sourceLocation)
    let p = sim.phone.pointer
    #expect(p.x >= 0 && p.x <= sim.phone.screen.width && p.y >= 0 && p.y <= sim.phone.screen.height,
            "phone pointer \(p) \(context())", sourceLocation: sourceLocation)
}

/// With every key and button physically released, nothing may remain held anywhere.
@MainActor
func checkQuiescent(_ sim: Simulation, _ context: @autoclosure () -> String = "",
                    sourceLocation: SourceLocation = #_sourceLocation) {
    sim.settle(0.2)
    #expect(sim.phone.isIdle,
            "phone holds keys \(sim.phone.pressedKeys) buttons \(sim.phone.buttons) modifiers \(sim.phone.modifiers) \(context())",
            sourceLocation: sourceLocation)
    #expect(sim.macKeysDown.isEmpty, "Mac stuck keys \(sim.macKeysDown) \(context())", sourceLocation: sourceLocation)
    #expect(sim.macButtonsDown.isEmpty, "Mac stuck buttons \(context())", sourceLocation: sourceLocation)
    #expect(!sim.session.phoneHoldsInput, "session holds input \(context())", sourceLocation: sourceLocation)
    #expect(sim.transport.queuedCount == 0, "reports still queued \(context())", sourceLocation: sourceLocation)
}

@MainActor
@Suite("Simulated iPhone: end-to-end scenarios")
struct SimulationTests {
    @Test("30 consecutive Mac → iPhone → Mac round trips with typing, clicking and scrolling",
          arguments: HIDProfile.Variant.allCases)
    func thirtyRoundTrips(variant: HIDProfile.Variant) {
        let sim = Simulation(profile: HIDProfile(variant))
        var expectedText = ""
        var expectedClicks = 0
        var scrolls = 0
        for trip in 1...30 {
            let fraction = Double(trip % 10) / 10 + 0.05
            #expect(sim.crossToPhone(atFraction: fraction), "trip \(trip): crossing")
            sim.move(dx: 60, dy: Double(trip % 7) * 10 - 30, step: 5)
            sim.click()
            expectedClicks += 1
            let word = "Trip \(trip)! "
            sim.type(word)
            expectedText += word
            sim.trackpadScroll(dy: -64, steps: 8)
            scrolls += 1
            #expect(sim.returnToMac(), "trip \(trip): return")
            checkInvariants(sim, "trip \(trip)")
            checkQuiescent(sim, "trip \(trip)")
            // Move inward and wait out the anti-bounce delay, as a user naturally would.
            sim.move(dx: -200, dy: 0, step: 20)
            sim.settle(InputSession.crossingCooldown)
        }
        #expect(sim.phone.text == expectedText)
        #expect(sim.phone.clicks.count == expectedClicks)
        if HIDProfile(variant).isAbsolute {
            // (A relative pointer drifts against the screen edge, so its drags can't be measured.)
            #expect(sim.phone.drags.count >= scrolls, "every two-finger scroll dragged the content")
            #expect(sim.phone.dragScroll.y < -Double(scrolls) * 60)
        }
        #expect(sim.ownerChanges.count == 60)
        #expect(sim.ownerChanges.allSatisfy { $0.1 == nil || $0.1 == .edge })
        // While the phone had input, nothing but pointer motion before crossing reached the Mac.
        #expect(!sim.macEvents.contains { if case .key = $0 { true } else { false } })
        #expect(!sim.macEvents.contains { if case .scroll = $0 { true } else { false } })
        #expect(!sim.macEvents.contains { if case .button = $0 { true } else { false } })
    }

    @Test("Thousands of edge transitions across random layouts, speeds and display arrangements")
    func randomTransitions() {
        var random = SeededRandom(seed: 0x4D61_6348_6F70)
        var crossings = 0
        var layoutsTested = 0
        for layoutIndex in 0..<40 {
            let side = Side.allCases.randomElement(using: &random)!
            let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: Double.random(in: 1024...2560, using: &random),
                                                  height: Double.random(in: 640...1440, using: &random)))
            var displays = [main]
            // Sometimes another display shares part of the same edge.
            if Bool.random(using: &random) {
                let height = Double.random(in: 200...600, using: &random)
                let x = side == .right ? main.frame.maxX : main.frame.minX - 1200
                let y = Double.random(in: -300...main.frame.maxY - 100, using: &random)
                displays.append(Display(id: 2, frame: Rect(x: x, y: y, width: 1200, height: height)))
            }
            let layout = PhoneLayout(displayID: 1, side: side,
                                     verticalPosition: Double.random(in: 0...1, using: &random),
                                     size: Double.random(in: 300...1400, using: &random),
                                     orientation: Bool.random(using: &random) ? .portrait : .landscape)
            let settings = SessionSettings(layout: layout, edgeResistance: Double.random(in: 0...30, using: &random))
            let sim = Simulation(settings: settings, displays: displays)
            guard let link = sim.session.screenLink else { continue }
            layoutsTested += 1
            for trip in 0..<50 {
                let context = "layout \(layoutIndex) trip \(trip)"
                let span = link.openSpans.randomElement(using: &random)!
                let y = Double.random(in: span.lowerBound..<span.upperBound, using: &random)
                let speed = Double.random(in: 1...60, using: &random)
                // Approach from inside, then push out at a random speed.
                sim.move(dx: link.edgeColumn - 80 * side.outward - sim.cursor.location.x,
                         dy: y - sim.cursor.location.y, step: 60)
                sim.move(dx: (120 + settings.edgeResistance) * side.outward, dy: 0, step: speed,
                         stopOnOwnerChange: true)
                #expect(sim.session.owner == .phone, "\(context): did not cross at y \(y)")
                checkInvariants(sim, context)
                guard sim.session.owner == .phone, let entry = sim.session.phonePointer else { continue }
                crossings += 1
                #expect(abs((link.phone.minY + entry.y) - y) <= max(speed, 2) + 1, "\(context): entry height")
                // Wander on the phone, away from the Mac so input stays there.
                sim.move(dx: Double.random(in: 0...150, using: &random) * side.outward,
                         dy: Double.random(in: -200...200, using: &random), step: speed)
                #expect(sim.session.owner == .phone, "\(context): left the phone while wandering")
                let phoneY = sim.session.phonePointer?.y ?? 0
                sim.move(dx: -(link.phone.width + 200) * side.outward, dy: 0, step: speed, stopOnOwnerChange: true)
                #expect(sim.session.owner == .mac, "\(context): did not return")
                checkInvariants(sim, context)
                let expected = link.returnPoint(phoneY: phoneY)
                #expect(abs(sim.cursor.location.y - expected.y) <= 1, "\(context): return height")
                sim.settle(InputSession.crossingCooldown)
            }
        }
        #expect(layoutsTested >= 30)
        #expect(crossings == layoutsTested * 50)
    }

    @Test("Random input never leaks to the Mac or leaves anything held", arguments: [1, 2, 3, 4, 5] as [UInt64])
    func fuzz(seed: UInt64) {
        var random = SeededRandom(seed: seed)
        let sim = Simulation(profile: HIDProfile(HIDProfile.Variant.allCases[Int(seed) % 3]))
        let modifierCodes: [UInt16] = [56, 59, 58, 55, 60, 62, 61, 54, 63]
        let keyCodes: [UInt16] = [0, 1, 2, 11, 12, 18, 36, 48, 49, 51, 123, 126, 122]
        for step in 0..<4000 {
            let context = "seed \(seed) step \(step)"
            let ownerBefore = sim.session.owner
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<12:
                if Bool.random(using: &random) { sim.crossToPhone(atFraction: Double.random(in: 0...1, using: &random)) }
                else { sim.returnToMac() }
            case 12..<25:
                sim.move(dx: Double.random(in: -300...300, using: &random), dy: Double.random(in: -200...200, using: &random),
                         step: Double.random(in: 1...40, using: &random))
            case 25..<40:
                let code = keyCodes.randomElement(using: &random)!
                if sim.heldKeys.contains(code) { sim.keyUp(code) }
                else if sim.keyDown(code) == .pass && ownerBefore == .phone {
                    Issue.record("\(context): key down leaked to the Mac")
                }
            case 40..<46:
                if let code = sim.heldKeys.filter({ !modifierCodes.contains($0) }).randomElement(using: &random) {
                    sim.keyDown(code, isRepeat: true)
                }
            case 46..<56:
                let code = modifierCodes.randomElement(using: &random)!
                if sim.heldKeys.contains(code) { sim.releaseModifier(code) } else { sim.pressModifier(code) }
            case 56..<66:
                let button = MouseButton.common.randomElement(using: &random)!
                if sim.heldButtons.contains(button) { sim.buttonUp(button) }
                else if sim.buttonDown(button) == .pass && ownerBefore == .phone {
                    Issue.record("\(context): click leaked to the Mac")
                }
            case 66..<76:
                sim.trackpadScroll(dy: Double.random(in: -200...200, using: &random),
                                   dx: Double.random(in: -50...50, using: &random),
                                   steps: Int.random(in: 1...6, using: &random),
                                   momentumSteps: Int.random(in: 0...6, using: &random))
            case 76..<80:
                let disposition = sim.deliver(.scroll(ScrollInput(dy: Double.random(in: -3...3, using: &random),
                                                                  continuous: false)))
                if ownerBefore == .phone { #expect(disposition == .suppress, "\(context): wheel leaked") }
            case 80..<85:
                let kind = GestureKind.allCases.randomElement(using: &random)!
                if kind == .smartMagnify || kind == .quickLook {
                    let disposition = sim.deliver(.gesture(kind, phase: .none))
                    if ownerBefore == .phone { #expect(disposition == .suppress, "\(context): gesture leaked") }
                } else {
                    sim.gesture(kind, steps: 3)
                }
            case 85..<88:
                sim.radio.disconnect()
                sim.settle(Double.random(in: 0...0.5, using: &random))
                sim.radio.connect()
            case 88..<91:
                sim.session.setEnabled(false, reason: "sleep")
                sim.settle(0.05)
                sim.session.setEnabled(sim.transport.isReady)
            case 91..<93:
                sim.session.reconcile(keysDown: sim.heldKeys, buttonsDown: sim.heldButtons)
            case 93..<95:
                if ownerBefore == .phone { sim.keyDown(KeyMap.escapeKeyCode); sim.keyUp(KeyMap.escapeKeyCode) }
            default:
                sim.settle(Double.random(in: 0...0.4, using: &random))
            }
            checkInvariants(sim, context)
        }
        // Let go of everything; nothing may stay held on either side.
        for code in sim.heldKeys {
            if modifierCodes.contains(code) { sim.releaseModifier(code) } else { sim.keyUp(code) }
        }
        for button in sim.heldButtons { sim.buttonUp(button) }
        sim.returnToMac()
        checkQuiescent(sim, "seed \(seed) end")
    }

    @Test("Fast typing survives a congested link in order and with nothing lost")
    func congestedLink() {
        let sim = Simulation()
        sim.radio.capacity = 2
        sim.radio.perEvent = 1
        sim.radio.connectionInterval = 0.030
        #expect(sim.crossToPhone())
        let text = "The quick brown fox jumps over the lazy dog 0123456789 ~!@#$%^&*()_+{}|:\"<>?"
        sim.type(text, interval: 0.004)
        sim.move(dx: 100, dy: 100, step: 1, interval: 0.001)
        sim.settle(15)
        #expect(sim.phone.text == text)
        #expect(sim.transport.stats.backpressureEvents > 0)
        #expect(sim.transport.stats.stalls == 0)
        #expect(sim.session.owner == .phone)
    }

    @Test("Pointer latency stays low under a flood of motion because positions coalesce")
    func motionFlood() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.move(dx: 200, dy: 400, step: 0.5, interval: 0.001)   // 1 kHz gaming-mouse rate
        sim.settle(0.1)
        #expect(sim.radio.maximumLatency <= 0.1)
        #expect(sim.transport.stats.coalesced > 100)
        let link = sim.session.screenLink!
        let pointer = sim.session.phonePointer!
        #expect(abs(sim.phone.pointer.x - pointer.x / link.phone.width * 393) < 0.1)
    }

    @Test("A dead radio returns input to the Mac within the stall timeout")
    func deadRadio() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.radio.isJammed = true
        sim.type("abc")
        sim.settle(sim.transport.stallTimeout + 0.1)
        #expect(sim.session.owner == .mac)
        #expect(!sim.cursor.isHidden)
        // Typing now reaches the Mac.
        #expect(sim.deliver(.key(code: 0, down: true, isRepeat: false, modifiers: [])) == .pass)
        #expect(sim.deliver(.key(code: 0, down: false, isRepeat: false, modifiers: [])) == .pass)
    }

    // Regression scenarios from the independent code review (12 Oct 2026).

    @Test("A stall cannot leave a key held once the radio recovers")
    func stallKeepsReleases() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.keyDown(0)
        sim.settle()
        #expect(sim.phone.pressedKeys == [0x04])
        sim.radio.isJammed = true
        sim.keyUp(0)
        sim.returnToMac()
        sim.settle(1.2)
        #expect(sim.transport.stats.stalls == 1)
        #expect(sim.session.owner == .mac)
        sim.radio.isJammed = false
        sim.transport.radioIsReady()
        sim.settle(0.5)
        #expect(sim.phone.pressedKeys.isEmpty)
        #expect(sim.transport.isReady)
    }

    @Test("Input is unavailable after a stall until the radio works again")
    func noReentryIntoDeadRadio() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.radio.isJammed = true
        sim.type("x")
        sim.settle(1.2)
        sim.session.setEnabled(sim.transport.isReady)   // what the app's refresh does
        sim.settle(InputSession.crossingCooldown)
        #expect(!sim.crossToPhone(), "must not cross back into a dead radio")
    }

    @Test("Suspend or a dropped report subscription cannot leave a key held", arguments: [true, false])
    func suspendReleases(suspend: Bool) {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.keyDown(0)
        sim.settle()
        if suspend {
            sim.transport.setSuspended(true)
            #expect(sim.session.owner == .mac)
            sim.transport.setSuspended(false)
        } else {
            sim.transport.unsubscribed(7)
            #expect(sim.session.owner == .mac)
            sim.transport.subscribed(7)
        }
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty)
    }

    @Test("A cancelled two-finger touch does not capture the next scroll", arguments: [true, false])
    func cancelledTouch(startOnMac: Bool) {
        let sim = Simulation()
        if !startOnMac { #expect(sim.crossToPhone()) }
        sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .mayBegin)))
        sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .cancelled)))
        if startOnMac {
            #expect(sim.crossToPhone())
            sim.deliver(.scroll(ScrollInput(dy: -32, continuous: true, phase: .began)))
            sim.deliver(.scroll(ScrollInput(dy: -32, continuous: true, phase: .changed)))
            sim.deliver(.scroll(ScrollInput(dy: 0, continuous: true, phase: .ended)))
            sim.settle()
            #expect(sim.phone.dragScroll.y < -60)
        } else {
            #expect(sim.returnToMac())
            #expect(sim.deliver(.scroll(ScrollInput(dy: -10, continuous: true, phase: .began))) == .pass)
            #expect(sim.deliver(.scroll(ScrollInput(dy: -10, continuous: true, phase: .changed))) == .pass)
        }
    }

    @Test("Unphased gestures (e.g. a discrete three-finger swipe) stay off the Mac while remote")
    func unphasedGestures() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        for kind in GestureKind.allCases { #expect(sim.deliver(.gesture(kind, phase: .none)) == .suppress, "\(kind)") }
        #expect(sim.returnToMac())
        for kind in GestureKind.allCases { #expect(sim.deliver(.gesture(kind, phase: .none)) == .pass, "\(kind)") }
    }

    @Test("A release missed while capture was interrupted is repaired by reconcile")
    func missedReleaseRepaired() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.keyDown(0)
        sim.settle()
        // The tap was disabled: the key-up went straight to macOS. The app reacts to
        // the gap by returning input and reconciling with the physical key state.
        sim.session.returnToMac(.unavailable("Input capture was interrupted"))
        sim.session.reconcile(keysDown: [], buttonsDown: [])
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty)
        #expect(!sim.session.phoneHoldsInput)
    }

    @Test("Sleep in the middle of typing releases everything; wake needs a new crossing")
    func sleepWake() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        sim.pressModifier(56)
        sim.keyDown(0)
        sim.session.setEnabled(false, reason: "Mac is going to sleep")
        sim.settle()
        #expect(sim.phone.isIdle)
        sim.keyUp(0)
        sim.releaseModifier(56)
        sim.session.setEnabled(true)
        #expect(sim.session.owner == .mac)
        checkQuiescent(sim)
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
    }

    @Test("Unplugging a display while on the phone returns control safely")
    func displayChange() {
        let external = Display(id: 2, frame: Rect(x: 1512, y: 0, width: 1920, height: 1080))
        let main = Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))
        let settings = SessionSettings(layout: PhoneLayout(displayID: 2, side: .right))
        let sim = Simulation(settings: settings, displays: [main, external])
        sim.move(dx: 1500, dy: 0, step: 30)
        #expect(sim.crossToPhone())
        sim.replaceDisplays([main])
        #expect(sim.session.owner == .mac)
        #expect(sim.session.screenLink == nil, "the phone's display is gone, so crossing is off")
        #expect(!sim.crossToPhone())
        sim.replaceDisplays([main, external])
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
    }

    @Test("Event handling is fast enough to never slow the Mac down")
    func performance() {
        let sim = Simulation()
        #expect(sim.crossToPhone())
        let clock = ContinuousClock()
        let events = 100_000
        let elapsed = clock.measure {
            for index in 0..<events {
                let delta = Point(x: index % 2 == 0 ? 1 : -1, y: index % 3 == 0 ? 1 : -1)
                _ = sim.session.handle(.pointerMoved(location: sim.cursor.location, delta: delta))
            }
        }
        let perEvent = elapsed / events
        print("InputSession: \(perEvent) per pointer event over \(events) events")
        #expect(perEvent < .microseconds(50))
    }
}

