// SPDX-License-Identifier: AGPL-3.0-only
import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Live capture of a USB-connected iPhone's screen, the mechanism QuickTime
/// Player uses. Needs no Xcode, developer mode or phone app; the phone must be
/// unlocked and trust this Mac, and the capturing process needs Camera access.
public final class PhoneScreen: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum CaptureError: Error, CustomStringConvertible {
        case noDevice, cameraAccessDenied, cannotOpen(String)
        public var description: String {
            switch self {
            case .noDevice:
                "No iPhone screen found. Connect the iPhone with a USB cable, unlock it and tap Trust if asked."
            case .cameraAccessDenied:
                "Camera access is needed to capture the iPhone screen. Allow it for your terminal in " +
                "System Settings → Privacy & Security → Camera."
            case .cannotOpen(let reason): "Could not open the iPhone screen: \(reason)"
            }
        }
    }

    public let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "local.machop.lab.capture")
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestTime = 0.0
    private var frameCount = 0
    private let context = CIContext()

    /// Makes iOS screens visible to AVFoundation as capture devices.
    public static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// iOS devices offering their screen; they appear a moment after enabling.
    public static func phones(waiting timeout: Double = 10) -> [AVCaptureDevice] {
        enableScreenCaptureDevices()
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed,
                                                          position: .unspecified).devices
            if !found.isEmpty { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return []
    }

    public static func requestCameraAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            AVCaptureDevice.requestAccess(for: .video) { granted = $0; semaphore.signal() }
            semaphore.wait()
            return granted
        default: return false
        }
    }

    public init(device: AVCaptureDevice) throws {
        self.device = device
        super.init()
        guard Self.requestCameraAccess() else { throw CaptureError.cameraAccessDenied }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cannotOpen("input rejected") }
            session.addInput(input)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.cannotOpen(error.localizedDescription)
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotOpen("output rejected") }
        session.addOutput(output)
    }

    public func start(timeout: Double = 5) throws {
        session.startRunning()
        let deadline = Date().addingTimeInterval(timeout)
        while frameCountSnapshot == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if frameCountSnapshot == 0 { throw CaptureError.cannotOpen("no frames arrived; is the iPhone unlocked?") }
    }

    public func stop() { session.stopRunning() }

    private var frameCountSnapshot: Int { lock.withLock { frameCount } }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.withLock {
            latestBuffer = buffer
            latestTime = ProcessInfo.processInfo.systemUptime
            frameCount += 1
        }
    }

    /// The newest frame, downsampled `scale`× for analysis.
    public func frame(scale: Int = 4) -> Frame? {
        guard let (buffer, time) = lock.withLock({ latestBuffer.map { ($0, latestTime) } }) else { return nil }
        return Self.gray(buffer, scale: scale, time: time)
    }

    /// Waits until a frame newer than `time` arrives (screen updates can lag input).
    public func frame(after time: Double, scale: Int = 4, timeout: Double = 1) -> Frame? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let frame = frame(scale: scale), frame.time > time { return frame }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return frame(scale: scale)
    }

    /// Captured screen size in pixels.
    public var pixelSize: (width: Int, height: Int)? {
        lock.withLock { latestBuffer.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) } }
    }

    public func image() -> CGImage? {
        guard let buffer = lock.withLock({ latestBuffer }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    public func savePNG(to url: URL) throws {
        guard let image = image(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.cannotOpen("no frame to save")
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Text on screen, recognised with Apple's Vision framework.
    public func recognizedText() -> [String] {
        guard let image = image() else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func gray(_ buffer: CVPixelBuffer, scale: Int, time: Double) -> Frame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let outWidth = width / scale, outHeight = height / scale
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let row = base + (y * scale) * stride
            for x in 0..<outWidth {
                let p = row + (x * scale) * 4
                // BGRA → luma (BT.601 integer approximation).
                pixels[y * outWidth + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
            }
        }
        return Frame(width: outWidth, height: outHeight, scale: scale, pixels: pixels, time: time)
    }
}
