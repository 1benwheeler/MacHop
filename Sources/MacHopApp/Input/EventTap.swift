// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MacHopCore

/// An active Quartz event tap at the head of the session's event stream.
///
/// Every keyboard, pointer, scroll and gesture event passes through `decide`,
/// which returns whether the Mac may see it. Requires Accessibility permission.
/// The tap runs on the main run loop, so the callback must stay fast (it does:
/// about a microsecond for routing plus one CoreBluetooth call).
final class EventTap {
    /// Returns what to do with an event; set by the app model.
    var decide: ((InputEvent) -> Disposition)?
    /// Rewrites modifier flags on events that reach the Mac (nil = unchanged).
    var visibleModifiers: ((ModifierFlags) -> ModifierFlags)?
    /// Diagnostics: log the raw values macOS attaches to trackpad gesture events.
    var traceGestures = false
    private var gestureTraceCount = 0
    private var lastTracedPhase: Int64 = -1

    /// macOS disabled the tap (timeout or user input). Events during the gap went
    /// straight to the Mac, so held-key bookkeeping must be repaired. The flag says
    /// whether the tap could be re-enabled.
    var onInterrupted: ((_ reason: BlockReason, _ revived: Bool) -> Void)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false

    /// Whether macOS will let MacHop capture input right now. `AXIsProcessTrusted` alone
    /// can go on saying yes after the permission is turned off in a running app (reported
    /// by developers, 2023 to 2026), and an event tap left running then can stop all
    /// keyboard and mouse input. So while it says yes, MacHop also checks that it could
    /// still create a tap.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() && canCreateTap() }

    private static var lastProbe: (time: Double, allowed: Bool)?

    /// Creates a tap for an event that doesn't occur (a graphics tablet's pen coming into
    /// range) and removes it at once; macOS refuses to create one without the permission.
    /// Never called unless `AXIsProcessTrusted` says yes, so it can't raise a permission
    /// prompt. The answer is reused for half a second.
    private static func canCreateTap() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let lastProbe, now - lastProbe.time < 0.5 { return lastProbe.allowed }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.tabletProximity.rawValue)
        let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                     userInfo: nil)
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        lastProbe = (now, port != nil)
        return port != nil
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard Self.accessibilityGranted else { return false }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: InputEvent.tapMask,
                                           callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.input.error("Could not create the event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        isRunning = true
        Log.input.notice("Input capture started")
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
        isRunning = false
        Log.input.notice("Input capture stopped")
    }

    /// Checks that macOS has not silently disabled the tap.
    var isHealthy: Bool { isRunning && port.map { CGEvent.tapIsEnabled(tap: $0) } == true }

    /// Returns true when the event must be swallowed.
    fileprivate func shouldSuppress(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A slow callback (timeout) is usually recoverable: re-enable at once.
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            let reason: BlockReason = type == .tapDisabledByTimeout ? .captureTimedOut : .captureDisabled
            Log.input.notice("Event tap was disabled by macOS (\(type.rawValue)); re-enabled: \(self.isHealthy)")
            onInterrupted?(reason, isHealthy)
            return false
        }
        guard let decide else { return false }
        if traceGestures, [18, 29, 30, 31].contains(type.rawValue) { traceGesture(event, type: type.rawValue) }
        let input = InputEvent(event, type: type)
        if case .other = input { return false }
        switch decide(input) {
        case .suppress:
            return true
        case .pass:
            if let visibleModifiers {
                let flags = ModifierFlags(rawValue: event.flags.rawValue)
                let visible = visibleModifiers(flags)
                if visible != flags { event.flags = CGEventFlags(rawValue: visible.rawValue) }
            }
            return false
        }
    }

    /// Gesture fields (undocumented CGEvent field numbers, as used by gesture tools):
    /// 110 HID event type (23 = Dock swipe, 6 = zoom), 132 phase, 123 swipe motion,
    /// 124 swipe progress, 125/126 position, 129/130 velocity, 134 swipe mask.
    private func traceGesture(_ event: CGEvent, type: UInt32) {
        func int(_ field: UInt32) -> Int64 { CGEventField(rawValue: field).map { event.getIntegerValueField($0) } ?? 0 }
        func dbl(_ field: UInt32) -> Double { CGEventField(rawValue: field).map { event.getDoubleValueField($0) } ?? 0 }
        let phase = int(132)
        gestureTraceCount += 1
        // Every phase change, plus every eighth event in between.
        guard phase != lastTracedPhase || gestureTraceCount % 8 == 0 else { return }
        lastTracedPhase = phase
        let appKit = NSEvent(cgEvent: event).map { "\($0.type.rawValue)/phase \($0.phase.rawValue)" } ?? "-"
        Log.input.notice("""
            gesture type \(type) hid \(int(110)) phase \(phase) motion \(int(123)) mask \(int(134))             progress \(dbl(124), format: .fixed(precision: 3)) pos (\(dbl(125), format: .fixed(precision: 2)),             \(dbl(126), format: .fixed(precision: 2))) vel (\(dbl(129), format: .fixed(precision: 1)),             \(dbl(130), format: .fixed(precision: 1))) appkit \(appKit, privacy: .public)
            """)
    }

    /// Keys and buttons physically held right now, from the HID system's state.
    static func physicallyHeld() -> (keys: Set<UInt16>, buttons: Set<MouseButton>) {
        let keys = Set((UInt16(0)...127).filter { CGEventSource.keyState(.hidSystemState, key: $0) })
        let buttons = Set((0..<5).compactMap { number -> MouseButton? in
            guard let button = CGMouseButton(rawValue: UInt32(number)) else { return nil }
            return CGEventSource.buttonState(.hidSystemState, button: button) ? MouseButton(number: number) : nil
        })
        return (keys, buttons)
    }
}

/// C callback: the tap's run-loop source is on the main run loop.
private nonisolated func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                          userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let tapPointer = userInfo else { return Unmanaged.passUnretained(event) }
    // The event and tap object are only touched on the main thread, synchronously.
    nonisolated(unsafe) let event = event
    nonisolated(unsafe) let pointer = tapPointer
    let suppress = MainActor.assumeIsolated {
        Unmanaged<EventTap>.fromOpaque(pointer).takeUnretainedValue().shouldSuppress(type: type, event: event)
    }
    return suppress ? nil : Unmanaged.passUnretained(event)
}
