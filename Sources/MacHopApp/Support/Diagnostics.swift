// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MacHopCore

/// A plain-text report for bug reports: versions, connection state and settings.
/// Safe to post publicly by construction: no device names or identifiers, no keys,
/// no typed text, nothing from the clipboard.
enum Diagnostics {
    /// Everything the report may draw on. The settings include the iPhone's name and
    /// identifier; `render` must never print them.
    struct Facts {
        var version = "?", build = "?"
        var system = "?", architecture = "?", macModel = "?"
        var settings: AppSettings
        var status = "", bluetooth = "", link = ""
        var accessibility = false, capturing = false
        var phoneModel: String?
        var subscribed: [UInt8] = [], required: [UInt8] = []
        var suspended = false, ready = false
        var stats = HIDTransport.Stats()
        var displays: [Display] = []
        var handoffs: [(time: Date, text: String)] = []
    }

    static func copy(_ model: AppModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(model), forType: .string)
    }

    static func report(_ model: AppModel) -> String { render(facts(model)) }

    static func facts(_ model: AppModel) -> Facts {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let transport = model.transport
        var facts = Facts(settings: model.settings)
        facts.version = info["CFBundleShortVersionString"] as? String ?? "?"
        facts.build = info["CFBundleVersion"] as? String ?? "?"
        facts.system = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        facts.architecture = "Apple silicon"
        #else
        facts.architecture = "Intel"
        #endif
        facts.macModel = macModel
        facts.status = "\(model.status)"
        facts.bluetooth = "\(model.bluetooth)"
        facts.link = "\(model.link)"
        facts.accessibility = model.accessibilityGranted
        facts.capturing = model.captureRunning
        facts.phoneModel = model.connector.modelIdentifier
        facts.subscribed = transport.subscribedReports.sorted()
        facts.required = transport.profile.requiredInputReportIDs.sorted()
        facts.suspended = transport.isSuspended
        facts.ready = transport.isReady
        facts.stats = transport.stats
        facts.displays = model.displays
        facts.handoffs = model.recentHandoffs
        return facts
    }

    static func render(_ facts: Facts) -> String {
        let settings = facts.settings, session = settings.session, layout = session.layout, stats = facts.stats
        func list(_ ids: [UInt8]) -> String { ids.map(String.init).joined(separator: ", ") }
        let displays = facts.displays.map { "\(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: ", ")
        var lines = [
            "MacHop \(facts.version) (\(facts.build))",
            "\(facts.system), \(facts.architecture), \(facts.macModel)",
            "",
            "Status: \(facts.status)",
            "Bluetooth: \(facts.bluetooth); link: \(facts.link)",
            "Accessibility: \(facts.accessibility ? "allowed" : "not allowed"); input capture: \(facts.capturing ? "running" : "stopped")",
            "iPhone: \(facts.phoneModel ?? settings.phoneModel ?? "unknown model"); screen: \(settings.screen?.rawValue ?? "automatic")",
            "Reports subscribed: [\(list(facts.subscribed))] of required [\(list(facts.required))]; " +
                "suspended: \(facts.suspended); ready: \(facts.ready)",
            "Keyboard and pointer layout: \(settings.profile.rawValue); MacHop \(settings.paused ? "off" : "on")",
            "",
            "Placement: \(layout.side.rawValue), \(layout.orientation.rawValue)\(layout.flipped ? ", flipped" : ""), " +
                "size \(Int(layout.size)), position \(String(format: "%.2f", layout.edgePosition))",
            "Displays: \(displays)",
            "Scrolling: \(session.scroll.style.rawValue); gestures: \(session.phoneGestures ? "on" : "off"); " +
                "media keys: \(session.mediaKeysToPhone ? "on" : "off"); wake: \(settings.wakesPhone == true ? "on" : "off"); " +
                "edge resistance \(Int(session.edgeResistance)); pointer speed \(String(format: "%.2f", session.pointerSpeed))",
            "",
            "Sent \(stats.submitted) reports, \(stats.coalesced) coalesced, \(stats.backpressureEvents) backpressure, " +
                "\(stats.stalls) stalls",
        ]
        lines.append(facts.handoffs.isEmpty ? "No handoffs since MacHop started." : "Recent handoffs:")
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        lines += facts.handoffs.map { "  \(clock.string(from: $0.time)) \($0.text)" }
        return lines.joined(separator: "\n")
    }

    private static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}
