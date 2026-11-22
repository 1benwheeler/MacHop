// SPDX-License-Identifier: AGPL-3.0-only

/// What MacHop's once-a-second look decides. While anything needs watching, `AppModel`
/// gathers the facts and does what comes back; the deciding is here, as plain values, so
/// it can be tested without a clock, Bluetooth or an event tap.
struct Watchdog {
    /// Seconds between looks.
    static let interval = 1.0
    /// How many looks in a row a linked iPhone may go without accepting input before the
    /// link is restarted.
    static let linkPatience = 12

    struct Facts {
        /// Input capture (the event tap) is running.
        var capturing = true
        /// What MacHop believed about the Accessibility permission, and what's true now.
        var accessibilityWasGranted = true
        var accessibilityGranted = true
        var phoneHasInput = false
        /// A password field on the Mac has taken the keyboard.
        var secureInput = false
        /// macOS still has the event tap switched on.
        var captureHealthy = true
        /// Linked, but the iPhone isn't accepting input (and isn't just asleep).
        var watchesLink = false
        var phoneChosen = true
    }

    enum Action: Equatable {
        /// Accessibility was turned off under a running tap: let go of it at once.
        case accessibilityRevoked
        /// Accessibility has been allowed at last: start up.
        case accessibilityGranted
        /// A password field took the keyboard while the iPhone had input: come back.
        case secureInputTookOver
        /// The tap died while the iPhone had input: come back and restart capture.
        case captureStopped
        /// The iPhone is linked but silent: restart the link.
        case reconnect
        /// Restarting hasn't helped: say so, once.
        case tellUserLinkIsStuck
    }

    private(set) var silentLooks = 0
    private(set) var linkAttempts = 0

    mutating func look(_ facts: Facts) -> [Action] {
        // Turning Accessibility off while an event tap runs can stop all keyboard and mouse
        // input until the Mac restarts (reported on macOS 15 to 27, Sept 2026), and the
        // change notification can arrive before the permission reads as gone. So this is
        // looked for first, and nothing else matters once it's found.
        if facts.capturing && !facts.accessibilityGranted { return [.accessibilityRevoked] }
        var actions: [Action] = []
        if !facts.accessibilityWasGranted && facts.accessibilityGranted { actions.append(.accessibilityGranted) }
        // While the phone has input, Secure Input or a dead tap must hand it back quickly.
        if facts.phoneHasInput {
            if facts.secureInput {
                actions.append(.secureInputTookOver)
            } else if !facts.captureHealthy {
                actions.append(.captureStopped)
            }
        }
        // If the link is up but the phone never starts accepting input, restart the link a
        // few times, then tell the user.
        if facts.watchesLink {
            silentLooks += 1
            if silentLooks >= Self.linkPatience {
                silentLooks = 0
                if facts.phoneChosen {
                    linkAttempts += 1
                    switch Availability.linkWatchAction(attempt: linkAttempts) {
                    case .reconnect: actions.append(.reconnect)
                    case .tellUser: actions.append(.tellUserLinkIsStuck)
                    case .wait: break
                    }
                }
            }
        } else {
            silentLooks = 0
        }
        return actions
    }

    /// The iPhone is accepting input, or the user asked to reconnect: count afresh.
    mutating func linkRecovered() { linkAttempts = 0 }
}
