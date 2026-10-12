// SPDX-License-Identifier: AGPL-3.0-only
import MacHopCore

/// A simulated iPhone acting as a HID host.
///
/// It parses the published report map itself and interprets raw report bytes the
/// way a host does: absolute or relative pointer, buttons, wheel and pan, keyboard
/// arrays and modifiers. It records typed text (US layout), clicks and scrolling so
/// tests can compare what the phone *saw* with what the user did on the Mac.
///
/// This models the HID protocol, not iOS AssistiveTouch: it cannot prove that a
/// real iPhone reacts the same way.
public final class VirtualPhone {
    public struct Click: Equatable {
        public var button: Int
        public var location: Point
    }

    public let descriptor: HIDDescriptor
    public let screen: (width: Double, height: Double)

    public private(set) var pointer: Point
    public private(set) var buttons: Set<Int> = []
    public private(set) var pressedKeys: Set<UInt8> = []
    public private(set) var modifiers: UInt8 = 0
    public private(set) var text = ""
    /// Accumulated wheel (y) and pan (x) steps; positive y = wheel away from user.
    public private(set) var scrollSteps = Point.zero
    /// Taps: presses released close to where they started (as iOS decides).
    public private(set) var clicks: [Click] = []
    /// Presses that moved: iOS scrolls (or drags) the content under them.
    public private(set) var drags: [(from: Point, to: Point)] = []
    /// Total touch movement while pressed: how far dragged content has moved.
    public private(set) var dragScroll = Point.zero
    /// iOS's tap tolerance, in screen points.
    public static let tapSlop = 10.0
    private var pressedAt: Point?
    public private(set) var consumerUsage: UInt16 = 0
    public private(set) var consumerPresses: [UInt16] = []
    public private(set) var reportsReceived = 0
    public private(set) var errors: [String] = []

    /// Points the relative profile's pointer moves per count (approximates iOS tracking).
    public var relativeScale = 1.0

    public init(reportMap: [UInt8], screen: (width: Double, height: Double) = (393, 852)) throws {
        descriptor = try HIDDescriptor(bytes: reportMap)
        self.screen = screen
        pointer = Point(x: screen.width / 2, y: screen.height / 2)
    }

    public var isIdle: Bool { buttons.isEmpty && pressedKeys.isEmpty && modifiers == 0 && consumerUsage == 0 }

    public func receive(reportID: UInt8, bytes: [UInt8]) {
        reportsReceived += 1
        guard let layout = descriptor.input(reportID) else {
            errors.append("Report \(reportID) is not an input report in the map")
            return
        }
        guard bytes.count == layout.byteLength else {
            errors.append("Report \(reportID) has \(bytes.count) bytes; the map declares \(layout.byteLength)")
            return
        }
        var newButtons = buttons
        var sawButtons = false
        var keys: Set<UInt8>?
        var consumer: UInt16?
        var newModifiers: UInt8?
        var absolute = (x: Double?.none, y: Double?.none)

        for field in layout.fields where !field.isConstant {
            if !field.isVariable {
                // Array field: each nonzero element names a usage that is currently down.
                let page = UInt16((field.usageMinimum ?? UInt32(field.usagePage) << 16) >> 16)
                if page == 0x07 { keys = keys ?? [] }
                if page == 0x0C { consumer = consumer ?? 0 }
                for element in 0..<field.count {
                    let value = field.value(at: element, in: bytes)
                    guard value != 0 else { continue }
                    guard value >= field.logicalMinimum, value <= field.logicalMaximum else {
                        errors.append("Report \(reportID): array value \(value) outside logical range")
                        continue
                    }
                    let usage = (field.usageMinimum ?? 0) + UInt32(value - field.logicalMinimum)
                    let id = UInt16(usage & 0xFFFF)
                    if page == 0x07 {
                        if id == 0x01 { errors.append("Keyboard rollover error reported") }
                        keys?.insert(UInt8(truncatingIfNeeded: id))
                    } else if page == 0x0C {
                        consumer = id
                    }
                }
                continue
            }
            for element in 0..<field.count {
                let value = field.value(at: element, in: bytes)
                guard let usage = field.usage(at: element) else { continue }
                let page = UInt16(usage >> 16), id = UInt16(usage & 0xFFFF)
                if value < field.logicalMinimum || value > field.logicalMaximum {
                    errors.append("Report \(reportID): value \(value) for usage \(page):\(id) outside logical range")
                }
                switch (page, id) {
                case (0x07, 0xE0...0xE7):
                    let bit = UInt8(1) << UInt8(id - 0xE0)
                    newModifiers = (newModifiers ?? 0) | (value != 0 ? bit : 0)
                case (0x09, 1...8):
                    sawButtons = true
                    if value != 0 { newButtons.insert(Int(id)) } else { newButtons.remove(Int(id)) }
                case (0x01, 0x30), (0x01, 0x31):
                    let isX = id == 0x30
                    if field.isRelative {
                        let delta = Double(value) * relativeScale
                        if isX { pointer.x = clamp(pointer.x + delta, 0, screen.width) }
                        else { pointer.y = clamp(pointer.y + delta, 0, screen.height) }
                    } else {
                        let span = Double(field.logicalMaximum - field.logicalMinimum)
                        let fraction = Double(value - field.logicalMinimum) / max(span, 1)
                        if isX { absolute.x = fraction * screen.width } else { absolute.y = fraction * screen.height }
                    }
                case (0x01, 0x38):
                    scrollSteps.y += Double(value)
                case (0x0C, 0x238):
                    scrollSteps.x += Double(value)
                default:
                    break
                }
            }
        }
        let previous = pointer
        if let x = absolute.x { pointer.x = x }
        if let y = absolute.y { pointer.y = y }
        if buttons.contains(1) {
            dragScroll.x += pointer.x - previous.x
            dragScroll.y += pointer.y - previous.y
        }
        // Modifiers are applied before keys so shifted characters come out right.
        if let newModifiers { modifiers = newModifiers }
        if let keys { applyKeys(keys) }
        if let consumer {
            if consumer != 0 && consumer != consumerUsage { consumerPresses.append(consumer) }
            consumerUsage = consumer
        }
        if sawButtons {
            for pressed in newButtons.subtracting(buttons) {
                if pressed == 1 { pressedAt = pointer } else { clicks.append(Click(button: pressed, location: pointer)) }
            }
            if buttons.contains(1), !newButtons.contains(1), let start = pressedAt {
                let moved = ((pointer.x - start.x) * (pointer.x - start.x) + (pointer.y - start.y) * (pointer.y - start.y)).squareRoot()
                if moved < Self.tapSlop { clicks.append(Click(button: 1, location: start)) } else { drags.append((start, pointer)) }
                pressedAt = nil
            }
            buttons = newButtons
        }
    }

    private func applyKeys(_ keys: Set<UInt8>) {
        let shift = modifiers & 0x22 != 0
        let shortcut = modifiers & 0xDD != 0  // Control, Option or Command held
        for key in keys.subtracting(pressedKeys).sorted() {
            if key == 0x2A, !shortcut {
                if !text.isEmpty { text.removeLast() }
            } else if !shortcut, let character = Self.character(for: key, shift: shift) {
                text.append(character)
            }
        }
        pressedKeys = keys
    }

    /// US-layout characters, the inverse of `KeyMap.keystroke(for:)`.
    static func character(for usage: UInt8, shift: Bool) -> Character? {
        switch usage {
        case 0x04...0x1D:
            let scalar = Unicode.Scalar((shift ? 65 : 97) + UInt32(usage - 0x04))!
            return Character(scalar)
        case 0x1E...0x26:
            return shift ? Array("!@#$%^&*(")[Int(usage - 0x1E)] : Character("\(usage - 0x1E + 1)")
        case 0x27: return shift ? ")" : "0"
        case 0x28: return "\n"
        case 0x2B: return "\t"
        case 0x2C: return " "
        default:
            let pairs: [UInt8: (Character, Character)] = [
                0x2D: ("-", "_"), 0x2E: ("=", "+"), 0x2F: ("[", "{"), 0x30: ("]", "}"), 0x31: ("\\", "|"),
                0x33: (";", ":"), 0x34: ("'", "\""), 0x35: ("`", "~"), 0x36: (",", "<"), 0x37: (".", ">"),
                0x38: ("/", "?")
            ]
            guard let pair = pairs[usage] else { return nil }
            return shift ? pair.1 : pair.0
        }
    }
}

private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
