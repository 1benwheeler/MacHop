// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
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

/// Where in System Settings MacHop is allowed to capture input. Apple renamed the pane in
/// macOS 27 and splits it in two in 27.3.
enum PrivacyPane {
    /// The pane's name, or nil where it isn't known which pane MacHop needs.
    static func accessibilityName(macOS version: OperatingSystemVersion) -> String? {
        if version.majorVersion < 27 { return "Accessibility" }
        // Read from macOS 27.2.1's own settings text, 22 Nov 2026.
        if version.majorVersion == 27 && version.minorVersion < 3 { return "Device Control and Data Access" }
        // 27.3 (in beta, Nov 2026) has "System & App Protection Override" and
        // "Accessibility"; Apple hasn't said which one an event tap needs.
        return nil
    }

    /// "System Settings → Privacy & Security → …", as far as it is known.
    static func accessibilityPath(macOS version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let privacy = "System Settings → Privacy & Security"
        return accessibilityName(macOS: version).map { "\(privacy) → \($0)" } ?? privacy
    }
}

extension PhoneConnector.LinkProblem {
    /// The notice shown when the link can't come up until the user does something.
    func text(phone: String) -> String {
        switch self {
        case .pairingRemoved:
            "\(phone) has forgotten its pairing with this Mac. In System Settings → Bluetooth on your Mac, " +
                "forget \(phone), then choose it again in MacHop."
        }
    }
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
