// SPDX-License-Identifier: AGPL-3.0-only

/// A Mac input event, reduced to the facts the session needs. The macOS adapter
/// builds these from CGEvents; tests and the simulator build them directly.
public enum InputEvent: Equatable, Sendable {
    /// Pointer motion, including drags. `delta` is device motion after macOS
    /// acceleration; it keeps reporting movement when the cursor is pinned or clamped.
    case pointerMoved(location: Point, delta: Point)
    case button(MouseButton, down: Bool, location: Point)
    case scroll(ScrollInput)
    /// A non-modifier key. `isRepeat` marks macOS auto-repeat.
    case key(code: UInt16, down: Bool, isRepeat: Bool, modifiers: ModifierFlags)
    /// A modifier key changed (Shift, Control, Option, Command, Caps Lock, Fn).
    case modifierChanged(code: UInt16, modifiers: ModifierFlags)
    case gesture(GestureKind, phase: GesturePhase)
    /// A three- or four-finger swipe the Mac uses for Mission Control and Spaces.
    case dockSwipe(DockSwipe)
    /// A media key on the keyboard's top row (volume, mute, play, track keys).
    case mediaKey(MediaKey, down: Bool, isRepeat: Bool)
    /// Anything else (system-defined media keys, tablet events, …). Always passes.
    case other
}

/// A Mac mouse button by number (0 left, 1 right, 2 middle, 3+ extra buttons).
/// Every button gets ownership tracking; only the first three are forwarded to the
/// phone. (The gestures press higher buttons of their own; see `PhoneAction`.)
public struct MouseButton: Hashable, Sendable, CustomStringConvertible {
    public let number: Int

    public init(number: Int) { self.number = max(0, min(31, number)) }

    public static let left = MouseButton(number: 0)
    public static let right = MouseButton(number: 1)
    public static let middle = MouseButton(number: 2)
    public static let common: [MouseButton] = [.left, .right, .middle, MouseButton(number: 3)]

    var hidBit: UInt8 { number < 8 ? 1 << UInt8(number) : 0 }
    public var description: String { "button \(number)" }
}

/// Scroll phases as reported for trackpad gestures. Mouse wheels have neither.
public enum ScrollPhase: Equatable, Sendable {
    case none, mayBegin, began, changed, ended, cancelled
}

public enum MomentumPhase: Equatable, Sendable {
    case none, began, changed, ended
}

public struct ScrollInput: Equatable, Sendable {
    /// Positive dy reveals content above (macOS convention, after the user's
    /// natural-scrolling preference has been applied).
    public var dx: Double
    public var dy: Double
    /// True for trackpads and Magic Mouse (deltas in points); false for line wheels.
    public var continuous: Bool
    public var phase: ScrollPhase
    public var momentum: MomentumPhase

    public init(dx: Double = 0, dy: Double, continuous: Bool,
                phase: ScrollPhase = .none, momentum: MomentumPhase = .none) {
        self.dx = dx
        self.dy = dy
        self.continuous = continuous
        self.phase = phase
        self.momentum = momentum
    }
}

/// Trackpad gesture families that can trigger Mac system actions (Mission Control,
/// app switching, Launchpad, Look Up, smart zoom).
public enum GestureKind: Equatable, Hashable, Sendable, CaseIterable {
    /// Generic gesture stream; carries Dock swipes (Mission Control, Spaces) when phased.
    case gesture
    case magnify, rotate, swipe
    /// Discrete gestures with no phase: two-finger double tap, three-finger tap.
    case smartMagnify, quickLook
}

public enum MediaKey: Hashable, Sendable, CaseIterable {
    case volumeUp, volumeDown, mute, playPause, next, previous, fastForward, rewind

    /// The Consumer page (0x0C) usage the phone understands for this key.
    public var consumerUsage: UInt16 {
        switch self {
        case .volumeUp: 0x00E9
        case .volumeDown: 0x00EA
        case .mute: 0x00E2
        case .playPause: 0x00CD
        case .next: 0x00B5
        case .previous: 0x00B6
        case .fastForward: 0x00B3
        case .rewind: 0x00B4
        }
    }
}

public struct DockSwipe: Equatable, Sendable {
    public enum Axis: Equatable, Sendable { case horizontal, vertical }

    public var axis: Axis
    /// How far the swipe has travelled; negative is up (vertical) or the
    /// first horizontal direction. About ±0.3 for an ordinary swipe.
    public var progress: Double
    public var phase: GesturePhase

    public init(axis: Axis, progress: Double, phase: GesturePhase) {
        self.axis = axis
        self.progress = progress
        self.phase = phase
    }
}

public enum GesturePhase: Equatable, Sendable {
    case none, mayBegin, began, changed, ended, cancelled
}

/// Modifier state carried by every Mac event, including side-specific bits.
public struct ModifierFlags: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    // Aggregate masks (CGEventFlags).
    public static let capsLock = ModifierFlags(rawValue: 0x0001_0000)
    public static let shift = ModifierFlags(rawValue: 0x0002_0000)
    public static let control = ModifierFlags(rawValue: 0x0004_0000)
    public static let option = ModifierFlags(rawValue: 0x0008_0000)
    public static let command = ModifierFlags(rawValue: 0x0010_0000)
    public static let function = ModifierFlags(rawValue: 0x0080_0000)

    // Device-dependent side bits (IOKit IOLLEvent.h NX_DEVICE*KEYMASK).
    public static let leftControl = ModifierFlags(rawValue: 0x0000_0001)
    public static let leftShift = ModifierFlags(rawValue: 0x0000_0002)
    public static let rightShift = ModifierFlags(rawValue: 0x0000_0004)
    public static let leftCommand = ModifierFlags(rawValue: 0x0000_0008)
    public static let rightCommand = ModifierFlags(rawValue: 0x0000_0010)
    public static let leftOption = ModifierFlags(rawValue: 0x0000_0020)
    public static let rightOption = ModifierFlags(rawValue: 0x0000_0040)
    public static let rightControl = ModifierFlags(rawValue: 0x0000_2000)

    public static let sideSpecific: ModifierFlags = [
        .leftControl, .rightControl, .leftShift, .rightShift,
        .leftOption, .rightOption, .leftCommand, .rightCommand
    ]
}
