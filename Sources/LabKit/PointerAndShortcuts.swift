// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Experiments on the iPhone's AssistiveTouch pointer visibility and on system
/// keyboard shortcuts. Like every lab experiment, they act only while Settings is
/// on screen, and they report whether the screen changed, never what it shows.
extension Lab {
    private var clock: Double { ProcessInfo.processInfo.systemUptime }

    /// Shows the pointer freshly at `point` (fractions of the screen) and returns a frame with it visible.
    private func showPointer(at point: (Double, Double)) throws -> Frame? {
        try app.send(["cmd": "hid.pointer", "x": point.0 + 0.1, "y": point.1 + 0.05])
        Thread.sleep(forTimeInterval: 0.15)
        try app.send(["cmd": "hid.pointer", "x": point.0, "y": point.1])
        return settledFrame(after: 0.35)
    }

    /// True when the screen around `point` no longer matches `shown` (the pointer faded or hid).
    private func pointerGone(since shown: Frame, at point: (Double, Double), in frame: Frame) -> Bool {
        guard let size = screen.pixelSize else { return false }
        let expected = (point.0 * Double(size.width), point.1 * Double(size.height))
        return FrameAnalysis.changedRegions(shown, frame).contains { blob in
            hypot(blob.centreX - expected.0, blob.centreY - expected.1) < Double(size.width) * 0.08
        }
    }

    /// Seconds until the pointer fades on its own (AssistiveTouch Auto-Hide), or nil if it
    /// is still showing after `limit`.
    public func pointerFadeTime(at point: (Double, Double) = (0.5, 0.11), limit: Double = 20) throws -> Double? {
        try requireExpectedScreen()
        guard let shown = try showPointer(at: point) else { return nil }
        let start = clock - 0.35
        while clock - start < limit {
            Thread.sleep(forTimeInterval: 0.2)
            guard let frame = screen.frame(after: clock - 0.02) else { continue }
            if pointerGone(since: shown, at: point, in: frame) { return clock - start }
        }
        return nil
    }

    /// Whether a key press (keyboard usage and modifier bits) makes the pointer disappear
    /// within `within` seconds. With no key and no modifiers this is the control run.
    public func pointerHidesOnKey(usage: UInt8?, modifiers: UInt8, within: Double = 0.5,
                                  at point: (Double, Double) = (0.5, 0.11)) throws -> Bool {
        try requireExpectedScreen()
        guard let shown = try showPointer(at: point) else { return false }
        if usage != nil || modifiers != 0 {
            try app.send(["cmd": "hid.keyboard", "modifiers": Int(modifiers), "keys": usage.map { [Int($0)] } ?? []])
            Thread.sleep(forTimeInterval: 0.06)
            try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
        }
        guard let after = settledFrame(after: within) else { return false }
        return pointerGone(since: shown, at: point, in: after)
    }

    /// Presses Globe (Consumer AC Next Keyboard Layout Select) with a key and reports
    /// whether the screen changed to something else. Restores Settings afterwards.
    public func globeShortcut(_ usage: UInt8) throws -> Bool {
        try requireExpectedScreen()
        // Park the pointer at the edge so it does not count as a change.
        try app.send(["cmd": "hid.pointer", "x": 0.99, "y": 0.5])
        Thread.sleep(forTimeInterval: 0.5)
        let before = Set(screen.recognizedText())
        try app.send(["cmd": "hid.consumer", "usage": 0x029D, "hold": true])
        Thread.sleep(forTimeInterval: 0.05)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int(usage)]])
        Thread.sleep(forTimeInterval: 0.08)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
        Thread.sleep(forTimeInterval: 0.05)
        try app.send(["cmd": "hid.consumer", "usage": 0])
        Thread.sleep(forTimeInterval: 1.5)
        let after = Set(screen.recognizedText())
        let similarity = Double(before.intersection(after).count) / Double(max(1, before.union(after).count))
        let changed = similarity < 0.4
        if changed { try reopenSettings() }
        return changed
    }

    /// Opens Settings through Spotlight (⌘Space, type, Return) and checks it is showing.
    public func reopenSettings() throws {
        try app.send(["cmd": "hid.keyboard", "modifiers": 0x08, "keys": [0x2C]])
        Thread.sleep(forTimeInterval: 0.08)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
        Thread.sleep(forTimeInterval: 1.0)
        try app.send(["cmd": "hid.type", "text": "Settings"])
        Thread.sleep(forTimeInterval: 1.2)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [0x28]])
        Thread.sleep(forTimeInterval: 0.08)
        try app.send(["cmd": "hid.keyboard", "modifiers": 0, "keys": [Int]()])
        Thread.sleep(forTimeInterval: 2.0)
        try requireExpectedScreen()
    }
}

extension Lab {
    /// Where the pointer appears when sent to a screen corner (fractions 0 or 1), as a
    /// bounding box in captured pixels measured from that corner, or nil if not seen.
    public func pointerInCorner(_ corner: (Double, Double)) throws -> (near: Int, far: Int, width: Int, height: Int)? {
        try requireExpectedScreen()
        guard let size = screen.pixelSize else { return nil }
        try app.send(["cmd": "hid.pointer", "x": 0.5, "y": 0.5])
        guard let away = settledFrame(after: 0.5) else { return nil }
        try app.send(["cmd": "hid.pointer", "x": corner.0, "y": corner.1])
        guard let there = settledFrame(after: 0.5) else { return nil }
        let cornerX = corner.0 * Double(size.width), cornerY = corner.1 * Double(size.height)
        let blobs = FrameAnalysis.changedRegions(away, there).filter { blob in
            hypot(blob.centreX - cornerX, blob.centreY - cornerY) < Double(size.width) * 0.2
        }
        guard let blob = blobs.first else { return nil }
        // Distances from the corner along each axis, in captured pixels.
        let dx = corner.0 == 0 ? (blob.minX, blob.maxX) : (size.width - blob.maxX, size.width - blob.minX)
        let dy = corner.1 == 0 ? (blob.minY, blob.maxY) : (size.height - blob.maxY, size.height - blob.minY)
        return (min(dx.0, dy.0), max(dx.1, dy.1), blob.maxX - blob.minX, blob.maxY - blob.minY)
    }
}

extension Lab {
    /// Presses a Consumer usage (e.g. Volume Increment) and reports whether the screen
    /// changed, as iOS's volume indicator does. Presses `undo` afterwards to restore.
    public func consumerKeyShowsChange(_ usage: Int, undo: Int) throws -> Bool {
        try requireExpectedScreen()
        try app.send(["cmd": "hid.pointer", "x": 0.99, "y": 0.99])
        guard let before = settledFrame(after: 1.5) else { return false }
        try app.send(["cmd": "hid.consumer", "usage": usage])
        guard let after = settledFrame(after: 0.5) else { return false }
        let blobs = FrameAnalysis.changedRegions(before, after, threshold: 10, minimumArea: 2)
        for blob in blobs.prefix(5) {
            log("  changed region: area \(blob.area) at (\(Int(blob.centreX)), \(Int(blob.centreY))) px")
        }
        if blobs.isEmpty { log("  no pixel changed") }
        let changed = blobs.contains { $0.area >= 40 }
        Thread.sleep(forTimeInterval: 0.5)
        try app.send(["cmd": "hid.consumer", "usage": undo])
        return changed
    }
}
