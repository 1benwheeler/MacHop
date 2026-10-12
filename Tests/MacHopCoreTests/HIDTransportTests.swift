import Testing
@testable import MacHopCore
@testable import VirtualPhone

/// A radio that records submissions and refuses on demand.
@MainActor
final class RecordingSink: NotificationSink {
    var accepted: [(UInt8, [UInt8])] = []
    var refuseNext = 0
    var refuseAll = false

    func submit(_ bytes: [UInt8], reportID: UInt8) -> Bool {
        if refuseAll { return false }
        if refuseNext > 0 {
            refuseNext -= 1
            return false
        }
        accepted.append((reportID, bytes))
        return true
    }
}

@MainActor
@Suite("HID transport")
struct HIDTransportTests {
    let scheduler = ManualScheduler()
    let sink = RecordingSink()
    let transport: HIDTransport

    init() {
        transport = HIDTransport(profile: .standard, scheduler: scheduler)
        transport.sink = sink
    }

    func connectAll() {
        for id in transport.profile.inputReportIDs { transport.subscribed(id) }
        sink.accepted.removeAll()
    }

    @Test("Ready only once every required report is subscribed; baselines go first")
    func readiness() {
        var changes: [Bool] = []
        transport.onReadyChange = { changes.append($0) }
        transport.subscribed(1)
        transport.subscribed(2)
        #expect(!transport.isReady)
        transport.subscribed(3)
        #expect(transport.isReady)
        // Each report's neutral baseline, then all-released keyboard and pointer.
        #expect(sink.accepted.map(\.0) == [1, 2, 3, 1, 2])
        #expect(sink.accepted.allSatisfy { $0.1.allSatisfy { $0 == 0 } || $0.0 == 2 })
        transport.unsubscribed(3)
        #expect(!transport.isReady)
        transport.subscribed(3)
        transport.setSuspended(true)
        #expect(!transport.isReady)
        transport.setSuspended(false)
        #expect(changes == [true, false, true, false, true])
    }

    @Test("Nothing is sent before the phone is ready")
    func gatedUntilReady() {
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.subscribed(1)
        #expect(sink.accepted.count == 1)   // only the baseline
        #expect(transport.queuedCount == 0)
    }

    @Test("Order is preserved and keys never coalesce")
    func ordering() {
        connectAll()
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.send(.keyboard(.released))
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.send(.keyboard(.released))
        #expect(sink.accepted.map(\.1[2]) == [4, 0, 4, 0])
    }

    @Test("Pointer moves are paced and coalesce to the latest position")
    func pacing() {
        connectAll()
        for step in 0..<20 {
            transport.send(.pointer(PointerReport(x: Double(step) / 20, y: 0.5)))
        }
        // First move goes out immediately; the rest collapse into one pending report.
        #expect(sink.accepted.count == 1)
        #expect(transport.queuedCount == 1)
        scheduler.advance(by: transport.motionInterval)
        #expect(sink.accepted.count == 2)
        let last = sink.accepted.last!.1
        #expect(UInt16(last[1]) | UInt16(last[2]) << 8 == PointerReport(x: 19.0 / 20, y: 0.5).logicalX)
    }

    @Test("A button change flushes in order and is never merged with motion")
    func buttonsNotMerged() {
        connectAll()
        transport.send(.pointer(PointerReport(x: 0.1, y: 0.1)))
        transport.send(.pointer(PointerReport(x: 0.2, y: 0.2)))           // paced, pending
        transport.send(.pointer(PointerReport(buttons: 1, x: 0.2, y: 0.2))) // press must follow the move
        transport.send(.pointer(PointerReport(buttons: 0, x: 0.2, y: 0.2))) // release
        scheduler.advance(by: 0.05)
        let buttons = sink.accepted.map { $0.1[0] }
        #expect(buttons == [0, 0, 1, 0])
        #expect(sink.accepted[1].1 == sink.accepted[2].1.enumerated().map { $0.offset == 0 ? 0 : $0.element })
    }

    @Test("Scroll steps add up while waiting")
    func scrollCoalesces() {
        connectAll()
        for _ in 0..<10 { transport.send(.scroll(ScrollReport(wheel: 1))) }
        scheduler.advance(by: 0.1)
        let total = sink.accepted.reduce(0) { $0 + Int(Int8(bitPattern: $1.1[0])) }
        #expect(total == 10)
        #expect(sink.accepted.count == 2)
    }

    @Test("Backpressure holds the exact report until the radio is ready")
    func backpressure() {
        connectAll()
        sink.refuseNext = 1
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.send(.keyboard(.released))
        #expect(sink.accepted.isEmpty)
        #expect(transport.stats.backpressureEvents == 1)
        transport.radioIsReady()
        #expect(sink.accepted.map(\.1[2]) == [4, 0])
    }

    @Test("A radio that never drains is reported as stalled")
    func stall() {
        connectAll()
        var stalled = 0
        transport.onStall = { stalled += 1 }
        sink.refuseAll = true
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        scheduler.advance(by: transport.stallTimeout - 0.01)
        #expect(stalled == 0)
        scheduler.advance(by: 0.02)
        #expect(stalled == 1)
        #expect(!transport.isReady, "input stays off until the radio accepts something again")
        // Stale input is gone; only the releases the phone is owed remain.
        sink.refuseAll = false
        transport.radioIsReady()
        #expect(sink.accepted.map(\.0) == [1, 2, 4])
        #expect(sink.accepted[0].1 == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(transport.isReady)
        scheduler.advance(by: 5)
        #expect(stalled == 1, "a stalled radio is reported once, not repeatedly")
    }

    @Test("A queued button press keeps its own position even when a drag follows")
    func pressKeepsPosition() {
        connectAll()
        sink.refuseNext = 1
        transport.send(.pointer(PointerReport(buttons: 0, x: 0.1, y: 0.5)))
        transport.send(.pointer(PointerReport(buttons: 1, x: 0.1, y: 0.5)))
        transport.send(.pointer(PointerReport(buttons: 1, x: 0.6, y: 0.5)))
        transport.send(.pointer(PointerReport(buttons: 1, x: 0.7, y: 0.5)))
        transport.radioIsReady()
        scheduler.advance(by: 0.1)
        let press = sink.accepted.first { $0.0 == 2 && $0.1[0] == 1 }.map { UInt16($0.1[1]) | UInt16($0.1[2]) << 8 }
        #expect(press == PointerReport(x: 0.1, y: 0.5).logicalX)
        let last = sink.accepted.last!.1
        #expect(UInt16(last[1]) | UInt16(last[2]) << 8 == PointerReport(x: 0.7, y: 0.5).logicalX, "drag still coalesces")
    }

    @Test("Releases are re-sent whenever input becomes available again")
    func releasesOnResume() {
        connectAll()
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.setSuspended(true)
        transport.send(.keyboard(.released))    // dropped: not ready while suspended
        sink.accepted.removeAll()
        transport.setSuspended(false)
        #expect(sink.accepted.first.map { $0.0 == 1 && $0.1[2] == 0 } == true)
    }

    @Test("A recovered radio does not trigger a stale stall")
    func noStaleStall() {
        connectAll()
        var stalled = 0
        transport.onStall = { stalled += 1 }
        sink.refuseNext = 1
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        scheduler.advance(by: 0.5)
        transport.radioIsReady()
        scheduler.advance(by: 2)
        #expect(stalled == 0)
    }

    @Test("Losing the link drops queued input instead of replaying it later")
    func resetDropsQueue() {
        connectAll()
        sink.refuseAll = true
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        transport.reset()
        #expect(!transport.isReady)
        sink.refuseAll = false
        connectAll()
        scheduler.advance(by: 0.1)
        #expect(sink.accepted.isEmpty)
    }

    @Test("Unsubscribed optional reports are skipped, not stalled on")
    func optionalChannels() {
        for id in transport.profile.requiredInputReportIDs { transport.subscribed(id) }
        sink.accepted.removeAll()
        transport.send(.consumer(ConsumerReport(usage: ConsumerReport.home)))
        transport.send(.keyboard(KeyboardReport(keys: [4])))
        #expect(sink.accepted.map(\.0) == [1])
    }
}
