// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Darwin
import MacHopCore

/// The real Mac cursor, hidden while the phone owns input.
///
/// macOS moves the cursor before an event tap sees an event, so the hidden cursor
/// still travels with the phone's pointer. The session moves it back to the middle
/// of the display before it can reach the Dock or a hot corner.
final class SystemCursor: CursorControl {
    private var hidden = false
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    init() {
        BackgroundCursorPermission.enable()
    }

    func hide() {
        if !hidden { hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success }
    }

    /// Relocates the cursor with a posted move, like a real mouse. A warp
    /// (CGWarpMouseCursorPosition) makes macOS ignore mouse movement for about
    /// 0.25 s, even with re-association; on macOS 26 that froze the cursor after a
    /// quick return (trace, 12 Oct 2026). The posted event reports no movement of its own.
    func move(to point: Point) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: point.x, y: point.y), mouseButton: .left) else {
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
            CGAssociateMouseAndMouseCursorPosition(1)
            return
        }
        event.flags = []
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        event.post(tap: .cghidEventTap)
    }

    func show(at point: Point?) {
        if let point { move(to: point) }
        if hidden {
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
    }
}

/// macOS only lets the frontmost app hide the cursor. A menu-bar utility is never
/// frontmost, so it sets the private WindowServer connection property
/// "SetsCursorInBackground" on its own connection. This is the same technique
/// used by Barrier/Deskflow-style keyboard-and-mouse sharing tools. It is not a
/// public API: it can change in future macOS releases and rules out the Mac App
/// Store. Symbols are looked up at runtime, so a missing symbol only means the
/// cursor stays visible.
enum BackgroundCursorPermission {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private(set) static var isEnabled = false

    static func enable() {
        guard !isEnabled else { return }
        for path in ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                     "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"] {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
                  let setterSymbol = dlsym(handle, "CGSSetConnectionProperty") else { continue }
            let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)()
            let setter = unsafeBitCast(setterSymbol, to: SetProperty.self)
            isEnabled = setter(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
            if isEnabled { return }
        }
        Log.input.notice("Background cursor hiding is unavailable; the Mac cursor may stay visible")
    }
}
