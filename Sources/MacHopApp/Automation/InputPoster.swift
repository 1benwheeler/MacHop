// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import MacHopCore

/// Test-only: posts real input events into macOS, as if from the trackpad and
/// keyboard. They pass through the system and MacHop's own event tap exactly like
/// hardware input, so end-to-end tests exercise the real path. Uses MacHop's
/// Accessibility permission; only reachable through the opt-in automation socket.
nonisolated enum InputPoster {
    static func handles(_ line: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["cmd"].map { "\($0)".hasPrefix("post.") } == true
    }

    static func respond(to line: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let response = handle(request)
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static var source: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    private static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    private static func handle(_ request: [String: Any]) -> [String: Any] {
        func number(_ key: String, _ fallback: Double) -> Double { (request[key] as? NSNumber)?.doubleValue ?? fallback }
        let interval = number("interval", 0.008)
        switch request["cmd"] as? String ?? "" {
        case "post.move":
            // Relative motion in steps, like a trackpad: each event carries its delta.
            let steps = max(1, Int(number("steps", 1)))
            let dx = number("dx", 0) / Double(steps), dy = number("dy", 0) / Double(steps)
            let dragging = request["drag"] as? Bool ?? false
            for _ in 0..<steps {
                let from = cursor
                let event = CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                                    mouseCursorPosition: CGPoint(x: from.x + dx, y: from.y + dy), mouseButton: .left)
                event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
                event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
                post(event)
                Thread.sleep(forTimeInterval: interval)
            }
            return ["ok": true, "cursor": ["x": cursor.x, "y": cursor.y]]

        case "post.moveTo":
            // Absolute placement on the Mac (only meaningful while the Mac has input).
            let target = CGPoint(x: number("x", cursor.x), y: number("y", cursor.y))
            post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left))
            return ["ok": true]

        case "post.click":
            let number = Int(number("button", 0))
            let (down, up): (CGEventType, CGEventType) = switch number {
            case 0: (.leftMouseDown, .leftMouseUp)
            case 1: (.rightMouseDown, .rightMouseUp)
            default: (.otherMouseDown, .otherMouseUp)
            }
            let button = CGMouseButton(rawValue: UInt32(number)) ?? .left
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursor, mouseButton: button)
                event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
                post(event)
                Thread.sleep(forTimeInterval: 0.06)
            }
            return ["ok": true]

        case "post.scroll":
            // A two-finger trackpad scroll with phases: mayBegin, began, changed…, ended.
            let steps = max(1, Int(number("steps", 10)))
            let dy = Int32((number("dy", 0) / Double(steps)).rounded()), dx = Int32((number("dx", 0) / Double(steps)).rounded())
            func scroll(_ y: Int32, _ x: Int32, phase: CGScrollPhase) {
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
                event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                post(event)
                Thread.sleep(forTimeInterval: 0.012)
            }
            scroll(0, 0, phase: .mayBegin)
            for index in 0..<steps { scroll(dy, dx, phase: index == 0 ? .began : .changed) }
            scroll(0, 0, phase: .ended)
            return ["ok": true]

        case "post.key":
            // A key press and release, with optional modifier flags (CGEventFlags raw value).
            let code = CGKeyCode(number("code", 0))
            let flags = CGEventFlags(rawValue: UInt64(number("flags", 0)))
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                event?.flags = flags
                post(event)
                Thread.sleep(forTimeInterval: 0.03)
            }
            return ["ok": true]

        case "post.type":
            var typed = 0
            for character in request["text"] as? String ?? "" {
                guard let stroke = KeyMap.keystroke(for: character), let code = keyCodes[stroke.usage] else { continue }
                let shift: CGEventFlags = stroke.shift ? [.maskShift] : []
                if stroke.shift { modifier(56, flags: [.maskShift]) }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                    event?.flags = shift
                    post(event)
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if stroke.shift { modifier(56, flags: []) }
                typed += 1
            }
            return ["ok": true, "typed": typed]

        default:
            return ["ok": false, "error": "unknown post command"]
        }
    }

    private static func modifier(_ code: CGKeyCode, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: !flags.isEmpty)
        event?.type = .flagsChanged
        event?.flags = flags.isEmpty ? [] : flags.union(CGEventFlags(rawValue: 0x02))   // left-Shift device bit
        post(event)
        Thread.sleep(forTimeInterval: 0.02)
    }

    /// HID usage → Mac key code, for typing text.
    private static let keyCodes: [UInt8: CGKeyCode] = {
        var map: [UInt8: CGKeyCode] = [:]
        for code in UInt16(0)...127 {
            if let usage = KeyMap.usage(forKeyCode: code), map[usage] == nil { map[usage] = code }
        }
        return map
    }()
}
