// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import LabKit

let usage = """
machop-lab — automated testing of MacHop on a physical iPhone

MacHop drives the iPhone over Bluetooth; the lab watches the iPhone's screen over
USB and checks what actually happened. Setup: CONTRIBUTING.md

Usage: machop-lab <command> [options]

  doctor                       Check MacHop, the iPhone link and screen capture
  snapshot [file.png]          Save the iPhone's screen
  text                         Print the text currently on the iPhone's screen
  pointer                      Measure absolute pointer placement across the screen
  sleep-check                  Simulate Mac sleep and wake; watch the iPhone for its pointer
  scroll [--profile P] [--trials N] [--size S] [--steps N] [--interval-ms T] [--at PERCENT]
                               Scroll a list and measure that the content moved
  scroll-matrix [--trials N]   Compare report layouts, step sizes and timings
  endurance [--profile P] [--trials N]
                               Long scrolling run; detects scrolling that stops
  type [--rounds N]            Type random words into a focused text field, read them back
  roundtrips [--count N]       Mac → iPhone → Mac transitions through MacHop's session
  acceptance                   pointer + scroll + 30 round trips, written to a report
  bench                        Measure routing/transport speed (simulated; no hardware)
  send '<json>'                Send one automation command to MacHop and print the reply
  mac-shot <file.png>          Screenshot the Mac's screen
  look <dir>                   Save both screens (iphone.png, mac.png) and MacHop's status
  Real-input driving (posted through macOS and MacHop's event tap, like a trackpad):
    cross | back               Push through the edge onto the iPhone / back to the Mac
    goto <x> <y>               Move the iPhone pointer to a point (fractions of the screen)
    click [button]             Click (0 left, 1 right)
    keys <text>                Type on the keyboard
    twofinger <dy> [dx]        Two-finger scroll by dy points (negative = fingers up)

Profiles: compatibility (default), standard, relative.
"""

func option(_ name: String, _ fallback: Int) -> Int {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return fallback }
    return Int(CommandLine.arguments[index + 1]) ?? fallback
}

func option(_ name: String, _ fallback: String) -> String {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func connectApp() -> AutomationClient {
    do { return try AutomationClient() } catch { fail("\(error)") }
}

func openScreen() -> PhoneScreen {
    guard let device = PhoneScreen.phones().first else { fail("\(PhoneScreen.CaptureError.noDevice)") }
    do {
        let screen = try PhoneScreen(device: device)
        try screen.start()
        return screen
    } catch {
        fail("\(error)")
    }
}

func requireReady(_ app: AutomationClient) {
    guard app.isPhoneReady else {
        fail("MacHop is running but the iPhone is not connected (no input subscriptions). Check MacHop's menu.")
    }
}

/// Appends a section to today's physical test report.
func report(_ title: String, _ lines: [String]) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let directory = URL(fileURLWithPath: "docs/results/\(formatter.string(from: Date()))")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("physical-tests.md")
    formatter.dateFormat = "HH:mm:ss"
    let text = "\n## \(title) — \(formatter.string(from: Date()))\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    } else {
        try? ("# Physical iPhone test results\n" + text).write(to: file, atomically: true, encoding: .utf8)
    }
    print("Recorded in \(file.path)")
}

func describe(_ summary: Lab.ScrollSummary) -> String {
    let rate = summary.trials.isEmpty ? 0 : summary.successes * 100 / summary.trials.count
    let perUnit = summary.pixelsPerUnit.map { String(format: "%.1f px per wheel unit", $0) } ?? "no movement"
    return "\(summary.config): \(summary.successes)/\(summary.trials.count) moved (\(rate)%), \(perUnit)" +
        (summary.firstFailure.map { ", first failure at trial \($0 + 1)" } ?? "")
}

var arguments = Array(CommandLine.arguments.dropFirst())
// When run as "MacHop Lab.app" (scripts/lab.sh), the working directory comes in explicitly.
if arguments.first == "--cwd", arguments.count > 1 {
    FileManager.default.changeCurrentDirectoryPath(arguments[1])
    arguments.removeFirst(2)
}
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

func macScreenshot(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-t", "png", path]
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
}

switch command {
case "send":
    guard arguments.count > 1, let data = arguments[1].data(using: .utf8),
          let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail("usage: machop-lab send '{\"cmd\": \"status\"}'")
    }
    let reply = (try? connectApp().send(request)) ?? ["ok": false, "error": "no reply"]
    let json = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    print(String(decoding: json, as: UTF8.self))

case "mac-shot":
    let path = arguments.dropFirst().first ?? "mac.png"
    guard macScreenshot(path) else {
        fail("Could not capture the Mac's screen. Allow MacHop Lab in System Settings → Privacy & Security → " +
             "Screen & System Audio Recording, then try again.")
    }
    print("Saved \(path)")

case "look":
    let directory = arguments.dropFirst().first ?? "look"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    if let status = try? connectApp().status(),
       let json = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
        print("MacHop: \(String(decoding: json, as: UTF8.self))")
    }
    let screen = openScreen()
    Thread.sleep(forTimeInterval: 0.3)
    do { try screen.savePNG(to: URL(fileURLWithPath: "\(directory)/iphone.png")) } catch { print("iPhone: \(error)") }
    screen.stop()
    print(macScreenshot("\(directory)/mac.png") ? "Saved \(directory)/iphone.png and \(directory)/mac.png"
          : "Saved \(directory)/iphone.png; Mac screenshot needs Screen Recording permission for MacHop Lab")

case "cross", "back", "goto", "click", "keys", "twofinger":
    let app = connectApp()
    requireReady(app)
    do {
        let driver = Driver(app: app)
        switch command {
        case "cross": print(try driver.cross() ? "On the iPhone" : "Did not cross")
        case "back": print(try driver.back() ? "Back on the Mac" : "Did not return")
        case "goto":
            guard arguments.count > 2, let x = Double(arguments[1]), let y = Double(arguments[2]) else { fail("usage: goto <x> <y>") }
            let reached = try driver.goto(x: x, y: y)
            print(String(format: "iPhone pointer at (%.3f, %.3f)", reached.0, reached.1))
        case "click": try driver.click(button: Int(arguments.dropFirst().first ?? "0") ?? 0); print("Clicked")
        case "keys": try driver.type(arguments.dropFirst().joined(separator: " ")); print("Typed")
        default:
            let dy = Double(arguments.dropFirst().first ?? "0") ?? 0
            let dx = Double(arguments.dropFirst(2).first ?? "0") ?? 0
            try driver.scroll(dy: dy, dx: dx); print("Scrolled")
        }
    } catch { fail("\(error)") }

case "bench":
    MainActor.assumeIsolated { Bench.run() }

case "doctor":
    var problems = 0
    if let app = try? AutomationClient() {
        let status = (try? app.status()) ?? [:]
        print("✓ MacHop automation reachable — \(status["status"] as? String ?? "?")")
        if status["ready"] as? Bool == true {
            print("✓ iPhone subscribed to input reports \(status["subscriptions"] ?? "") (profile \(status["profile"] ?? "?"))")
        } else {
            problems += 1
            print("✗ iPhone not connected to MacHop. Keep it unlocked with AssistiveTouch on; use Reconnect in MacHop.")
        }
    } else {
        problems += 1
        print("✗ MacHop automation not reachable. Run: defaults write local.machop AutomationEnabled -bool YES, then restart MacHop.")
    }
    let phones = PhoneScreen.phones()
    if let phone = phones.first {
        print("✓ iPhone screen available over USB: \(phone.localizedName)")
        do {
            let screen = try PhoneScreen(device: phone)
            try screen.start()
            if let size = screen.pixelSize { print("✓ Capturing \(size.width)×\(size.height)") }
            screen.stop()
        } catch {
            problems += 1
            print("✗ \(error)")
        }
    } else {
        problems += 1
        print("✗ \(PhoneScreen.CaptureError.noDevice)")
    }
    print(problems == 0 ? "Ready for physical tests." : "\(problems) problem(s) to fix first.")
    exit(problems == 0 ? 0 : 1)

case "tap":
    // Clicks the iPhone at (x, y), fractions of its screen, straight over Bluetooth.
    guard arguments.count > 2, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
        fail("usage: machop-lab tap <x 0…1> <y 0…1>")
    }
    let app = connectApp()
    requireReady(app)
    do {
        try app.send(["cmd": "hid.pointer", "x": x, "y": y])
        Thread.sleep(forTimeInterval: 0.2)
        try app.send(["cmd": "hid.pointer", "x": x, "y": y, "buttons": 1])
        Thread.sleep(forTimeInterval: 0.08)
        try app.send(["cmd": "hid.pointer", "x": x, "y": y])
        print(String(format: "Tapped (%.3f, %.3f)", x, y))
    } catch { fail("\(error)") }

case "snapshot":
    let screen = openScreen()
    let path = arguments.dropFirst().first ?? "iphone-\(Int(Date().timeIntervalSince1970)).png"
    do { try screen.savePNG(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
    print("Saved \(path)")

case "text":
    let screen = openScreen()
    Thread.sleep(forTimeInterval: 0.3)
    screen.recognizedText().forEach { print($0) }

case "pointer":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        let result = try lab.pointerTest()
        let found = result.samples.filter { $0.found != nil }.count
        let line = result.visible
            ? "Pointer seen at \(found)/\(result.samples.count) positions; mean error " +
              String(format: "%.3f of screen width/height", result.meanError ?? 0)
            : "The AssistiveTouch pointer is not visible in USB screen capture, so placement cannot be measured optically."
        print(line)
        report("Pointer placement", [line])
    } catch { fail("\(error)") }

case "to-settings":
    // From any app: AssistiveTouch menu → Home, then Spotlight → Settings.
    let app = connectApp()
    let lab = Lab(app: app, screen: openScreen())
    do {
        try lab.backToSettings()
        print("Settings is open.")
    } catch { fail("\(error)") }

case "open-settings":
    // From the Home Screen: taps the Settings icon, if its label is on screen.
    let app = connectApp()
    let lab = Lab(app: app, screen: openScreen())
    do {
        guard try lab.tapIcon("Settings") else { fail("No Settings icon on screen.") }
        Thread.sleep(forTimeInterval: 2)
        try lab.requireExpectedScreen()
        print("Settings is open.")
    } catch { fail("\(error)") }

case "wheel-trigger":
    // One trial: fresh connection, wheel, then <navigateInSettings|spotlight|switchApp>, wheel.
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    let name = CommandLine.arguments.dropFirst().first { Lab.WheelTrigger(rawValue: $0) != nil } ?? "navigateInSettings"
    let save = CommandLine.arguments.firstIndex(of: "--save").flatMap { index in
        index + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
    }
    do {
        let result = try lab.wheelTrial(Lab.WheelTrigger(rawValue: name)!, saveTo: save)
        let line = "Wheel trigger \(name): before \(result.before)/3, after \(result.after)/3"
        print(line)
        report("Wheel trigger", [line])
    } catch { fail("\(error)") }

case "sleep-check":
    // Simulates the Mac sleeping and waking, and watches the iPhone for its pointer.
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        let save = CommandLine.arguments.firstIndex(of: "--save").flatMap { index in
            index + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[index + 1]) : nil
        }
        let seen = try lab.changesAroundSleep(saveTo: save)
        func describe(_ points: [(Double, Double)]) -> String {
            points.isEmpty ? "nothing" : Set(points.map { String(format: "(%.2f, %.2f)", $0.0, $0.1) }).sorted().joined(separator: " ")
        }
        let lines = ["While the Mac slept: changes at \(describe(seen.asleep))",
                     "After it woke and the iPhone reconnected: changes at \(describe(seen.awake))"]
        lines.forEach { print($0) }
        report("Sleep check", lines)
    } catch { fail("\(error)") }

case "pointer-fade":
    // What makes the AssistiveTouch pointer disappear: its own Auto-Hide, or a key press.
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        var lines: [String] = []
        let control = try lab.pointerHidesOnKey(usage: nil, modifiers: 0)
        lines.append("No key (control): pointer \(control ? "disappeared" : "still showing") after 0.5 s")
        for (name, usage, modifiers) in [("Left Shift", nil, 0x02), ("Left Control", nil, 0x01), ("F15", 0x6A, 0)] as [(String, UInt8?, UInt8)] {
            let hid = try lab.pointerHidesOnKey(usage: usage, modifiers: modifiers)
            lines.append("\(name): pointer \(hid ? "disappeared" : "still showing") after 0.5 s")
        }
        let fade = try lab.pointerFadeTime()
        lines.append(fade.map { String(format: "Auto-Hide: pointer faded %.1f s after the last movement", $0) }
                     ?? "Auto-Hide: pointer still showing after 20 s (Auto-Hide off or long)")
        lines.forEach { print($0) }
        report("Pointer visibility", lines)
    } catch { fail("\(error)") }

case "pointer-corners":
    // Where the pointer sits when parked in each corner (rounded display corners may hide it).
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        var lines: [String] = []
        for (name, corner) in [("top-left", (0.0, 0.0)), ("top-right", (1.0, 0.0)),
                               ("bottom-left", (0.0, 1.0)), ("bottom-right", (1.0, 1.0))] {
            let found = try lab.pointerInCorner(corner)
            lines.append(found.map { "\(name): pointer box \($0.width)×\($0.height) px, spanning \($0.near)–\($0.far) px from the corner" }
                         ?? "\(name): pointer not seen")
            print(lines.last!)
        }
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.5])
        report("Pointer in corners", lines)
    } catch { fail("\(error)") }

case "is-settings":
    // Only whether Settings is showing; never prints the screen's text.
    let lab = Lab(app: connectApp(), screen: openScreen())
    print((try? lab.requireExpectedScreen()) != nil ? "Settings is showing" : "Settings is NOT showing")

case "media":
    // Whether the iPhone responds to Consumer volume keys (its volume indicator appears).
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        var lines: [String] = []
        let up = try lab.consumerKeyShowsChange(0xE9, undo: 0xEA)
        lines.append("Volume up (then down to restore): iPhone screen \(up ? "changed (volume indicator)" : "unchanged")")
        if CommandLine.arguments.contains("--search") {
            // AC Search opens Spotlight on iPad keyboards; Escape closes it again.
            let search = try lab.consumerKeyShowsChange(0x0221, undo: 0)
            try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [0x29]])
            Thread.sleep(forTimeInterval: 0.08)
            try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
            lines.append("AC Search (then Escape): iPhone screen \(search ? "changed" : "unchanged")")
        }
        lines.forEach { print($0) }
        report("Media keys", lines)
    } catch { fail("\(error)") }

case "globe":
    // Globe-key system shortcuts (iPad: Globe-H Home, Globe-N Notification Centre, Globe-↑ App Switcher).
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        var lines: [String] = []
        // Only Globe-H by default: Home is the one screen the lab can always return from.
        let all: [(String, UInt8)] = [("Globe-H", 0x0B), ("Globe-N", 0x11), ("Globe-↑", 0x52)]
        for (name, usage) in CommandLine.arguments.contains("--all") ? all : [all[0]] {
            let changed = try lab.globeShortcut(usage)
            lines.append("\(name): screen \(changed ? "changed (shortcut works)" : "unchanged")")
            print(lines.last!)
        }
        report("Globe shortcuts", lines)
    } catch { fail("\(error)") }

case "scroll":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    var config = Lab.ScrollConfig(profile: option("--profile", "compatibility"), stepSize: option("--size", 1),
                                  steps: option("--steps", 6), interval: Double(option("--interval-ms", 30)) / 1000)
    config.pointerY = Double(option("--at", 50)) / 100
    config.drag = CommandLine.arguments.contains("--drag")
    config.nudge = CommandLine.arguments.contains("--nudge")
    config.throughSession = CommandLine.arguments.contains("--session")
    if let index = CommandLine.arguments.firstIndex(of: "--save"), index + 1 < CommandLine.arguments.count {
        config.saveDirectory = CommandLine.arguments[index + 1]
        try? FileManager.default.createDirectory(atPath: CommandLine.arguments[index + 1], withIntermediateDirectories: true)
    }
    do {
        let blind = CommandLine.arguments.contains("--blind")
        if blind { lab.screen.stop() }
        let summary = blind ? try lab.blindScrollTest(config, trials: option("--trials", 10))
                            : try lab.scrollTest(config, trials: option("--trials", 10))
        print(describe(summary))
        report("Scrolling", [describe(summary)])
    } catch { fail("\(error)") }

case "scroll-matrix":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    let trials = option("--trials", 8)
    var lines: [String] = []
    for profile in ["compatibility", "standard", "relative"] {
        for (size, steps, interval) in [(1, 6, 0.03), (1, 6, 0.0), (3, 2, 0.05), (1, 6, 0.1)] {
            for nudge in [false, true] {
                let config = Lab.ScrollConfig(profile: profile, stepSize: size, steps: steps, interval: interval, nudge: nudge)
                print("▶ \(config)")
                do {
                    let line = describe(try lab.scrollTest(config, trials: trials))
                    print(line)
                    lines.append(line)
                } catch {
                    lines.append("\(config): \(error)")
                    print("  \(error)")
                }
            }
        }
    }
    _ = try? app.send(["cmd": "profile", "variant": "compatibility"])
    report("Scroll matrix", lines)

case "touch":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    var lines: [String] = []
    for profile in ["touchscreen", "touchpad"] {
        print("▶ \(profile)")
        do {
            let (subscribed, summary) = try lab.touchTest(profile: profile, trials: option("--trials", 6))
            lines.append(subscribed ? "\(profile): touch surface accepted; \(summary.successes)/\(summary.trials.count) moves scrolled"
                                    : "\(profile): iPhone did not subscribe to the touch surface")
        } catch {
            lines.append("\(profile): \(error)")
        }
        print(lines.last!)
    }
    _ = try? app.send(["cmd": "profile", "variant": "compatibility"])
    _ = app.waitUntilReady(timeout: 30)
    report("Touch surface experiment", lines)

case "unstick":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        let results = try lab.unstickSearch(profile: option("--profile", "standard"), rounds: option("--rounds", 20))
        var lines: [String] = []
        for name in Set(results.map(\.action)).sorted() {
            let tries = results.filter { $0.action == name }
            lines.append("\(name): recovered \(tries.filter(\.recovered).count)/\(tries.count)")
        }
        lines.forEach { print($0) }
        report("Wheel unstick search", lines)
    } catch { fail("\(error)") }

case "endurance":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        let (summary, recovered) = try lab.scrollEndurance(profile: option("--profile", "compatibility"),
                                                           trials: option("--trials", 100))
        var lines = [describe(summary)]
        if let recovered { lines.append("After the first failure, re-sending the pointer \(recovered ? "restored" : "did not restore") scrolling.") }
        lines.forEach { print($0) }
        report("Scroll endurance", lines)
    } catch { fail("\(error)") }

case "type":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        let (passed, failures) = try lab.typingTest(rounds: option("--rounds", 5))
        let line = "Typing: \(passed)/\(passed + failures.count) words read back from the screen" +
            (failures.isEmpty ? "" : "; missing: \(failures.joined(separator: ", "))")
        print(line)
        report("Typing", [line])
    } catch { fail("\(error)") }

case "roundtrips", "acceptance":
    let app = connectApp()
    requireReady(app)
    let lab = Lab(app: app, screen: openScreen())
    do {
        var lines: [String] = []
        if command == "acceptance" {
            let pointer = try lab.pointerTest()
            lines.append(pointer.visible ? String(format: "Pointer placement mean error %.3f", pointer.meanError ?? 0)
                         : "Pointer not visible in screen capture (placement not measured)")
            lines.append(describe(try lab.scrollTest(Lab.ScrollConfig(profile: "compatibility"), trials: 20)))
        }
        let trips = try lab.roundTrips(option("--count", 30))
        var consecutive = 0, best = 0
        for trip in trips {
            consecutive = trip.passed ? consecutive + 1 : 0
            best = max(best, consecutive)
        }
        lines.append("Round trips: \(trips.filter(\.passed).count)/\(trips.count) passed; longest consecutive run \(best)")
        lines.forEach { print($0) }
        report(command == "acceptance" ? "Acceptance" : "Round trips", lines)
        exit(best >= min(30, trips.count) ? 0 : 1)
    } catch { fail("\(error)") }

default:
    print(usage)
    exit(2)
}
