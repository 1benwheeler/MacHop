// SPDX-License-Identifier: AGPL-3.0-only
import MacHopCore

/// A deterministic clock: deferred work runs only when the test advances time.
@MainActor
public final class ManualScheduler: Scheduler {
    public private(set) var now: Double = 0
    private var tasks: [(time: Double, order: Int, action: @MainActor () -> Void)] = []
    private var order = 0

    public init() {}

    public func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        tasks.append((now + max(0, delay), order, action))
        order += 1
    }

    public func advance(by seconds: Double) {
        let end = now + max(0, seconds)
        while let index = tasks.indices.min(by: { (tasks[$0].time, tasks[$0].order) < (tasks[$1].time, tasks[$1].order) }),
              tasks[index].time <= end {
            let task = tasks.remove(at: index)
            now = max(now, task.time)
            task.action()
        }
        now = end
    }

    public var pendingTasks: Int { tasks.count }
}

/// A BLE link with a small transmit queue drained once per connection event,
/// delivering notifications to a `VirtualPhone`.
@MainActor
public final class SimulatedRadio: NotificationSink {
    public let phone: VirtualPhone
    public weak var transport: HIDTransport?
    /// Notifications the radio accepts before refusing (CoreBluetooth's queue).
    public var capacity = 8
    /// Notifications delivered per connection event.
    public var perEvent = 4
    public var connectionInterval = 0.015
    /// When true the radio accepts nothing and never drains (a dead link).
    public var isJammed = false

    public private(set) var delivered = 0
    public private(set) var refused = 0
    public private(set) var deliveryLog: [(time: Double, reportID: UInt8, bytes: [UInt8])] = []
    private var buffer: [(reportID: UInt8, bytes: [UInt8], queuedAt: Double)] = []
    private var eventScheduled = false
    private var owesReadyCallback = false
    private let scheduler: ManualScheduler
    public private(set) var maximumLatency = 0.0

    public init(phone: VirtualPhone, scheduler: ManualScheduler) {
        self.phone = phone
        self.scheduler = scheduler
    }

    public func submit(_ bytes: [UInt8], reportID: UInt8) -> Bool {
        guard !isJammed, buffer.count < capacity else {
            refused += 1
            owesReadyCallback = !isJammed || owesReadyCallback
            return false
        }
        buffer.append((reportID, bytes, scheduler.now))
        scheduleEvent()
        return true
    }

    private func scheduleEvent() {
        guard !eventScheduled else { return }
        eventScheduled = true
        scheduler.after(connectionInterval) { [weak self] in self?.connectionEvent() }
    }

    private func connectionEvent() {
        eventScheduled = false
        guard !isJammed else { return }
        for _ in 0..<min(perEvent, buffer.count) {
            let next = buffer.removeFirst()
            maximumLatency = max(maximumLatency, scheduler.now - next.queuedAt)
            deliveryLog.append((scheduler.now, next.reportID, next.bytes))
            phone.receive(reportID: next.reportID, bytes: next.bytes)
            delivered += 1
        }
        if owesReadyCallback && buffer.count < capacity {
            owesReadyCallback = false
            transport?.radioIsReady()
        }
        if !buffer.isEmpty { scheduleEvent() }
    }

    /// The phone disappears: in-flight notifications are lost.
    public func disconnect() {
        buffer.removeAll()
        owesReadyCallback = false
        transport?.reset()
    }

    /// The phone (re)connects and subscribes to every input report.
    public func connect() {
        guard let transport else { return }
        for id in transport.profile.inputReportIDs { transport.subscribed(id) }
    }
}

/// The Mac cursor as the session sees it: moved by the "hardware", clamped to the
/// displays, hidden and pinned while parked.
///
/// Like macOS, a warp's distance is not lost: it is added to the delta of the
/// next reported pointer event (observed on the real Mac, 12 Oct 2026).
@MainActor
public final class VirtualCursor: CursorControl {
    public private(set) var location: Point
    public private(set) var isHidden = false
    public private(set) var warps = 0
    public var displays: [Display]
    private var unreportedWarp = Point.zero

    public init(location: Point, displays: [Display]) {
        self.location = location
        self.displays = displays
    }

    public func hide() { isHidden = true }

    /// How often the session asked the cursor to stay hidden.
    public private(set) var keepHiddenRequests = 0
    public func keepHidden() { keepHiddenRequests += 1 }

    public func move(to point: Point) { warp(to: point) }

    public func show(at point: Point?) {
        isHidden = false
        if let point { warp(to: point) }
    }

    private func warp(to point: Point) {
        unreportedWarp = Point(x: unreportedWarp.x + point.x - location.x, y: unreportedWarp.y + point.y - location.y)
        location = point
        warps += 1
    }

    /// The delta macOS reports for a device movement: the movement plus any warp
    /// since the previous event.
    public func reportedDelta(for movement: Point) -> Point {
        defer { unreportedWarp = .zero }
        return Point(x: movement.x + unreportedWarp.x, y: movement.y + unreportedWarp.y)
    }

    /// Moves the cursor as the window server would: onto any display containing the
    /// destination, otherwise clamped to the display the cursor is on.
    public func hardwareMove(by delta: Point) -> Point {
        let target = Point(x: location.x + delta.x, y: location.y + delta.y)
        if displays.contains(where: { $0.frame.contains(target) }) {
            location = target
        } else if let current = displays.first(where: { $0.frame.contains(location) }) ?? displays.first {
            let f = current.frame
            location = Point(x: min(max(target.x, f.minX), f.maxX - 1), y: min(max(target.y, f.minY), f.maxY - 1))
        }
        return location
    }
}

/// A complete simulated setup: the production `InputSession` and `HIDTransport`
/// connected through a simulated radio to a virtual iPhone, driven by a virtual
/// Mac user. Every event the session lets through is recorded as reaching the Mac.
@MainActor
public final class Simulation {
    public let scheduler = ManualScheduler()
    public let phone: VirtualPhone
    public let radio: SimulatedRadio
    public let transport: HIDTransport
    public let cursor: VirtualCursor
    public let session: InputSession
    public private(set) var displays: [Display]
    /// Events delivered to macOS (the session returned `.pass`).
    public private(set) var macEvents: [InputEvent] = []
    public private(set) var ownerChanges: [(Owner, ReturnReason?)] = []
    public private(set) var macKeysDown: Set<UInt16> = []
    public private(set) var macButtonsDown: Set<MouseButton> = []
    /// Keys and buttons the user is physically holding.
    public private(set) var heldKeys: Set<UInt16> = []
    public private(set) var heldButtons: Set<MouseButton> = []
    public private(set) var flags: ModifierFlags = []

    public init(profile: HIDProfile = .compatibility, settings: SessionSettings? = nil,
                displays: [Display] = [Display(id: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982))],
                phoneScreen: (width: Double, height: Double) = (393, 852)) {
        self.displays = displays
        phone = try! VirtualPhone(reportMap: profile.reportMap, screen: phoneScreen)
        radio = SimulatedRadio(phone: phone, scheduler: scheduler)
        transport = HIDTransport(profile: profile, scheduler: scheduler)
        transport.sink = radio
        radio.transport = transport
        let main = displays[0].frame
        cursor = VirtualCursor(location: Point(x: main.x + main.width / 2, y: main.y + main.height / 2),
                               displays: displays)
        let scheduler = self.scheduler
        session = InputSession(settings: settings ?? SessionSettings(layout: PhoneLayout(displayID: displays[0].id)),
                               displays: displays, link: transport, cursor: cursor, clock: { scheduler.now })
        session.onOwnerChange = { [weak self] owner, reason in self?.ownerChanges.append((owner, reason)) }
        session.schedule = { delay, action in scheduler.after(delay, action) }
        transport.onReadyChange = { [weak self] ready in
            self?.session.setEnabled(ready, reason: ready ? "" : "iPhone disconnected")
        }
        transport.onStall = { [weak self] in self?.session.setEnabled(false, reason: "Bluetooth stalled") }
        radio.connect()
        settle()
    }

    // MARK: Low-level input

    @discardableResult
    public func deliver(_ event: InputEvent) -> Disposition {
        let disposition = session.handle(event)
        if disposition == .pass {
            macEvents.append(event)
            switch event {
            case let .key(code, down, _, _):
                if down { macKeysDown.insert(code) } else { macKeysDown.remove(code) }
            case let .modifierChanged(code, modifiers):
                if let held = KeyMap.heldFlag(forKeyCode: code), modifiers.contains(held) { macKeysDown.insert(code) }
                else { macKeysDown.remove(code) }
            case let .button(button, down, _):
                if down { macButtonsDown.insert(button) } else { macButtonsDown.remove(button) }
            default: break
            }
        }
        return disposition
    }

    public func settle(_ seconds: Double = 0.1) { scheduler.advance(by: seconds) }

    // MARK: User actions

    /// Moves the physical pointer, split into steps of at most `step` points.
    /// With `stopOnOwnerChange`, the movement ends as soon as input changes hands.
    public func move(dx: Double, dy: Double, step: Double = 8, interval: Double = 0.008,
                     stopOnOwnerChange: Bool = false) {
        let count = max(1, Int((max(abs(dx), abs(dy)) / step).rounded(.up)))
        let startOwner = session.owner
        for _ in 0..<count {
            if stopOnOwnerChange && session.owner != startOwner { break }
            let delta = Point(x: dx / Double(count), y: dy / Double(count))
            let location = cursor.hardwareMove(by: delta)
            deliver(.pointerMoved(location: location, delta: cursor.reportedDelta(for: delta)))
            scheduler.advance(by: interval)
        }
    }

    /// Moves the pointer onto the phone through its edge, and returns whether the phone took input.
    @discardableResult
    public func crossToPhone(atFraction fraction: Double = 0.5) -> Bool {
        guard let link = session.screenLink else { return false }
        let span = link.openSpans[0]
        let along = span.lowerBound + (span.upperBound - span.lowerBound) * fraction
        let start = Point(along: along, across: link.edgeLine, side: link.side).offset(outward: -40, through: link.side)
        // Arrive near the edge from the interior, then push outward through it.
        move(dx: start.x - cursor.location.x, dy: start.y - cursor.location.y, step: 40)
        let push = Point.zero.offset(outward: 80, through: link.side)
        move(dx: push.x, dy: push.y, step: 4, stopOnOwnerChange: true)
        return session.owner == .phone
    }

    /// Moves the phone pointer back through the edge facing the Mac.
    @discardableResult
    public func returnToMac() -> Bool {
        guard let link = session.screenLink, session.owner == .phone else { return session.owner == .mac }
        let back = Point.zero.offset(outward: -(link.phoneDepth + 60), through: link.side)
        move(dx: back.x, dy: back.y, step: 6, stopOnOwnerChange: true)
        return session.owner == .mac
    }

    public func click(_ button: MouseButton = .left, hold: Double = 0.05) {
        buttonDown(button)
        settle(hold)
        buttonUp(button)
        settle(0.03)
    }

    @discardableResult
    public func buttonDown(_ button: MouseButton) -> Disposition {
        heldButtons.insert(button)
        return deliver(.button(button, down: true, location: cursor.location))
    }

    @discardableResult
    public func buttonUp(_ button: MouseButton) -> Disposition {
        heldButtons.remove(button)
        return deliver(.button(button, down: false, location: cursor.location))
    }

    public func pressModifier(_ code: UInt16) {
        guard let held = KeyMap.heldFlag(forKeyCode: code), let aggregate = KeyMap.aggregateFlag(forKeyCode: code) else { return }
        heldKeys.insert(code)
        flags.formUnion([held, aggregate])
        deliver(.modifierChanged(code: code, modifiers: flags))
    }

    public func releaseModifier(_ code: UInt16) {
        guard let held = KeyMap.heldFlag(forKeyCode: code), let aggregate = KeyMap.aggregateFlag(forKeyCode: code) else { return }
        heldKeys.remove(code)
        flags.remove(held)
        let sameKind = heldKeys.contains { KeyMap.aggregateFlag(forKeyCode: $0) == aggregate }
        if !sameKind { flags.remove(aggregate) }
        deliver(.modifierChanged(code: code, modifiers: flags))
    }

    @discardableResult
    public func keyDown(_ code: UInt16, isRepeat: Bool = false) -> Disposition {
        heldKeys.insert(code)
        return deliver(.key(code: code, down: true, isRepeat: isRepeat, modifiers: flags))
    }

    @discardableResult
    public func keyUp(_ code: UInt16) -> Disposition {
        heldKeys.remove(code)
        return deliver(.key(code: code, down: false, isRepeat: false, modifiers: flags))
    }

    /// Types US-layout text with realistic key timing.
    public func type(_ text: String, interval: Double = 0.03) {
        for character in text {
            guard let stroke = KeyMap.keystroke(for: character), let code = Self.keyCode(forUsage: stroke.usage) else {
                continue
            }
            if stroke.shift { pressModifier(56) }
            keyDown(code)
            settle(interval / 2)
            keyUp(code)
            if stroke.shift { releaseModifier(56) }
            settle(interval / 2)
        }
    }

    /// A two-finger trackpad scroll: began, changes, ended, then optional momentum.
    public func trackpadScroll(dy: Double, dx: Double = 0, steps: Int = 10, momentumSteps: Int = 0) {
        let perStep = (dx / Double(max(steps, 1)), dy / Double(max(steps, 1)))
        deliver(.scroll(ScrollInput(dx: 0, dy: 0, continuous: true, phase: .mayBegin)))
        for index in 0..<steps {
            let phase: ScrollPhase = index == 0 ? .began : .changed
            deliver(.scroll(ScrollInput(dx: perStep.0, dy: perStep.1, continuous: true, phase: phase)))
            settle(0.012)
        }
        deliver(.scroll(ScrollInput(dx: 0, dy: 0, continuous: true, phase: .ended)))
        for index in 0..<momentumSteps {
            let momentum: MomentumPhase = index == 0 ? .began : index == momentumSteps - 1 ? .ended : .changed
            let decay = pow(0.85, Double(index))
            deliver(.scroll(ScrollInput(dx: perStep.0 * decay, dy: perStep.1 * decay, continuous: true, momentum: momentum)))
            settle(0.016)
        }
    }

    /// A mouse-wheel notch (line-based, no phases).
    public func wheel(lines: Double) {
        deliver(.scroll(ScrollInput(dy: lines, continuous: false)))
    }

    /// A phased trackpad gesture such as a three-finger swipe (Mission Control).
    public func gesture(_ kind: GestureKind, steps: Int = 8) {
        deliver(.gesture(kind, phase: .began))
        for _ in 0..<steps {
            deliver(.gesture(kind, phase: .changed))
            settle(0.012)
        }
        deliver(.gesture(kind, phase: .ended))
    }

    @discardableResult
    public func mediaKey(_ key: MediaKey, down: Bool, isRepeat: Bool = false) -> Disposition {
        deliver(.mediaKey(key, down: down, isRepeat: isRepeat))
    }

    /// A three-finger swipe as macOS reports it (values from a real trackpad trace):
    /// progress grows to `to` over about 80 ms; `hold` rests the fingers before lifting.
    public func dockSwipe(_ axis: DockSwipe.Axis, to progress: Double, hold: Double = 0) {
        deliver(.dockSwipe(DockSwipe(axis: axis, progress: progress * 0.03, phase: .began)))
        for step in 1...8 {
            settle(0.010)
            deliver(.dockSwipe(DockSwipe(axis: axis, progress: progress * Double(step) / 8, phase: .changed)))
        }
        settle(hold + 0.01)
        deliver(.dockSwipe(DockSwipe(axis: axis, progress: progress, phase: .ended)))
        settle(0.1)
    }

    public func replaceDisplays(_ newDisplays: [Display]) {
        displays = newDisplays
        cursor.displays = newDisplays
        session.configure(settings: session.settings, displays: newDisplays)
    }

    private nonisolated static let reverseKeyMap: [UInt8: UInt16] = {
        var map: [UInt8: UInt16] = [:]
        for code in UInt16(0)...127 {
            if let usage = KeyMap.usage(forKeyCode: code), map[usage] == nil { map[usage] = code }
        }
        return map
    }()

    public nonisolated static func keyCode(forUsage usage: UInt8) -> UInt16? { reverseKeyMap[usage] }
}

private func pow(_ base: Double, _ exponent: Double) -> Double {
    var result = 1.0
    for _ in 0..<Int(exponent) { result *= base }
    return result
}
