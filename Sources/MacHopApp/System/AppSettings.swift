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

    enum GestureSetup: String, Codable { case done, skipped }

    /// Whether to show the setup guide at launch. Settings from before the guide
    /// existed count as set up once an iPhone has been chosen.
    var needsSetup: Bool { !(setupFinished ?? (phoneID != nil)) }

    static let key = "settings.v1"

    static func defaultSettings(mainDisplay: UInt32) -> AppSettings {
        AppSettings(session: SessionSettings(layout: PhoneLayout(displayID: mainDisplay)))
    }

    /// Loads saved settings, or the defaults on first launch.
    static func load(defaults: UserDefaults = .standard, mainDisplay: UInt32, displays: [Display] = []) -> AppSettings {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(AppSettings.self, from: data) {
            var settings = saved
            settings.session = settings.session.sanitized()
            return settings
        }
        return defaultSettings(mainDisplay: mainDisplay)
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
