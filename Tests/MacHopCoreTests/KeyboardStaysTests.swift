import Foundation
import Testing
@testable import MacHopCore
@testable import VirtualPhone

/// The option to keep typing on the iPhone after the pointer has come back to the Mac,
/// until the user clicks on the Mac.
@MainActor
@Suite("Typing stays on the iPhone")
struct KeyboardStaysTests {
    let sim = Simulation(settings: SessionSettings(layout: PhoneLayout(displayID: 1), keyboardStaysOnPhone: true))

    /// Onto the iPhone, a click there (as in a text box), and back through the edge.
    private func clickOnPhoneAndComeBack() {
        #expect(sim.crossToPhone())
        sim.move(dx: 80, dy: 40, step: 5)
        sim.click()
        #expect(sim.returnToMac())
        sim.settle()
    }

    private func macKeyEvents() -> Int {
        sim.macEvents.filter { if case .key = $0 { true } else { false } }.count
    }

    // MARK: Off by default

    @Test("By default, and in settings saved before the option existed, typing follows the pointer")
    func offByDefault() throws {
        #expect(!SessionSettings(layout: PhoneLayout(displayID: 1)).keyboardStaysOnPhone)
        let saved = #"{"layout":{"aspectRatio":0.46,"verticalPosition":0.5,"size":620,"displayID":1,"orientation":"portrait","side":"right"}}"#
        #expect(try !JSONDecoder().decode(SessionSettings.self, from: Data(saved.utf8)).keyboardStaysOnPhone)

        let plain = Simulation()
        #expect(plain.crossToPhone())
        plain.move(dx: 80, dy: 40, step: 5)
        plain.click()
        #expect(plain.returnToMac())
        #expect(plain.session.keyboardOwner == .mac)
        plain.type("mac")
        plain.settle()
        #expect(plain.phone.text.isEmpty, "nothing typed on the iPhone once the pointer is back")
        #expect(plain.macEvents.contains { if case .key = $0 { true } else { false } })
    }

    // MARK: Staying

    @Test("After a click on the iPhone, typing carries on there when the pointer returns to the Mac")
    func typingStays() {
        clickOnPhoneAndComeBack()
        #expect(sim.session.owner == .mac && !sim.cursor.isHidden, "the pointer really is back on the Mac")
        #expect(sim.session.keyboardOwner == .phone)
        sim.type("Still here 123!")
        sim.settle()
        #expect(sim.phone.text == "Still here 123!")
        #expect(macKeyEvents() == 0, "none of it reached the Mac")
        // The pointer, meanwhile, works on the Mac as usual.
        let before = sim.macEvents.count
        sim.move(dx: -200, dy: 30)
        #expect(sim.macEvents.count > before)
        #expect(sim.session.keyboardOwner == .phone, "moving the pointer about the Mac changes nothing")
    }

    @Test("Without a click on the iPhone, typing comes back with the pointer")
    func noClickNoStay() {
        #expect(sim.crossToPhone())
        sim.move(dx: 80, dy: 40, step: 5)
        #expect(sim.returnToMac())
        #expect(sim.session.keyboardOwner == .mac)
        sim.type("mac")
        sim.settle()
        #expect(sim.phone.text.isEmpty)
    }

    @Test("Going back onto the iPhone and off again keeps typing there")
    func staysAcrossVisits() {
        clickOnPhoneAndComeBack()
        sim.settle(InputSession.crossingCooldown)
        #expect(sim.crossToPhone())
        #expect(sim.returnToMac())
        #expect(sim.session.keyboardOwner == .phone)
        sim.type("ok")
        sim.settle()
        #expect(sim.phone.text == "ok")
    }

    // MARK: Coming back

    @Test("A click on the Mac brings typing back: the click reaches the Mac, and so does what is typed next")
    func macClickReturnsTyping() {
        clickOnPhoneAndComeBack()
        sim.type("a")
        #expect(sim.buttonDown(.left) == .pass)
        #expect(sim.session.keyboardOwner == .mac)
        #expect(sim.buttonUp(.left) == .pass)
        sim.type("mac")
        sim.settle()
        #expect(sim.phone.text == "a")
        #expect(sim.phone.isIdle)
        #expect(macKeyEvents() == 6, "three keys down and up on the Mac")
    }

    @Test("A key still held when typing comes back is released on the iPhone and its release kept from the Mac")
    func heldKeyComesBackCleanly() {
        clickOnPhoneAndComeBack()
        sim.keyDown(0)
        sim.settle()
        #expect(sim.phone.pressedKeys == [0x04])
        sim.click()                       // on the Mac
        sim.settle()
        #expect(sim.phone.pressedKeys.isEmpty, "the iPhone doesn't keep the key")
        #expect(sim.keyUp(0) == .suppress, "the Mac never saw it pressed")
        #expect(sim.macKeysDown.isEmpty)
    }

    @Test("⌃⌥⌘⎋ brings typing back without any of the chord reaching the Mac or staying held on the iPhone")
    func emergencyShortcut() {
        clickOnPhoneAndComeBack()
        for code: UInt16 in [59, 58, 55] { sim.pressModifier(code) }
        sim.keyDown(KeyMap.escapeKeyCode)
        #expect(sim.session.keyboardOwner == .mac)
        sim.keyUp(KeyMap.escapeKeyCode)
        for code: UInt16 in [55, 58, 59] { sim.releaseModifier(code) }
        sim.settle()
        #expect(sim.phone.isIdle)
        #expect(macKeyEvents() == 0)
        #expect(sim.macKeysDown.isEmpty)
        sim.type("m")
        #expect(macKeyEvents() == 2)
    }

    @Test("Anything that makes the iPhone unavailable brings typing back and leaves nothing held",
          arguments: ["disconnect", "disabled", "asleep", "reconfigured", "asked"])
    func unavailableReturnsTyping(how: String) {
        clickOnPhoneAndComeBack()
        sim.pressModifier(56)
        sim.keyDown(0)
        sim.settle()
        switch how {
        case "disconnect": sim.radio.disconnect()
        case "disabled": sim.session.setEnabled(false, reason: .macLocked)
        case "asleep": sim.transport.setSuspended(true)    // the iPhone paused input: its screen went off
        case "reconfigured": sim.session.configure(settings: sim.session.settings, displays: sim.displays)
        default: sim.session.returnKeyboardToMac()      // what the app does when you switch apps on the Mac
        }
        #expect(sim.session.keyboardOwner == .mac)
        sim.keyUp(0)
        sim.releaseModifier(56)
        // The releases owed to the iPhone arrive once it can take input again.
        if how == "disconnect" { sim.radio.connect() }
        if how == "asleep" { sim.transport.setSuspended(false) }
        sim.settle(0.5)
        #expect(sim.phone.pressedKeys.isEmpty && sim.phone.modifiers == 0)
        #expect(sim.macKeysDown.isEmpty)
        #expect(!sim.session.phoneHoldsInput)
    }

    @Test("A modifier held for the iPhone is hidden from Mac pointer events, so moving the pointer isn't a ⌘-drag")
    func modifiersHiddenFromMac() {
        clickOnPhoneAndComeBack()
        sim.pressModifier(55)
        #expect(sim.session.hidesModifiers)
        #expect(sim.session.macVisibleModifiers([.command, .leftCommand]).isEmpty)
        sim.releaseModifier(55)
        sim.settle()
        #expect(sim.phone.isIdle)
    }

    @Test("Media keys go with the keyboard when they're sent to the iPhone")
    func mediaKeysFollowTheKeyboard() {
        var settings = sim.session.settings
        settings.mediaKeysToPhone = true
        sim.session.configure(settings: settings, displays: sim.displays)
        sim.settle(InputSession.exitCooldown)
        clickOnPhoneAndComeBack()
        #expect(sim.mediaKey(.volumeUp, down: true) == .suppress)
        sim.settle()
        #expect(sim.phone.consumerUsage == MediaKey.volumeUp.consumerUsage)
        sim.click()                       // on the Mac, with the key still down
        sim.settle()
        #expect(sim.phone.consumerUsage == 0)
        #expect(sim.mediaKey(.volumeUp, down: false) == .suppress)
        #expect(sim.mediaKey(.volumeUp, down: true) == .pass, "the next press is the Mac's")
    }

    @Test("The app is told each time typing moves")
    func announcesKeyboardMoves() {
        var moves: [Owner] = []
        sim.session.onKeyboardOwnerChange = { moves.append($0) }
        clickOnPhoneAndComeBack()
        #expect(moves == [.phone], "it went over with the pointer and stayed")
        sim.click()
        #expect(moves == [.phone, .mac])
    }
}
