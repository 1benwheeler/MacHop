import Testing
@testable import MacHopCore
@testable import VirtualPhone

/// A sleeping iPhone (it suspended input) and the ⌃⌥⌘I shortcut.
@MainActor
@Suite("Waking and jumping")
struct WakeAndJumpTests {
    let sim = Simulation()

    /// What the app does: let the session wake the phone through the transport.
    private func allowWaking() {
        sim.session.mayWakePhone = true
        sim.session.onWakePhone = { [transport = sim.transport] in transport.wake() }
    }

    private func pressJump() {
        for code: UInt16 in [59, 58, 55] { sim.pressModifier(code) }
        sim.keyDown(KeyMap.jumpKeyCode)
        sim.keyUp(KeyMap.jumpKeyCode)
        for code: UInt16 in [55, 58, 59] { sim.releaseModifier(code) }
        sim.settle()
    }

    // MARK: Waking

    @Test("A sleeping iPhone stays asleep unless waking is allowed")
    func asleepStaysAsleep() {
        sim.radio.sleepScreen()
        sim.settle()
        let sent = sim.radio.delivered
        #expect(!sim.crossToPhone())
        sim.settle(1)
        #expect(sim.radio.delivered == sent, "nothing reaches a sleeping iPhone")
        #expect(sim.radio.wakes == 0)
        #expect(sim.transport.isSuspended)
    }

    @Test("Pushing into a sleeping iPhone's edge wakes it once; pushing on crosses once it's on")
    func pushWakes() {
        allowWaking()
        sim.radio.sleepScreen()
        sim.settle()
        #expect(!sim.crossToPhone(), "the push that wakes it doesn't cross")
        sim.settle(0.1)
        #expect(sim.radio.wakes == 1)
        #expect(sim.phone.text.isEmpty && sim.phone.clicks.isEmpty && sim.phone.isIdle, "waking types and clicks nothing")
        sim.settle(sim.radio.wakeDelay)
        #expect(!sim.transport.isSuspended)
        #expect(sim.crossToPhone())
    }

    @Test("Pushing on while it wakes doesn't send another wake")
    func oneWakePerPush() {
        allowWaking()
        sim.radio.wakeDelay = 10
        sim.radio.sleepScreen()
        sim.settle()
        sim.crossToPhone()
        sim.settle(0.1)
        let sent = sim.transport.stats.submitted
        #expect(sent > 0)
        for _ in 0..<3 {
            sim.crossToPhone()
            sim.settle(0.2)
        }
        #expect(sim.transport.stats.submitted == sent)
        #expect(sim.session.owner == .mac)
    }

    @Test("The transport only wakes a phone that has suspended input")
    func wakeNeedsSuspension() {
        #expect(!sim.transport.wake())
        sim.radio.sleepScreen()
        #expect(sim.transport.wake())
        sim.radio.disconnect()
        #expect(!sim.transport.wake())
    }

    // MARK: Jumping

    @Test("⌃⌥⌘I jumps to the middle of the iPhone, and back to where the cursor was")
    func jumpAndBack() {
        let start = sim.cursor.location
        pressJump()
        #expect(sim.session.owner == .phone)
        #expect(sim.cursor.isHidden)
        #expect(abs(sim.phone.pointer.x - 393 / 2) < 1 && abs(sim.phone.pointer.y - 852 / 2) < 1)
        #expect(sim.phone.isIdle, "the shortcut's keys don't reach the iPhone")
        #expect(sim.macKeysDown.isEmpty, "nor stay held on the Mac")
        #expect(!sim.macEvents.contains { if case .key(KeyMap.jumpKeyCode, _, _, _) = $0 { true } else { false } })
        sim.move(dx: 30, dy: 20)
        pressJump()
        #expect(sim.session.owner == .mac)
        #expect(!sim.cursor.isHidden)
        #expect(sim.cursor.location == start)
        #expect(sim.phone.isIdle)
    }

    @Test("⌃⌥⌘⎋ after a jump also puts the cursor back")
    func escapeAfterJump() {
        let start = sim.cursor.location
        pressJump()
        for code: UInt16 in [59, 58, 55] { sim.pressModifier(code) }
        sim.keyDown(KeyMap.escapeKeyCode)
        sim.keyUp(KeyMap.escapeKeyCode)
        for code: UInt16 in [55, 58, 59] { sim.releaseModifier(code) }
        #expect(sim.session.owner == .mac)
        #expect(sim.cursor.location == start)
    }

    @Test("A return through the edge after a jump lands at the edge, as usual")
    func edgeReturnAfterJump() throws {
        let link = try #require(sim.session.screenLink)
        pressJump()
        #expect(sim.returnToMac())
        #expect(abs(sim.cursor.location.x - link.edgeLine) < 60)
    }

    @Test("⌃⌥⌘I wakes a sleeping iPhone when allowed, then jumps once it's on")
    func jumpWakes() {
        allowWaking()
        sim.radio.sleepScreen()
        sim.settle()
        pressJump()
        #expect(sim.radio.wakes == 1)
        #expect(sim.session.owner == .mac)
        sim.settle(sim.radio.wakeDelay)
        #expect(sim.session.owner == .phone)
    }

    @Test("A late wake doesn't jump long after the shortcut")
    func lateWakeDoesNotJump() {
        allowWaking()
        sim.radio.wakeDelay = InputSession.jumpWakeWindow + 1
        sim.radio.sleepScreen()
        sim.settle()
        pressJump()
        sim.settle(sim.radio.wakeDelay + 0.1)
        #expect(!sim.transport.isSuspended)
        #expect(sim.session.owner == .mac)
    }

    @Test("⌃⌥⌘I with no iPhone available says so and isn't passed on")
    func jumpUnavailable() {
        var told = 0
        sim.session.onJumpUnavailable = { told += 1 }
        sim.radio.sleepScreen()
        sim.settle()
        pressJump()
        #expect(told == 1)
        #expect(sim.session.owner == .mac)
        #expect(sim.radio.wakes == 0)
        #expect(!sim.macEvents.contains { if case .key(KeyMap.jumpKeyCode, _, _, _) = $0 { true } else { false } })
    }

    @Test("⌃⌥⇧⌘I and plain I are ordinary keys")
    func otherCombinationsPass() {
        sim.keyDown(KeyMap.jumpKeyCode)
        sim.keyUp(KeyMap.jumpKeyCode)
        for code: UInt16 in [59, 58, 55, 56] { sim.pressModifier(code) }
        sim.keyDown(KeyMap.jumpKeyCode)
        sim.keyUp(KeyMap.jumpKeyCode)
        for code: UInt16 in [56, 55, 58, 59] { sim.releaseModifier(code) }
        #expect(sim.session.owner == .mac)
        #expect(sim.macEvents.filter { if case .key(KeyMap.jumpKeyCode, true, _, _) = $0 { true } else { false } }.count == 2)
    }
}
