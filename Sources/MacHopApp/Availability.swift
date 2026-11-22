// SPDX-License-Identifier: AGPL-3.0-only
import MacHopCore

/// Everything that decides whether the iPhone may take input, and what MacHop says about
/// it, as plain values. `AppModel` fills one in from the live components; keeping the
/// decision here means it can be tested without Bluetooth or an event tap.
struct Availability: Equatable {
    var owner: Owner = .mac
    /// MacHop is switched off.
    var paused = false
    var accessibilityGranted = true
    /// Input capture (the event tap) is running.
    var capturing = true
    /// Why the Mac itself must keep input (asleep, locked, another user), if anything.
    var systemBlock: BlockReason?
    var bluetooth: HIDPeripheral.State = .waiting
    var link: PhoneConnector.LinkState = .connected
    var phoneChosen = true
    /// The iPhone is subscribed and accepting input.
    var phoneReady = true
    /// The iPhone has paused input: its screen is off.
    var phoneSuspended = false
    /// The arrangement gives the pointer somewhere to cross.
    var arrangementUsable = true
    /// The user lets MacHop wake a sleeping iPhone.
    var wakesPhone = false

    /// What stops input on the Mac's side, whatever the iPhone is doing.
    private var blocker: BlockReason? {
        paused ? .paused :
            !accessibilityGranted ? .needsAccessibility :
            !capturing ? .captureUnavailable :
            systemBlock
    }

    /// Why the iPhone may not take input right now; nil when it may.
    var disabledReason: BlockReason? {
        blocker ?? (phoneReady ? nil : .phoneNotConnected) ?? (arrangementUsable ? nil : .arrangement)
    }

    /// Waking is only offered when the iPhone being asleep is all that's in the way.
    var mayWakePhone: Bool {
        wakesPhone && phoneSuspended && blocker == nil && arrangementUsable
    }

    /// Whether the link watchdog should run: linked, but the iPhone hasn't started accepting
    /// input. A sleeping iPhone pauses input on purpose; reconnecting would only wake it up
    /// every few seconds.
    var watchesLink: Bool {
        link == .connected && !phoneReady && !phoneSuspended
    }

    var status: AppModel.Status {
        if owner == .phone { return .controlling }
        if paused { return .paused }
        if !accessibilityGranted { return .needsAccessibility }
        switch bluetooth {
        case .off: return .bluetoothOff
        case .unauthorized: return .bluetoothDenied
        case .unsupported: return .bluetoothUnavailable("This Mac cannot act as a Bluetooth keyboard.")
        case .failed(let message): return .bluetoothUnavailable(message)
        default: break
        }
        if !phoneChosen && !phoneReady { return .choosePhone }
        if let systemBlock { return .blocked(systemBlock) }
        if phoneReady { return arrangementUsable ? .ready : .blocked(.arrangement) }
        if link == .connected && phoneSuspended { return .phoneAsleep }
        return link == .connected ? .waitingForPhone : .connecting
    }

    /// What the link watchdog does each time it finds the iPhone linked but still not
    /// accepting input: restart the link a few times, then tell the user once.
    enum LinkWatchAction: Equatable { case reconnect, tellUser, wait }

    static func linkWatchAction(attempt: Int) -> LinkWatchAction {
        attempt <= 3 ? .reconnect : attempt == 4 ? .tellUser : .wait
    }
}
