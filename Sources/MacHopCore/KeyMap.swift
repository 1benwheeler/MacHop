// SPDX-License-Identifier: AGPL-3.0-only

/// Physical key translation from macOS virtual key codes (Carbon `kVK_*`) to
/// USB HID Keyboard/Keypad usages (HID Usage Tables, page 0x07).
///
/// Keys are sent by position, never as text: the iPhone applies its own
/// hardware-keyboard layout, exactly as with a physical Bluetooth keyboard.
public enum KeyMap {
    public static func usage(forKeyCode code: UInt16) -> UInt8? { usages[code] }

    /// HID modifier bit for a modifier key code, if it is one.
    public static func modifierBit(forKeyCode code: UInt16) -> UInt8? { modifiers[code]?.hidBit }

    /// The side-specific (or aggregate, for Fn) flag that says whether this
    /// modifier key is currently held.
    public static func heldFlag(forKeyCode code: UInt16) -> ModifierFlags? { modifiers[code]?.deviceFlag }

    public static func aggregateFlag(forKeyCode code: UInt16) -> ModifierFlags? { modifiers[code]?.aggregate }

    public static let capsLockKeyCode: UInt16 = 57
    public static let functionKeyCode: UInt16 = 63
    public static let escapeKeyCode: UInt16 = 53
    /// The I key (ANSI position): ⌃⌥⌘I jumps to the iPhone and back.
    public static let jumpKeyCode: UInt16 = 34
    public static let capsLockUsage: UInt8 = 0x39

    private struct Modifier {
        let hidBit: UInt8?
        let deviceFlag: ModifierFlags
        let aggregate: ModifierFlags
    }

    private static let modifiers: [UInt16: Modifier] = [
        59: Modifier(hidBit: 0x01, deviceFlag: .leftControl, aggregate: .control),
        56: Modifier(hidBit: 0x02, deviceFlag: .leftShift, aggregate: .shift),
        58: Modifier(hidBit: 0x04, deviceFlag: .leftOption, aggregate: .option),
        55: Modifier(hidBit: 0x08, deviceFlag: .leftCommand, aggregate: .command),
        62: Modifier(hidBit: 0x10, deviceFlag: .rightControl, aggregate: .control),
        60: Modifier(hidBit: 0x20, deviceFlag: .rightShift, aggregate: .shift),
        61: Modifier(hidBit: 0x40, deviceFlag: .rightOption, aggregate: .option),
        54: Modifier(hidBit: 0x80, deviceFlag: .rightCommand, aggregate: .command),
        // Fn/Globe has no standard keyboard usage; it is tracked so its release
        // goes to whichever side saw the press.
        63: Modifier(hidBit: nil, deviceFlag: .function, aggregate: .function)
    ]

    private static let usages: [UInt16: UInt8] = [
        // Letters
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A,
        0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11,
        0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18,
        0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        // Number row
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24,
        0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        // Editing and punctuation
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E,
        0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36,
        0x2F: 0x37, 0x2C: 0x38, 0x39: 0x39,
        // ISO section key and JIS keys
        0x0A: 0x64, 0x5D: 0x89, 0x5E: 0x87, 0x5F: 0x85, 0x66: 0x91, 0x68: 0x90,
        // Function keys
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40,
        0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45, 0x69: 0x68, 0x6B: 0x69,
        0x71: 0x6A, 0x6A: 0x6B, 0x40: 0x6C, 0x4F: 0x6D, 0x50: 0x6E, 0x5A: 0x6F,
        // Navigation (Help sits where PC keyboards have Insert)
        0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52, 0x6E: 0x65,
        // Keypad
        0x47: 0x53, 0x4B: 0x54, 0x43: 0x55, 0x4E: 0x56, 0x45: 0x57, 0x4C: 0x58, 0x53: 0x59,
        0x54: 0x5A, 0x55: 0x5B, 0x56: 0x5C, 0x57: 0x5D, 0x58: 0x5E, 0x59: 0x5F, 0x5B: 0x60,
        0x5C: 0x61, 0x52: 0x62, 0x41: 0x63, 0x51: 0x67,
        // Hardware volume keys on some keyboards
        0x4A: 0x7F, 0x48: 0x80, 0x49: 0x81
    ]

    /// US-layout text to key presses, used by automation and tests to type known
    /// strings. Returns nil for characters with no single-key equivalent.
    public static func keystroke(for character: Character) -> (usage: UInt8, shift: Bool)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              scalar.isASCII else { return nil }
        let value = UInt8(scalar.value)
        switch scalar {
        case "a"..."z": return (0x04 + value - 97, false)
        case "A"..."Z": return (0x04 + value - 65, true)
        case "1"..."9": return (0x1E + value - 49, false)
        case "0": return (0x27, false)
        default: break
        }
        if let index = Array("!@#$%^&*()").firstIndex(of: character) { return (0x1E + UInt8(index), true) }
        let plain: [Character: UInt8] = [
            "\n": 0x28, "\t": 0x2B, " ": 0x2C, "-": 0x2D, "=": 0x2E, "[": 0x2F, "]": 0x30,
            "\\": 0x31, ";": 0x33, "'": 0x34, "`": 0x35, ",": 0x36, ".": 0x37, "/": 0x38
        ]
        let shifted: [Character: UInt8] = [
            "_": 0x2D, "+": 0x2E, "{": 0x2F, "}": 0x30, "|": 0x31, ":": 0x33, "\"": 0x34,
            "~": 0x35, "<": 0x36, ">": 0x37, "?": 0x38
        ]
        if let usage = plain[character] { return (usage, false) }
        if let usage = shifted[character] { return (usage, true) }
        return nil
    }
}
