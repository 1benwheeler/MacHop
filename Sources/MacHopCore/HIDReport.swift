// SPDX-License-Identifier: AGPL-3.0-only

/// What the iPhone should see, independent of how a particular report map lays
/// it out in bytes. The session produces these; an `HIDProfile` encodes them.
public enum HIDReport: Equatable, Sendable {
    case keyboard(KeyboardReport)
    case pointer(PointerReport)
    case scroll(ScrollReport)
    case consumer(ConsumerReport)
    /// Contacts on a touch surface (experimental touchscreen/touchpad layouts only).
    case touch(TouchReport)

    public var kind: Kind {
        switch self {
        case .keyboard: .keyboard
        case .pointer: .pointer
        case .scroll: .scroll
        case .consumer: .consumer
        case .touch: .touch
        }
    }

    public enum Kind: Hashable, Sendable, CaseIterable {
        case keyboard, pointer, scroll, consumer, touch
    }
}

/// A full keyboard state: modifiers plus up to six held keys (boot-keyboard style).
public struct KeyboardReport: Equatable, Sendable {
    public var modifiers: UInt8
    public var keys: [UInt8]

    public init(modifiers: UInt8 = 0, keys: [UInt8] = []) {
        self.modifiers = modifiers
        self.keys = keys
    }

    public static let released = KeyboardReport()
}

/// Absolute pointer state. Coordinates are normalized to the phone screen (0…1).
public struct PointerReport: Equatable, Sendable {
    public var buttons: UInt8
    public var x: Double
    public var y: Double

    public init(buttons: UInt8 = 0, x: Double, y: Double) {
        self.buttons = buttons
        self.x = x
        self.y = y
    }

    /// Logical coordinate sent on the wire (0…32767).
    public static let logicalMaximum: Double = 32767
    public var logicalX: UInt16 { Self.logical(x) }
    public var logicalY: UInt16 { Self.logical(y) }

    static func logical(_ value: Double) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(1, max(0, value)) * logicalMaximum).rounded())
    }
}

/// Relative scroll steps. Positive `wheel` is a wheel rolled away from the user;
/// positive `pan` scrolls right. Each value is −127…127 per report.
public struct ScrollReport: Equatable, Sendable {
    public var wheel: Int
    public var pan: Int

    public init(wheel: Int = 0, pan: Int = 0) {
        self.wheel = wheel
        self.pan = pan
    }

    public var isZero: Bool { wheel == 0 && pan == 0 }
}

/// Up to two contacts on a touch surface, positions normalized to it (0…1).
public struct TouchReport: Equatable, Sendable {
    public struct Contact: Equatable, Sendable {
        public var id: UInt8
        public var x: Double
        public var y: Double
        /// False on the report that lifts this contact.
        public var down: Bool

        public init(id: UInt8, x: Double, y: Double, down: Bool) {
            self.id = id
            self.x = x
            self.y = y
            self.down = down
        }
    }

    public var contacts: [Contact]
    public var button: Bool

    public init(contacts: [Contact], button: Bool = false) {
        self.contacts = contacts
        self.button = button
    }
}

/// A Consumer Control usage (page 0x0C) held down, or 0 for none.
public struct ConsumerReport: Equatable, Sendable {
    public var usage: UInt16

    public init(usage: UInt16 = 0) { self.usage = usage }

    public static let released = ConsumerReport()
    public static let home: UInt16 = 0x0223          // AC Home
    public static let search: UInt16 = 0x0221        // AC Search (Spotlight)
    public static let keyboardToggle: UInt16 = 0x01AE // AL Keyboard Layout (show/hide keyboard)
}
