// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A grayscale, downsampled copy of one iPhone screen frame.
public struct Frame: Sendable {
    public let width: Int
    public let height: Int
    /// Downsampling factor relative to the captured screen pixels.
    public let scale: Int
    /// Row-major luminance, 0…255.
    public let pixels: [UInt8]
    /// Capture time (seconds, monotonic).
    public let time: Double

    public init(width: Int, height: Int, scale: Int = 1, pixels: [UInt8], time: Double = 0) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
        self.time = time
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

public enum FrameAnalysis {
    /// PNG data for a (grayscale) analysis frame, for keeping evidence.
    public static func png(_ frame: Frame) throws -> Data {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(frame.pixels) as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: frame.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    public struct Shift: Sendable, CustomStringConvertible {
        /// Content movement in captured pixels; positive = content moved up (scrolled down).
        public let pixels: Int
        /// Mean absolute difference at the best alignment and with no shift.
        public let error: Double
        public let errorWithoutShift: Double

        /// True when the frames are best explained by content moving, not by noise.
        public var moved: Bool { pixels != 0 && errorWithoutShift > 1.5 && error < errorWithoutShift * 0.6 }
        public var description: String {
            moved ? "moved \(pixels) px (residual \(Int(error)) vs \(Int(errorWithoutShift)))" : "no movement"
        }
    }

    /// Estimates how far the screen content scrolled vertically between two frames.
    ///
    /// Compares the frames at every candidate offset, ignoring the status bar and
    /// home-indicator strips, which never scroll. Coarse search then refinement.
    /// `ignoring` is a band (fractions of the height) that never counts, e.g. an alert
    /// that stays put while the content behind it scrolls.
    public static func verticalShift(from a: Frame, to b: Frame, maxShift: Int? = nil,
                                     excludeTop: Double = 0.07, excludeBottom: Double = 0.06,
                                     ignoring ignoredBand: ClosedRange<Double>? = nil) -> Shift {
        precondition(a.width == b.width && a.height == b.height)
        let top = Int(Double(a.height) * excludeTop), bottom = a.height - Int(Double(a.height) * excludeBottom)
        let band = bottom - top
        let limit = min(maxShift.map { $0 / a.scale } ?? band * 2 / 3, band * 2 / 3)
        let columns = Array(stride(from: a.width / 20, to: a.width - a.width / 20, by: 2))
        var ignored: ClosedRange<Int>?
        if let ignoredBand {
            let low = Int(ignoredBand.lowerBound * Double(a.height)), high = Int(ignoredBand.upperBound * Double(a.height))
            ignored = low...high
        }

        func error(_ shift: Int, rowStep: Int) -> Double {
            var total = 0, count = 0
            var y = max(top, top + shift)
            let end = min(bottom, bottom + shift)
            while y < end {
                if let ignored, ignored.contains(y) || ignored.contains(y - shift) {
                    y += rowStep
                    continue
                }
                let rowA = y * a.width, rowB = (y - shift) * b.width
                for x in columns {
                    total += abs(Int(a.pixels[rowA + x]) - Int(b.pixels[rowB + x]))
                }
                count += columns.count
                y += rowStep
            }
            return count == 0 ? .infinity : Double(total) / Double(count)
        }

        // Coarse: every third offset on every other row.
        var coarse = 0, coarseError = error(0, rowStep: 2)
        for shift in stride(from: -limit, through: limit, by: 3) where shift != 0 {
            let value = error(shift, rowStep: 2)
            if value < coarseError { coarse = shift; coarseError = value }
        }
        // Fine: every offset near the coarse winner on every row.
        var best = coarse, bestError = error(coarse, rowStep: 1)
        for shift in (coarse - 2)...(coarse + 2) where shift != coarse && abs(shift) <= limit {
            let value = error(shift, rowStep: 1)
            if value < bestError { best = shift; bestError = value }
        }
        return Shift(pixels: best * a.scale, error: bestError, errorWithoutShift: error(0, rowStep: 1))
    }

    public static func meanDifference(_ a: Frame, _ b: Frame) -> Double {
        precondition(a.pixels.count == b.pixels.count)
        var total = 0
        for index in a.pixels.indices { total += abs(Int(a.pixels[index]) - Int(b.pixels[index])) }
        return Double(total) / Double(max(1, a.pixels.count))
    }

    public struct Blob: Sendable, Equatable {
        public var area: Int
        /// Centroid in captured-pixel coordinates.
        public var centreX: Double
        public var centreY: Double
        public var minX: Int, minY: Int, maxX: Int, maxY: Int
    }

    /// Connected regions that changed between two frames, largest first.
    /// Used to find the pointer: move it, capture, and look for what changed.
    public static func changedRegions(_ a: Frame, _ b: Frame, threshold: Int = 18, minimumArea: Int = 4) -> [Blob] {
        let width = a.width, height = a.height
        var changed = [Bool](repeating: false, count: a.pixels.count)
        for index in a.pixels.indices where abs(Int(a.pixels[index]) - Int(b.pixels[index])) > threshold {
            changed[index] = true
        }
        var visited = [Bool](repeating: false, count: changed.count)
        var blobs: [Blob] = []
        var stack: [Int] = []
        for start in changed.indices where changed[start] && !visited[start] {
            var blob = Blob(area: 0, centreX: 0, centreY: 0, minX: .max, minY: .max, maxX: 0, maxY: 0)
            var sumX = 0, sumY = 0
            stack.append(start)
            visited[start] = true
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                blob.area += 1
                sumX += x
                sumY += y
                blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let next = ny * width + nx
                    if changed[next] && !visited[next] {
                        visited[next] = true
                        stack.append(next)
                    }
                }
            }
            guard blob.area >= minimumArea else { continue }
            let s = Double(a.scale)
            blob.centreX = (Double(sumX) / Double(blob.area) + 0.5) * s
            blob.centreY = (Double(sumY) / Double(blob.area) + 0.5) * s
            blob.minX *= a.scale; blob.maxX *= a.scale; blob.minY *= a.scale; blob.maxY *= a.scale
            blobs.append(blob)
        }
        return blobs.sorted { $0.area > $1.area }
    }
}
