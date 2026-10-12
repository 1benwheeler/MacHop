// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Drives MacHop with real posted input (through macOS and MacHop's event tap),
/// checking MacHop's own state after each step.
public final class Driver {
    public enum DriverError: Error, CustomStringConvertible {
        case notOnPhone, noEdge
        public var description: String {
            switch self {
            case .notOnPhone: "The iPhone does not have input; run `cross` first."
            case .noEdge: "MacHop reports no usable screen edge."
            }
        }
    }

    let app: AutomationClient
    public init(app: AutomationClient) { self.app = app }

    public func status() throws -> [String: Any] { try app.status() }
    public var owner: String { ((try? status())?["owner"] as? String) ?? "?" }

    func edge() throws -> (x: Double, top: Double, bottom: Double, outward: Double) {
        guard let edge = try status()["edge"] as? [String: Any], let x = edge["x"] as? Double,
              let top = edge["top"] as? Double, let bottom = edge["bottom"] as? Double else { throw DriverError.noEdge }
        return (x, top, bottom, (edge["side"] as? String) == "left" ? -1 : 1)
    }

    /// Phone pointer as fractions of the phone screen, and the phone size in Mac points.
    func pointer() throws -> (x: Double, y: Double)? {
        guard let p = try status()["phonePointer"] as? [String: Any], let x = p["x"] as? Double, let y = p["y"] as? Double else {
            return nil
        }
        return (x, y)
    }

    @discardableResult
    func move(dx: Double, dy: Double, step: Double = 6) throws -> [String: Any] {
        let steps = max(1, Int((max(abs(dx), abs(dy)) / step).rounded(.up)))
        return try app.send(["cmd": "post.move", "dx": dx, "dy": dy, "steps": steps, "interval": 0.008])
    }

    /// Approach the edge from inside the Mac screen, then push through it.
    public func cross(fraction: Double = 0.5) throws -> Bool {
        if owner == "phone" { return true }
        let edge = try edge()
        let y = edge.top + (edge.bottom - edge.top) * fraction
        try app.send(["cmd": "post.moveTo", "x": edge.x - 60 * edge.outward, "y": y])
        Thread.sleep(forTimeInterval: 0.3)
        for _ in 0..<8 {
            try move(dx: 20 * edge.outward, dy: 0, step: 4)
            if owner == "phone" { return true }
        }
        return owner == "phone"
    }

    /// Move back through the phone's edge facing the Mac.
    public func back() throws -> Bool {
        let outward = try edge().outward
        for _ in 0..<40 {
            if owner == "mac" { return true }
            try move(dx: -40 * outward, dy: 0)
        }
        return owner == "mac"
    }

    /// Relative moves (like a trackpad) until the phone pointer reaches the target.
    public func goto(x: Double, y: Double) throws -> (Double, Double) {
        guard owner == "phone" else { throw DriverError.notOnPhone }
        let size = phoneSize()
        for _ in 0..<4 {
            guard let p = try pointer() else { throw DriverError.notOnPhone }
            let dx = (x - p.x) * size.width, dy = (y - p.y) * size.height
            if abs(dx) < 1 && abs(dy) < 1 { break }
            try move(dx: dx, dy: dy, step: 5)
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let p = try pointer() else { throw DriverError.notOnPhone }
        return (p.x, p.y)
    }

    func phoneSize() -> (width: Double, height: Double) {
        // MacHop's default 620-point phone in portrait; the lab only needs the ratio.
        let status = (try? self.status()) ?? [:]
        if let phone = status["phoneSize"] as? [String: Any], let w = phone["width"] as? Double, let h = phone["height"] as? Double {
            return (w, h)
        }
        return (620 * 393 / 852, 620)
    }

    public func click(button: Int = 0) throws {
        guard owner == "phone" else { throw DriverError.notOnPhone }
        try app.send(["cmd": "post.click", "button": button])
    }

    public func type(_ text: String) throws {
        guard owner == "phone" else { throw DriverError.notOnPhone }
        try app.send(["cmd": "post.type", "text": text])
    }

    public func scroll(dy: Double, dx: Double = 0) throws {
        guard owner == "phone" else { throw DriverError.notOnPhone }
        try app.send(["cmd": "post.scroll", "dy": dy, "dx": dx, "steps": 12])
    }
}
