import Testing
@testable import MacHopApp

/// MacHop's once-a-second look: what it does about a revoked permission, a password
/// field or dead tap while the iPhone has input, and a linked iPhone that stays silent.
@MainActor
@Suite("Watchdog")
struct WatchdogTests {
    @Test("With everything in order, looking does nothing, however long it goes on")
    func quiet() {
        var watchdog = Watchdog()
        for _ in 0..<100 { #expect(watchdog.look(Watchdog.Facts()).isEmpty) }
        for _ in 0..<100 { #expect(watchdog.look(Watchdog.Facts(phoneHasInput: true)).isEmpty) }
    }

    @Test("Accessibility turned off under a running tap is acted on at the next look, before anything else")
    func revoked() {
        var watchdog = Watchdog()
        // Everything else going on at once: only letting go of the tap matters.
        let facts = Watchdog.Facts(capturing: true, accessibilityGranted: false, phoneHasInput: true, secureInput: true,
                                   captureHealthy: false, watchesLink: true)
        #expect(watchdog.look(facts) == [.accessibilityRevoked])
        // With no tap running there is nothing to let go of.
        #expect(watchdog.look(Watchdog.Facts(capturing: false, accessibilityWasGranted: false, accessibilityGranted: false)).isEmpty)
    }

    @Test("Accessibility allowed at last starts MacHop up")
    func granted() {
        var watchdog = Watchdog()
        let waiting = Watchdog.Facts(capturing: false, accessibilityWasGranted: false, accessibilityGranted: false)
        #expect(watchdog.look(waiting).isEmpty)
        var allowed = waiting
        allowed.accessibilityGranted = true
        #expect(watchdog.look(allowed) == [.accessibilityGranted])
    }

    @Test("While the iPhone has input, a password field or a dead tap hands input back; on the Mac they change nothing")
    func whilePhoneHasInput() {
        var watchdog = Watchdog()
        #expect(watchdog.look(Watchdog.Facts(phoneHasInput: true, secureInput: true)) == [.secureInputTookOver])
        #expect(watchdog.look(Watchdog.Facts(phoneHasInput: true, captureHealthy: false)) == [.captureStopped])
        // Secure Input is the reason given when both are true, as before.
        #expect(watchdog.look(Watchdog.Facts(phoneHasInput: true, secureInput: true, captureHealthy: false)) == [.secureInputTookOver])
        #expect(watchdog.look(Watchdog.Facts(phoneHasInput: false, secureInput: true, captureHealthy: false)).isEmpty)
    }

    @Test("A linked iPhone that stays silent: the link is restarted every 12 looks, three times, then the user is told once")
    func silentLink() {
        var watchdog = Watchdog()
        let silent = Watchdog.Facts(watchesLink: true)
        var log: [(Int, Watchdog.Action)] = []
        for second in 1...120 {
            for action in watchdog.look(silent) { log.append((second, action)) }
        }
        #expect(log.map(\.0) == [12, 24, 36, 48])
        #expect(log.map(\.1) == [.reconnect, .reconnect, .reconnect, .tellUserLinkIsStuck])
    }

    @Test("The count starts again whenever the iPhone isn't silently linked: working, asleep or not linked")
    func silenceMustBeUnbroken() {
        var watchdog = Watchdog()
        let silent = Watchdog.Facts(watchesLink: true)
        for _ in 0..<11 { #expect(watchdog.look(silent).isEmpty) }
        #expect(watchdog.look(Watchdog.Facts(watchesLink: false)).isEmpty)
        for _ in 0..<11 { #expect(watchdog.look(silent).isEmpty) }
        #expect(watchdog.look(silent) == [.reconnect])
    }

    @Test("Once the iPhone accepts input, or the user reconnects, the restarts are counted afresh")
    func recovery() {
        var watchdog = Watchdog()
        let silent = Watchdog.Facts(watchesLink: true)
        for _ in 0..<(3 * Watchdog.linkPatience) { _ = watchdog.look(silent) }
        #expect(watchdog.linkAttempts == 3)
        watchdog.linkRecovered()
        var actions: [Watchdog.Action] = []
        for _ in 0..<Watchdog.linkPatience { actions += watchdog.look(silent) }
        #expect(actions == [.reconnect], "a restart again, not the notice")
    }

    @Test("With no iPhone chosen there is nothing to restart")
    func noPhoneChosen() {
        var watchdog = Watchdog()
        for _ in 0..<60 { #expect(watchdog.look(Watchdog.Facts(watchesLink: true, phoneChosen: false)).isEmpty) }
        #expect(watchdog.linkAttempts == 0)
    }
}
