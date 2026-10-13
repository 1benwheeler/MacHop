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

    func edge() throws -> LabEdge {
        guard let edge = LabEdge(status: try status()) else { throw DriverError.noEdge }
        return edge
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
        let start = edge.point(along: edge.start + (edge.end - edge.start) * fraction, inside: 60)
        try app.send(["cmd": "post.moveTo", "x": start.x, "y": start.y])
        Thread.sleep(forTimeInterval: 0.3)
        let push = edge.delta(outward: 20)
        for _ in 0..<8 {
            try move(dx: push.dx, dy: push.dy, step: 4)
            if owner == "phone" { return true }
        }
        return owner == "phone"
    }

    /// Move back through the phone's edge facing the Mac.
    public func back() throws -> Bool {
        let inward = try edge().delta(outward: -40)
        for _ in 0..<40 {
            if owner == "mac" { return true }
            try move(dx: inward.dx, dy: inward.dy)
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

/// The screen edge MacHop shares with the iPhone, as its automation status reports it.
struct LabEdge {
    /// Across the edge: an x beside the screen, a y above it.
    let line: Double
    /// Along the edge: the open part's two ends.
    let start: Double, end: Double
    let side: String

    init?(status: [String: Any]) {
        guard let edge = status["edge"] as? [String: Any], let line = edge["line"] as? Double,
              let start = edge["start"] as? Double, let end = edge["end"] as? Double, let side = edge["side"] as? String else { return nil }
        (self.line, self.start, self.end, self.side) = (line, start, end, side)
    }

    var outward: Double { side == "right" ? 1 : -1 }
    var horizontal: Bool { side == "top" }

    /// The Mac point `along` the edge, `inside` points in from it.
    func point(along: Double, inside: Double) -> (x: Double, y: Double) {
        let across = line - inside * outward
        return horizontal ? (along, across) : (across, along)
    }

    /// A movement of `distance` outward through the edge (negative moves inward), plus `sideways` along it.
    func delta(outward distance: Double, sideways: Double = 0) -> (dx: Double, dy: Double) {
        horizontal ? (sideways, distance * outward) : (distance * outward, sideways)
    }
}
