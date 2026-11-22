import ServiceManagement
import SwiftUI
import Testing
@testable import MacHopApp
@testable import MacHopCore

/// What the UI shows for each status must agree with itself across the menu bar, the
/// menu, the sidebar and the My iPhone page.
@MainActor
@Suite("Status presentation")
struct StatusPresentationTests {
    nonisolated static let all: [AppModel.Status] = [
        .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable("It broke"), .choosePhone,
        .connecting, .waitingForPhone, .phoneAsleep, .ready, .controlling, .paused, .blocked(.macLocked)
    ]

    @Test("Connected looks connected everywhere: green, the full menu-bar mark, a lit iPhone", arguments: all)
    func connected(status: AppModel.Status) {
        let connected = status == .ready || status == .controlling
        #expect(status.isConnected == connected)
        #expect((status.colour == .green) == connected)
        #expect((status.menuBarIcon == .mark) == connected)
        #expect((status.stage != .offline) == connected)
    }

    @Test("Something to fix looks the same everywhere: red, a warning sign, 'Needs attention'", arguments: all)
    func needsFixing(status: AppModel.Status) {
        let broken: Bool = switch status {
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable: true
        default: false
        }
        #expect((status.colour == .red) == broken)
        #expect((status.menuBarIcon == .warning) == broken)
        #expect((status.shortText == "Needs attention") == broken)
        // The menu says what's wrong in full, since it has no other line to say it.
        if broken { #expect(status.menuText(phone: "iPhone1") == status.title(phone: "iPhone1")) }
    }

    @Test("The words name the iPhone and pass on the reason")
    func words() {
        #expect(AppModel.Status.ready.title(phone: "iPhone1") == "Connected to iPhone1")
        #expect(AppModel.Status.controlling.title(phone: "iPhone1") == "Controlling iPhone1")
        #expect(AppModel.Status.phoneAsleep.title(phone: "iPhone1") == "iPhone1 Is Asleep")
        #expect(AppModel.Status.ready.detail(side: .bottom, wakesPhone: false) == "Move the pointer past the bottom edge of your screen.")
        #expect(AppModel.Status.phoneAsleep.detail(side: .right, wakesPhone: true) == "Move onto your iPhone to wake it.")
        #expect(AppModel.Status.phoneAsleep.detail(side: .right, wakesPhone: false) == "Wake your iPhone to use it.")
        let locked = AppModel.Status.blocked(.macLocked)
        #expect(locked.detail(side: .right, wakesPhone: false) == "Your Mac is locked")
        #expect(locked.menuText(phone: "iPhone1") == "Your Mac is locked")
        #expect(locked.shortText == "On hold")
        #expect(AppModel.Status.bluetoothUnavailable("It broke").detail(side: .right, wakesPhone: false) == "It broke")
        let arrangement = AppModel.Status.blocked(.arrangement)
        #expect(arrangement.detail(side: .right, wakesPhone: false) == "Check the arrangement in Settings.")
    }

    @Test("Every reason keeps its wording")
    func reasonWording() {
        let expected: [BlockReason: String] = [
            .starting: "Starting", .paused: "Paused", .needsAccessibility: "MacHop needs Accessibility permission",
            .captureUnavailable: "Input capture is unavailable", .macAsleep: "Your Mac is asleep",
            .displaysAsleep: "Your displays are asleep", .macLocked: "Your Mac is locked",
            .otherUserActive: "Another user is active", .phoneNotConnected: "iPhone is not connected",
            .arrangement: "Check the arrangement", .macGoingToSleep: "Your Mac is going to sleep",
            .bluetoothStalled: "Bluetooth stopped responding", .secureInput: "Secure Input became active on your Mac",
            .accessibilityRevoked: "Accessibility permission was turned off", .captureTimedOut: "Input capture timed out",
            .captureDisabled: "Input capture was disabled", .captureStopped: "Input capture stopped"
        ]
        #expect(expected.count == BlockReason.allCases.count)
        for reason in BlockReason.allCases { #expect(reason.text == expected[reason], "\(reason)") }
        #expect(EntryRefusal.secureInput.text == "A password field on your Mac is using Secure Input.")
        #expect(EntryRefusal.missionControl.text == "Close Mission Control to move onto your iPhone.")
    }

    @Test("The permission instruction names the pane as this macOS calls it, and no pane where that isn't known")
    func privacyPane() {
        func path(_ major: Int, _ minor: Int) -> String {
            PrivacyPane.accessibilityPath(macOS: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        #expect(path(14, 0) == "System Settings → Privacy & Security → Accessibility")
        #expect(path(26, 5) == "System Settings → Privacy & Security → Accessibility")
        #expect(path(27, 0) == "System Settings → Privacy & Security → Device Control and Data Access")
        #expect(path(27, 2) == "System Settings → Privacy & Security → Device Control and Data Access")
        #expect(path(27, 3) == "System Settings → Privacy & Security", "27.3 splits the pane; which half isn't known yet")
        #expect(path(28, 0) == "System Settings → Privacy & Security")
        #expect(AppModel.Status.needsAccessibility.detail(side: .right, wakesPhone: false)
                == "Allow MacHop in \(PrivacyPane.accessibilityPath()).")
    }

    @Test("Notice text is dark enough to read on a white card")
    func noticeContrast() throws {
        let colour = try #require(Theme.noticeOnLight.usingColorSpace(.sRGB))
        func linear(_ c: CGFloat) -> Double { c <= 0.03928 ? Double(c) / 12.92 : pow((Double(c) + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(colour.redComponent) + 0.7152 * linear(colour.greenComponent) + 0.0722 * linear(colour.blueComponent)
        let ratio = 1.05 / (luminance + 0.05)
        #expect(ratio >= 4.5, "contrast against white is \(ratio)")
    }

    @Test("Input coming back is announced, except when the user switched MacHop off themselves")
    func announcements() {
        for reason in BlockReason.allCases { #expect(reason.isAnnounced == (reason != .paused), "\(reason)") }
    }

    @Test("The main button offers the next step; the steps that get MacHop going stand out")
    func mainButton() {
        let expected: [(AppModel.Status, String, Bool)] = [
            (.needsAccessibility, "Allow Access…", true), (.bluetoothDenied, "Open Bluetooth Settings…", false),
            (.controlling, "Return to Mac", false), (.connecting, "Reconnect", false), (.waitingForPhone, "Reconnect", false),
            (.paused, "Turn On", true), (.choosePhone, "Choose iPhone…", true), (.ready, "Turn Off", false),
            (.phoneAsleep, "Turn Off", false), (.blocked(.macLocked), "Turn Off", false),
            (.bluetoothOff, "Turn Off", false), (.bluetoothUnavailable("It broke"), "Turn Off", false)
        ]
        #expect(expected.count == Self.all.count)
        for (status, title, prominent) in expected {
            #expect(status.mainAction.title == title, "\(status)")
            #expect(status.mainAction.isProminent == prominent, "\(status)")
        }
    }

    @Test("A blocked login item is explained only when the user has just asked for Open at login")
    func blockedLoginItem() {
        #expect(AppModel.loginItemNeedsApproval(asked: true, status: .requiresApproval))
        #expect(!AppModel.loginItemNeedsApproval(asked: false, status: .requiresApproval), "turning it off needs no explaining")
        #expect(!AppModel.loginItemNeedsApproval(asked: true, status: .enabled))
        #expect(!AppModel.loginItemNeedsApproval(asked: true, status: .notRegistered))
        #expect(!AppModel.loginItemNeedsApproval(asked: true, status: .notFound))
    }

    @Test("At launch the window opens only when a first setup step is missing", arguments: all)
    func launch(status: AppModel.Status) {
        let opens = status == .needsAccessibility || status == .choosePhone || status == .bluetoothDenied
        #expect(status.opensWindowAtLaunch == opens)
    }
}
