import CoreBluetooth
import Testing
@testable import MacHopApp
@testable import MacHopCore

/// May the iPhone take input, and what does MacHop say about it? The starting point in
/// each test is an iPhone that is chosen, linked, awake and ready.
@MainActor
@Suite("Availability")
struct AvailabilityTests {
    let ready = Availability()

    @Test("A chosen, linked, awake iPhone with a usable arrangement may take input")
    func readyByDefault() {
        #expect(ready.disabledReason == nil)
        #expect(ready.status == .ready)
        #expect(!ready.mayWakePhone && !ready.watchesLink)
    }

    // MARK: Why input is off

    @Test("The reason input is off: MacHop's own blockers first, then the iPhone, then the arrangement")
    func disabledReasonOrder() {
        // Everything wrong at once; each fix reveals the next reason.
        var all = Availability(paused: true, accessibilityGranted: false, capturing: false, systemBlock: .macLocked,
                               phoneReady: false, arrangementUsable: false)
        #expect(all.disabledReason == .paused)
        all.paused = false
        #expect(all.disabledReason == .needsAccessibility)
        all.accessibilityGranted = true
        #expect(all.disabledReason == .captureUnavailable)
        all.capturing = true
        #expect(all.disabledReason == .macLocked)
        all.systemBlock = nil
        #expect(all.disabledReason == .phoneNotConnected)
        all.phoneReady = true
        #expect(all.disabledReason == .arrangement)
        all.arrangementUsable = true
        #expect(all.disabledReason == nil)
    }

    @Test("Every system state that keeps input on the Mac disables the iPhone and shows as on hold",
          arguments: [BlockReason.macAsleep, .displaysAsleep, .macLocked, .otherUserActive])
    func systemBlocks(reason: BlockReason) {
        var blocked = ready
        blocked.systemBlock = reason
        #expect(blocked.disabledReason == reason)
        #expect(blocked.status == .blocked(reason))
    }

    // MARK: Waking

    @Test("Waking is offered only when the iPhone being asleep is all that's in the way")
    func waking() {
        var asleep = Availability(link: .connected, phoneReady: false, phoneSuspended: true, wakesPhone: true)
        #expect(asleep.mayWakePhone)
        #expect(asleep.disabledReason == .phoneNotConnected, "input itself stays off until it wakes")
        #expect(asleep.status == .phoneAsleep)

        asleep.wakesPhone = false
        #expect(!asleep.mayWakePhone, "the setting is off")
        asleep.wakesPhone = true

        for change in [\Availability.paused, \.phoneSuspended] as [WritableKeyPath<Availability, Bool>] {
            var other = asleep
            other[keyPath: change].toggle()
            #expect(!other.mayWakePhone)
        }
        for change in [\Availability.accessibilityGranted, \.capturing, \.arrangementUsable] as [WritableKeyPath<Availability, Bool>] {
            var other = asleep
            other[keyPath: change] = false
            #expect(!other.mayWakePhone)
        }
        var locked = asleep
        locked.systemBlock = .macLocked
        #expect(!locked.mayWakePhone)
    }

    // MARK: Status

    @Test("Status: whoever has input, then off, then what's missing, in that order")
    func statusOrder() {
        // Everything wrong at once; each fix reveals the next status.
        var all = Availability(owner: .phone, paused: true, accessibilityGranted: false, systemBlock: .macLocked,
                               bluetooth: .off, link: .connecting, phoneChosen: false, phoneReady: false,
                               arrangementUsable: false)
        #expect(all.status == .controlling)
        all.owner = .mac
        #expect(all.status == .paused)
        all.paused = false
        #expect(all.status == .needsAccessibility)
        all.accessibilityGranted = true
        #expect(all.status == .bluetoothOff)
        all.bluetooth = .waiting
        #expect(all.status == .choosePhone)
        all.phoneChosen = true
        #expect(all.status == .blocked(.macLocked))
        all.systemBlock = nil
        #expect(all.status == .connecting)
        all.link = .connected
        #expect(all.status == .waitingForPhone)
        all.phoneReady = true
        #expect(all.status == .blocked(.arrangement))
        all.arrangementUsable = true
        #expect(all.status == .ready)
    }

    @Test("Bluetooth problems each have their own status")
    func bluetoothStates() {
        var state = ready
        state.bluetooth = .off
        #expect(state.status == .bluetoothOff)
        state.bluetooth = .unauthorized
        #expect(state.status == .bluetoothDenied)
        state.bluetooth = .unsupported
        #expect(state.status == .bluetoothUnavailable("This Mac cannot act as a Bluetooth keyboard."))
        state.bluetooth = .failed("It broke")
        #expect(state.status == .bluetoothUnavailable("It broke"))
        for fine in [HIDPeripheral.State.starting, .waiting, .connected(subscriptions: 5)] {
            state.bluetooth = fine
            #expect(state.status == .ready)
        }
    }

    @Test("An iPhone that connected from its own Bluetooth settings counts, even before it's remembered")
    func unchosenButReady() {
        var state = ready
        state.phoneChosen = false
        #expect(state.status == .ready)
        state.phoneReady = false
        #expect(state.status == .choosePhone)
    }

    @Test("Asleep means linked and paused by the iPhone; an unlinked iPhone is just connecting")
    func asleep() {
        var state = Availability(link: .connected, phoneReady: false, phoneSuspended: true)
        #expect(state.status == .phoneAsleep)
        state.link = .connecting
        #expect(state.status == .connecting)
    }

    // MARK: The link watchdog

    @Test("The link watchdog runs only for a linked iPhone that isn't accepting input, and never for a sleeping one")
    func watchesLink() {
        var state = Availability(link: .connected, phoneReady: false)
        #expect(state.watchesLink)
        state.phoneSuspended = true
        #expect(!state.watchesLink, "a sleeping iPhone paused input on purpose (the 16 Oct reconnect loop)")
        state.phoneSuspended = false
        state.phoneReady = true
        #expect(!state.watchesLink)
        state.phoneReady = false
        state.link = .connecting
        #expect(!state.watchesLink)
    }

    @Test("The watchdog restarts the link three times, tells the user once, then waits")
    func linkWatchActions() {
        #expect((1...6).map(Availability.linkWatchAction(attempt:)) == [.reconnect, .reconnect, .reconnect, .tellUser, .wait, .wait])
    }

    @Test("A link that fails because the iPhone forgot the pairing is recognised; other failures are just retried")
    func pairingRemoved() {
        #expect(PhoneConnector.linkProblem(from: CBError(.peerRemovedPairingInformation)) == .pairingRemoved)
        #expect(PhoneConnector.linkProblem(from: NSError(domain: CBErrorDomain, code: 14)) == .pairingRemoved)
        #expect(PhoneConnector.linkProblem(from: CBError(.connectionTimeout)) == nil)
        #expect(PhoneConnector.linkProblem(from: CBError(.peripheralDisconnected)) == nil)
        #expect(PhoneConnector.linkProblem(from: NSError(domain: "another", code: 14)) == nil)
        #expect(PhoneConnector.linkProblem(from: nil) == nil)
        let notice = PhoneConnector.LinkProblem.pairingRemoved.text(phone: "iPhone1")
        #expect(notice.contains("iPhone1 has forgotten its pairing") && notice.contains("System Settings → Bluetooth"))
    }

    @Test("Reconnecting: at once after a plain drop, then doubling up to half a minute")
    func retryDelays() {
        #expect((0...7).map(PhoneConnector.retryDelay(afterFailures:)) == [0.5, 2, 4, 8, 16, 30, 30, 30])
        #expect(PhoneConnector.countsAsFailure(linkLasted: 0))
        #expect(PhoneConnector.countsAsFailure(linkLasted: 9.9))
        #expect(!PhoneConnector.countsAsFailure(linkLasted: 10))
    }
}
