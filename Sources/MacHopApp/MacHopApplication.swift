// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// Entry point used by the `MacHop` executable.
public enum MacHopApplication {
    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private let navigation = Navigation()
    private var menuBar: MenuBarController?
    private var window: NSWindow?
    private var automation: AutomationServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        menuBar = MenuBarController(model: model, actions: .init(
            open: { [weak self] in self?.showWindow(page: .phone) },
            guide: { [weak self] in self?.showSetup() },
            about: { [weak self] in self?.showAbout() }))
        model.start()
        if AutomationServer.isEnabled && !model.dryRun {
            automation = AutomationServer(model: model)
            automation?.start()
        }
        if model.dryRun {
            if CommandLine.arguments.contains("--demo") { model.enterDemoMode() }
            // `--light`: render in light mode whatever the system uses (for the README).
            if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
            // Lay out the window off screen to check the UI builds, without taking focus.
            let window = makeWindow()
            window.contentView?.layoutSubtreeIfNeeded()
            Log.app.notice("Dry run: window laid out at \(Int(window.contentView?.fittingSize.height ?? 0), privacy: .public) pt")
            // `--snapshot-ui <folder>`: render every page to PNG files, off screen, and quit.
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--snapshot-ui"), index + 1 < arguments.count {
                let folder = URL(fileURLWithPath: arguments[index + 1])
                var steps: [(String, () -> Void)] = Navigation.Page.allCases.map { page in
                    ("\(page)", { [navigation] in navigation.showingSetup = false; navigation.page = page })
                }
                steps.append(("setup", { [navigation] in navigation.showingSetup = true }))
                let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 320), styleMask: [.borderless],
                                          backing: .buffered, defer: false)
                menuWindow.contentView = NSHostingView(rootView: MenuBarController.preview(model: model))
                // A crowded room: 30 devices, to check the list scrolls and Done stays in view.
                let crowd = (1...30).map { index in
                    NearbyDevice(id: UUID(), name: index == 1 ? "iPhone1" : index <= 4 ? "Apple device \(index)" : "Speaker \(index)",
                                 signal: -50 - index, isApple: index <= 4)
                }
                let controlsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360), styleMask: [.titled],
                                              backing: .buffered, defer: false)
                controlsWindow.contentView = NSHostingView(rootView: Panel { ArrangementControls(model: model) }
                    .padding(20).background(Theme.canvas))
                let pickerWindow = NSWindow(contentRect: NSRect(origin: .zero, size: PhonePicker.size), styleMask: [.titled],
                                            backing: .buffered, defer: false)
                pickerWindow.contentView = NSHostingView(rootView: PhonePicker(model: model, sample: crowd, showingOthers: true) {}
                    .background(Theme.canvas))
                snapshot(window, steps: steps, to: folder) { [weak self] in
                    self?.snapshot(menuWindow, steps: [("menu", {})], to: folder) {
                        self?.snapshot(pickerWindow, steps: [("picker", {})], to: folder) {
                            self?.snapshot(controlsWindow, steps: [("controls", {})], to: folder) {
                                self?.snapshotAbout(to: folder)
                            }
                        }
                    }
                }
            }
            return
        }
        // First launch: the setup guide. Later, if something needs attention: the window.
        if model.settings.needsSetup {
            showSetup()
            return
        }
        switch model.status {
        case .needsAccessibility, .choosePhone, .bluetoothDenied: showWindow(page: .phone)
        default: break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        automation?.stop()
        model.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Opens MacHop's window (on `page` when given). While it is open MacHop shows in the Dock.
    func showWindow(page: Navigation.Page? = nil) {
        // Opening the window while the phone has input would strand the pointer on the phone.
        model.returnToMac()
        if let page {
            navigation.page = page
            navigation.showingSetup = false
        }
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showSetup() {
        navigation.showingSetup = true
        showWindow()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // Back to a menu-bar-only app once the window is closed.
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    /// Renders the window after each step to `<name>.png` (dry runs only), off screen, then quits.
    private func snapshot(_ window: NSWindow, steps: [(String, () -> Void)], to folder: URL,
                          then finish: (() -> Void)? = nil) {
        guard let (name, apply) = steps.first else {
            if let finish { finish() } else { NSApp.terminate(nil) }
            return
        }
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let view = window.contentView else { return }
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.orderFrontRegardless()
                view.layoutSubtreeIfNeeded()
                view.display()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
                }
                self.snapshot(window, steps: Array(steps.dropFirst()), to: folder, then: finish)
            }
        }
    }

    /// The standard About panel with two short lines of credits and no copyright line. The
    /// licence and acknowledgements ship in the app (LICENSE, THIRD-PARTY-NOTICES.md) and on GitHub.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let credits = NSMutableAttributedString()
        func add(_ text: String, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred
            ]
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("Made by ")
        add("Ben Wheeler", link: URL(string: "https://1benwheeler.com/"))
        add("\n\nOpen source on ")
        add("GitHub", link: URL(string: "https://github.com/1benwheeler/MacHop"))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): ""])
    }

    /// Dry runs: renders the About panel to `about.png`, off screen, then quits.
    private func snapshotAbout(to folder: URL) {
        let ours = Set(NSApp.windows.map(ObjectIdentifier.init))
        showAbout()
        let panel = NSApp.windows.first { !ours.contains(ObjectIdentifier($0)) && $0.isVisible }
        panel?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                if let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("about.png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "MacHop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: MainView(model: model, navigation: navigation) { [weak self] in
            self?.showAbout()
        })
        window.contentMinSize = NSSize(width: 860, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Dry runs render at the default size and leave the saved window frame alone.
        if !model.dryRun { window.setFrameAutosaveName("MacHopMain") }
        window.center()
        return window
    }

    @objc private func showAboutFromMenu() { showAbout() }

    /// Standard Edit and window commands so text fields and ⌘W/⌘Q work in Settings.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacHop", action: #selector(showAboutFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacHop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
