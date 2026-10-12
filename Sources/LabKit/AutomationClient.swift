// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Talks to a running MacHop over its opt-in automation socket.
public final class AutomationClient {
    public enum ClientError: Error, CustomStringConvertible {
        case notRunning(String), failed(String)
        public var description: String {
            switch self {
            case .notRunning(let path):
                "MacHop's automation socket is not available at \(path).\n" +
                "Enable it with: defaults write local.machop AutomationEnabled -bool YES, then restart MacHop."
            case .failed(let message): message
            }
        }
    }

    public static var defaultPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacHop/automation.sock").path
    }

    private let fd: Int32
    private var buffer = Data()

    public init(path: String = AutomationClient.defaultPath) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, result == 0 else {
            if fd >= 0 { close(fd) }
            throw ClientError.notRunning(path)
        }
    }

    deinit { close(fd) }

    @discardableResult
    public func send(_ request: [String: Any]) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw ClientError.failed("could not write to MacHop") }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { throw ClientError.failed("MacHop closed the connection") }
            buffer.append(chunk, count: count)
        }
        let newline = buffer.firstIndex(of: 0x0A)!
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        return (try JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    }

    public func status() throws -> [String: Any] { try send(["cmd": "status"]) }

    public var isPhoneReady: Bool { ((try? status())?["ready"] as? Bool) == true }

    /// Waits until the phone is subscribed (e.g. after a profile change).
    public func waitUntilReady(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPhoneReady { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
