// SPDX-License-Identifier: AGPL-3.0-only
// The `compatibility` report map reproduces the layout that worked on the test
// iPhone in MacHop's earlier prototype, whose keyboard/system/consumer
// collections are byte-for-byte from BT Remote by jqssun (AGPL-3.0-only,
// https://github.com/jqssun/darwin-bt-remote, ad7a76ce). See THIRD-PARTY-NOTICES.md.

/// A report as it travels over HID-over-GATT: the report ID selects the GATT
/// characteristic, and the payload carries no ID byte.
public struct EncodedReport: Equatable, Sendable {
    public var reportID: UInt8
    public var bytes: [UInt8]

    public init(reportID: UInt8, bytes: [UInt8]) {
        self.reportID = reportID
        self.bytes = bytes
    }
}

/// One complete HID report map plus the encoding that matches it.
public struct HIDProfile: Equatable, Hashable, Sendable {
    public enum Variant: String, Codable, CaseIterable, Sendable {
        /// The layout proven on the test iPhone: absolute pointer (report 1),
        /// keyboard (2), LEDs (3 out), battery (4), system (5), consumer (6) and a
        /// separate vertical wheel (7).
        case compatibility
        /// MacHop's own minimal layout: keyboard (1), absolute pointer (2), wheel
        /// plus horizontal pan (3), consumer (4).
        case standard
        /// A relative mouse with wheel and pan, like most BLE mice. The phone pointer
        /// position becomes an estimate, so edge return is less precise.
        case relative
        /// Experimental: `standard` plus a two-finger touchscreen digitizer (report 5).
        case touchscreen
        /// Experimental: `standard` plus a two-finger precision touchpad (report 5).
        case touchpad
        /// Experimental: `compatibility` with a high-resolution wheel: report 7 also
        /// carries a Resolution Multiplier feature (1 or 16) that the host may set.
        case hiResWheel
    }

    /// The layout used for keyboard, pointer, scroll and consumer reports.
    public var base: Variant {
        switch variant {
        case .touchscreen, .touchpad: .standard
        case .hiResWheel: .compatibility
        default: variant
        }
    }

    public var hasTouchSurface: Bool { variant == .touchscreen || variant == .touchpad }
    public static let touchReportID: UInt8 = 5

    public let variant: Variant

    public init(_ variant: Variant) { self.variant = variant }

    public static let compatibility = HIDProfile(.compatibility)
    public static let standard = HIDProfile(.standard)
    public static let relative = HIDProfile(.relative)

    public var isAbsolute: Bool { variant != .relative }
    public var supportsHorizontalScroll: Bool { base != .compatibility }

    /// Input reports, in the order their GATT characteristics are published.
    public var inputReportIDs: [UInt8] {
        switch variant {
        case .compatibility, .hiResWheel: [5, 6, 1, 2, 7]
        case .standard: [1, 2, 3, 4]
        case .relative: [1, 2, 4]
        case .touchscreen, .touchpad: [1, 2, 3, 4, 5]
        }
    }

    public var keyboardLEDReportID: UInt8 { base == .compatibility ? 3 : 1 }

    /// Feature reports and their initial values (the host may read and write them).
    public var featureReports: [UInt8: [UInt8]] { variant == .hiResWheel ? [7: [0]] : [:] }

    /// Input reports the phone must subscribe to before input can be sent.
    public var requiredInputReportIDs: Set<UInt8> {
        switch variant {
        case .compatibility, .hiResWheel: [1, 2, 7]
        case .standard: [1, 2, 3]
        case .relative: [1, 2]
        // The touch surface is optional: if the phone ignores it, input still works,
        // and its missing subscription is the answer to the experiment.
        case .touchscreen, .touchpad: [1, 2, 3]
        }
    }

    public var keyboardReportID: UInt8 { base == .compatibility ? 2 : 1 }
    public var pointerReportID: UInt8 { base == .compatibility ? 1 : 2 }
    public var scrollReportID: UInt8 { switch base { case .compatibility: 7; case .relative: 2; default: 3 } }
    public var consumerReportID: UInt8 { base == .compatibility ? 6 : 4 }

    /// The all-released value for an input report, sent when the phone subscribes.
    public func neutralPayload(for reportID: UInt8) -> [UInt8] {
        if hasTouchSurface && reportID == Self.touchReportID {
            return [UInt8](repeating: 0, count: variant == .touchscreen ? 13 : 16)
        }
        return switch (base, reportID) {
        case (.compatibility, 1): [0, 0, 0x40, 0, 0x40, 0]
        case (.compatibility, 2): [UInt8](repeating: 0, count: 8)
        case (.compatibility, 5), (.compatibility, 7): [0]
        case (.compatibility, 6): [0, 0, 0, 0, 0]
        case (.standard, 1), (.relative, 1): [UInt8](repeating: 0, count: 8)
        case (.standard, 2): [0, 0, 0x40, 0, 0x40]
        case (.standard, 3): [0, 0]
        case (.standard, 4), (.relative, 4): [0, 0]
        case (.relative, 2): [0, 0, 0, 0, 0]
        default: [0]
        }
    }

    public var reportMap: [UInt8] {
        switch variant {
        case .compatibility: Self.compatibilityMap
        case .hiResWheel: Self.hiResWheelMap
        case .standard: Self.standardMap
        case .relative: Self.relativeMap
        case .touchscreen: Self.standardMap + Self.touchscreenCollection
        case .touchpad: Self.standardMap + Self.touchpadCollection
        }
    }
}

// MARK: - Encoding

/// Encodes semantic reports for one profile. Stateful only for the relative
/// profile, which turns absolute positions into movement deltas.
public struct HIDEncoder: Sendable {
    public let profile: HIDProfile
    private var lastPointer: PointerReport?
    private var scanTime: UInt16 = 0

    /// Relative profile: mouse counts per full phone width/height. The phone's own
    /// pointer acceleration still applies, so this is an approximation.
    public static let relativeCountsPerScreen = 400.0

    public init(profile: HIDProfile) { self.profile = profile }

    public mutating func reset() { lastPointer = nil }

    public mutating func encode(_ report: HIDReport) -> [EncodedReport] {
        switch report {
        case .keyboard(let keyboard):
            let keys = Array(keyboard.keys.prefix(6))
            let bytes = [keyboard.modifiers, 0] + keys + [UInt8](repeating: 0, count: 6 - keys.count)
            return [EncodedReport(reportID: profile.keyboardReportID, bytes: bytes)]

        case .pointer(let pointer):
            let buttons = pointer.buttons
            switch profile.base {
            case .compatibility, .hiResWheel:
                let x = pointer.logicalX, y = pointer.logicalY
                return [EncodedReport(reportID: 1, bytes: [buttons, UInt8(x & 0xFF), UInt8(x >> 8),
                                                            UInt8(y & 0xFF), UInt8(y >> 8), 0])]
            case .standard:
                let x = pointer.logicalX, y = pointer.logicalY
                return [EncodedReport(reportID: 2, bytes: [buttons, UInt8(x & 0xFF), UInt8(x >> 8),
                                                            UInt8(y & 0xFF), UInt8(y >> 8)])]
            case .relative:
                let previous = lastPointer ?? pointer
                lastPointer = pointer
                var dx = Int(((pointer.x - previous.x) * Self.relativeCountsPerScreen).rounded())
                var dy = Int(((pointer.y - previous.y) * Self.relativeCountsPerScreen).rounded())
                var reports: [EncodedReport] = []
                repeat {
                    let sx = Self.clamp8(dx), sy = Self.clamp8(dy)
                    reports.append(EncodedReport(reportID: 2, bytes: [buttons, Self.byte(sx), Self.byte(sy), 0, 0]))
                    dx -= sx
                    dy -= sy
                } while dx != 0 || dy != 0
                return reports
            case .touchscreen, .touchpad:
                return []
            }

        case .scroll(let scroll):
            var wheel = scroll.wheel
            var pan = profile.supportsHorizontalScroll ? scroll.pan : 0
            var reports: [EncodedReport] = []
            while wheel != 0 || pan != 0 {
                let w = Self.clamp8(wheel), p = Self.clamp8(pan)
                switch profile.base {
                case .compatibility, .hiResWheel:
                    reports.append(EncodedReport(reportID: 7, bytes: [Self.byte(w)]))
                case .standard:
                    reports.append(EncodedReport(reportID: 3, bytes: [Self.byte(w), Self.byte(p)]))
                case .relative:
                    let buttons = lastPointer?.buttons ?? 0
                    reports.append(EncodedReport(reportID: 2, bytes: [buttons, 0, 0, Self.byte(w), Self.byte(p)]))
                case .touchscreen, .touchpad:
                    break
                }
                wheel -= w
                pan -= p
            }
            return reports

        case .touch(let touch):
            guard profile.hasTouchSurface else { return [] }
            let slots = Array(touch.contacts.prefix(2))
            var bytes: [UInt8] = []
            for index in 0..<2 {
                guard index < slots.count else {
                    bytes += [0, 0, 0, 0, 0, 0]
                    continue
                }
                let contact = slots[index]
                let flags: UInt8
                let x: UInt16, y: UInt16
                if profile.variant == .touchscreen {
                    flags = contact.down ? 0b11 : 0          // tip switch, in range
                    x = PointerReport.logical(contact.x)
                    y = PointerReport.logical(contact.y)
                } else {
                    flags = 0b01 | (contact.down ? 0b10 : 0)  // confidence, tip switch
                    x = UInt16((min(1, max(0, contact.x)) * 4000).rounded())
                    y = UInt16((min(1, max(0, contact.y)) * 2600).rounded())
                }
                bytes += [flags, contact.id & 0x0F, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
            }
            if profile.variant == .touchpad {
                scanTime &+= 100   // 10 ms in 100 µs units
                bytes += [UInt8(scanTime & 0xFF), UInt8(scanTime >> 8)]
            }
            bytes.append(UInt8(slots.count))
            if profile.variant == .touchpad { bytes.append(touch.button ? 1 : 0) }
            return [EncodedReport(reportID: HIDProfile.touchReportID, bytes: bytes)]

        case .consumer(let consumer):
            guard profile.base == .compatibility else {
                let usage = min(consumer.usage, 0x03FF)
                return [EncodedReport(reportID: profile.consumerReportID,
                                      bytes: [UInt8(usage & 0xFF), UInt8(usage >> 8)])]
            }
            // The legacy consumer report splits usages across three array fields.
            var bytes: [UInt8] = [0, 0, 0, 0, 0]
            switch consumer.usage {
            case 0: break
            case 0x0001...0x0174:
                bytes[0] = UInt8(consumer.usage & 0xFF)
                bytes[1] = UInt8(consumer.usage >> 8)
            case 0x0181...0x01CB: bytes[2] = UInt8(consumer.usage - 0x0180)
            case 0x0201...0x02B0: bytes[3] = UInt8(consumer.usage - 0x0200)
            default: return []
            }
            return [EncodedReport(reportID: 6, bytes: bytes)]
        }
    }

    private static func clamp8(_ value: Int) -> Int { max(-127, min(127, value)) }
    private static func byte(_ value: Int) -> UInt8 { UInt8(bitPattern: Int8(clamp8(value))) }
}

// MARK: - Report maps

extension HIDProfile {
    /// Keyboard, battery, system and consumer collections shared verbatim with the
    /// proven layout (report IDs 2–6).
    private static let compatibilityTail: [UInt8] = [
        // Keyboard input (report 2) and LED output (report 3)
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x02,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x75, 0x01, 0x95, 0x08, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x19, 0x00, 0x29, 0xDD, 0x95, 0x06, 0x25, 0xDD, 0x81, 0x00,
        0x85, 0x03, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x95, 0x05, 0x75, 0x01, 0x25, 0x01, 0x91, 0x02,
        0x95, 0x03, 0x91, 0x03,
        0xC0,
        // Battery strength (report 4)
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x04,
        0x05, 0x06, 0x09, 0x20, 0x75, 0x08, 0x95, 0x01, 0x15, 0x00, 0x25, 0x64, 0x81, 0x02,
        0xC0,
        // System control (report 5)
        0x05, 0x01, 0x09, 0x80, 0xA1, 0x01, 0x85, 0x05,
        0x09, 0x81, 0x09, 0x82, 0x09, 0x8E, 0x09, 0xA8, 0x09, 0x8F, 0x09, 0x85, 0x09, 0x86, 0x09, 0xA7,
        0x75, 0x01, 0x95, 0x08, 0x15, 0x00, 0x25, 0x01, 0x81, 0x06,
        0xC0,
        // Consumer control (report 6)
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x06,
        0x19, 0x00, 0x2A, 0x74, 0x01, 0x75, 0x10, 0x95, 0x01, 0x15, 0x00, 0x26, 0x74, 0x01, 0x81, 0x00,
        0x1A, 0x81, 0x01, 0x2A, 0xCB, 0x01, 0x95, 0x01, 0x75, 0x08, 0x15, 0x01, 0x25, 0x4B, 0x81, 0x00,
        0x1A, 0x01, 0x02, 0x2A, 0xB0, 0x02, 0x25, 0xB0, 0x81, 0x00,
        0xA1, 0x03, 0x19, 0x00, 0x29, 0xFF, 0x95, 0x01, 0x75, 0x08, 0x15, 0x00, 0x25, 0xFF, 0x81, 0x00, 0xC0,
        0xC0
    ]

    static let compatibilityMap: [UInt8] = [
        // Mouse (report 1): 3 buttons, absolute X/Y 0…32767, one padding byte
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01,
        0x09, 0x01, 0xA1, 0x00,
        // 8 buttons (the proven layout had 3 plus padding): buttons 4–8 can be
        // assigned iPhone actions such as Home in AssistiveTouch settings.
        0x05, 0x09, 0x19, 0x01, 0x29, 0x08, 0x75, 0x01, 0x95, 0x08, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x75, 0x10, 0x95, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x81, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x03,
        // Vertical wheel in its own report (7) within the same pointer collection
        0x85, 0x07, 0x05, 0x01, 0x09, 0x38, 0x75, 0x08, 0x95, 0x01, 0x15, 0x81, 0x25, 0x7F, 0x81, 0x06,
        0xC0, 0xC0
    ] + compatibilityTail

    /// `compatibilityMap` with the wheel inside a logical collection that also holds a
    /// Resolution Multiplier feature (logical 0…1 = ×1…×16), as high-resolution wheels
    /// describe it. Until the host sets the multiplier the wheel reports whole detents.
    static let hiResWheelMap: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x08, 0x75, 0x01, 0x95, 0x08, 0x15, 0x00, 0x25, 0x01, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x75, 0x10, 0x95, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x7F, 0x81, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x03,
        0x85, 0x07,                                     // Report ID (7)
        0xA1, 0x02,                                     // Collection (Logical)
        0x05, 0x01, 0x09, 0x48,                         //   Usage (Resolution Multiplier)
        0x15, 0x00, 0x25, 0x01, 0x35, 0x01, 0x45, 0x10, //   Logical 0…1, Physical 1…16
        0x75, 0x02, 0x95, 0x01, 0xB1, 0x02,             //   Feature (Data, Variable, Absolute), 2 bits
        0x75, 0x06, 0xB1, 0x03,                         //   Feature padding, 6 bits
        0x35, 0x00, 0x45, 0x00,                         //   Physical range reset
        0x09, 0x38, 0x15, 0x81, 0x25, 0x7F,             //   Usage (Wheel), −127…127
        0x75, 0x08, 0x95, 0x01, 0x81, 0x06,             //   Input (Data, Variable, Relative)
        0xC0,                                           // End Collection (Logical)
        0xC0, 0xC0
    ] + compatibilityTail

    private static let keyboardCollection: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x06,        // Usage (Keyboard)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x01,        //   Report ID (1)
        0x05, 0x07,        //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,        //   Usage Minimum (Left Control)
        0x29, 0xE7,        //   Usage Maximum (Right GUI)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x75, 0x01,        //   Report Size (1)
        0x95, 0x08,        //   Report Count (8)
        0x81, 0x02,        //   Input (Data, Variable, Absolute): modifiers
        0x95, 0x01,        //   Report Count (1)
        0x75, 0x08,        //   Report Size (8)
        0x81, 0x01,        //   Input (Constant): reserved
        0x95, 0x06,        //   Report Count (6)
        0x75, 0x08,        //   Report Size (8)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xDD, 0x00,  //   Logical Maximum (221)
        0x19, 0x00,        //   Usage Minimum (0)
        0x29, 0xDD,        //   Usage Maximum (221)
        0x81, 0x00,        //   Input (Data, Array, Absolute): keys
        0x05, 0x08,        //   Usage Page (LEDs)
        0x19, 0x01,        //   Usage Minimum (Num Lock)
        0x29, 0x05,        //   Usage Maximum (Kana)
        0x15, 0x00,        //   Logical Minimum (0)
        0x25, 0x01,        //   Logical Maximum (1)
        0x95, 0x05,        //   Report Count (5)
        0x75, 0x01,        //   Report Size (1)
        0x91, 0x02,        //   Output (Data, Variable, Absolute): LEDs
        0x95, 0x01,        //   Report Count (1)
        0x75, 0x03,        //   Report Size (3)
        0x91, 0x01,        //   Output (Constant): padding
        0xC0               // End Collection
    ]

    private static let consumerCollection: [UInt8] = [
        0x05, 0x0C,        // Usage Page (Consumer)
        0x09, 0x01,        // Usage (Consumer Control)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x04,        //   Report ID (4)
        0x15, 0x00,        //   Logical Minimum (0)
        0x26, 0xFF, 0x03,  //   Logical Maximum (1023)
        0x19, 0x00,        //   Usage Minimum (0)
        0x2A, 0xFF, 0x03,  //   Usage Maximum (1023)
        0x75, 0x10,        //   Report Size (16)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x00,        //   Input (Data, Array, Absolute)
        0xC0               // End Collection
    ]

    static let standardMap: [UInt8] = keyboardCollection + [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x02,        // Usage (Mouse)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x02,        //   Report ID (2)
        0x09, 0x01,        //   Usage (Pointer)
        0xA1, 0x00,        //   Collection (Physical)
        0x05, 0x09,        //     Usage Page (Button)
        0x19, 0x01,        //     Usage Minimum (1)
        0x29, 0x08,        //     Usage Maximum (8)
        0x15, 0x00,        //     Logical Minimum (0)
        0x25, 0x01,        //     Logical Maximum (1)
        0x95, 0x08,        //     Report Count (8)
        0x75, 0x01,        //     Report Size (1)
        0x81, 0x02,        //     Input (Data, Variable, Absolute): buttons
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x09, 0x31,        //     Usage (Y)
        0x15, 0x00,        //     Logical Minimum (0)
        0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
        0x75, 0x10,        //     Report Size (16)
        0x95, 0x02,        //     Report Count (2)
        0x81, 0x02,        //     Input (Data, Variable, Absolute): X, Y
        0x85, 0x03,        //     Report ID (3)
        0x09, 0x38,        //     Usage (Wheel)
        0x15, 0x81,        //     Logical Minimum (-127)
        0x25, 0x7F,        //     Logical Maximum (127)
        0x75, 0x08,        //     Report Size (8)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x06,        //     Input (Data, Variable, Relative): wheel
        0x05, 0x0C,        //     Usage Page (Consumer)
        0x0A, 0x38, 0x02,  //     Usage (AC Pan)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x06,        //     Input (Data, Variable, Relative): pan
        0xC0,              //   End Collection
        0xC0               // End Collection
    ] + consumerCollection

    /// Two-finger touchscreen digitizer (Digitizers page, Touch Screen), report 5:
    /// per finger [tip|inRange bits, contact id, X, Y (0…32767)], then contact count.
    static let touchscreenCollection: [UInt8] = [
        0x05, 0x0D,        // Usage Page (Digitizers)
        0x09, 0x04,        // Usage (Touch Screen)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x05,        //   Report ID (5)
    ] + touchscreenFinger + touchscreenFinger + [
        0x09, 0x54,        //   Usage (Contact Count)
        0x25, 0x02,        //   Logical Maximum (2)
        0x75, 0x08,        //   Report Size (8)
        0x95, 0x01,        //   Report Count (1)
        0x81, 0x02,        //   Input (Data, Variable, Absolute)
        0xC0               // End Collection
    ]

    private static let touchscreenFinger: [UInt8] = [
        0x09, 0x22,        //   Usage (Finger)
        0xA1, 0x02,        //   Collection (Logical)
        0x09, 0x42,        //     Usage (Tip Switch)
        0x09, 0x32,        //     Usage (In Range)
        0x15, 0x00,        //     Logical Minimum (0)
        0x25, 0x01,        //     Logical Maximum (1)
        0x75, 0x01,        //     Report Size (1)
        0x95, 0x02,        //     Report Count (2)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x95, 0x06,        //     Report Count (6)
        0x81, 0x03,        //     Input (Constant): padding
        0x09, 0x51,        //     Usage (Contact Identifier)
        0x25, 0x0F,        //     Logical Maximum (15)
        0x75, 0x08,        //     Report Size (8)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x09, 0x31,        //     Usage (Y)
        0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
        0x75, 0x10,        //     Report Size (16)
        0x95, 0x02,        //     Report Count (2)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x05, 0x0D,        //     Usage Page (Digitizers)
        0xC0               //   End Collection
    ]

    /// Two-finger precision touchpad (Digitizers page, Touch Pad), report 5:
    /// per finger [confidence|tip bits, contact id, X 0…4000, Y 0…2600 (10 × 6.5 cm)],
    /// then scan time (100 µs units), contact count and the pad's click button.
    static let touchpadCollection: [UInt8] = [
        0x05, 0x0D,        // Usage Page (Digitizers)
        0x09, 0x05,        // Usage (Touch Pad)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x05,        //   Report ID (5)
    ] + touchpadFinger + touchpadFinger + [
        0x09, 0x56,                    //   Usage (Scan Time)
        0x55, 0x0C,                    //   Unit Exponent (-4)
        0x66, 0x01, 0x10,              //   Unit (seconds)
        0x47, 0xFF, 0xFF, 0x00, 0x00,  //   Physical Maximum (65535)
        0x27, 0xFF, 0xFF, 0x00, 0x00,  //   Logical Maximum (65535)
        0x75, 0x10,                    //   Report Size (16)
        0x95, 0x01,                    //   Report Count (1)
        0x81, 0x02,                    //   Input (Data, Variable, Absolute)
        0x55, 0x00, 0x65, 0x00, 0x45, 0x00,  // Unit Exponent 0, no unit, Physical Maximum 0
        0x09, 0x54,                    //   Usage (Contact Count)
        0x25, 0x02,                    //   Logical Maximum (2)
        0x75, 0x08,                    //   Report Size (8)
        0x95, 0x01,                    //   Report Count (1)
        0x81, 0x02,                    //   Input (Data, Variable, Absolute)
        0x05, 0x09,                    //   Usage Page (Button)
        0x09, 0x01,                    //   Usage (Button 1)
        0x25, 0x01,                    //   Logical Maximum (1)
        0x75, 0x01,                    //   Report Size (1)
        0x95, 0x01,                    //   Report Count (1)
        0x81, 0x02,                    //   Input (Data, Variable, Absolute)
        0x95, 0x07,                    //   Report Count (7)
        0x81, 0x03,                    //   Input (Constant): padding
        0xC0                           // End Collection
    ]

    private static let touchpadFinger: [UInt8] = [
        0x09, 0x22,        //   Usage (Finger)
        0xA1, 0x02,        //   Collection (Logical)
        0x09, 0x47,        //     Usage (Confidence)
        0x09, 0x42,        //     Usage (Tip Switch)
        0x15, 0x00,        //     Logical Minimum (0)
        0x25, 0x01,        //     Logical Maximum (1)
        0x75, 0x01,        //     Report Size (1)
        0x95, 0x02,        //     Report Count (2)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x95, 0x06,        //     Report Count (6)
        0x81, 0x03,        //     Input (Constant): padding
        0x09, 0x51,        //     Usage (Contact Identifier)
        0x25, 0x0F,        //     Logical Maximum (15)
        0x75, 0x08,        //     Report Size (8)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x55, 0x0E,        //     Unit Exponent (-2)
        0x65, 0x11,        //     Unit (centimetres)
        0x35, 0x00,        //     Physical Minimum (0)
        0x46, 0xE8, 0x03,  //     Physical Maximum (1000): 10 cm
        0x26, 0xA0, 0x0F,  //     Logical Maximum (4000)
        0x75, 0x10,        //     Report Size (16)
        0x95, 0x01,        //     Report Count (1)
        0x09, 0x30,        //     Usage (X)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x46, 0x8A, 0x02,  //     Physical Maximum (650): 6.5 cm
        0x26, 0x28, 0x0A,  //     Logical Maximum (2600)
        0x09, 0x31,        //     Usage (Y)
        0x81, 0x02,        //     Input (Data, Variable, Absolute)
        0x05, 0x0D,        //     Usage Page (Digitizers)
        0x55, 0x00, 0x65, 0x00, 0x45, 0x00,  // Unit Exponent 0, no unit, Physical Maximum 0
        0xC0               //   End Collection
    ]

    static let relativeMap: [UInt8] = keyboardCollection + [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x02,        // Usage (Mouse)
        0xA1, 0x01,        // Collection (Application)
        0x85, 0x02,        //   Report ID (2)
        0x09, 0x01,        //   Usage (Pointer)
        0xA1, 0x00,        //   Collection (Physical)
        0x05, 0x09,        //     Usage Page (Button)
        0x19, 0x01,        //     Usage Minimum (1)
        0x29, 0x08,        //     Usage Maximum (8)
        0x15, 0x00,        //     Logical Minimum (0)
        0x25, 0x01,        //     Logical Maximum (1)
        0x95, 0x08,        //     Report Count (8)
        0x75, 0x01,        //     Report Size (1)
        0x81, 0x02,        //     Input (Data, Variable, Absolute): buttons
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x09, 0x31,        //     Usage (Y)
        0x09, 0x38,        //     Usage (Wheel)
        0x15, 0x81,        //     Logical Minimum (-127)
        0x25, 0x7F,        //     Logical Maximum (127)
        0x75, 0x08,        //     Report Size (8)
        0x95, 0x03,        //     Report Count (3)
        0x81, 0x06,        //     Input (Data, Variable, Relative): X, Y, wheel
        0x05, 0x0C,        //     Usage Page (Consumer)
        0x0A, 0x38, 0x02,  //     Usage (AC Pan)
        0x95, 0x01,        //     Report Count (1)
        0x81, 0x06,        //     Input (Data, Variable, Relative): pan
        0xC0,              //   End Collection
        0xC0               // End Collection
    ] + consumerCollection
}
