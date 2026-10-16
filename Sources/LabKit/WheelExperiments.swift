// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// What stops the iPhone acting on wheel reports. Each trial starts from a fresh
/// connection (which brings the wheel back), checks the wheel, does one thing, and
/// checks the wheel again. Everything happens in Settings, except the app switch,
/// which goes to Calculator through Spotlight and back, checking the screen first.
extension Lab {
    public enum WheelTrigger: String, CaseIterable {
        case navigateInSettings, spotlight, switchApp, goHome, wheelOverToolbar, wheelPastEnd, otherApp, whatsApp, homeSwipe, homeSwipeHigher, controlCentreSwipe
    }

    private func rest(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    private var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// Wheel trials that moved the list, out of `trials`.
    func wheelScrolls(trials: Int = 3) throws -> Int {
        try scrollTest(ScrollConfig(profile: "compatibility"), trials: trials).successes
    }

    /// The link drops and comes back, as when the Mac sleeps and wakes. A jammed wheel
    /// sometimes needs iOS to forget the device, which takes longer than a few seconds.
    func freshConnection() throws {
        try app.send(["cmd": "sleep"])
        rest(20)
        try app.send(["cmd": "wake"])
        guard app.waitUntilReady(timeout: 30) else {
            throw AutomationClient.ClientError.failed("The iPhone didn't reconnect within 30 s.")
        }
        rest(3)
    }

    func click(atX x: Double, y: Double) throws {
        try app.send(["cmd": "hid.pointer", "x": x, "y": y])
        rest(0.3)
        try app.send(["cmd": "hid.pointer", "x": x, "y": y, "buttons": 1])
        rest(0.08)
        try app.send(["cmd": "hid.pointer", "x": x, "y": y, "buttons": 0])
    }

    /// Spotlight: the Consumer AC Search key (⌘Space doesn't open it on this iPhone).
    func openSpotlight() throws {
        try app.send(["cmd": "hid.consumer", "usage": 0x0221])
        rest(0.1)
        try app.send(["cmd": "hid.consumer", "usage": 0])
    }

    func drag(from start: (Double, Double), to end: (Double, Double), steps: Int = 12) throws {
        try app.send(["cmd": "hid.pointer", "x": start.0, "y": start.1])
        rest(0.3)
        try app.send(["cmd": "hid.pointer", "x": start.0, "y": start.1, "buttons": 1])
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try app.send(["cmd": "hid.pointer", "x": start.0 + (end.0 - start.0) * t, "y": start.1 + (end.1 - start.1) * t, "buttons": 1])
            rest(0.016)
        }
        try app.send(["cmd": "hid.pointer", "x": end.0, "y": end.1, "buttons": 0])
    }

    func key(_ usage: Int, modifiers: Int = 0) throws {
        try app.send(["cmd": "hid.keyboard", "modifiers": modifiers, "keys": [usage]])
        rest(0.08)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
    }

    /// Where `text` appears on screen (exact match), as the centre of its box.
    func find(_ text: String) -> (x: Double, y: Double)? {
        screen.textBoxes().first { $0.text.trimmingCharacters(in: .whitespaces) == text }.map { ($0.box.midX, $0.box.midY) }
    }

    func showing(_ text: String, within seconds: Double = 3) -> Bool {
        let deadline = uptime + seconds
        repeat {
            if screen.recognizedText().contains(where: { $0.trimmingCharacters(in: .whitespaces) == text }) { return true }
            rest(0.3)
        } while uptime < deadline
        return false
    }

    /// Taps the Home Screen icon labelled `label` (just above its label). False if not on screen.
    public func tapIcon(_ label: String) throws -> Bool {
        guard let spot = find(label) else { return false }
        try click(atX: spot.x, y: spot.y - 0.035)
        return true
    }

    /// Wheel scrolls that moved whatever is on screen, out of `trials`. Only the pointer
    /// and the wheel are used: nothing is clicked, so it's safe in any app.
    func wheelMovesScreen(trials: Int = 3) throws -> Int {
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
        rest(0.4)
        var moved = 0
        for trial in 0..<trials {
            guard let before = settledFrame(after: 0.3) else { continue }
            for _ in 0..<6 { try app.send(["cmd": "hid.scroll", "wheel": trial % 2 == 0 ? -1 : 1]); rest(0.03) }
            guard let after = settledFrame(after: 0.8) else { continue }
            if FrameAnalysis.verticalShift(from: before, to: after).moved { moved += 1 }
        }
        return moved
    }

    /// Home through the AssistiveTouch menu (its button sits at the right edge on Ben's iPhone).
    func goHomeWithMenu() throws {
        try click(atX: 0.90, y: 0.21)
        rest(1.0)
        guard let home = find("Home") else {
            try key(0x29)
            throw AutomationClient.ClientError.failed("The AssistiveTouch menu didn't show Home; stopped.")
        }
        try click(atX: home.x, y: home.y)
        rest(1.5)
    }

    /// From anywhere: Home, then Spotlight from the Home Screen, then taps the app's result.
    func openApp(_ name: String, marker: String) throws {
        try goHomeWithMenu()
        try openSpotlight()
        rest(1.5)
        try app.send(["cmd": "hid.type", "text": name])
        rest(2)
        guard try tapIcon(name) else {
            throw AutomationClient.ClientError.failed("Spotlight didn't show \(name); stopped. Please reopen Settings.")
        }
        rest(3)
        guard showing(marker, within: 5) else {
            throw AutomationClient.ClientError.failed("\(name) didn't open as expected; stopped. Please reopen Settings.")
        }
    }

    /// Opens an app from the Home Screen's Spotlight without checking its screen afterwards
    /// (for apps whose content the lab must not read).
    func openAppBlind(_ name: String) throws {
        try goHomeWithMenu()
        try openSpotlight()
        rest(1.5)
        try app.send(["cmd": "hid.type", "text": name])
        rest(2)
        guard try tapIcon(name) else {
            throw AutomationClient.ClientError.failed("Spotlight didn't show \(name); stopped. Please reopen Settings.")
        }
        rest(3)
    }

    /// Back to Settings from any app, through the AssistiveTouch menu and Spotlight.
    public func backToSettings() throws {
        try openApp("Settings", marker: "Settings")
        try requireExpectedScreen()
    }

    /// Opens Spotlight, types `query`, and opens the top hit only if Spotlight is showing it.
    func openWithSpotlight(_ query: String, expecting marker: String) throws {
        try openSpotlight()
        rest(1.2)
        try app.send(["cmd": "hid.type", "text": query])
        guard showing(query, within: 3) else {
            try key(0x29)                 // Escape
            throw AutomationClient.ClientError.failed("Spotlight didn't show \(query); stopped before opening anything.")
        }
        try key(0x28)                     // Return
        guard showing(marker, within: 5) else {
            throw AutomationClient.ClientError.failed("\(query) didn't open as expected; stopped.")
        }
    }

    /// Runs one trigger trial; returns the wheel's successes before and after (out of 3 each).
    public func wheelTrial(_ trigger: WheelTrigger, saveTo folder: URL? = nil) throws -> (before: Int, after: Int) {
        try requireExpectedScreen()
        try freshConnection()
        let before = try wheelScrolls()
        func save(_ name: String) { if let folder { try? screen.savePNG(to: folder.appendingPathComponent("\(trigger.rawValue)-\(name).png")) } }
        switch trigger {
        case .navigateInSettings:
            try requireExpectedScreen()
            // A row that opens a page without changing anything (never one with a switch).
            guard let row = ["General", "Bluetooth", "Wi-Fi", "Battery"].lazy.compactMap({ self.find($0) }).first else {
                throw AutomationClient.ClientError.failed("Couldn't find General, Bluetooth, Wi-Fi or Battery in Settings.")
            }
            try click(atX: 0.5, y: row.y)
            rest(1.5)
            save("general")
            // Back: the top-left back button, then confirm Settings is showing again.
            try click(atX: 0.09, y: 0.075)
            rest(1.5)
            save("back")
            guard showing("Settings") else {
                throw AutomationClient.ClientError.failed("Couldn't get back to the main Settings screen; please tap Back.")
            }
        case .spotlight:
            try openSpotlight()
            rest(1.2)
            guard !showing("Settings", within: 0.5) else {
                throw AutomationClient.ClientError.failed("Spotlight didn't open.")
            }
            try key(0x29)
            rest(1.2)
        case .wheelOverToolbar:
            // Wheel with the pointer over the bottom search bar, where nothing scrolls.
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.94])
            rest(0.4)
            for _ in 0..<18 { try app.send(["cmd": "hid.scroll", "wheel": 1]); rest(0.03) }
            rest(1)
        case .wheelPastEnd:
            // Far more wheel than the list has, so it hits the top and keeps pushing.
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.5])
            rest(0.4)
            for _ in 0..<60 { try app.send(["cmd": "hid.scroll", "wheel": 1]); rest(0.03) }
            rest(1.5)
        case .homeSwipe:
            // Home the way a finger does it: press at the bottom edge and drag up.
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.995])
            rest(0.3)
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.995, "buttons": 1])
            for step in 1...12 {
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.995 - 0.45 * Double(step) / 12, "buttons": 1])
                rest(0.016)
            }
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.545, "buttons": 0])
            rest(1.5)
            guard !showing("Apple Account, iCloud+ and more", within: 0.5) else {
                throw AutomationClient.ClientError.failed("The swipe didn't go Home; stopped.")
            }
            try openSpotlight()
            rest(1.5)
            try app.send(["cmd": "hid.type", "text": "Settings"])
            rest(2)
            guard try tapIcon("Settings") else {
                throw AutomationClient.ClientError.failed("Spotlight didn't show Settings; please reopen Settings.")
            }
            rest(2)
        case .homeSwipeHigher:
            // The same swipe, starting above the home indicator (5% up from the bottom).
            try drag(from: (0.5, 0.95), to: (0.5, 0.5))
            rest(1.5)
            try backToSettings()
        case .controlCentreSwipe:
            // Control Centre: down from the top-right corner, then Escape.
            try drag(from: (0.92, 0.005), to: (0.92, 0.5))
            rest(1.5)
            guard showing("Stopwatch", within: 1) || showing("Focus", within: 1) else {
                throw AutomationClient.ClientError.failed("Control Centre didn't open; stopped.")
            }
            try key(0x29)   // Escape closes it (neither Home nor a tap outside does)
            rest(1.5)
        case .whatsApp:
            // Only the wheel inside WhatsApp: no clicks, no typing, no screenshots.
            try openAppBlind("WhatsApp")
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
            rest(0.4)
            for trial in 0..<3 {
                for _ in 0..<6 { try app.send(["cmd": "hid.scroll", "wheel": trial % 2 == 0 ? -1 : 1]); rest(0.03) }
                rest(0.8)
            }
            try backToSettings()
            rest(1)
        case .otherApp:
            try openApp("App Store", marker: "Games")
            let there = try wheelMovesScreen()
            log("  wheel in the App Store: \(there)/3 moved")
            try openApp("Settings", marker: "Apple Account, iCloud+ and more")
        case .goHome:
            // Home through the AssistiveTouch menu (its button sits at the right edge on
            // Ben's iPhone), then back to Settings through Spotlight from the Home Screen.
            try click(atX: 0.90, y: 0.21)
            rest(1.0)
            guard let home = find("Home") else {
                try key(0x29)
                throw AutomationClient.ClientError.failed("The AssistiveTouch menu didn't show Home; stopped.")
            }
            try click(atX: home.x, y: home.y)
            rest(1.5)
            guard !showing("Apple Account, iCloud+ and more", within: 0.5) else {
                throw AutomationClient.ClientError.failed("Still in Settings after choosing Home; stopped.")
            }
            // Spotlight opens from the Home Screen (not from inside Settings); Return doesn't
            // launch the hit, so the Settings result is tapped.
            try openSpotlight()
            rest(1.5)
            try app.send(["cmd": "hid.type", "text": "Settings"])
            rest(2)
            guard try tapIcon("Settings") else {
                throw AutomationClient.ClientError.failed("Spotlight didn't show Settings; please reopen Settings.")
            }
            rest(2)
        case .switchApp:
            try openWithSpotlight("Calculator", expecting: "AC")
            save("calculator")
            rest(1)
            try openWithSpotlight("Settings", expecting: "Settings")
            rest(1.5)
        }
        try requireExpectedScreen()
        let after = try wheelScrolls()
        return (before, after)
    }
}
