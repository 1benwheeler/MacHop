// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Carbon
import MacHopCore

/// Mac states in which input must stay local: asleep, displays asleep, screen
/// locked, or another user's session in front. Also reports display changes.
final class SystemMonitor {
    var onChange: (() -> Void)?
    var onDisplaysChanged: (() -> Void)?

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

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.asleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
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
