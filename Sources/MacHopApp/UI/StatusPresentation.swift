// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import MacHopCore

// Everything the UI shows for each status, in one place: the words, the colour, the
// menu-bar icon, the drawing and the main button. Every switch here names every status,
// so adding one makes the compiler ask what each part of the UI should show for it.

/// Human-readable status, shared by the menu and the settings window.
enum StatusText {
    static func title(_ model: AppModel) -> String { model.status.title(phone: model.phoneName) }

    static func detail(_ model: AppModel) -> String {
        model.status.detail(side: model.settings.session.layout.side, wakesPhone: model.settings.wakesPhone == true)
    }
}

extension AppModel.Status {
    /// The headline: the status pill, the menu-bar tooltip.
    func title(phone: String) -> String {
        switch self {
        case .controlling: "Controlling \(phone)"
        case .ready: "Connected to \(phone)"
        case .paused: "MacHop Is Off"
        case .needsAccessibility: "Accessibility Permission Needed"
        case .bluetoothOff: "Bluetooth Is Off"
        case .bluetoothDenied: "Bluetooth Permission Needed"
        case .bluetoothUnavailable: "Bluetooth Unavailable"
        case .choosePhone: "Choose Your iPhone"
        case .connecting: "Connecting to \(phone)…"
        case .waitingForPhone: "Waiting for \(phone)…"
        case .phoneAsleep: "\(phone) Is Asleep"
        case .blocked: "Input Stays on Your Mac"
        }
    }

    /// What to do next, in a sentence: under the page title.
    func detail(side: Side, wakesPhone: Bool) -> String {
        let side = side.rawValue
        switch self {
        case .controlling: return "Move back across the edge, or press ⌃⌥⌘⎋, to return."
        case .ready: return "Move the pointer past the \(side) edge of your screen."
        case .paused: return "Your keyboard and pointer only control this Mac."
        case .needsAccessibility: return "Allow MacHop in System Settings → Privacy & Security → Accessibility."
        case .bluetoothOff: return "Turn on Bluetooth to connect to your iPhone."
        case .bluetoothDenied: return "Allow MacHop in System Settings → Privacy & Security → Bluetooth."
        case .bluetoothUnavailable(let message): return message
        case .choosePhone: return "Choose your iPhone to get started."
        case .connecting: return "Keep your iPhone nearby and unlocked."
        case .waitingForPhone: return "Your iPhone is linked; waiting for it to accept the keyboard and pointer."
        case .phoneAsleep:
            return wakesPhone ? "Move onto your iPhone to wake it." : "Wake your iPhone to use it."
        case .blocked(let reason): return reason.statusText
        }
    }

    /// A word or two, for the sidebar.
    var shortText: String {
        switch self {
        case .controlling: "In use"
        case .ready: "Connected"
        case .paused: "Off"
        case .connecting, .waitingForPhone: "Connecting…"
        case .phoneAsleep: "Asleep"
        case .choosePhone: "Not set up"
        case .blocked: "On hold"
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: "Needs attention"
        }
    }

    /// The line under the iPhone's name in the menu.
    func menuText(phone: String) -> String {
        switch self {
        case .controlling: "In use · ⌃⌥⌘⎋ returns to your Mac"
        case .ready: "Connected"
        case .paused: "MacHop is off"
        case .connecting, .waitingForPhone: "Connecting…"
        case .phoneAsleep: "Asleep"
        case .choosePhone: "Choose your iPhone to begin"
        case .blocked(let reason): reason.statusText
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: title(phone: phone)
        }
    }

    /// Green when connected, orange while waiting on something, red when something needs fixing.
    var colour: Color {
        switch self {
        case .ready, .controlling: .green
        case .connecting, .waitingForPhone, .phoneAsleep, .choosePhone, .paused, .blocked: .orange
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: .red
        }
    }

    /// Connected to the iPhone: ready, or in use.
    var isConnected: Bool {
        switch self {
        case .ready, .controlling: true
        case .paused, .connecting, .waitingForPhone, .phoneAsleep, .choosePhone, .blocked,
             .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: false
        }
    }

    enum MenuBarIcon: Equatable { case mark, dimmedMark, warning }

    /// MacHop's mark when connected, dimmed while it isn't, a warning sign when something needs fixing.
    var menuBarIcon: MenuBarIcon {
        switch self {
        case .ready, .controlling: .mark
        case .paused, .connecting, .waitingForPhone, .phoneAsleep, .choosePhone, .blocked: .dimmedMark
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: .warning
        }
    }

    /// How the arrangement drawing shows the iPhone.
    var stage: DeviceStage.Status {
        switch self {
        case .controlling: .controlling
        case .ready: .ready
        case .paused, .connecting, .waitingForPhone, .phoneAsleep, .choosePhone, .blocked,
             .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: .offline
        }
    }

    /// The one button on the My iPhone page that fits the state.
    enum MainAction: Equatable {
        case allowAccess, openBluetoothSettings, returnToMac, reconnect, turnOn, choosePhone, turnOff

        var title: String {
            switch self {
            case .allowAccess: "Allow Access…"
            case .openBluetoothSettings: "Open Bluetooth Settings…"
            case .returnToMac: "Return to Mac"
            case .reconnect: "Reconnect"
            case .turnOn: "Turn On"
            case .choosePhone: "Choose iPhone…"
            case .turnOff: "Turn Off"
            }
        }

        /// The steps that get MacHop going stand out.
        var isProminent: Bool { self == .allowAccess || self == .turnOn || self == .choosePhone }
    }

    var mainAction: MainAction {
        switch self {
        case .needsAccessibility: .allowAccess
        case .bluetoothDenied: .openBluetoothSettings
        case .controlling: .returnToMac
        case .connecting, .waitingForPhone: .reconnect
        case .paused: .turnOn
        case .choosePhone: .choosePhone
        case .ready, .phoneAsleep, .blocked, .bluetoothOff, .bluetoothUnavailable: .turnOff
        }
    }

    /// At launch MacHop stays in the menu bar unless one of the first setup steps is missing.
    var opensWindowAtLaunch: Bool {
        switch self {
        case .needsAccessibility, .choosePhone, .bluetoothDenied: true
        case .controlling, .ready, .paused, .connecting, .waitingForPhone, .phoneAsleep, .blocked,
             .bluetoothOff, .bluetoothUnavailable: false
        }
    }
}

extension AppModel {
    var stageState: DeviceStage.Status { status.stage }

    /// Colour for the status pill.
    var statusColour: Color { status.colour }
}
