// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import MacHopCore

/// Everything MacHop remembers between launches. Stored as JSON in UserDefaults.
nonisolated struct AppSettings: Codable, Equatable {
    var phoneID: UUID?
    var phoneName: String?
    var session: SessionSettings
    var profile: HIDProfile.Variant = .compatibility
    var paused = false
    /// Set when the setup guide is finished. Absent in settings saved before the guide existed.
    var setupFinished: Bool?
    /// Set the first time the pointer crosses onto the iPhone.
    var hasCrossed: Bool?
    /// Which iPhone screen to use for the layout; nil means automatic.
    var screen: IPhoneScreen?
    /// The model identifier the iPhone last reported (e.g. "iPhone16,1").
    var phoneModel: String?
    /// The gestures step of the setup guide, once finished. MacHop can't see the
    /// iPhone's AssistiveTouch settings, so this is remembered instead.
    var gestureSetup: GestureSetup?
    /// Whether moving onto a sleeping iPhone (or ⌃⌥⌘I) wakes it. Absent means off.
    var wakesPhone: Bool?

    enum GestureSetup: String, Codable { case done, skipped }

    /// Whether to show the setup guide at launch. Settings from before the guide
    /// existed count as set up once an iPhone has been chosen.
    var needsSetup: Bool { !(setupFinished ?? (phoneID != nil)) }

    static let key = "settings.v1"

    static func defaultSettings(mainDisplay: UInt32) -> AppSettings {
        AppSettings(session: SessionSettings(layout: PhoneLayout(displayID: mainDisplay)))
    }

    /// Where saved settings that couldn't be read are kept, so they aren't lost when
    /// the defaults are saved in their place.
    static let unreadableKey = "settings.v1.unreadable"

    /// Loads saved settings, or the defaults on first launch. Settings that can't be read
    /// (damaged, or saved by a newer MacHop with an option this one doesn't know) also
    /// give the defaults, but a copy is kept and the failure is logged.
    static func load(defaults: UserDefaults = .standard, mainDisplay: UInt32, displays: [Display] = []) -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return defaultSettings(mainDisplay: mainDisplay) }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.session = settings.session.sanitized()
            return settings
        } catch {
            defaults.set(data, forKey: unreadableKey)
            // The name of the setting only, never its value.
            Log.app.error("Saved settings could not be read (\(unreadableField(error), privacy: .public)); using the defaults. A copy is kept.")
            return defaultSettings(mainDisplay: mainDisplay)
        }
    }

    /// Which setting stopped the saved settings loading, e.g. "session.scroll.style".
    static func unreadableField(_ error: Error) -> String {
        let path: [CodingKey]
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?: path = context.codingPath + [key]
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?, .dataCorrupted(let context)?:
            path = context.codingPath
        default: return "unknown"
        }
        return path.isEmpty ? "not valid settings" : path.map(\.stringValue).joined(separator: ".")
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
