// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics
import CryptoKit
import Foundation
import Security
import MacHopCore

/// Test-only control channel used by `machop-lab` to drive the running app.
///
/// Off by default. Enable with `defaults write local.machop AutomationEnabled -bool YES`
/// (or launch with `--automation`). It listens on a Unix socket readable only by
/// the current user: ~/Library/Application Support/MacHop/automation.sock.
/// Requests and responses are single-line JSON objects.
///
/// Only programs signed with the same certificate as MacHop itself (its lab tool)
/// may connect. Without that check, any program running as the user could switch
/// automation on and borrow MacHop's Accessibility permission to type and click on
/// the Mac. An unsigned (ad-hoc) MacHop never starts automation at all.
final class AutomationServer {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "AutomationEnabled") || CommandLine.arguments.contains("--automation")
    }

    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacHop/automation.sock")
    }

    private let model: AppModel
    private var listener: Int32 = -1
    private let queue = DispatchQueue(label: "local.machop.automation")

    init(model: AppModel) { self.model = model }

    func start() {
        guard Self.trustedClients != nil else {
            Log.automation.error("Automation needs MacHop to be signed with a certificate; not started")
            return
        }
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.socketURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            Log.automation.error("Automation socket could not start")
            return
        }
        listener = fd
        Log.automation.notice("Automation enabled at \(path, privacy: .public)")
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        // Wake the blocked accept() before closing, so the descriptor can't be reused under it.
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
        listener = -1
        unlink(Self.socketURL.path)
    }

    private nonisolated func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard Self.isTrusted(client) else {
                close(client)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        Log.automation.error("Refused an automation connection from a program not signed like MacHop")
                    }
                }
                continue
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private nonisolated func serve(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                // Posted input runs on this thread: the main thread must stay free to
                // run MacHop's own event tap, which receives these events.
                var data = InputPoster.handles(line) ? InputPoster.respond(to: line)
                    : DispatchQueue.main.sync { MainActor.assumeIsolated { self.respond(to: line) } }
                data.append(0x0A)
                _ = data.withUnsafeBytes { write(client, $0.baseAddress, data.count) }
            }
        }
    }

    // MARK: Who may connect

    /// "Signed with the same certificate as this MacHop", or nil if MacHop has no certificate.
    private nonisolated(unsafe) static let trustedClients: SecRequirement? = {
        var me: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("certificate leaf = H\"\(digest)\"" as CFString, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    /// Checks the connecting process's code signature, identified by its audit token.
    private nonisolated static func isTrusted(_ client: Int32) -> Bool {
        guard let requirement = trustedClients else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Commands

    private func respond(to line: Data) -> Data {
        let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
        let response = handle(request)
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private func handle(_ request: [String: Any]) -> [String: Any] {
        let command = request["cmd"] as? String ?? ""
        let session = model.session
        let transport = model.transport
        func number(_ key: String, _ fallback: Double = 0) -> Double { (request[key] as? NSNumber)?.doubleValue ?? fallback }

        switch command {
        case "status":
            return status()

        case "login":
            model.setLaunchAtLogin(request["enabled"] as? Bool ?? true)
            return ["ok": true, "launchAtLogin": model.launchAtLogin]

        case "enter":
            // `position` along the shared edge (a y beside the screen, an x above it); the middle by default.
            let position = request["position"] as? Double
                ?? session.screenLink.map { ($0.openSpans[0].lowerBound + $0.openSpans[0].upperBound) / 2 } ?? 0
            return ["ok": session.enterPhone(atEdge: position)]

        case "return":
            session.returnToMac(.requested)
            return ["ok": true]

        case "move":
            // Synthetic pointer motion through the session, as if from the trackpad.
            let delta = Point(x: number("dx"), y: number("dy"))
            let given = Point(x: number("x", .nan), y: number("y", .nan))
            let current = CGEvent(source: nil).map { Point(x: $0.location.x, y: $0.location.y) } ?? .zero
            let at = given.isFinite ? given : current
            return ["ok": true, "disposition": "\(session.handle(.pointerMoved(location: at, delta: delta)))"]

        case "button":
            let button = MouseButton(number: Int(number("button")))
            let down = request["down"] as? Bool ?? true
            return ["disposition": "\(session.handle(.button(button, down: down, location: .zero)))"]

        case "scroll":
            let input = ScrollInput(dx: number("dx"), dy: number("dy"), continuous: request["continuous"] as? Bool ?? true,
                                    phase: Self.scrollPhase(request["phase"] as? String),
                                    momentum: Self.momentumPhase(request["momentum"] as? String))
            return ["disposition": "\(session.handle(.scroll(input)))"]

        case "key":
            let code = UInt16(number("code"))
            let down = request["down"] as? Bool ?? true
            let flags = ModifierFlags(rawValue: UInt64(number("flags")))
            return ["disposition": "\(session.handle(.key(code: code, down: down, isRepeat: false, modifiers: flags)))"]

        case "hid.pointer":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            transport.send(.pointer(PointerReport(buttons: UInt8(number("buttons")), x: number("x", 0.5), y: number("y", 0.5))))
            return ["ok": true]

        case "hid.scroll":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            transport.send(.scroll(ScrollReport(wheel: Int(number("wheel")), pan: Int(number("pan")))))
            return ["ok": true]

        case "hid.keyboard":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            let keys = (request["keys"] as? [NSNumber] ?? []).map(\.uint8Value)
            transport.send(.keyboard(KeyboardReport(modifiers: UInt8(number("modifiers")), keys: keys)))
            return ["ok": true]

        case "hid.touch":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            let contacts = (request["contacts"] as? [[String: Any]] ?? []).map { contact in
                TouchReport.Contact(id: UInt8((contact["id"] as? NSNumber)?.intValue ?? 0),
                                    x: (contact["x"] as? NSNumber)?.doubleValue ?? 0.5,
                                    y: (contact["y"] as? NSNumber)?.doubleValue ?? 0.5,
                                    down: contact["down"] as? Bool ?? true)
            }
            transport.send(.touch(TouchReport(contacts: contacts, button: request["button"] as? Bool ?? false)))
            return ["ok": true, "touchSubscribed": transport.subscribedReports.contains(HIDProfile.touchReportID)]

        case "hid.consumer":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            transport.send(.consumer(ConsumerReport(usage: UInt16(number("usage")))))
            // `hold` leaves the usage pressed (for combinations); usage 0 releases it.
            if request["hold"] as? Bool != true { transport.send(.consumer(.released)) }
            return ["ok": true]

        case "hid.type":
            guard transport.isReady else { return ["ok": false, "error": "iPhone not connected"] }
            var typed = 0
            for character in request["text"] as? String ?? "" {
                guard let stroke = KeyMap.keystroke(for: character) else { continue }
                let shift: UInt8 = stroke.shift ? 0x02 : 0
                transport.send(.keyboard(KeyboardReport(modifiers: shift, keys: [stroke.usage])))
                transport.send(.keyboard(KeyboardReport(modifiers: shift)))
                typed += 1
            }
            transport.send(.keyboard(.released))
            return ["ok": true, "typed": typed]

        case "profile":
            guard let variant = HIDProfile.Variant(rawValue: request["variant"] as? String ?? "") else {
                return ["ok": false, "error": "unknown profile"]
            }
            model.update { $0.profile = variant }
            return ["ok": true]

        case "pacing":
            transport.motionInterval = number("motionInterval", transport.motionInterval)
            return ["ok": true, "motionInterval": transport.motionInterval]

        case "settings.scroll":
            model.update {
                if let style = (request["style"] as? String).flatMap(ScrollStyle.init(rawValue:)) { $0.session.scroll.style = style }
                if let speed = request["speed"] as? Double { $0.session.scroll.speed = speed }
                if let reversed = request["reversed"] as? Bool { $0.session.scroll.reversed = reversed }
            }
            return ["ok": true]

        case "settings.layout":
            // For lab runs on another edge; any field left out stays as it is.
            model.update {
                if let side = (request["side"] as? String).flatMap(Side.init(rawValue:)) { $0.session.layout.side = side }
                if let position = request["edgePosition"] as? Double { $0.session.layout.edgePosition = position }
                if let orientation = (request["orientation"] as? String).flatMap(Orientation.init(rawValue:)) {
                    $0.session.layout.orientation = orientation
                }
                if let flipped = request["flipped"] as? Bool { $0.session.layout.flipped = flipped }
            }
            return ["ok": true]

        case "reconnect":
            // The menu's Reconnect: drop the link and connect again (services stay published).
            model.reconnect()
            return ["ok": true]

        case "sleep", "wake":
            // What MacHop does when the Mac sleeps and wakes, without sleeping it.
            model.simulateSleep(command == "sleep")
            return ["ok": true]

        case "pause", "resume":
            if model.settings.paused != (command == "pause") { model.togglePause() }
            return ["ok": true]

        default:
            return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    private func status() -> [String: Any] {
        let session = model.session
        var result: [String: Any] = [
            "ok": true,
            "owner": session.owner == .phone ? "phone" : "mac",
            "enabled": session.isEnabled,
            "disabledReason": session.disabledReason,
            "ready": model.transport.isReady,
            "subscriptions": model.transport.subscribedReports.sorted().map(Int.init),
            "profile": model.settings.profile.rawValue,
            "scrollStyle": model.settings.session.scroll.style.rawValue,
            "status": StatusText.title(model),
            "queued": model.transport.queuedCount,
            "submitted": model.transport.stats.submitted,
            "backpressure": model.transport.stats.backpressureEvents,
            "stalls": model.transport.stats.stalls,
            "launchAtLogin": model.launchAtLogin,
            "bundle": Bundle.main.bundlePath
        ]
        if let link = session.screenLink {
            result["phoneSize"] = ["width": link.phone.width, "height": link.phone.height]
        }
        if let pointer = session.phonePointer, let link = session.screenLink {
            result["phonePointer"] = ["x": pointer.x / link.phone.width, "y": pointer.y / link.phone.height]
        }
        if let link = session.screenLink {
            // `line` is across the edge (an x beside the screen, a y above it); `start` and `end` run along it.
            let layout = session.settings.layout
            result["layout"] = ["side": layout.side.rawValue, "edgePosition": layout.edgePosition,
                                "orientation": layout.orientation.rawValue, "flipped": layout.flipped]
            result["edge"] = ["line": link.edgeLine, "start": link.openSpans[0].lowerBound, "end": link.openSpans[0].upperBound,
                              "side": link.side.rawValue]
        }
        return result
    }

    private static func scrollPhase(_ name: String?) -> ScrollPhase {
        switch name {
        case "mayBegin": .mayBegin
        case "began": .began
        case "changed": .changed
        case "ended": .ended
        case "cancelled": .cancelled
        default: .none
        }
    }

    private static func momentumPhase(_ name: String?) -> MomentumPhase {
        switch name {
        case "began": .began
        case "changed": .changed
        case "ended": .ended
        default: .none
        }
    }
}
