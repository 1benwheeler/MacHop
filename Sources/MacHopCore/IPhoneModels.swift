// SPDX-License-Identifier: AGPL-3.0-only

/// iPhone screens, so the phone MacHop draws and drives has the real screen's shape.
/// An iPhone reports its model identifier (e.g. "iPhone16,1") over Bluetooth.
public enum IPhoneScreen: String, Codable, Sendable, CaseIterable {
    /// Use the model the iPhone reports; Standard until it has.
    case automatic
    /// 6.1–6.3": iPhone 12–17 and their Pro models, 16e.
    case standard
    /// 6.5–6.9": Plus, Pro Max and Air models.
    case large
    /// 5.4–5.8": mini, and X/XS/11 Pro.
    case compact
    /// 4.7": iPhone SE (2nd and 3rd generation), the older 16:9 shape.
    case se

    /// The screen in iOS points (width, height) for a fixed choice.
    public var points: (width: Double, height: Double) {
        switch self {
        case .automatic, .standard: (393, 852)
        case .large: (430, 932)
        case .compact: (375, 812)
        case .se: (375, 667)
        }
    }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .standard: "Standard (6.1–6.3″)"
        case .large: "Plus, Pro Max or Air (6.5–6.9″)"
        case .compact: "mini (5.4–5.8″)"
        case .se: "SE (4.7″)"
        }
    }
}

public enum IPhoneModels {
    /// Marketing name and screen size in points for each model identifier since iPhone X.
    public static func model(for identifier: String) -> (name: String, width: Double, height: Double)? {
        table[identifier]
    }

    private static let table: [String: (name: String, width: Double, height: Double)] = [
        "iPhone10,3": ("iPhone X", 375, 812), "iPhone10,6": ("iPhone X", 375, 812),
        "iPhone11,2": ("iPhone XS", 375, 812), "iPhone11,4": ("iPhone XS Max", 414, 896),
        "iPhone11,6": ("iPhone XS Max", 414, 896), "iPhone11,8": ("iPhone XR", 414, 896),
        "iPhone12,1": ("iPhone 11", 414, 896), "iPhone12,3": ("iPhone 11 Pro", 375, 812),
        "iPhone12,5": ("iPhone 11 Pro Max", 414, 896), "iPhone12,8": ("iPhone SE", 375, 667),
        "iPhone13,1": ("iPhone 12 mini", 375, 812), "iPhone13,2": ("iPhone 12", 390, 844),
        "iPhone13,3": ("iPhone 12 Pro", 390, 844), "iPhone13,4": ("iPhone 12 Pro Max", 428, 926),
        "iPhone14,4": ("iPhone 13 mini", 375, 812), "iPhone14,5": ("iPhone 13", 390, 844),
        "iPhone14,2": ("iPhone 13 Pro", 390, 844), "iPhone14,3": ("iPhone 13 Pro Max", 428, 926),
        "iPhone14,6": ("iPhone SE", 375, 667), "iPhone14,7": ("iPhone 14", 390, 844),
        "iPhone14,8": ("iPhone 14 Plus", 428, 926), "iPhone15,2": ("iPhone 14 Pro", 393, 852),
        "iPhone15,3": ("iPhone 14 Pro Max", 430, 932), "iPhone15,4": ("iPhone 15", 393, 852),
        "iPhone15,5": ("iPhone 15 Plus", 430, 932), "iPhone16,1": ("iPhone 15 Pro", 393, 852),
        "iPhone16,2": ("iPhone 15 Pro Max", 430, 932), "iPhone17,1": ("iPhone 16 Pro", 402, 874),
        "iPhone17,2": ("iPhone 16 Pro Max", 440, 956), "iPhone17,3": ("iPhone 16", 393, 852),
        "iPhone17,4": ("iPhone 16 Plus", 430, 932), "iPhone17,5": ("iPhone 16e", 390, 844),
    ]
}

extension PhoneLayout {
    /// This layout sized for a screen of `points`: the real shape, and a size on the
    /// Mac that keeps the default (620 points for a 852-point-tall iPhone) proportional.
    public func sized(for points: (width: Double, height: Double)) -> PhoneLayout {
        var copy = self
        copy.aspectRatio = points.width / points.height
        copy.size = PhoneLayout.referenceSize * points.height / 852
        return copy.sanitized()
    }
}
