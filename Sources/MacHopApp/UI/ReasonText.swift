// SPDX-License-Identifier: AGPL-3.0-only
import MacHopCore

// The words for why the iPhone can't take input, or why input came back to the Mac.
// The decisions pass these reasons around as values; this is the one place they
// become sentences.

extension BlockReason {
    /// In a few words: after "Input returned to your Mac:", in the log and in diagnostics.
    var text: String {
        switch self {
        case .starting: "Starting"
        case .paused: "Paused"
        case .needsAccessibility: "MacHop needs Accessibility permission"
        case .captureUnavailable: "Input capture is unavailable"
        case .macAsleep: "Your Mac is asleep"
        case .displaysAsleep: "Your displays are asleep"
        case .macLocked: "Your Mac is locked"
        case .otherUserActive: "Another user is active"
        case .phoneNotConnected: "iPhone is not connected"
        case .arrangement: "Check the arrangement"
        case .macGoingToSleep: "Your Mac is going to sleep"
        case .bluetoothStalled: "Bluetooth stopped responding"
        case .secureInput: "Secure Input became active on your Mac"
        case .accessibilityRevoked: "Accessibility permission was turned off"
        case .captureTimedOut: "Input capture timed out"
        case .captureDisabled: "Input capture was disabled"
        case .captureStopped: "Input capture stopped"
        }
    }

    /// As a status line of its own, where the arrangement says where to fix it.
    var statusText: String {
        self == .arrangement ? "Check the arrangement in Settings." : text
    }

    /// Whether to tell the user when input comes back to the Mac for this reason.
    /// Not when they switched MacHop off themselves.
    var isAnnounced: Bool { self != .paused }
}

extension EntryRefusal {
    /// The notice shown when a push into the edge is refused.
    var text: String {
        switch self {
        case .secureInput: "A password field on your Mac is using Secure Input."
        case .missionControl: "Close Mission Control to move onto your iPhone."
        }
    }
}
