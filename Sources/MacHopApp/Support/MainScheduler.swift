// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MacHopCore

/// `Scheduler` on the main queue with a monotonic clock.
final class MainScheduler: Scheduler {
    var now: Double { ProcessInfo.processInfo.systemUptime }

    func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            MainActor.assumeIsolated { action() }
        }
    }
}
