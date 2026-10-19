// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Darwin
import Foundation
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

    var currentLocation: Point? {
        CGEvent(source: nil).map { Point(x: $0.location.x, y: $0.location.y) }
    }

    func hide() {
        if !hidden { hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success }
        lastCheck = 0
        reportedReappearance = false
    }

    /// macOS can show the cursor again while MacHop has it hidden: switching Spaces or
    /// full-screen apps hands the cursor to the newly active app (Ben, 12 Oct 2026: "two
    /// mice moving"). Checked at most ten times a second; each extra hide is counted so
    /// `show` stays balanced.
    func keepHidden() {
        guard hidden, let isVisible = Self.isVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck >= 0.1 else { return }
        lastCheck = now
        guard isVisible() != 0 else { return }
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { extraHides += 1 }
        if !reportedReappearance {
            reportedReappearance = true
            Log.input.notice("The Mac cursor reappeared while the iPhone had input; hid it again")
        }
    }

    /// Hides the cursor once more while the phone has input, without asking whether it
    /// is visible: called when switching Spaces or apps, which can show it again. The
    /// extra hide is counted, so `show` stays balanced.
    func reassertHidden() {
        guard hidden, CGDisplayHideCursor(CGMainDisplayID()) == .success else { return }
        extraHides += 1
    }

    private var lastCheck = 0.0
    private var extraHides = 0
    private var reportedReappearance = false

    /// CGCursorIsVisible: unavailable to Swift by name, but still provided by macOS.
    private static let isVisible: (@convention(c) () -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()

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
            for _ in 0...extraHides { CGDisplayShowCursor(CGMainDisplayID()) }
            // Never leave the Mac without a cursor, whatever macOS did to the count.
            var tries = 0
            while let isVisible = Self.isVisible, isVisible() == 0, tries < 5 {
                CGDisplayShowCursor(CGMainDisplayID())
                tries += 1
            }
            hidden = false
            extraHides = 0
        }
    }
}

/// macOS only lets the frontmost app hide the cursor. A menu-bar utility is never
/// frontmost, so it sets the private WindowServer connection property
/// "SetsCursorInBackground" on its own connection, as keyboard-and-mouse sharing
/// tools do. It is not a public API: it can change in future macOS releases and rules out the Mac App
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
