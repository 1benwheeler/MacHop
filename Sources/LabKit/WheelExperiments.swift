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

    /// With `fling` false it holds still before letting go, so the list stops where it is.
    func drag(from start: (Double, Double), to end: (Double, Double), steps: Int = 12, fling: Bool = true) throws {
        try app.send(["cmd": "hid.pointer", "x": start.0, "y": start.1])
        rest(0.3)
        try app.send(["cmd": "hid.pointer", "x": start.0, "y": start.1, "buttons": 1])
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try app.send(["cmd": "hid.pointer", "x": start.0 + (end.0 - start.0) * t, "y": start.1 + (end.1 - start.1) * t, "buttons": 1])
            rest(0.016)
        }
        if !fling { rest(0.25) }
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

/// How smoothly content moves under wheel scrolling: every captured frame is kept while
/// it runs, then the movement between consecutive frames is measured. Only the pointer
/// and the wheel (or MacHop's own scrolling) are used; no frames are saved.
extension Lab {
    public struct MotionTrace {
        /// Seconds since the input started, and the content's movement since then (points).
        public var samples: [(time: Double, points: Double)]
        public var summary: String {
            guard let last = samples.last else { return "no frames" }
            let pairs = Array(zip(samples.dropFirst(), samples))
            let steps = pairs.map { abs($0.0.points - $0.1.points) }
            let moving = steps.filter { $0 > 0.5 }
            let first = samples.first { abs($0.points) > 0.5 }?.time
            let lastMove = pairs.last { abs($0.0.points - $0.1.points) > 0.5 }?.0.time
            let span = (lastMove ?? 0) - (first ?? 0)
            let stalls = pairs
                .filter { $0.0.time > (first ?? .infinity) && $0.0.time < (lastMove ?? 0) && abs($0.0.points - $0.1.points) <= 0.5 }.count
            return String(format: "moved %.0f pt over %.2f s in %d frames; per-frame %.1f–%.1f pt; %d still frames mid-scroll",
                          abs(last.points), span, steps.count, moving.min() ?? 0, moving.max() ?? 0, stalls)
        }
    }

    /// Runs `input`, measuring the content's movement frame by frame for `duration`
    /// seconds from its start. Each frame is compared with the one before as it arrives,
    /// so nothing piles up in memory.
    func trace(duration: Double, _ input: @escaping () throws -> Void) throws -> MotionTrace {
        guard let size = screen.pixelSize else { return MotionTrace(samples: []) }
        // Captured pixels per point (iPhone 15 Pro: 3).
        let pixelsPerPoint = Double(size.width) / 393.0
        let start = uptime
        let worker = Thread { try? input() }
        worker.start()
        var previous: Frame?
        var position = 0.0
        var samples: [(time: Double, points: Double)] = []
        var last = start - 0.001
        while uptime - start < duration {
            guard let frame = screen.frame(after: last, timeout: 0.2), frame.time > last else { continue }
            last = frame.time
            if let previous {
                let shift = FrameAnalysis.verticalShift(from: previous, to: frame, maxShift: Int(Double(size.height) * 0.3))
                if shift.moved { position += Double(shift.pixels) / pixelsPerPoint }
            }
            samples.append((frame.time - start, position))
            previous = frame
        }
        return MotionTrace(samples: samples)
    }

    /// Single steps, steady streams and MacHop's own long scroll, on whatever is showing.
    public func wheelMotion() throws -> [(String, MotionTrace)] {
        var results: [(String, MotionTrace)] = []
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
        rest(1)
        results.append(("1 step", try trace(duration: 0.8) {
            try self.app.send(["cmd": "hid.scroll", "wheel": -1])
        }))
        rest(1)
        for (interval, count, direction) in [(0.05, 20, 1), (0.025, 40, -1)] {
            results.append(("\(count) steps every \(Int(interval * 1000)) ms", try trace(duration: Double(count) * interval + 0.8) {
                for _ in 0..<count {
                    try self.app.send(["cmd": "hid.scroll", "wheel": direction])
                    Thread.sleep(forTimeInterval: interval)
                }
            }))
            rest(1)
        }
        // MacHop's own path: a long two-finger scroll with momentum, as the trackpad sends it.
        try app.send(["cmd": "enter"])
        // Well inside the iPhone, so a stray movement can't cross straight back.
        if let edge = LabEdge(status: try app.status()) {
            let deeper = edge.delta(outward: 20)
            for _ in 0..<8 { try app.send(["cmd": "move", "dx": deeper.dx, "dy": deeper.dy]); rest(0.01) }
        }
        rest(0.5)
        results.append(("MacHop two-finger scroll", try trace(duration: 2.5) {
            try self.app.send(["cmd": "scroll", "dy": 0, "phase": "mayBegin"])
            for index in 0..<40 {
                try self.app.send(["cmd": "scroll", "dy": 12, "phase": index == 0 ? "began" : "changed"])
                Thread.sleep(forTimeInterval: 0.016)
            }
            try self.app.send(["cmd": "scroll", "dy": 0, "phase": "ended"])
            var speed = 12.0
            for index in 0..<40 {
                try self.app.send(["cmd": "scroll", "dy": speed, "momentum": index == 0 ? "began" : "changed"])
                speed *= 0.93
                Thread.sleep(forTimeInterval: 0.016)
            }
            try self.app.send(["cmd": "scroll", "dy": 0, "momentum": "ended"])
        }))
        try app.send(["cmd": "return"])
        return results
    }
}

extension Lab {
    /// Records the screen for `seconds` while someone scrolls by hand, and returns the
    /// content's movement in 100 ms slices (points; positive = page moved up).
    public func watchScrolling(seconds: Double) throws -> (trace: MotionTrace, slices: [Double]) {
        let trace = try trace(duration: seconds) {}
        var slices: [Double] = []
        var previous = 0.0
        var edge = 0.1
        for sample in trace.samples {
            while sample.time > edge {
                slices.append(sample.points - previous)
                previous = sample.points
                edge += 0.1
            }
        }
        return (trace, slices)
    }
}

extension Lab {
    /// Several separate scroll gestures with the pointer still, without and then with a
    /// tiny pointer nudge before each. Pointer and wheel only; works on whatever is showing.
    public func wheelNeedsNudge(gestures: Int = 3) throws -> (still: [Double], nudged: [Double]) {
        func gesture(nudge: Bool, direction: Int) throws -> Double {
            if nudge {
                try app.send(["cmd": "hid.pointer", "x": 0.501, "y": 0.55])
                rest(0.03)
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
                rest(0.03)
            }
            let moved = try trace(duration: 1.0) {
                for _ in 0..<6 {
                    try self.app.send(["cmd": "hid.scroll", "wheel": direction])
                    Thread.sleep(forTimeInterval: 0.04)
                }
            }
            rest(0.8)
            return abs(moved.samples.last?.points ?? 0)
        }
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
        rest(1)
        var still: [Double] = [], nudged: [Double] = []
        for index in 0..<gestures { still.append(try gesture(nudge: false, direction: index % 2 == 0 ? 1 : -1)) }
        for index in 0..<gestures { nudged.append(try gesture(nudge: true, direction: index % 2 == 0 ? 1 : -1)) }
        return (still, nudged)
    }
}

extension Lab {
    /// Per-frame movement statistics while content moves (points).
    public struct Smoothness: CustomStringConvertible {
        public var total: Double, perStep: Double?, biggestFrame: Double, typicalFrame: Double, stillShare: Double
        public var description: String {
            String(format: "moved %.0f pt%@; biggest single-frame jump %.0f pt, typical %.0f pt; %.0f%% of frames still while moving",
                   total, perStep.map { String(format: " (%.0f pt per step)", $0) } ?? "", biggestFrame, typicalFrame, stillShare * 100)
        }
    }

    func smoothness(_ trace: MotionTrace, steps: Int?) -> Smoothness {
        let pairs = Array(zip(trace.samples.dropFirst(), trace.samples))
        let deltas = pairs.map { abs($0.0.points - $0.1.points) }
        guard let first = deltas.firstIndex(where: { $0 > 0.5 }), let last = deltas.lastIndex(where: { $0 > 0.5 }) else {
            return Smoothness(total: 0, perStep: nil, biggestFrame: 0, typicalFrame: 0, stillShare: 0)
        }
        let window = Array(deltas[first...last])
        let moving = window.filter { $0 > 0.5 }.sorted()
        let total = abs(trace.samples.last?.points ?? 0)
        return Smoothness(total: total, perStep: steps.map { total / Double($0) }, biggestFrame: moving.last ?? 0,
                          typicalFrame: moving[moving.count / 2], stillShare: Double(window.count - moving.count) / Double(window.count))
    }

    /// Wheel steps and keyboard keys, each measured for smoothness, on the current profile.
    /// Pointer, wheel and navigation keys only (Settings must be showing).
    public func scrollOptions(profile: String) throws -> [(String, Smoothness)] {
        try requireExpectedScreen()
        try switchProfile(profile)
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.55])
        rest(1)
        var results: [(String, Smoothness)] = []
        let wheel = try trace(duration: 1.6) {
            for _ in 0..<12 { try self.app.send(["cmd": "hid.scroll", "wheel": -1]); Thread.sleep(forTimeInterval: 0.05) }
        }
        results.append(("\(profile) wheel, 12 steps", smoothness(wheel, steps: 12)))
        rest(1)
        let back = try trace(duration: 1.6) {
            for _ in 0..<12 { try self.app.send(["cmd": "hid.scroll", "wheel": 1]); Thread.sleep(forTimeInterval: 0.05) }
        }
        results.append(("\(profile) wheel back, 12 steps", smoothness(back, steps: 12)))
        return results
    }

    /// Keyboard scrolling in Settings: the down arrow held, Page Down, then back up.
    public func keyboardScrolling() throws -> [(String, Smoothness)] {
        try requireExpectedScreen()
        var results: [(String, Smoothness)] = []
        func press(_ usage: Int, hold: Double) throws {
            try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [usage]])
            Thread.sleep(forTimeInterval: hold)
            try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
        }
        results.append(("down arrow held 1 s", smoothness(try trace(duration: 2) { try press(0x51, hold: 1.0) }, steps: nil)))
        rest(1)
        results.append(("up arrow held 1 s", smoothness(try trace(duration: 2) { try press(0x52, hold: 1.0) }, steps: nil)))
        rest(1)
        results.append(("Page Down", smoothness(try trace(duration: 1.5) { try press(0x4E, hold: 0.08) }, steps: nil)))
        rest(1)
        results.append(("Page Up", smoothness(try trace(duration: 1.5) { try press(0x4B, hold: 0.08) }, steps: nil)))
        return results
    }
}

extension Lab {
    /// Short chained drags, the pointer hopping back to the start after each: how smoothly
    /// does the content move? Settings only (each press lands on a list row, briefly).
    public func chainedDrags(strokes: Int = 10, distance: Double = 0.03, glide: Bool) throws -> Smoothness {
        try requireExpectedScreen()
        let x = 0.5, start = 0.62
        try app.send(["cmd": "hid.pointer", "x": x, "y": start])
        rest(0.8)
        let trace = try trace(duration: Double(strokes) * 0.16 + 1.5) {
            for _ in 0..<strokes {
                try self.app.send(["cmd": "hid.pointer", "x": x, "y": start, "buttons": 1])
                for step in 1...6 {
                    try self.app.send(["cmd": "hid.pointer", "x": x, "y": start - distance * Double(step) / 6, "buttons": 1])
                    Thread.sleep(forTimeInterval: 0.016)
                }
                // Without glide, rest before letting go so iOS adds no momentum.
                if !glide { Thread.sleep(forTimeInterval: 0.06) }
                try self.app.send(["cmd": "hid.pointer", "x": x, "y": start - distance, "buttons": 0])
                try self.app.send(["cmd": "hid.pointer", "x": x, "y": start])
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return smoothness(trace, steps: nil)
    }
}

extension Lab {
    /// Clicks the Settings row labelled `label`, dragging the list to reveal it if needed:
    /// first towards the end, then back towards the top.
    func openRow(_ label: String, contains: Bool = false) throws {
        for attempt in 0..<16 {
            let match = screen.textBoxes().first { box in
                let text = box.text.trimmingCharacters(in: .whitespaces)
                return contains ? text.contains(label) : text == label
            }
            if let match, match.box.midY > 0.12, match.box.midY < 0.9 {
                try click(atX: 0.5, y: match.box.midY)
                rest(1.5)
                return
            }
            try dragList(down: attempt < 5)
            rest(0.8)
        }
        throw AutomationClient.ClientError.failed("Couldn't find \(label) in Settings; stopped.")
    }

    /// Settings → Accessibility → Touch → AssistiveTouch → Devices → this Mac → Customise
    /// Additional Buttons, then presses spare button `number` so iOS lists the actions it
    /// can have, reads them, and cancels without choosing. Settings only.
    public func assistiveTouchActions(macName: String, button number: Int = 7) throws -> [String] {
        try requireExpectedScreen()
        for row in ["Accessibility", "Touch", "AssistiveTouch", "Devices"] { try openRow(row) }
        try openRow(macName, contains: true)
        try openRow("Customise Additional Buttons", contains: true)
        rest(1)
        // iOS asks for a button press; press the spare button once.
        let bit = 1 << (number - 1)
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.5, "buttons": bit])
        rest(0.1)
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.5, "buttons": 0])
        rest(2)
        var seen: [String] = []
        for _ in 0..<6 {
            for text in screen.recognizedText() where !seen.contains(text) { seen.append(text) }
            try dragList(down: true)
            rest(0.8)
        }
        if let cancel = find("Cancel") { try click(atX: cancel.x, y: cancel.y) }
        return seen
    }
}

extension Lab {
    public func tapRow(atY y: Double) throws { try click(atX: 0.5, y: y) }
    public func dragList(down: Bool) throws {
        try drag(from: (0.5, down ? 0.82 : 0.2), to: (0.5, down ? 0.2 : 0.82), steps: 30, fling: false)
    }
}

extension Lab {
    /// A long two-finger scroll through MacHop (as the trackpad sends it), on the Settings
    /// list: how the content moves, where the pointer ends up, and that nothing was tapped.
    public func sessionLongScroll(events: Int = 80, points: Double = 15, upwards: Bool = false) throws
        -> (smoothness: Smoothness, pointerBefore: (Double, Double)?, pointerAfter: (Double, Double)?, stillSettings: Bool) {
        try requireExpectedScreen()
        try app.send(["cmd": "enter"])
        if let edge = LabEdge(status: try app.status()) {
            let deeper = edge.delta(outward: 20)
            for _ in 0..<8 { try app.send(["cmd": "move", "dx": deeper.dx, "dy": deeper.dy]); rest(0.01) }
        }
        rest(0.5)
        func pointer() throws -> (Double, Double)? {
            guard let p = try app.status()["phonePointer"] as? [String: Any], let x = p["x"] as? Double, let y = p["y"] as? Double else { return nil }
            return (x, y)
        }
        let before = try pointer()
        let dy = upwards ? points : -points
        let trace = try trace(duration: Double(events) * 0.016 + 2.0) {
            try self.app.send(["cmd": "scroll", "dy": 0, "phase": "mayBegin"])
            for index in 0..<events {
                try self.app.send(["cmd": "scroll", "dy": dy, "phase": index == 0 ? "began" : "changed"])
                Thread.sleep(forTimeInterval: 0.016)
            }
            try self.app.send(["cmd": "scroll", "dy": 0, "phase": "ended"])
        }
        let after = try pointer()
        try app.send(["cmd": "return"])
        rest(1)
        let still = screen.recognizedText().contains { $0.trimmingCharacters(in: .whitespaces) == "Settings" }
        return (smoothness(trace, steps: nil), before, after, still)
    }
}
