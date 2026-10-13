// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import SwiftUI

/// The menu-bar item: a status line and a few commands. Never activates the app
/// during ordinary use.
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var open: () -> Void
        var guide: () -> Void
        var about: () -> Void
    }

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let actions: Actions

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        trackStatus()
    }

    /// Updates the icon whenever the status changes.
    private func trackStatus() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackStatus() } }
        }
    }

    private func updateIcon() {
        let title = StatusText.title(model)
        var dimmed = false
        let image: NSImage?
        switch model.status {
        case .ready, .controlling:
            image = Self.mark
        case .paused, .connecting, .waitingForPhone, .choosePhone, .blocked:
            image = Self.mark
            dimmed = true
        case .needsAccessibility, .bluetoothOff, .bluetoothDenied, .bluetoothUnavailable:
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            image?.isTemplate = true
        }
        image?.accessibilityDescription = "MacHop: \(title)"
        item.button?.image = image
        item.button?.appearsDisabled = dimmed
        item.button?.toolTip = "MacHop — \(title)"
    }

    private static let mark = MacHopMark.menuBarImage()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // Control Centre style: a header with an on/off switch, the iPhone as a device row, then commands.
        menu.addItem(hosted(MenuHeader(model: model)))
        menu.addItem(.separator())
        menu.addItem(hosted(MenuDeviceRow(model: model) { [weak self] in
            self?.closeMenu { self?.model.settings.phoneID == nil ? self?.actions.guide() : self?.actions.open() }
        }))
        if let notice = model.notice {
            menu.addItem(hosted(Text(notice).font(.system(size: 11.5)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 4)))
        }
        menu.addItem(.separator())
        if model.owner == .phone {
            let back = add("Return to Mac", #selector(returnToMac), to: menu)
            back.keyEquivalent = "\u{1b}"
            back.keyEquivalentModifierMask = [.control, .option, .command]
        }
        if model.settings.phoneID != nil {
            add("Reconnect", #selector(reconnect), to: menu)
        }
        if model.owner == .phone || model.settings.phoneID != nil { menu.addItem(.separator()) }
        add("MacHop Settings…", #selector(showSettings), key: ",", to: menu)
        add("Setup Guide…", #selector(showGuide), to: menu)
        menu.addItem(.separator())
        add("About MacHop", #selector(showAbout), to: menu)
        add("Quit MacHop", #selector(quit), key: "q", to: menu)
    }

    /// A menu item showing a SwiftUI view at the menu's width.
    private func hosted<Content: View>(_ content: Content) -> NSMenuItem {
        let host = NSHostingView(rootView: content.frame(width: Self.menuWidth, alignment: .leading))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    fileprivate static let menuWidth = 300.0

    /// Closes the menu, then runs `action` (custom rows don't close it themselves).
    private func closeMenu(then action: @escaping () -> Void) {
        item.menu?.cancelTracking()
        DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func returnToMac() { model.returnToMac() }
    @objc private func reconnect() { model.reconnect() }
    @objc private func showSettings() { actions.open() }
    @objc private func showGuide() { actions.guide() }
    @objc private func showAbout() { actions.about() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Human-readable status, shared by the menu and the settings window.
enum StatusText {
    static func title(_ model: AppModel) -> String {
        switch model.status {
        case .controlling: "Controlling \(model.phoneName)"
        case .ready: "Connected to \(model.phoneName)"
        case .paused: "MacHop Is Off"
        case .needsAccessibility: "Accessibility Permission Needed"
        case .bluetoothOff: "Bluetooth Is Off"
        case .bluetoothDenied: "Bluetooth Permission Needed"
        case .bluetoothUnavailable: "Bluetooth Unavailable"
        case .choosePhone: "Choose Your iPhone"
        case .connecting: "Connecting to \(model.phoneName)…"
        case .waitingForPhone: "Waiting for \(model.phoneName)…"
        case .blocked: "Input Stays on Your Mac"
        }
    }

    static func detail(_ model: AppModel) -> String {
        let side = model.settings.session.layout.side == .right ? "right" : "left"
        switch model.status {
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
        case .blocked(let reason): return reason
        }
    }
}

/// "MacHop" with a switch that turns it on or off (pauses it), like Control Centre's Wi-Fi menu.
private struct MenuHeader: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text("MacHop").font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("MacHop", isOn: Binding(get: { !model.settings.paused },
                                           set: { on in model.update { $0.paused = !on } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// The iPhone as a device row: a round icon, its name and its state. Clicking opens MacHop.
private struct MenuDeviceRow: View {
    let model: AppModel
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.18))
                    Image(systemName: "iphone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(active ? Color.white : Color.secondary)
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.settings.phoneID == nil ? "Set Up Your iPhone" : model.phoneName)
                        .font(.system(size: 13, weight: .medium))
                    Text(state).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .accessibilityLabel("\(model.phoneName), \(state)")
    }

    private var active: Bool { model.status == .ready || model.status == .controlling }

    private var state: String {
        switch model.status {
        case .controlling: "In use · ⌃⌥⌘⎋ returns to your Mac"
        case .ready: "Connected"
        case .paused: "MacHop is off"
        case .connecting, .waitingForPhone: "Connecting…"
        case .choosePhone: "Choose your iPhone to begin"
        case .blocked(let reason): reason
        default: StatusText.title(model)
        }
    }
}

extension MenuBarController {
    /// The menu's custom rows above a sample of its items, for off-screen design checks (dry runs).
    static func preview(model: AppModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader(model: model)
            Divider().padding(.vertical, 5).padding(.horizontal, 14)
            MenuDeviceRow(model: model) {}
            Divider().padding(.vertical, 5).padding(.horizontal, 14)
            ForEach(["Reconnect", "MacHop Settings…", "Setup Guide…", "About MacHop", "Quit MacHop"], id: \.self) { title in
                Text(title).font(.system(size: 13)).padding(.horizontal, 14).padding(.vertical, 3.5)
            }
        }
        .padding(.vertical, 6)
        .frame(width: menuWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
    }
}
