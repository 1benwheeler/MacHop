import Testing
@testable import LabKit

/// A synthetic "screen": a tall document viewed through a window, with fixed
/// status-bar and home-indicator strips like iOS.
struct SyntheticScreen {
    let width = 150, height = 320
    var document: [UInt8]
    let documentHeight: Int

    /// List-like content: uniform rows with separators, plus irregular "text".
    init(seed: UInt64, documentHeight: Int = 1400) {
        self.documentHeight = documentHeight
        var state = seed
        func random() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        document = [UInt8](repeating: 245, count: width * documentHeight)
        for y in 0..<documentHeight {
            if y % 22 == 0 { for x in 10..<width { document[y * width + x] = 200 } }   // separators
        }
        // Text-like dark blocks at irregular positions.
        for _ in 0..<(documentHeight / 6) {
            let x0 = Int(random() % UInt64(width - 30)), y0 = Int(random() % UInt64(documentHeight - 8))
            let length = 6 + Int(random() % 24)
            for y in y0..<(y0 + 5) { for x in x0..<(x0 + length) { document[y * width + x] = UInt8(30 + random() % 60) } }
        }
    }

    func frame(scrolledBy offset: Int, scale: Int = 4) -> Frame {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { pixels[y * width + x] = document[(y + offset) * width + x] }
        }
        // Fixed strips that never scroll.
        for y in 0..<(height * 7 / 100) { for x in 0..<width { pixels[y * width + x] = UInt8((x * 7) % 255) } }
        for y in (height - height * 6 / 100)..<height { for x in 0..<width { pixels[y * width + x] = 40 } }
        return Frame(width: width, height: height, scale: scale, pixels: pixels)
    }
}

@Suite("Frame analysis")
struct FrameAnalysisTests {
    @Test("Detects how far a list scrolled, in either direction", arguments: [7, 23, 60, 150, -9, -44, -120])
    func detectsShift(offset: Int) {
        let screen = SyntheticScreen(seed: 42)
        let start = 400
        let before = screen.frame(scrolledBy: start)
        let after = screen.frame(scrolledBy: start + offset)
        let shift = FrameAnalysis.verticalShift(from: before, to: after)
        #expect(shift.moved, "\(shift)")
        #expect(shift.pixels == offset * 4, "expected \(offset * 4) captured pixels, got \(shift.pixels)")
    }

    @Test("An unchanged screen is not reported as scrolling")
    func noMovement() {
        let screen = SyntheticScreen(seed: 7)
        let shift = FrameAnalysis.verticalShift(from: screen.frame(scrolledBy: 300), to: screen.frame(scrolledBy: 300))
        #expect(!shift.moved)
    }

    @Test("A screen that changed without scrolling is not reported as scrolling")
    func unrelatedChange() {
        let before = SyntheticScreen(seed: 1).frame(scrolledBy: 300)
        let after = SyntheticScreen(seed: 2).frame(scrolledBy: 300)
        #expect(!FrameAnalysis.verticalShift(from: before, to: after).moved)
    }

    @Test("Finds the pointer as the region that changed")
    func findsPointer() {
        let screen = SyntheticScreen(seed: 3)
        let before = screen.frame(scrolledBy: 200)
        var pixels = before.pixels
        // A grey disc of radius 6 (downsampled pixels) centred at (90, 150).
        for y in 0..<before.height {
            for x in 0..<before.width where (x - 90) * (x - 90) + (y - 150) * (y - 150) <= 36 {
                pixels[y * before.width + x] = 120
            }
        }
        let after = Frame(width: before.width, height: before.height, scale: 4, pixels: pixels)
        let blob = FrameAnalysis.changedRegions(before, after).first
        #expect(blob != nil)
        if let blob {
            #expect(abs(blob.centreX - 90.5 * 4) < 6)
            #expect(abs(blob.centreY - 150.5 * 4) < 6)
        }
        #expect(FrameAnalysis.changedRegions(before, before).isEmpty)
    }
}
