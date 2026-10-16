// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Carbon
import MacHopCore

/// Mac states in which input must stay local: asleep, displays asleep, screen
/// locked, or another user's session in front. Also reports display changes.
final class SystemMonitor {
    var onChange: (() -> Void)?
    var onDisplaysChanged: (() -> Void)?
    /// The active Space or the frontmost app changed (either can show a hidden cursor).
    var onFrontChange: (() -> Void)?

    private(set) var asleep = false
    private(set) var displaysAsleep = false
    private(set) var locked = false
    private(set) var sessionInactive = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    /// Why input must stay on the Mac right now, if anything.
    var blockingReason: String? {
        if asleep { return "Your Mac is asleep" }
        if displaysAsleep { return "Your displays are asleep" }
        if locked { return "Your Mac is locked" }
        if sessionInactive { return "Another user is active" }
        return nil
    }

    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// True while Mission Control or App Exposé is showing. macOS keeps the cursor
    /// visible over it, so hopping onto the iPhone would leave two pointers. The Dock
    /// then covers the screen with a window at layer 18, which it has at no other time.
    /// Takes a few milliseconds, so it's checked only when crossing.
    static var missionControlShowing: Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? Int32) == dock && ($0[kCGWindowLayer as String] as? Int) == 18
        }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        // Screens only wake on a real wake (never during the Mac's background wakes), so
        // they also end sleep, in case a did-wake notice never comes (an aborted sleep).
        observe(workspace, NSWorkspace.screensDidWakeNotification) {
            $0.displaysAsleep = false
            $0.asleep = false
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        // Posted when the Accessibility permission list changes.
        observe(distributed, Notification.Name("com.apple.accessibility.api")) { _ in }
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplaysChanged?() }
        }
        tokens.append((NotificationCenter.default, token))
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            let front = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFrontChange?() }
            }
            tokens.append((workspace, front))
        }
    }

    /// Sleep or wake as the system notices would, for testing through automation.
    func simulate(asleep: Bool) {
        self.asleep = asleep
        Log.app.notice("System state: simulated \(asleep ? "sleep" : "wake", privacy: .public)")
        onChange?()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ update: @escaping @MainActor (SystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                Log.app.notice("System state: \(name.rawValue, privacy: .public)")
                self.onChange?()
            }
        }
        tokens.append((center, token))
    }

    /// The Mac's displays in global (top-left origin) coordinates.
    static func displays() -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            let bounds = CGDisplayBounds(id)
            return Display(id: id, frame: Rect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height))
        }
    }

    static func displayName(_ id: UInt32) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "Display \(id)"
    }
}
