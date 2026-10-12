// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MacHopCore

/// CGEvent type numbers for trackpad gestures. CoreGraphics has no public names
/// for these; the values are AppKit's `NSEvent.EventType` raw values, which share
/// the CGEvent numbering. Type 30 also carries Dock swipes (Mission Control,
/// Spaces, Launchpad) in addition to pinch magnification.
enum GestureEventType {
    static let rotate: UInt32 = 18
    static let gesture: UInt32 = 29
    static let magnifyOrDock: UInt32 = 30
    static let swipe: UInt32 = 31
    static let smartMagnify: UInt32 = 32
    static let quickLook: UInt32 = 33
}

extension InputEvent {
    /// Event types the tap listens to.
    static let tappedTypes: [UInt32] = [
        CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged
    ].map(\.rawValue) + [systemDefined, GestureEventType.rotate, GestureEventType.gesture, GestureEventType.magnifyOrDock,
                         GestureEventType.swipe, GestureEventType.smartMagnify, GestureEventType.quickLook]

    /// NX_SYSDEFINED: carries the media keys (volume, mute, play, track keys).
    static let systemDefined: UInt32 = 14

    static var tapMask: CGEventMask { tappedTypes.reduce(0) { $0 | (1 << CGEventMask($1)) } }

    /// Reduces a CGEvent to what the session needs. Returns `.other` for events
    /// the session should always pass through.
    init(_ event: CGEvent, type: CGEventType) {
        let location = Point(x: event.location.x, y: event.location.y)
        let modifiers = ModifierFlags(rawValue: event.flags.rawValue)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let delta = Point(x: event.getDoubleValueField(.mouseEventDeltaX),
                              y: event.getDoubleValueField(.mouseEventDeltaY))
            self = .pointerMoved(location: location, delta: delta)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let number = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            self = .button(MouseButton(number: number), down: down, location: location)
        case .keyDown, .keyUp:
            self = .key(code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                        down: type == .keyDown,
                        isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        modifiers: modifiers)
        case .flagsChanged:
            self = .modifierChanged(code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                                    modifiers: modifiers)
        case .scrollWheel:
            self = .scroll(Self.scroll(from: event))
        default:
            if type.rawValue == Self.systemDefined {
                self = Self.mediaKey(from: event) ?? .other
            } else {
                self = Self.gesture(from: event, rawType: type.rawValue) ?? .other
            }
        }
    }

    private static func scroll(from event: CGEvent) -> ScrollInput {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let dx: Double, dy: Double
        if continuous {
            // AppKit exposes the fractional point deltas trackpads produce.
            if let precise = NSEvent(cgEvent: event) {
                dx = precise.scrollingDeltaX
                dy = precise.scrollingDeltaY
            } else {
                dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
                dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            }
        } else {
            dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        }
        let phase: ScrollPhase = switch event.getIntegerValueField(.scrollWheelEventScrollPhase) {
        case Int64(CGScrollPhase.began.rawValue): .began
        case Int64(CGScrollPhase.changed.rawValue): .changed
        case Int64(CGScrollPhase.ended.rawValue): .ended
        case Int64(CGScrollPhase.cancelled.rawValue): .cancelled
        case Int64(CGScrollPhase.mayBegin.rawValue): .mayBegin
        default: .none
        }
        // kCGMomentumScrollPhaseBegin/Continue/End.
        let momentum: MomentumPhase = switch event.getIntegerValueField(.scrollWheelEventMomentumPhase) {
        case 1: .began
        case 2: .changed
        case 3: .ended
        default: .none
        }
        return ScrollInput(dx: dx, dy: dy, continuous: continuous, phase: phase, momentum: momentum)
    }

    /// Media keys arrive as auxiliary control buttons (subtype 8): the key code is in
    /// the top half of data1, its state (0x0A down, 0x0B up) and repeat bit in the bottom.
    private static func mediaKey(from event: CGEvent) -> InputEvent? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let flags = ns.data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0x0A || state == 0x0B else { return nil }
        let key: MediaKey
        switch code {
        case 0: key = .volumeUp        // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown      // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute            // NX_KEYTYPE_MUTE
        case 16: key = .playPause      // NX_KEYTYPE_PLAY
        case 17: key = .next           // NX_KEYTYPE_NEXT
        case 18: key = .previous       // NX_KEYTYPE_PREVIOUS
        case 19: key = .fastForward    // NX_KEYTYPE_FAST
        case 20: key = .rewind         // NX_KEYTYPE_REWIND
        default: return nil            // brightness and the rest stay with the Mac
        }
        return .mediaKey(key, down: state == 0x0A, isRepeat: flags & 0x1 != 0)
    }

    private static func gesture(from event: CGEvent, rawType: UInt32) -> InputEvent? {
        // Dock swipes (Mission Control, Spaces) carry their axis and progress in
        // undocumented fields: 110 = HID event type (23 for a Dock swipe),
        // 123 = axis (1 horizontal, 2 vertical), 124 = progress.
        if rawType == GestureEventType.magnifyOrDock,
           let typeField = CGEventField(rawValue: 110), event.getIntegerValueField(typeField) == 23,
           let axisField = CGEventField(rawValue: 123), let progressField = CGEventField(rawValue: 124) {
            let axis: DockSwipe.Axis = event.getIntegerValueField(axisField) == 1 ? .horizontal : .vertical
            return .dockSwipe(DockSwipe(axis: axis, progress: event.getDoubleValueField(progressField),
                                        phase: phase(of: event)))
        }
        let kind: GestureKind
        switch rawType {
        case GestureEventType.gesture: kind = .gesture
        case GestureEventType.magnifyOrDock: kind = .magnify
        case GestureEventType.rotate: kind = .rotate
        case GestureEventType.swipe: kind = .swipe
        case GestureEventType.smartMagnify: return .gesture(.smartMagnify, phase: .none)
        case GestureEventType.quickLook: return .gesture(.quickLook, phase: .none)
        default: return nil
        }
        return .gesture(kind, phase: phase(of: event))
    }

    /// Gesture phases are only exposed through AppKit's conversion.
    private static func phase(of event: CGEvent) -> GesturePhase {
        let phase = NSEvent(cgEvent: event)?.phase ?? []
        return phase.contains(.mayBegin) ? .mayBegin :
            phase.contains(.began) ? .began :
            phase.contains(.ended) ? .ended :
            phase.contains(.cancelled) ? .cancelled :
            phase.contains(.changed) || phase.contains(.stationary) ? .changed : .none
    }
}
