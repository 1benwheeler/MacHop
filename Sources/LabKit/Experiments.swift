// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Physical-device experiments: MacHop drives the real iPhone over Bluetooth and
/// the lab observes the phone's screen over USB. Nothing here is a simulation.
public final class Lab {
    public let app: AutomationClient
    public let screen: PhoneScreen
    public var log: (String) -> Void = { print($0) }

    public init(app: AutomationClient, screen: PhoneScreen) {
        self.app = app
        self.screen = screen
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    public enum SafetyError: Error, CustomStringConvertible {
        case wrongScreen(expected: String)
        public var description: String {
            switch self {
            case .wrongScreen(let expected):
                "Stopped: the iPhone is not showing \(expected). Open it on the phone and run again " +
                "(the lab never sends input to other apps, e.g. messaging)."
            }
        }
    }

    /// The text a screen must show for experiments to touch it (OCR of the phone).
    public var requiredScreenText = "Settings"

    /// Refuses to continue unless the phone shows the expected app.
    public func requireExpectedScreen(_ expected: String? = nil) throws {
        let required = expected ?? requiredScreenText
        let text = screen.recognizedText()
        guard text.contains(where: { $0.trimmingCharacters(in: .whitespaces) == required }) else {
            throw SafetyError.wrongScreen(expected: required)
        }
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A frame captured after the screen has had time to settle.
    func settledFrame(after delay: Double = 0.5) -> Frame? {
        pause(delay)
        return screen.frame(after: now - 0.02)
    }

    // MARK: Pointer

    public struct PointerResult {
        public var visible: Bool
        public var samples: [(expected: (Double, Double), found: (Double, Double)?)]
        public var meanError: Double? {
            let errors = samples.compactMap { sample in
                sample.found.map { hypot($0.0 - sample.expected.0, $0.1 - sample.expected.1) }
            }
            return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
        }
    }

    /// Moves the absolute pointer around a grid and finds it in the captured screen.
    /// Coordinates in the result are fractions of the screen.
    public func pointerTest(columns: Int = 3, rows: Int = 5) throws -> PointerResult {
        try requireExpectedScreen()
        guard let size = screen.pixelSize else { throw PhoneScreen.CaptureError.noDevice }
        var result = PointerResult(visible: false, samples: [])
        for row in 0..<rows {
            for column in 0..<columns {
                let x = (Double(column) + 0.5) / Double(columns), y = (Double(row) + 0.5) / Double(rows)
                // Park the pointer far away for a reference frame, then bring it to the target.
                try app.send(["cmd": "hid.pointer", "x": x < 0.5 ? 0.95 : 0.05, "y": y < 0.5 ? 0.95 : 0.05])
                guard let before = settledFrame(after: 0.4) else { continue }
                try app.send(["cmd": "hid.pointer", "x": x, "y": y])
                guard let after = settledFrame(after: 0.4) else { continue }
                let expected = (x * Double(size.width), y * Double(size.height))
                let near = FrameAnalysis.changedRegions(before, after).first { blob in
                    hypot(blob.centreX - expected.0, blob.centreY - expected.1) < Double(size.width) * 0.15
                }
                if near != nil { result.visible = true }
                result.samples.append(((x, y), near.map { ($0.centreX / Double(size.width), $0.centreY / Double(size.height)) }))
                log(String(format: "  pointer → (%.2f, %.2f): %@", x, y,
                           near.map { String(format: "seen at (%.3f, %.3f)", $0.centreX / Double(size.width),
                                             $0.centreY / Double(size.height)) } ?? "not seen"))
            }
        }
        return result
    }

    // MARK: Scrolling

    public struct ScrollConfig: CustomStringConvertible {
        public var profile: String
        /// Wheel value per report and number of reports per trial.
        public var stepSize: Int
        public var steps: Int
        /// Seconds between reports.
        public var interval: Double
        /// Re-send the pointer position just before scrolling.
        public var nudge: Bool
        /// Where the pointer sits while scrolling (fraction of screen height).
        public var pointerY = 0.5
        /// Scroll by pressing and dragging instead of with the wheel (reference method).
        public var drag = false
        /// When set, the first trial's before/after screens are saved here.
        public var saveDirectory: String?
        /// Scroll through MacHop's input session with trackpad phases (the path real
        /// two-finger scrolling takes), instead of raw HID reports.
        public var throughSession = false

        public init(profile: String, stepSize: Int = 1, steps: Int = 6, interval: Double = 0.03, nudge: Bool = false) {
            self.profile = profile
            self.stepSize = stepSize
            self.steps = steps
            self.interval = interval
            self.nudge = nudge
        }

        public var description: String {
            "\(profile): \(steps)×\(stepSize) every \(Int(interval * 1000)) ms\(nudge ? ", nudge" : "")"
        }
    }

    public struct ScrollTrial {
        public var direction: Int
        public var shift: FrameAnalysis.Shift
    }

    public struct ScrollSummary {
        public var config: ScrollConfig
        public var trials: [ScrollTrial]
        public var successes: Int { trials.filter { $0.shift.moved }.count }
        /// Content movement in screen pixels per wheel unit, signed by wheel direction.
        public var pixelsPerUnit: Double? {
            let moved = trials.filter(\.shift.moved)
            guard !moved.isEmpty else { return nil }
            let units = Double(config.steps * config.stepSize)
            return moved.map { Double($0.shift.pixels) / units * Double($0.direction) }.reduce(0, +) / Double(moved.count)
        }
        public var firstFailure: Int? { trials.firstIndex { !$0.shift.moved } }
    }

    /// Requires a long scrollable list on screen (Settings' main list works well).
    public func scrollTest(_ config: ScrollConfig, trials: Int) throws -> ScrollSummary {
        try requireExpectedScreen()
        try switchProfile(config.profile)
        if config.throughSession { try placeSessionPointer(y: config.pointerY) }
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": config.pointerY])
        pause(0.4)
        var summary = ScrollSummary(config: config, trials: [])
        for trial in 0..<trials {
            if trial > 0 && trial % 4 == 0 { try requireExpectedScreen() }
            // Alternate direction so the list stays within range.
            let direction = trial % 2 == 0 ? -1 : 1
            guard let before = settledFrame(after: 0.2) else { continue }
            if config.nudge {
                // A real (tiny) movement, not just re-sending the same position.
                try app.send(["cmd": "hid.pointer", "x": 0.51, "y": config.pointerY])
                pause(0.03)
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": config.pointerY])
                pause(0.03)
            }
            if trial == 0, let directory = config.saveDirectory {
                try? screen.savePNG(to: URL(fileURLWithPath: "\(directory)/before.png"))
            }
            if config.throughSession {
                // A two-finger trackpad scroll as macOS reports it: fingers down,
                // began, changed…, ended. Fingers up (negative) scrolls content up.
                let points = Double(direction) * Double(config.steps * config.stepSize) * 10
                try app.send(["cmd": "scroll", "dy": 0, "phase": "mayBegin"])
                for index in 0..<10 {
                    try app.send(["cmd": "scroll", "dy": points / 10, "phase": index == 0 ? "began" : "changed"])
                    pause(0.016)
                }
                try app.send(["cmd": "scroll", "dy": 0, "phase": "ended"])
            } else if config.drag {
                // Press, drag 15% of the screen, release: what a finger swipe does.
                let start = config.pointerY, end = config.pointerY + 0.15 * Double(direction)
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": start, "buttons": 1])
                for step in 1...10 {
                    try app.send(["cmd": "hid.pointer", "x": 0.5, "y": start + (end - start) * Double(step) / 10, "buttons": 1])
                    pause(0.016)
                }
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": end, "buttons": 0])
                pause(0.2)
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": start, "buttons": 0])
            } else {
                for _ in 0..<config.steps {
                    try app.send(["cmd": "hid.scroll", "wheel": direction * config.stepSize])
                    pause(config.interval)
                }
            }
            // Drag scrolling hands iOS a flick; wait for its momentum to finish.
            guard let after = settledFrame(after: config.throughSession ? 2.5 : 0.7) else { continue }
            if trial == 0, let directory = config.saveDirectory {
                try? screen.savePNG(to: URL(fileURLWithPath: "\(directory)/after.png"))
            }
            let shift = FrameAnalysis.verticalShift(from: before, to: after)
            summary.trials.append(ScrollTrial(direction: direction, shift: shift))
            if !shift.moved, let directory = config.saveDirectory {
                // Keep evidence of every miss: the "after" screen, and the before frame as analysed.
                try? screen.savePNG(to: URL(fileURLWithPath: "\(directory)/miss\(trial + 1)-after.png"))
                try? FrameAnalysis.png(before).write(to: URL(fileURLWithPath: "\(directory)/miss\(trial + 1)-before.png"))
            }
            log("  trial \(trial + 1) wheel \(direction > 0 ? "+" : "-"): \(shift)")
        }
        return summary
    }

    /// Scrolling with no capture running during the action.
    ///
    /// While the iPhone's screen is being captured, iOS shows a modal "Are you
    /// connecting headphones?" alert that blocks scroll and drag input. So the
    /// screen is photographed before and after, with capture stopped in between,
    /// and the band where the alert sits (36–66% of the height) is ignored.
    public func blindScrollTest(_ config: ScrollConfig, trials: Int) throws -> ScrollSummary {
        try requireExpectedScreen()
        try switchProfile(config.profile)
        var summary = ScrollSummary(config: config, trials: [])
        for trial in 0..<trials {
            let direction = trial % 2 == 0 ? -1 : 1
            guard let before = photo(save: trial == 0 ? config.saveDirectory.map { "\($0)/before.png" } : nil) else { continue }
            pause(1.5)   // capture stopped: the alert goes away
            try app.send(["cmd": "hid.pointer", "x": 0.5, "y": config.pointerY])
            pause(0.3)
            if config.drag {
                let start = config.pointerY, end = config.pointerY + 0.12 * Double(direction)
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": start, "buttons": 1])
                for step in 1...10 {
                    try app.send(["cmd": "hid.pointer", "x": 0.5, "y": start + (end - start) * Double(step) / 10, "buttons": 1])
                    pause(0.016)
                }
                try app.send(["cmd": "hid.pointer", "x": 0.5, "y": end, "buttons": 0])
            } else {
                for _ in 0..<config.steps {
                    try app.send(["cmd": "hid.scroll", "wheel": direction * config.stepSize])
                    pause(config.interval)
                }
            }
            pause(1.0)
            guard let after = photo(save: trial == 0 ? config.saveDirectory.map { "\($0)/after.png" } : nil) else { continue }
            let shift = FrameAnalysis.verticalShift(from: before, to: after, excludeTop: 0.12, excludeBottom: 0.1,
                                                    ignoring: 0.36...0.66)
            summary.trials.append(ScrollTrial(direction: direction, shift: shift))
            log("  trial \(trial + 1) \(config.drag ? "drag" : "wheel") \(direction > 0 ? "+" : "-"): \(shift)")
        }
        return summary
    }

    /// Starts capture briefly, takes one settled frame, stops capture.
    func photo(save path: String?) -> Frame? {
        do { try screen.start() } catch { return nil }
        defer { screen.stop() }
        pause(0.6)
        if let path { try? screen.savePNG(to: URL(fileURLWithPath: path)) }
        return screen.frame()
    }

    /// Experimental touch layouts: does the iPhone subscribe to the touch surface,
    /// and does moving contacts on it scroll the content?
    public func touchTest(profile: String, trials: Int) throws -> (subscribed: Bool, summary: ScrollSummary) {
        try requireExpectedScreen()
        try switchProfile(profile)
        pause(2)
        let subscriptions = (try app.status()["subscriptions"] as? [Int]) ?? []
        let subscribed = subscriptions.contains(Int(5))
        log("  iPhone subscribed to: \(subscriptions) — touch surface \(subscribed ? "ACCEPTED" : "not subscribed")")
        let config = ScrollConfig(profile: profile)
        var summary = ScrollSummary(config: config, trials: [])
        guard subscribed else { return (false, summary) }
        let fingers = profile == "touchpad" ? [(0, 0.42), (1, 0.58)] : [(0, 0.5)]
        func send(_ y: Double, down: Bool) throws {
            let contacts = fingers.map { ["id": $0.0, "x": $0.1, "y": y, "down": down] as [String: Any] }
            try app.send(["cmd": "hid.touch", "contacts": contacts])
        }
        for trial in 0..<trials {
            if trial > 0 && trial % 4 == 0 { try requireExpectedScreen() }
            let direction = trial % 2 == 0 ? -1.0 : 1.0
            guard let before = settledFrame(after: 0.3) else { continue }
            let start = 0.55, end = 0.55 + 0.2 * direction
            for step in 0...12 {
                try send(start + (end - start) * Double(step) / 12, down: true)
                pause(0.016)
            }
            try send(end, down: false)
            guard let after = settledFrame(after: 2.0) else { continue }
            let shift = FrameAnalysis.verticalShift(from: before, to: after)
            summary.trials.append(ScrollTrial(direction: Int(direction), shift: shift))
            log("  trial \(trial + 1): \(shift)")
        }
        return (true, summary)
    }

    /// Searches for what makes iOS accept wheel scrolling again after it stops.
    ///
    /// Scrolls with the wheel; whenever a scroll fails, applies the next candidate
    /// recovery action and scrolls again, recording whether that recovered it.
    public func unstickSearch(profile: String, rounds: Int) throws -> [(action: String, recovered: Bool)] {
        try requireExpectedScreen()
        try switchProfile(profile)
        let y = 0.55
        func pointer(_ x: Double, _ yy: Double) throws { try app.send(["cmd": "hid.pointer", "x": x, "y": yy]) }
        let candidates: [(String, () throws -> Void)] = [
            ("wait 3 s", { self.pause(3) }),
            ("pointer wiggle", {
                for dx in [0.02, -0.02, 0.0] { try pointer(0.5 + dx, y); self.pause(0.03) }
            }),
            ("pointer away and back", {
                for step in 0...10 { try pointer(0.5, y - 0.3 * Double(step) / 10); self.pause(0.016) }
                for step in 0...10 { try pointer(0.5, y - 0.3 + 0.3 * Double(step) / 10); self.pause(0.016) }
            }),
            ("Shift key tap", {
                try self.app.send(["cmd": "hid.keyboard", "modifiers": 2, "keys": []])
                self.pause(0.05)
                try self.app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": []])
            }),
            ("tiny opposite wheel", {
                try self.app.send(["cmd": "hid.scroll", "wheel": 1]); self.pause(0.05)
                try self.app.send(["cmd": "hid.scroll", "wheel": -1])
            })
        ]
        func trial(_ direction: Int) throws -> Bool {
            guard let before = settledFrame(after: 0.3) else { return false }
            for _ in 0..<8 {
                try app.send(["cmd": "hid.scroll", "wheel": direction])
                pause(0.03)
            }
            guard let after = settledFrame(after: 1.2) else { return false }
            return FrameAnalysis.verticalShift(from: before, to: after).moved
        }
        try pointer(0.5, y)
        pause(0.5)
        var results: [(String, Bool)] = []
        var direction = -1
        var next = 0
        for round in 1...rounds {
            if round % 4 == 0 { try requireExpectedScreen() }
            let ok = try trial(direction)
            direction = -direction
            log("  scroll \(round): \(ok ? "moved" : "no movement")")
            guard !ok else { continue }
            let (name, action) = candidates[next % candidates.count]
            next += 1
            try action()
            let recovered = try trial(direction)
            direction = -direction
            results.append((name, recovered))
            log("    after \(name): \(recovered ? "RECOVERED" : "still stuck")")
        }
        return results
    }

    /// Long run of identical scrolls to catch scrolling that stops after a while.
    /// On the first failure it checks whether re-sending the pointer revives it.
    public func scrollEndurance(profile: String, trials: Int) throws -> (summary: ScrollSummary, recoveredByNudge: Bool?) {
        try requireExpectedScreen()
        var config = ScrollConfig(profile: profile)
        let summary = try scrollTest(config, trials: trials)
        guard summary.firstFailure != nil else { return (summary, nil) }
        config.nudge = true
        let retry = try scrollTest(config, trials: 4)
        return (summary, retry.successes > 0)
    }

    /// Hands input to the phone through the session and moves its pointer to (0.5, y).
    func placeSessionPointer(y: Double) throws {
        if (try app.status()["owner"] as? String) != "phone" { try app.send(["cmd": "enter"]) }
        let status = try app.status()
        guard let pointer = status["phonePointer"] as? [String: Any], let px = pointer["x"] as? Double,
              let py = pointer["y"] as? Double, let size = status["phoneSize"] as? [String: Any],
              let width = size["width"] as? Double, let height = size["height"] as? Double else { return }
        try app.send(["cmd": "move", "dx": (0.5 - px) * width, "dy": (y - py) * height])
    }

    func switchProfile(_ profile: String) throws {
        let current = try app.status()["profile"] as? String
        guard current != profile else { return }
        log("  switching HID profile to \(profile); waiting for the iPhone to re-subscribe…")
        try app.send(["cmd": "profile", "variant": profile])
        pause(1)
        guard app.waitUntilReady(timeout: 30) else {
            throw AutomationClient.ClientError.failed("The iPhone did not re-subscribe after switching to \(profile).")
        }
        pause(1)
    }

    // MARK: Typing

    /// Requires a focused text field on the phone (e.g. a new note).
    public func typingTest(rounds: Int) throws -> (passed: Int, failures: [String]) {
        var passed = 0
        var failures: [String] = []
        for round in 1...rounds {
            // Typing goes to whatever has focus: only ever into Notes.
            try requireExpectedScreen("Notes")
            let token = "mh" + String((0..<6).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
            try app.send(["cmd": "hid.type", "text": token])
            pause(0.8)
            let text = screen.recognizedText().joined(separator: " ")
            if text.contains(token) {
                passed += 1
                log("  round \(round): typed \(token) — seen on screen")
            } else {
                failures.append(token)
                log("  round \(round): typed \(token) — NOT seen (screen text: \(text.prefix(120)))")
            }
            // Delete it again with Backspace.
            for _ in token {
                try app.send(["cmd": "hid.keyboard", "keys": [0x2A]])
                try app.send(["cmd": "hid.keyboard", "keys": []])
            }
            pause(0.4)
        }
        return (passed, failures)
    }

    // MARK: Round trips

    public struct RoundTrip {
        public var entered: Bool
        public var pointerSeen: Bool?
        public var scrolled: Bool
        public var returned: Bool
        public var passed: Bool { entered && returned && scrolled && pointerSeen != false }
    }

    /// Full Mac → iPhone → Mac transitions through MacHop's real input session:
    /// synthetic Mac pointer and trackpad events go through the same routing,
    /// Bluetooth and iPhone path as real ones. (The macOS event tap itself is the
    /// only layer bypassed.) Requires a scrollable list on screen.
    public func roundTrips(_ count: Int) throws -> [RoundTrip] {
        var results: [RoundTrip] = []
        for trip in 1...count {
            if trip % 5 == 1 { try requireExpectedScreen() }
            let status = try app.status()
            guard let edge = status["edge"] as? [String: Any], let edgeX = edge["x"] as? Double,
                  let top = edge["top"] as? Double, let bottom = edge["bottom"] as? Double else {
                throw AutomationClient.ClientError.failed("MacHop has no usable screen edge; check the arrangement.")
            }
            let outward: Double = (edge["side"] as? String) == "left" ? -1 : 1
            let y = top + (bottom - top) * (0.3 + 0.4 * Double(trip % 3) / 2)
            if (status["owner"] as? String) == "phone" { try app.send(["cmd": "return"]) }
            pause(0.3)
            let reference = screen.frame()
            // Push through the edge.
            for _ in 0..<12 {
                try app.send(["cmd": "move", "x": edgeX, "y": y, "dx": 2 * outward, "dy": 0])
                pause(0.008)
            }
            let entered = (try app.status()["owner"] as? String) == "phone"
            // Move into the phone and look for the pointer.
            for _ in 0..<20 { try app.send(["cmd": "move", "dx": 5 * outward, "dy": 2]); pause(0.008) }
            let moved = settledFrame(after: 0.4)
            let pointerSeen: Bool? = {
                guard let reference, let moved else { return nil }
                return !FrameAnalysis.changedRegions(reference, moved).isEmpty
            }()
            // Two-finger scroll with phases, as the trackpad sends it.
            let before = screen.frame()
            try app.send(["cmd": "scroll", "dy": 0, "phase": "mayBegin"])
            for index in 0..<10 {
                // A short stroke and a long settle keep iOS's momentum within what the lab can measure.
                try app.send(["cmd": "scroll", "dy": trip % 2 == 0 ? 4 : -4, "phase": index == 0 ? "began" : "changed"])
                pause(0.012)
            }
            try app.send(["cmd": "scroll", "dy": 0, "phase": "ended"])
            let after = settledFrame(after: 2.5)
            let scrolled = before.flatMap { b in after.map { FrameAnalysis.verticalShift(from: b, to: $0).moved } } ?? false
            // Back across the edge.
            var returned = false
            for _ in 0..<200 {
                try app.send(["cmd": "move", "dx": -6 * outward, "dy": 0])
                if (try app.status()["owner"] as? String) == "mac" { returned = true; break }
                pause(0.004)
            }
            let result = RoundTrip(entered: entered, pointerSeen: pointerSeen, scrolled: scrolled, returned: returned)
            results.append(result)
            log("  trip \(trip): entered \(entered), pointer \(pointerSeen.map { $0 ? "seen" : "NOT seen" } ?? "n/a"), " +
                "scrolled \(scrolled), returned \(returned) → \(result.passed ? "PASS" : "FAIL")")
            pause(0.35)
        }
        return results
    }
}
