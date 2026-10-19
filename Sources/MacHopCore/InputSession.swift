// SPDX-License-Identifier: AGPL-3.0-only

/// Sends HID reports to the phone. Implemented by the Bluetooth transport and,
/// in tests, by a simulated link feeding a virtual iPhone.
@MainActor
public protocol HIDLink: AnyObject {
    /// True when the phone is subscribed and accepting input.
    var isReady: Bool { get }
    /// False for a relative pointer, whose position on the phone is only an estimate.
    var pointerIsAbsolute: Bool { get }
    func send(_ report: HIDReport)
}

public extension HIDLink {
    var pointerIsAbsolute: Bool { true }
}

/// Controls the Mac cursor. Implemented with CoreGraphics in the app.
@MainActor
public protocol CursorControl: AnyObject {
    /// Hide the cursor while the phone owns input.
    func hide()
    /// Called as the pointer moves on the phone: hide the cursor again if macOS has
    /// shown it (for example after switching Spaces), so two pointers never move at once.
    func keepHidden()
    /// Move the (hidden) cursor without it counting as pointer movement.
    func move(to point: Point)
    /// Show the cursor again, moving it to `point` first when given.
    func show(at point: Point?)
    /// Where the cursor is now, if known.
    var currentLocation: Point? { get }
}

public enum Owner: Equatable, Sendable {
    case mac, phone
}

public enum Disposition: Equatable, Sendable {
    /// Deliver the event to the Mac unchanged.
    case pass
    /// Swallow the event: it went to the phone, or belongs to nobody.
    case suppress
}

public enum ReturnReason: Equatable, Sendable {
    case edge
    case shortcut
    case requested
    case unavailable(String)
    case reconfigured
}

public struct SessionSettings: Equatable, Hashable, Sendable, Codable {
    public var layout: PhoneLayout
    public var scroll: ScrollSettings
    /// Points of outward push needed to cross an edge, in either direction.
    public var edgeResistance: Double
    /// Three-finger swipes press extra pointer buttons that AssistiveTouch maps
    /// to iPhone actions (Home, App Switcher, Notification Centre).
    public var phoneGestures: Bool
    /// How fast the pointer moves on the phone; 1 is the original feel.
    public var pointerSpeed: Double
    /// Volume, mute and media keys control the phone while it has input.
    public var mediaKeysToPhone: Bool

    public static let resistanceRange: ClosedRange<Double> = 0...60
    public static let pointerSpeedRange: ClosedRange<Double> = 0.4...2.5

    public init(layout: PhoneLayout, scroll: ScrollSettings = ScrollSettings(), edgeResistance: Double = 6,
                phoneGestures: Bool = true, pointerSpeed: Double = 1, mediaKeysToPhone: Bool = false) {
        self.layout = layout
        self.scroll = scroll
        self.edgeResistance = edgeResistance
        self.phoneGestures = phoneGestures
        self.pointerSpeed = pointerSpeed
        self.mediaKeysToPhone = mediaKeysToPhone
    }

    private enum CodingKeys: String, CodingKey {
        case layout, scroll, edgeResistance, phoneGestures, pointerSpeed, mediaKeysToPhone
    }

    /// Settings saved before newer fields existed decode with their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = try container.decode(PhoneLayout.self, forKey: .layout)
        scroll = try container.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? ScrollSettings()
        edgeResistance = try container.decodeIfPresent(Double.self, forKey: .edgeResistance) ?? 6
        phoneGestures = try container.decodeIfPresent(Bool.self, forKey: .phoneGestures) ?? true
        pointerSpeed = try container.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? 1
        mediaKeysToPhone = try container.decodeIfPresent(Bool.self, forKey: .mediaKeysToPhone) ?? false
    }

    public func sanitized() -> SessionSettings {
        var copy = self
        copy.layout = layout.sanitized()
        copy.scroll = scroll.sanitized()
        copy.edgeResistance = edgeResistance.isFinite
            ? min(Self.resistanceRange.upperBound, max(Self.resistanceRange.lowerBound, edgeResistance)) : 6
        copy.pointerSpeed = pointerSpeed.isFinite
            ? min(Self.pointerSpeedRange.upperBound, max(Self.pointerSpeedRange.lowerBound, pointerSpeed)) : 1
        return copy
    }
}

/// Decides, event by event, whether input belongs to the Mac or the phone.
///
/// Ownership is tracked per key, per mouse button, per scroll gesture and per
/// trackpad gesture, so a press always has its release delivered to the same
/// side. That single rule is what prevents stuck keys, stuck buttons, and
/// gesture tails (Mission Control, momentum) leaking across the edge.
@MainActor
public final class InputSession {
    public private(set) var owner: Owner = .mac
    public private(set) var settings: SessionSettings
    public private(set) var screenLink: ScreenLink?
    /// The phone pointer, in phone-local Mac points (0…width, 0…height).
    public private(set) var phonePointer: Point?
    /// Set when the session may hand input to the phone (capture healthy, not paused…).
    public private(set) var isEnabled = false
    public private(set) var disabledReason = "Starting"

    /// Called after every ownership change.
    public var onOwnerChange: ((Owner, ReturnReason?) -> Void)?
    /// Consulted just before the phone takes input; a non-nil reason refuses the
    /// crossing (for example while macOS Secure Input protects a password field).
    public var entryGuard: (() -> String?)?
    /// Each two-finger scroll event sent to the phone as wheel steps, for diagnosing feel
    /// (amounts and phases only).
    public var onScrollTrace: ((ScrollInput, ScrollReport) -> Void)?
    /// Pointer presses on the phone and home-indicator decisions, for the same purpose.
    public var onPhoneTrace: ((String) -> Void)?

    /// Called when `entryGuard` refused a crossing.
    public var onEntryRefused: ((String) -> Void)?
    /// Set while the only thing keeping input off the phone is that it's asleep (it
    /// suspended input) and the user lets MacHop wake it.
    public var mayWakePhone = false
    /// Wakes the phone: called when you push into its edge or press ⌃⌥⌘I while it sleeps.
    public var onWakePhone: (() -> Void)?
    /// ⌃⌥⌘I was pressed but input can't go to the phone (and it can't be woken).
    public var onJumpUnavailable: (() -> Void)?
    /// Runs work later on the main actor; used to release a drag-scroll whose
    /// end never arrived. Without it, strokes end only on the next event.
    public var schedule: ((Double, @escaping @MainActor () -> Void) -> Void)?

    private let link: HIDLink
    private let cursor: CursorControl
    private let clock: () -> Double

    private enum Holder { case mac, phone, swallowed }
    private var keyHolders: [UInt16: Holder] = [:]
    private var buttonHolders: [MouseButton: Holder] = [:]
    private var mediaHolders: [MediaKey: Holder] = [:]
    private var gestureHolders: [GestureKind: Owner] = [:]
    private var scroller: TouchScroller?
    private var strokeGeneration = 0
    /// A drag-scroll with no scroll input for this long is released.
    public static let strokeTimeout = 0.35
    private var scrollHolder: Owner?
    private var scrollTentative = false
    private var tentativeGestures: Set<GestureKind> = []

    private var crossingPressure = 0.0
    private var lastMacLocation: Point?
    /// Last known Mac cursor location, from events and our own cursor moves.
    private var lastLocation: Point?
    private var pendingJump: (offset: Point, eventsLeft: Int)?
    private var returnPressure = 0.0
    private var crossingAllowedAfter = 0.0
    private var wakeAllowedAfter = 0.0
    /// After ⌃⌥⌘I woke the phone: jump as soon as it accepts input, until this time.
    private var jumpWhenReadyUntil: Double?
    /// Where the Mac cursor was when ⌃⌥⌘I jumped to the phone; a shortcut return puts it back.
    private var jumpOrigin: Point?
    private var scroll = ScrollConverter()
    private var keyboard = KeyboardReport.released
    private var phoneButtons: UInt8 = 0

    /// Time after a return before the pointer may cross again, so jitter at the
    /// edge cannot bounce input straight back. Short, so fast deliberate flicks back
    /// and forth aren't held at the edge (0.25 s did that; trace, 12 Oct 2026); edge
    /// resistance and the carried flick keep real bounces out.
    public static let crossingCooldown = 0.08
    /// After ⌃⌥⌘⎋ or any return not made through the edge: a longer hold-off, and the
    /// cursor lands this far inside the screen.
    public static let exitCooldown = 0.6
    static let exitInset = 40.0
    /// Pushing on while a woken phone comes on doesn't wake it again this soon.
    public static let wakeInterval = 2.0
    /// How long after ⌃⌥⌘I wakes the phone it may still jump there once it's on.
    public static let jumpWakeWindow = 3.0

    public init(settings: SessionSettings, displays: [Display], link: HIDLink, cursor: CursorControl,
                clock: @escaping () -> Double) {
        self.settings = settings.sanitized()
        self.link = link
        self.cursor = cursor
        self.clock = clock
        self.screenLink = ScreenLink(layout: self.settings.layout, displays: displays)
    }

    // MARK: Configuration and availability

    public func configure(settings: SessionSettings, displays: [Display]) {
        returnToMac(.reconfigured)
        self.settings = settings.sanitized()
        screenLink = ScreenLink(layout: self.settings.layout, displays: displays)
        crossingPressure = 0
    }

    /// Enables or disables handing input to the phone. Disabling while the phone
    /// owns input returns control to the Mac immediately.
    public func setEnabled(_ enabled: Bool, reason: String = "") {
        isEnabled = enabled
        disabledReason = enabled ? "" : reason
        if !enabled { returnToMac(.unavailable(reason)) }
        if let until = jumpWhenReadyUntil, enabled, link.isReady {
            jumpWhenReadyUntil = nil
            if clock() <= until { jumpToPhone() }
        }
    }

    /// Modifier flags the Mac should see on events it receives. Modifiers held
    /// down for the phone (or swallowed) are removed so a click on the Mac is not
    /// turned into a Command-click by a key the Mac never saw pressed.
    public func macVisibleModifiers(_ flags: ModifierFlags) -> ModifierFlags {
        var visible = flags
        var hiddenAggregates: ModifierFlags = []
        for (code, holder) in keyHolders where holder != .mac {
            guard let held = KeyMap.heldFlag(forKeyCode: code),
                  let aggregate = KeyMap.aggregateFlag(forKeyCode: code) else { continue }
            visible.remove(held)
            hiddenAggregates.insert(aggregate)
        }
        // Keep an aggregate flag only if the Mac still has a key of that kind held.
        for (code, holder) in keyHolders where holder == .mac {
            if let aggregate = KeyMap.aggregateFlag(forKeyCode: code) { hiddenAggregates.remove(aggregate) }
        }
        visible.subtract(hiddenAggregates)
        return visible
    }

    /// True if any key or button is held on behalf of the phone.
    public var phoneHoldsInput: Bool {
        keyHolders.values.contains(.phone) || buttonHolders.values.contains(.phone)
    }

    // MARK: Events

    public func handle(_ event: InputEvent) -> Disposition {
        switch event {
        case let .pointerMoved(location, delta):
            return pointerMoved(location: location, delta: delta)
        case let .button(button, down, _):
            return buttonChanged(button, down: down)
        case let .scroll(input):
            return scrolled(input)
        case let .key(code, down, isRepeat, modifiers):
            return keyChanged(code: code, down: down, isRepeat: isRepeat, modifiers: modifiers)
        case let .modifierChanged(code, modifiers):
            return modifierChanged(code: code, modifiers: modifiers)
        case let .gesture(kind, phase):
            return gesture(kind, phase: phase)
        case let .mediaKey(key, down, isRepeat):
            return mediaKeyChanged(key, down: down, isRepeat: isRepeat)
        case let .dockSwipe(swipe):
            // Ownership as for any phased gesture; on the phone it can become an action.
            let disposition = gesture(.magnify, phase: swipe.phase)
            if disposition == .suppress && owner == .phone { trackPhoneSwipe(swipe) }
            return disposition
        case .other:
            return .pass
        }
    }

    /// Returns input to the Mac, releasing everything held on the phone.
    public func returnToMac(_ reason: ReturnReason, cursorAt point: Point? = nil) {
        guard owner == .phone else { return }
        finishStroke()
        homeIndicatorPress = nil
        owner = .mac
        for (code, holder) in keyHolders where holder == .phone { keyHolders[code] = .swallowed }
        for (button, holder) in buttonHolders where holder == .phone { buttonHolders[button] = .swallowed }
        var mediaHeld = false
        for (key, holder) in mediaHolders where holder == .phone {
            mediaHolders[key] = .swallowed
            mediaHeld = true
        }
        if mediaHeld { link.send(.consumer(.released)) }
        keyboard = .released
        phoneButtons = 0
        link.send(.keyboard(.released))
        // Release any button where it is, and leave the pointer there: iOS fades it
        // after about 15 s without movement (nothing a Bluetooth pointer sends hides it sooner).
        if let pointer = phonePointer { link.send(.pointer(pointerReport(at: pointer))) }
        // A shortcut return after jumping with ⌃⌥⌘I puts the cursor back where it was.
        let jumpedFrom = reason == .shortcut ? jumpOrigin : nil
        jumpOrigin = nil
        var destination = point ?? jumpedFrom ?? phonePointer.flatMap { pointer in
            screenLink.map { $0.returnPoint(phoneAlong: pointer.along($0.side)) }
        }
        // A return the user didn't make by pushing through the edge (⌃⌥⌘⎋, Bluetooth
        // dropping, …) lands a little inside the screen and holds off re-entry for
        // longer, so a hand still moving towards the phone can't carry input straight back.
        let deliberateExit = reason != .edge
        if deliberateExit, point == nil, jumpedFrom == nil, let link = screenLink, let landing = destination {
            destination = landing.offset(outward: -Self.exitInset, through: link.side)
        }
        phonePointer = nil
        crossingPressure = 0
        returnPressure = 0
        crossingAllowedAfter = clock() + (deliberateExit ? Self.exitCooldown : Self.crossingCooldown)
        if let destination, let from = lastLocation { expectJump(from: from, to: destination) }
        lastMacLocation = destination
        lastLocation = destination ?? lastLocation
        scroll.reset()
        cursor.show(at: destination)
        onOwnerChange?(.mac, reason)
    }

    /// Hands input to the phone as if the pointer had crossed at Mac position `position`
    /// along the shared edge (a y beside the screen, an x above it). `carry` is hand
    /// movement past the crossing point (Mac points, inward), applied on the phone so a
    /// fast flick keeps going instead of stopping at the edge.
    /// Used by edge crossing and by automation.
    @discardableResult
    public func enterPhone(atEdge position: Double, carry: Double = 0) -> Bool {
        guard owner == .mac, isEnabled, link.isReady, let screenLink, !entryRefused() else { return false }
        let side = screenLink.side
        let inset = min(2, screenLink.phoneDepth / 4)
        // Moving deeper into the phone is outward through the Mac's edge.
        let inward = min(max(0, carry) * pointerScale, screenLink.phoneDepth / 2)
        let entry = screenLink.entryPoint(macAlong: position, inset: inset).offset(outward: inward, through: side)
        takeInput(at: entry, cursorFrom: Point(along: position, across: screenLink.edgeLine, side: side))
        return true
    }

    /// ⌃⌥⌘I: hands input to the phone without crossing an edge, with its pointer in the
    /// middle of the screen. The same keys, or ⌃⌥⌘⎋, put the cursor back where it was.
    @discardableResult
    public func jumpToPhone() -> Bool {
        guard owner == .mac, isEnabled, link.isReady, let screenLink, !entryRefused() else { return false }
        let display = screenLink.display
        let origin = cursor.currentLocation ?? lastLocation
        let from = origin ?? Point(x: display.minX + display.width / 2, y: display.midY)
        jumpOrigin = origin
        takeInput(at: Point(x: screenLink.phone.width / 2, y: screenLink.phone.height / 2), cursorFrom: from)
        return true
    }

    /// Asks `entryGuard`; a refusal is reported and holds off crossing for a moment.
    private func entryRefused() -> Bool {
        guard let refusal = entryGuard?() else { return false }
        crossingPressure = 0
        crossingAllowedAfter = clock() + Self.crossingCooldown
        onEntryRefused?(refusal)
        return true
    }

    private func takeInput(at entry: Point, cursorFrom location: Point) {
        guard let screenLink else { return }
        owner = .phone
        phonePointer = entry
        crossingPressure = 0
        returnPressure = 0
        scroll.reset()
        phoneButtons = 0
        cursor.hide()
        recentre(from: location, within: screenLink.display)
        link.send(.pointer(pointerReport(at: entry)))
        onOwnerChange?(.phone, nil)
    }

    /// ⌃⌥⌘I from the Mac: jump to the phone, or wake it and jump once it's on.
    public func jumpOrWake() {
        if isEnabled && link.isReady {
            jumpToPhone()
        } else if mayWakePhone {
            jumpWhenReadyUntil = clock() + Self.jumpWakeWindow
            wakePhone()
        } else {
            onJumpUnavailable?()
        }
    }

    private func wakePhone() {
        guard clock() >= wakeAllowedAfter else { return }
        wakeAllowedAfter = clock() + Self.wakeInterval
        onWakePhone?()
    }

    private func pointerMoved(location: Point, delta rawDelta: Point) -> Disposition {
        guard location.isFinite, rawDelta.isFinite else { return owner == .phone ? .suppress : .pass }
        let delta = compensated(rawDelta)
        lastLocation = location
        switch owner {
        case .mac:
            if let carry = crossing(location: location, delta: delta), let side = screenLink?.side {
                return enterPhone(atEdge: location.along(side), carry: carry) ? .suppress : .pass
            }
            return .pass
        case .phone:
            // A zero-movement event (such as MacHop's own move of the hidden cursor)
            // moves nothing, and must not end a drag-scroll in progress.
            guard delta != .zero else { return .suppress }
            finishStroke()
            cursor.keepHidden()
            movePhonePointer(by: delta)
            // The hidden cursor moves with the phone pointer. Before it can reach a
            // screen edge (Dock, hot corners), put it back in the middle.
            if owner == .phone, let screenLink {
                let safe = screenLink.display
                let margin = Self.recentreMargin
                if location.x < safe.minX + margin || location.x > safe.maxX - margin ||
                    location.y < safe.minY + margin || location.y > safe.maxY - margin {
                    recentre(from: location, within: safe)
                }
            }
            return .suppress
        }
    }

    /// How close the hidden cursor may get to a screen edge while the phone has input.
    public static let recentreMargin = 80.0

    private func recentre(from location: Point, within display: Rect) {
        let centre = Point(x: display.minX + display.width / 2, y: display.midY)
        cursor.move(to: centre)
        expectJump(from: location, to: centre)
        lastLocation = centre
    }

    /// macOS adds a cursor jump (warp) to the delta of a following pointer event.
    /// Remember the jump so it can be taken back out of that event, instead of
    /// being read as the user moving the pointer.
    private func expectJump(from: Point, to: Point) {
        let offset = Point(x: to.x - from.x, y: to.y - from.y)
        // Small jumps can't be told apart from real movement, and barely matter.
        pendingJump = max(abs(offset.x), abs(offset.y)) >= 100 ? (offset, 4) : nil
    }

    private func compensated(_ delta: Point) -> Point {
        guard var pending = pendingJump else { return delta }
        let jump = pending.offset
        // Real movement folded in with the jump can be large during a fast flick, but
        // stays well below the jump itself (at least 100 points, usually several hundred).
        let tolerance = max(60, 0.35 * max(abs(jump.x), abs(jump.y)))
        if abs(delta.x - jump.x) < tolerance && abs(delta.y - jump.y) < tolerance {
            pendingJump = nil
            return Point(x: delta.x - jump.x, y: delta.y - jump.y)
        }
        pending.eventsLeft -= 1
        pendingJump = pending.eventsLeft > 0 ? pending : nil
        return delta
    }

    /// Phone-local points per Mac point: the speed setting, independent of the phone's size.
    private var pointerScale: Double { settings.pointerSpeed * settings.layout.size / PhoneLayout.referenceSize }

    /// Hand movement beyond the edge's resistance (Mac points) when this motion
    /// crosses onto the phone, or nil when it does not cross.
    private func crossing(location: Point, delta: Point) -> Double? {
        let previous = lastMacLocation ?? Point(x: location.x - delta.x, y: location.y - delta.y)
        lastMacLocation = location
        let available = isEnabled && link.isReady
        guard available || mayWakePhone, let screenLink, clock() >= crossingAllowedAfter,
              !buttonHolders.values.contains(.mac) else {
            crossingPressure = 0
            return nil
        }
        let side = screenLink.side, line = screenLink.edgeLine
        let push = delta.across(side) * side.outward
        // Only motion that would have carried the cursor past the edge counts as a
        // push, so a fast move that merely lands on the edge does not cross.
        let beyond = (previous.across(side) + delta.across(side) - line) * side.outward
        var outward = min(push, max(0, beyond))
        let across = location.across(side), bounds = screenLink.display.across(side)
        let atEdge = side.outward > 0
            ? across >= line - 0.5 && across < bounds.max + 0.5
            : across <= line + 0.5 && across > bounds.min - 1.5
        let along = location.along(side), edge = screenLink.display.along(side)
        guard atEdge, screenLink.isOpen(along: along), along >= edge.min, along < edge.max else {
            crossingPressure = 0
            return nil
        }
        if push < 0 { crossingPressure = 0 }
        // The menu bar and the Dock are targets people fling the pointer at, so at the top
        // and bottom edges the movement that arrives there doesn't count: only pushing on
        // once there does.
        if side.isHorizontal, abs(previous.across(side) - line) > 0.5 { outward = 0 }
        guard outward > 0, !Self.slidesAlongEdge(delta, side: side) else { return nil }
        crossingPressure += outward
        let needed = max(0.5, settings.edgeResistance, side.isHorizontal ? Self.menuBarResistance : 0)
        guard crossingPressure >= needed else { return nil }
        guard available else {
            // The phone is asleep: this push wakes it, and pushing on crosses once it's on.
            crossingPressure = 0
            wakePhone()
            return nil
        }
        return crossingPressure - needed
    }

    /// The least push that crosses the top or bottom edge, whatever the resistance
    /// setting: the menu bar and the Dock are there, and reaching for them shouldn't
    /// land on the iPhone.
    public static let menuBarResistance = 18.0

    /// Motion that is mostly along an edge slides along it instead of pushing
    /// through it, so drifting outward while moving along the edge never crosses.
    static func slidesAlongEdge(_ delta: Point, side: Side) -> Bool {
        abs(delta.along(side)) > 2 * abs(delta.across(side))
    }

    private func movePhonePointer(by macDelta: Point) {
        guard let screenLink, var pointer = phonePointer else { return }
        let side = screenLink.side, scale = pointerScale
        let delta = Point(x: macDelta.x * scale, y: macDelta.y * scale)
        let raw = Point(x: pointer.x + delta.x, y: pointer.y + delta.y)
        pointer = Point(x: min(max(raw.x, 0), screenLink.phone.width), y: min(max(raw.y, 0), screenLink.phone.height))
        // Overshoot past the edge that faces the Mac builds return pressure.
        let towardMac = -delta.across(side) * side.outward
        let overshoot = side.outward > 0 ? max(0, -raw.across(side)) : max(0, raw.across(side) - screenLink.phoneDepth)
        if towardMac < 0 { returnPressure = 0 }
        // Pressure is counted in hand movement (Mac points), so resistance feels the same at any speed.
        if overshoot > 0, !Self.slidesAlongEdge(delta, side: side) { returnPressure += overshoot / max(scale, 0.01) }
        phonePointer = pointer
        followHomeIndicatorPress(to: pointer)
        let holdingButton = buttonHolders.values.contains(.phone)
        let needed = max(0.5, settings.edgeResistance)
        if overshoot > 0, !holdingButton, returnPressure >= needed {
            // Carry the movement past the resistance onto the Mac, as on the way in.
            let inward = min(returnPressure - needed, screenLink.displayDepth / 4)
            let destination = screenLink.returnPoint(phoneAlong: pointer.along(side)).offset(outward: -inward, through: side)
            returnToMac(.edge, cursorAt: destination)
            return
        }
        link.send(.pointer(pointerReport(at: pointer)))
    }

    private func pointerReport(at pointer: Point, buttons: UInt8? = nil) -> PointerReport {
        let size = screenLink.map { ($0.phone.width, $0.phone.height) } ?? (1, 1)
        let screen = settings.layout.screenFraction(x: pointer.x / max(size.0, 1), y: pointer.y / max(size.1, 1))
        return PointerReport(buttons: buttons ?? phoneButtons, x: screen.x, y: screen.y)
    }

    // MARK: The home indicator

    /// A left press that began on the iPhone's home indicator, held back. With wheel
    /// scrolling, a pointer drag there would start iOS's Home gesture, and afterwards
    /// AssistiveTouch ignores the wheel until the iPhone forgets MacHop (measured on an
    /// iPhone 15 Pro, iOS 26). So dragged up, it becomes the Home key instead; released
    /// in place, it's an ordinary click; dragged sideways (switching apps), it carries on
    /// as a real drag.
    private var homeIndicatorPress: (start: Point, wentHome: Bool)?
    /// How close to the bottom of the iPhone's screen counts as the home indicator.
    public static let homeIndicatorZone = 0.035
    /// How far up (or sideways), as a share of the screen's height, decides the drag.
    public static let homeSwipeDistance = 0.04

    /// A point on the phone as a fraction of the iPhone's own (upright portrait) screen.
    private func screenFraction(_ point: Point) -> (x: Double, y: Double) {
        guard let screenLink else { return (0.5, 0.5) }
        return settings.layout.screenFraction(x: point.x / max(screenLink.phone.width, 1),
                                              y: point.y / max(screenLink.phone.height, 1))
    }

    private func pressesHomeIndicator(_ button: MouseButton) -> Bool {
        guard settings.scroll.style == .wheel, button == .left, phoneButtons == 0, let pointer = phonePointer else { return false }
        return screenFraction(pointer).y >= 1 - Self.homeIndicatorZone
    }

    /// Follows a held-back home-indicator press as the pointer moves.
    private func followHomeIndicatorPress(to pointer: Point) {
        guard let press = homeIndicatorPress, !press.wentHome else { return }
        let start = screenFraction(press.start), now = screenFraction(pointer)
        if start.y - now.y >= Self.homeSwipeDistance {
            homeIndicatorPress?.wentHome = true
            onPhoneTrace?("home indicator swipe: sent the Home key")
            pressHomeKey()
        } else if abs(now.x - start.x) >= Self.homeSwipeDistance * 1.5 {
            // Switching apps along the bottom: press where it started and carry on.
            onPhoneTrace?("home indicator: sideways, carried on as a drag")
            homeIndicatorPress = nil
            phoneButtons |= MouseButton.left.hidBit
            link.send(.pointer(pointerReport(at: press.start)))
        }
    }

    private func buttonChanged(_ button: MouseButton, down: Bool) -> Disposition {
        finishStroke()
        if owner == .phone, let pointer = phonePointer {
            let at = screenFraction(pointer)
            onPhoneTrace?("button \(button) \(down ? "down" : "up") at \(Int(at.x * 100))%, \(Int(at.y * 100))% of the screen")
        }
        if down, owner == .phone, pressesHomeIndicator(button), let pointer = phonePointer {
            buttonHolders[button] = .phone
            homeIndicatorPress = (pointer, false)
            return .suppress
        }
        if !down, button == .left, buttonHolders[button] == .phone, let press = homeIndicatorPress {
            buttonHolders.removeValue(forKey: button)
            homeIndicatorPress = nil
            if !press.wentHome {
                // Released in place: an ordinary click where it was pressed.
                link.send(.pointer(pointerReport(at: press.start, buttons: phoneButtons | MouseButton.left.hidBit)))
                let release = { [weak self] in
                    guard let self else { return }
                    self.link.send(.pointer(self.pointerReport(at: press.start, buttons: self.phoneButtons)))
                }
                if let schedule { schedule(0.05) { release() } } else { release() }
            }
            return .suppress
        }
        if down {
            let holder: Holder = owner == .phone ? .phone : .mac
            buttonHolders[button] = holder
            guard holder == .phone else { return .pass }
            phoneButtons |= button.hidBit
            sendPointerState()
            return .suppress
        }
        let holder = buttonHolders.removeValue(forKey: button)
        switch holder {
        case .phone:
            phoneButtons &= ~button.hidBit
            sendPointerState()
            return .suppress
        case .swallowed:
            return .suppress
        case .mac, nil:
            return .pass
        }
    }

    private func sendPointerState() {
        guard owner == .phone, let pointer = phonePointer else { return }
        link.send(.pointer(pointerReport(at: pointer)))
    }

    private func keyChanged(code: UInt16, down: Bool, isRepeat: Bool, modifiers: ModifierFlags) -> Disposition {
        if down {
            if isRepeat {
                // Auto-repeat follows the original press. The phone repeats held keys
                // itself, and a Mac key must not keep repeating once the phone has input.
                let holder = keyHolders[code] ?? .mac
                return holder == .mac && owner == .mac ? .pass : .suppress
            }
            if keyHolders[code] == .phone && owner == .phone { return .suppress }
            if owner == .phone && isEmergencyShortcut(code: code, modifiers: modifiers) {
                keyHolders[code] = .swallowed
                returnToMac(.shortcut)
                return .suppress
            }
            if isJumpShortcut(code: code, modifiers: modifiers), screenLink != nil {
                keyHolders[code] = .swallowed
                if owner == .phone { returnToMac(.shortcut) } else { jumpOrWake() }
                return .suppress
            }
            // A fresh press replaces any stale record left by a missed release.
            guard owner == .phone else {
                keyHolders[code] = .mac
                return .pass
            }
            keyHolders[code] = .phone
            if let usage = KeyMap.usage(forKeyCode: code) { pressKey(usage) }
            return .suppress
        }
        switch keyHolders.removeValue(forKey: code) {
        case .phone:
            if let usage = KeyMap.usage(forKeyCode: code) { releaseKey(usage) }
            return .suppress
        case .swallowed:
            return .suppress
        case .mac, nil:
            return .pass
        }
    }

    private func modifierChanged(code: UInt16, modifiers: ModifierFlags) -> Disposition {
        if code == KeyMap.capsLockKeyCode {
            // Caps Lock arrives as a toggle, not a press/release pair.
            guard owner == .phone else { return .pass }
            pressKey(KeyMap.capsLockUsage)
            releaseKey(KeyMap.capsLockUsage)
            return .suppress
        }
        guard let aggregate = KeyMap.aggregateFlag(forKeyCode: code),
              let held = KeyMap.heldFlag(forKeyCode: code) else { return owner == .phone ? .suppress : .pass }
        let current = keyHolders[code]
        // Prefer the side-specific bit; synthetic events may only carry the aggregate.
        let isDown: Bool
        if modifiers.contains(held) { isDown = true }
        else if !modifiers.contains(aggregate) { isDown = false }
        else if !modifiers.isDisjoint(with: .sideSpecific) { isDown = false }
        else { isDown = current == nil }

        if isDown {
            if let current { return current == .mac ? .pass : .suppress }
            guard owner == .phone else {
                keyHolders[code] = .mac
                return .pass
            }
            keyHolders[code] = .phone
            if let bit = KeyMap.modifierBit(forKeyCode: code) {
                keyboard.modifiers |= bit
                link.send(.keyboard(keyboard))
            }
            return .suppress
        }
        switch keyHolders.removeValue(forKey: code) {
        case .phone:
            if let bit = KeyMap.modifierBit(forKeyCode: code) {
                keyboard.modifiers &= ~bit
                link.send(.keyboard(keyboard))
            }
            return .suppress
        case .swallowed:
            return .suppress
        case .mac, nil:
            return .pass
        }
    }

    private func pressKey(_ usage: UInt8) {
        guard !keyboard.keys.contains(usage) else { return }
        // Six-key rollover: a seventh simultaneous key is dropped rather than
        // reported as an error state the phone might misinterpret.
        guard keyboard.keys.count < 6 else { return }
        keyboard.keys.append(usage)
        link.send(.keyboard(keyboard))
    }

    private func releaseKey(_ usage: UInt8) {
        guard let index = keyboard.keys.firstIndex(of: usage) else { return }
        keyboard.keys.remove(at: index)
        link.send(.keyboard(keyboard))
    }

    /// Media keys follow the same rule as keys: a release goes where the press went.
    /// They reach the phone only when the user chose that; otherwise they stay with the Mac.
    private func mediaKeyChanged(_ key: MediaKey, down: Bool, isRepeat: Bool) -> Disposition {
        if down {
            if isRepeat { return (mediaHolders[key] ?? .mac) == .mac ? .pass : .suppress }
            guard owner == .phone, settings.mediaKeysToPhone else {
                mediaHolders[key] = .mac
                return .pass
            }
            mediaHolders[key] = .phone
            link.send(.consumer(ConsumerReport(usage: key.consumerUsage)))
            return .suppress
        }
        switch mediaHolders.removeValue(forKey: key) {
        case .phone:
            link.send(.consumer(.released))
            return .suppress
        case .swallowed:
            return .suppress
        case .mac, nil:
            return .pass
        }
    }

    /// Control-Option-Command-Escape.
    private func isEmergencyShortcut(code: UInt16, modifiers: ModifierFlags) -> Bool {
        code == KeyMap.escapeKeyCode && modifiers.isSuperset(of: [.control, .option, .command])
    }

    private func isJumpShortcut(code: UInt16, modifiers: ModifierFlags) -> Bool {
        code == KeyMap.jumpKeyCode && modifiers.isSuperset(of: [.control, .option, .command])
            && !modifiers.contains(.shift)
    }

    private func scrolled(_ input: ScrollInput) -> Disposition {
        // A trackpad gesture belongs to whoever owned input when it started; its
        // momentum stays with it. A mayBegin (fingers down) and the began that
        // follows are one gesture, even if ownership changed in between.
        switch input.phase {
        case .mayBegin:
            scrollHolder = owner
            scrollTentative = true
        case .began:
            if !scrollTentative { scrollHolder = owner }
            scrollTentative = false
        case .ended, .cancelled:
            // Fingers lifted (or a two-finger click cancelled the touch): the next
            // began starts a new gesture with whoever owns input then.
            scrollTentative = false
        default:
            break
        }
        let isWheel = input.phase == .none && input.momentum == .none
        // A stream whose start was never seen belongs to the Mac, so the phone
        // never receives a stray tail.
        let streamOwner = isWheel ? owner : (scrollHolder ?? .mac)
        guard streamOwner == owner else { return .suppress }
        guard owner == .phone else { return .pass }
        if settings.scroll.style == .off { return .suppress }
        if settings.scroll.style == .drag, input.continuous, !isWheel, phoneButtons == 0 {
            dragScroll(input)
            return .suppress
        }
        let report = scroll.convert(input, settings: settings.scroll)
        if !report.isZero { link.send(.scroll(report)) }
        onScrollTrace?(input, report)
        return .suppress
    }

    // MARK: Drag scrolling

    private func dragScroll(_ input: ScrollInput) {
        // iOS adds its own momentum when the drag is released mid-motion.
        guard input.momentum == .none else { return }
        switch input.phase {
        case .ended, .cancelled:
            finishStroke()
            return
        case .began:
            finishStroke()
        case .mayBegin, .none, .changed:
            break
        }
        guard input.phase != .mayBegin, let pointer = phonePointer, let screenLink else { return }
        if scroller == nil {
            scroller = TouchScroller(anchor: pointer, phoneSize: (screenLink.phone.width, screenLink.phone.height))
        }
        let scale = settings.scroll.speed * (settings.scroll.reversed ? -1 : 1)
        // Natural scrolling: the content (and so the touch) follows the fingers.
        let delta = Point(x: settings.scroll.horizontal ? input.dx * scale : 0, y: input.dy * scale)
        perform(scroller?.scroll(by: delta, at: clock()) ?? [])
        strokeGeneration += 1
        let generation = strokeGeneration
        schedule?(Self.strokeTimeout) { [weak self] in
            guard let self, self.strokeGeneration == generation else { return }
            self.finishStroke()
        }
    }

    /// Releases any drag-scroll in progress. Like a click-and-hold drag, the
    /// pointer stays where the drag left it.
    private func finishStroke() {
        guard var current = scroller else { return }
        scroller = nil
        strokeGeneration += 1
        perform(current.finish())
        phonePointer = current.endPoint
    }

    private func perform(_ actions: [TouchScroller.Action]) {
        guard screenLink != nil else { return }
        for action in actions {
            let (point, buttons): (Point, UInt8) = switch action {
            case .press(let p), .move(let p): (p, phoneButtons | MouseButton.left.hidBit)
            case .release(let p), .hop(let p): (p, phoneButtons)
            }
            link.send(.pointer(pointerReport(at: point, buttons: buttons)))
        }
    }

    // MARK: iPhone gestures

    /// The pointer buttons that gestures press. Assign them in iPhone Settings →
    /// Accessibility → Touch → AssistiveTouch → Devices.
    /// Home is the Menu key, which iPhone treats as its Home button (no setup). The
    /// others press extra pointer buttons that the user assigns once in AssistiveTouch.
    public enum PhoneAction: Int, Sendable {
        case home = 4, appSwitcher = 5, notificationCentre = 6
    }

    /// Called when a gesture triggers a phone action (for diagnostics and UI).
    public var onPhoneAction: ((PhoneAction) -> Void)?
    /// A swipe counts once it has travelled this far (progress).
    static let swipeThreshold = 0.1
    /// Fingers resting this long at the end of a swipe up means "and hold".
    static let holdDuration = 0.3

    private var phoneSwipe: (axis: DockSwipe.Axis, peak: Double, lastGrowth: Double)?

    private func trackPhoneSwipe(_ swipe: DockSwipe) {
        switch swipe.phase {
        case .began, .mayBegin:
            phoneSwipe = (swipe.axis, swipe.progress, clock())
        case .changed:
            guard var current = phoneSwipe else { return }
            if abs(swipe.progress) > abs(current.peak) + 0.005 {
                current.peak = swipe.progress
                current.lastGrowth = clock()
            }
            phoneSwipe = current
        case .ended:
            defer { phoneSwipe = nil }
            guard settings.phoneGestures, let current = phoneSwipe, current.axis == .vertical,
                  abs(current.peak) >= Self.swipeThreshold else { return }
            let held = clock() - current.lastGrowth >= Self.holdDuration
            let action: PhoneAction = current.peak > 0 ? .notificationCentre : held ? .appSwitcher : .home
            if action == .home { pressHomeKey() } else { pressPhoneButton(action.rawValue) }
            onPhoneAction?(action)
        case .cancelled, .none:
            phoneSwipe = nil
        }
    }

    /// Home on iPhone: a press of the Menu key (Apple's accessory guidelines list it as the
    /// Home button; confirmed on an iPhone 15 Pro with iOS 26).
    private func pressHomeKey() {
        link.send(.consumer(ConsumerReport(usage: ConsumerReport.menu)))
        let release = { [weak self] in self?.link.send(.consumer(.released)) }
        if let schedule { schedule(0.06) { release() } } else { release() }
    }

    /// Clicks pointer button `number` (1-based) on the phone, where the pointer is.
    private func pressPhoneButton(_ number: Int) {
        guard let pointer = phonePointer else { return }
        let bit = UInt8(1) << UInt8(number - 1)
        let base = pointerReport(at: pointer)
        link.send(.pointer(PointerReport(buttons: base.buttons | bit, x: base.x, y: base.y)))
        let release = { [weak self] in
            guard let self else { return }
            let now = self.phonePointer.map { self.pointerReport(at: $0) } ?? base
            self.link.send(.pointer(PointerReport(buttons: now.buttons & ~bit, x: now.x, y: now.y)))
        }
        if let schedule { schedule(0.06) { release() } } else { release() }
    }

    private func gesture(_ kind: GestureKind, phase: GesturePhase) -> Disposition {
        switch phase {
        case .none:
            // An unphased gesture is not part of a sequence, so it belongs to whoever
            // owns input now. Discrete gestures (smart zoom, Look Up, legacy swipes)
            // would act on whatever is under the parked cursor.
            return owner == .phone ? .suppress : .pass
        case .mayBegin:
            gestureHolders[kind] = owner
            tentativeGestures.insert(kind)
        case .began:
            // A began without a preceding mayBegin starts a new sequence, which also
            // repairs a sequence whose end was missed.
            if tentativeGestures.remove(kind) == nil { gestureHolders[kind] = owner }
        case .changed:
            break
        case .ended, .cancelled:
            tentativeGestures.remove(kind)
            return gestureHolders.removeValue(forKey: kind) == .phone ? .suppress : .pass
        }
        // Unmatched phases pass: their start may predate capture.
        return gestureHolders[kind] == .phone ? .suppress : .pass
    }

    // MARK: Recovery

    /// Drops records of keys and buttons that are no longer physically held,
    /// releasing them on the phone. Called when capture (re)starts and after a
    /// return, so a release missed while capture was interrupted cannot leave a
    /// key stuck on either side.
    public func reconcile(keysDown: Set<UInt16>, buttonsDown: Set<MouseButton>) {
        for (code, holder) in keyHolders where !keysDown.contains(code) {
            keyHolders[code] = nil
            guard holder == .phone else { continue }
            if let usage = KeyMap.usage(forKeyCode: code) { releaseKey(usage) }
            if let bit = KeyMap.modifierBit(forKeyCode: code), keyboard.modifiers & bit != 0 {
                keyboard.modifiers &= ~bit
                link.send(.keyboard(keyboard))
            }
        }
        for (button, holder) in buttonHolders where !buttonsDown.contains(button) {
            buttonHolders[button] = nil
            if holder == .phone {
                phoneButtons &= ~button.hidBit
                sendPointerState()
            }
        }
    }

    /// True when some modifier is held on the phone's behalf, so Mac-bound events
    /// need `macVisibleModifiers` applied.
    public var hidesModifiers: Bool {
        keyHolders.contains { $0.value != .mac && KeyMap.aggregateFlag(forKeyCode: $0.key) != nil }
    }
}
