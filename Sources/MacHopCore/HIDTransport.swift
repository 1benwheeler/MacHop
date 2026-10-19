// SPDX-License-Identifier: AGPL-3.0-only

/// Time and deferred work, injected so tests can run on a manual clock.
@MainActor
public protocol Scheduler: AnyObject {
    var now: Double { get }
    func after(_ delay: Double, _ action: @escaping @MainActor () -> Void)
}

/// The radio: CoreBluetooth in the app, a simulated link in tests.
@MainActor
public protocol NotificationSink: AnyObject {
    /// Hands one input-report notification to the radio. Returns false when the
    /// radio's queue is full; the owner then calls `HIDTransport.radioIsReady()`
    /// once it can accept more.
    func submit(_ bytes: [UInt8], reportID: UInt8) -> Bool
}

/// Delivers HID reports to the phone in order, with as little latency as the link allows.
///
/// - Reports leave in exactly the order they were produced.
/// - Pointer moves and scroll steps coalesce while waiting, so a slow or busy link
///   delivers the latest position instead of building a backlog. Button and key
///   changes never coalesce.
/// - Pointer and scroll notifications are paced to roughly the BLE connection
///   interval, keeping the radio's own queue (which adds latency) nearly empty.
/// - If the radio stops draining, `onStall` fires so the Mac can take input back.
@MainActor
public final class HIDTransport: HIDLink {
    public let profile: HIDProfile
    public weak var sink: NotificationSink?

    public private(set) var subscribedReports: Set<UInt8> = []
    public private(set) var isSuspended = false
    public private(set) var isReady = false
    public var onReadyChange: ((Bool) -> Void)?
    /// The radio stopped accepting input for longer than `stallTimeout`.
    public var onStall: (() -> Void)?

    /// Minimum spacing between pointer-only or scroll notifications.
    public var motionInterval = 0.010
    public var stallTimeout = 1.0
    public static let capacity = 512

    public private(set) var stats = Stats()
    public struct Stats: Equatable, Sendable {
        public var submitted = 0
        public var coalesced = 0
        public var backpressureEvents = 0
        public var maximumQueueDepth = 0
        public var stalls = 0

        public init() {}
    }

    private enum Item {
        /// `transition` marks a pointer report that changes buttons: it must reach
        /// the phone at its own position, so nothing merges into it.
        case report(HIDReport, transition: Bool)
        case raw(EncodedReport)
    }

    private var queue: [Item] = []
    private var encoder: HIDEncoder
    private let scheduler: Scheduler
    private var blockedSince: Double?
    private var lastMotionSubmission = -Double.infinity
    /// Buttons held according to the last pointer report the radio accepted.
    private var lastPointerButtons: UInt8 = 0
    /// Where a pointer button was pressed, until a release reaches the phone. Unlike
    /// the rest, it survives losing the link: if the phone could still be holding the
    /// button, it's released there on reconnecting.
    private var heldPointer: PointerReport?
    /// The most recent pointer position handed to the transport.
    private var lastPointer: PointerReport?
    /// After a stall, input stays off until the radio accepts the queued releases.
    private var isStalled = false
    private var drainScheduled = false
    private var generation = 0

    public init(profile: HIDProfile, scheduler: Scheduler) {
        self.profile = profile
        self.scheduler = scheduler
        self.encoder = HIDEncoder(profile: profile)
    }

    public var queuedCount: Int { queue.count }
    public var pointerIsAbsolute: Bool { profile.isAbsolute }

    // MARK: Link lifecycle (called by the radio adapter)

    /// The phone subscribed to an input report. It first receives that report's
    /// all-released value, so it never inherits a stale held key. The pointer is the
    /// exception: any pointer report shows the iPhone's pointer where it says (the
    /// neutral one, in the middle of the screen), so none is sent until it's needed.
    public func subscribed(_ reportID: UInt8) {
        guard profile.inputReportIDs.contains(reportID) else { return }
        let isNew = subscribedReports.insert(reportID).inserted
        if isNew, reportID != profile.pointerReportID {
            enqueue(.raw(EncodedReport(reportID: reportID, bytes: profile.neutralPayload(for: reportID))))
        }
        updateReadiness()
        drain()
    }

    public func unsubscribed(_ reportID: UInt8) {
        subscribedReports.remove(reportID)
        if subscribedReports.isEmpty { clearQueue() }
        updateReadiness()
    }

    /// HID Control Point: the phone asked us to suspend (e.g. while locked) or resume.
    public func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        updateReadiness()
        drain()
    }

    /// Asks a phone that has paused input (its screen went to sleep) to wake up. This
    /// device advertises remote wake, which lets it send input while suspended. A tap
    /// of Shift is the input: it types nothing and does nothing on any screen.
    @discardableResult
    public func wake(with reports: [HIDReport] = HIDTransport.wakeReports) -> Bool {
        guard isSuspended, !isStalled, subscribedReports.contains(profile.keyboardReportID) else { return false }
        for report in reports { enqueue(.report(report, transition: false)) }
        drain()
        return true
    }

    public static let wakeReports: [HIDReport] = [.keyboard(KeyboardReport(modifiers: 0x02)), .keyboard(.released)]

    /// The link to the phone is gone. Everything queued is dropped: input is
    /// never replayed after a reconnection.
    public func reset() {
        subscribedReports.removeAll()
        isSuspended = false
        isStalled = false
        clearQueue()
        lastPointerButtons = 0
        lastPointer = nil
        updateReadiness()
    }

    /// The radio can accept more notifications.
    public func radioIsReady() {
        blockedSince = nil
        drain()
    }

    // MARK: HIDLink

    public func send(_ report: HIDReport) {
        guard isReady else { return }
        if case .pointer(let pointer) = report {
            lastPointer = pointer
            if pointer.buttons != 0 { heldPointer = pointer }
        }
        enqueue(.report(report, transition: false))
        drain()
    }

    // MARK: Queue

    /// Buttons the phone will hold once everything queued has been delivered.
    private var buttonsAhead: UInt8 {
        for item in queue.reversed() {
            if case .report(.pointer(let pointer), _) = item { return pointer.buttons }
        }
        return lastPointerButtons
    }

    private func enqueue(_ item: Item) {
        var item = item
        if case .report(.pointer(let pointer), _) = item {
            item = .report(.pointer(pointer), transition: pointer.buttons != buttonsAhead)
        }
        if case .report(let incoming, false) = item, let last = queue.last,
           case .report(let previous, false) = last, let merged = Self.coalesce(previous, incoming) {
            queue[queue.count - 1] = .report(merged, transition: false)
            stats.coalesced += 1
            return
        }
        guard queue.count < Self.capacity else {
            stall()
            return
        }
        queue.append(item)
        stats.maximumQueueDepth = max(stats.maximumQueueDepth, queue.count)
    }

    /// Pointer moves replace each other; scroll steps add. Never applied to a
    /// button transition, which keeps its own position.
    private static func coalesce(_ previous: HIDReport, _ incoming: HIDReport) -> HIDReport? {
        switch (previous, incoming) {
        case let (.pointer(a), .pointer(b)) where a.buttons == b.buttons:
            return .pointer(b)
        case let (.scroll(a), .scroll(b)):
            return .scroll(ScrollReport(wheel: a.wheel + b.wheel, pan: a.pan + b.pan))
        default:
            return nil
        }
    }

    /// All-released reports for every subscribed input, so the phone holds nothing.
    private func enqueueReleases() {
        if subscribedReports.contains(profile.keyboardReportID) {
            enqueue(.report(.keyboard(.released), transition: false))
        }
        // A pointer report shows the iPhone's pointer, so it's only released when a
        // button may still be down, and where the pointer was left.
        if subscribedReports.contains(profile.pointerReportID), lastPointerButtons != 0 || heldPointer != nil {
            if let last = lastPointer ?? heldPointer {
                enqueue(.report(.pointer(PointerReport(buttons: 0, x: last.x, y: last.y)), transition: false))
            } else {
                enqueue(.raw(EncodedReport(reportID: profile.pointerReportID,
                                           bytes: profile.neutralPayload(for: profile.pointerReportID))))
            }
        }
        if subscribedReports.contains(profile.consumerReportID) {
            enqueue(.report(.consumer(.released), transition: false))
        }
    }

    private func isPacedMotion(_ item: Item) -> Bool {
        switch item {
        case .report(.pointer, let transition): return !transition
        case .report(.scroll, _): return true
        default: return false
        }
    }

    private func drain() {
        guard let sink else { return }
        var recovered = false
        defer { if recovered { updateReadiness() } }
        while let head = queue.first {
            if blockedSince != nil { return }
            if isPacedMotion(head) {
                let readyAt = lastMotionSubmission + motionInterval
                if scheduler.now < readyAt {
                    scheduleDrain(at: readyAt)
                    return
                }
            }
            let encoded: [EncodedReport]
            switch head {
            case .raw(let raw): encoded = [raw]
            case .report(let report, _): encoded = encoder.encode(report)
            }
            // Multi-part reports (large scroll or relative moves) submit atomically
            // from the queue's point of view: the remainder is requeued in front.
            var remaining = encoded[...]
            while let part = remaining.first {
                guard subscribedReports.contains(part.reportID) else {
                    remaining = remaining.dropFirst()
                    continue
                }
                if sink.submit(part.bytes, reportID: part.reportID) {
                    stats.submitted += 1
                    remaining = remaining.dropFirst()
                    // Byte 0 of every pointer-report payload is the button byte.
                    if part.reportID == profile.pointerReportID {
                        lastPointerButtons = part.bytes[0]
                        if part.bytes[0] == 0 { heldPointer = nil }
                    }
                    if isStalled {
                        isStalled = false
                        recovered = true
                    }
                } else {
                    stats.backpressureEvents += 1
                    blockedSince = scheduler.now
                    queue[0] = .raw(part)
                    queue.insert(contentsOf: remaining.dropFirst().map { Item.raw($0) }, at: 1)
                    watchForStall()
                    return
                }
            }
            queue.removeFirst()
            if case .report(let report, _) = head, isMotion(report) { lastMotionSubmission = scheduler.now }
        }
    }

    private func isMotion(_ report: HIDReport) -> Bool {
        if case .scroll = report { return true }
        if case .pointer = report { return true }
        return false
    }

    private func scheduleDrain(at time: Double) {
        guard !drainScheduled else { return }
        drainScheduled = true
        let token = generation
        scheduler.after(max(0, time - scheduler.now)) { [weak self] in
            guard let self, self.generation == token else { return }
            self.drainScheduled = false
            self.drain()
        }
    }

    private func watchForStall() {
        let token = generation
        let since = blockedSince
        scheduler.after(stallTimeout) { [weak self] in
            guard let self, self.generation == token, !self.isStalled,
                  let since, self.blockedSince == since else { return }
            self.stall()
        }
    }

    /// The radio stopped draining. Pending input is dropped (it is stale), but the
    /// phone is owed releases for anything held, so those are queued in its place
    /// and input stays unavailable until the radio accepts them.
    private func stall() {
        stats.stalls += 1
        clearQueue()
        isStalled = true
        enqueueReleases()
        updateReadiness()
        onStall?()
        drain()
    }

    private func clearQueue() {
        queue.removeAll()
        encoder.reset()
        blockedSince = nil
        drainScheduled = false
        generation += 1
    }

    private func updateReadiness() {
        let ready = !isSuspended && !isStalled && profile.requiredInputReportIDs.isSubset(of: subscribedReports)
        guard ready != isReady else { return }
        isReady = ready
        // Whenever input becomes available again (resume, re-subscription, recovery
        // from a stall) the phone first gets all-released reports, so a release
        // dropped while input was unavailable can never leave a key held.
        if ready { enqueueReleases() }
        onReadyChange?(ready)
    }
}
