// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MacHopCore
import VirtualPhone

/// Measures the production routing and transport code in an optimized build,
/// driving the simulated phone. No hardware involved.
@MainActor
enum Bench {
    static func run() {
        let clock = ContinuousClock()
        func report(_ name: String, _ count: Int, _ duration: Duration) {
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            print(String(format: "%-44@ %9.3f µs per event  (%d events)", name as NSString, seconds / Double(count) * 1e6, count))
        }

        // 1. Routing decisions alone while the Mac owns input (the common case).
        let idle = Simulation()
        var location = Point(x: 700, y: 400)
        let localEvents = 1_000_000
        report("Mac-owned pointer event (pass-through)", localEvents, clock.measure {
            for index in 0..<localEvents {
                location.x = 700 + Double(index % 200)
                _ = idle.session.handle(.pointerMoved(location: location, delta: Point(x: 1, y: 0)))
            }
        })

        // 2. Phone-owned motion: routing + encoding + queue + coalescing.
        let sim = Simulation()
        _ = sim.crossToPhone()
        let remoteEvents = 1_000_000
        report("Phone-owned pointer event (routed + queued)", remoteEvents, clock.measure {
            for index in 0..<remoteEvents {
                let delta = Point(x: index % 2 == 0 ? 1 : -1, y: index % 3 == 0 ? 1 : -1)
                _ = sim.session.handle(.pointerMoved(location: sim.cursor.location, delta: delta))
            }
        })

        // 3. Keystrokes end to end through the simulated radio to the virtual phone,
        //    at 50 characters per second (several times faster than a fast typist).
        let typing = Simulation()
        _ = typing.crossToPhone()
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 12)
        report("Keystroke incl. simulated Bluetooth delivery", text.count, clock.measure {
            typing.type(text, interval: 0.02)
            typing.settle(2)
        })
        let stats = typing.transport.stats
        print("  typed text intact on the virtual phone: \(typing.phone.text == text); " +
              "max queue \(stats.maximumQueueDepth), backpressure \(stats.backpressureEvents), stalls \(stats.stalls), " +
              String(format: "max radio latency %.0f ms", typing.radio.maximumLatency * 1000))

        // 4. Full round trips.
        let trips = Simulation()
        var passed = 0
        let tripCount = 1000
        report("Mac → iPhone → Mac round trip (simulated)", tripCount, clock.measure {
            for _ in 0..<tripCount {
                if trips.crossToPhone() && trips.returnToMac() { passed += 1 }
                trips.settle(InputSession.crossingCooldown)
            }
        })
        print("  round trips completed: \(passed)/\(tripCount)")
    }
}
