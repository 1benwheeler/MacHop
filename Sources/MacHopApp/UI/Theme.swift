// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

/// MacHop's visual language: a calm grey canvas, white cards with hairline
/// borders, soft icon tiles, small spaced capitals over large titles.
enum Theme {
    static let sidebar = dynamic(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.125, alpha: 1))
    static let canvas = dynamic(light: NSColor(red: 0.972, green: 0.975, blue: 0.982, alpha: 1),
                                dark: NSColor(white: 0.095, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(white: 0.155, alpha: 1))
    static let border = dynamic(light: NSColor(white: 0.885, alpha: 1), dark: NSColor(white: 0.24, alpha: 1))
    static let tile = dynamic(light: NSColor(red: 0.935, green: 0.945, blue: 0.965, alpha: 1),
                              dark: NSColor(white: 0.22, alpha: 1))
    static let selection = dynamic(light: .white, dark: NSColor(white: 0.2, alpha: 1))

    static let cardRadius = 16.0

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Small spaced capitals, then a large title and an optional subtitle (as in Duet's headers).
struct PageHeader: View {
    let overline: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(overline.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 30, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A white card with a hairline border.
struct Panel<Content: View>: View {
    var padding = 20.0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A rounded square holding a symbol, like the platform tiles in Duet.
struct IconTile: View {
    let symbol: String
    var size = 44.0
    var tint: Color = .primary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One line inside a panel: a tile, a title with an optional explanation, and a control.
struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 10)
    }
}

/// A hairline between rows inside a panel.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50)
    }
}

/// A Settings path drawn as chips: Settings › Accessibility › …
struct SettingsPath: View {
    let parts: [String]
    var then: String?

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: 4) {
                    Text(part)
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.tile, in: Capsule())
                    if index < parts.count - 1 {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    }
                }
            }
            if let then {
                Text(then).font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: Double = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x = 0.0, y = 0.0, rowHeight = 0.0, widest = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, widest), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight = 0.0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A speed slider with normal (1×) in the middle, marked and sticky, curving
/// gently to the range's ends on either side. Most people keep the default.
struct SpeedSlider: View {
    @Binding var speed: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text("Slow").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Self.position(for: speed, in: range) },
                                  set: { speed = Self.speed(at: $0, in: range) }), in: 0...1)
                .labelsHidden()
                .background(Capsule().fill(Color.secondary.opacity(0.55)).frame(width: 2, height: 14))
                .accessibilityValue(speed == 1 ? "Normal" : String(format: "%.1f times", speed))
            Text("Fast").font(.caption).foregroundStyle(.secondary)
        }
        .help("The middle mark is normal speed.")
    }

    /// Positions within this distance of the middle snap to normal speed.
    static let snap = 0.035

    static func position(for speed: Double, in range: ClosedRange<Double>) -> Double {
        guard speed.isFinite, speed > 0 else { return 0.5 }
        if speed < 1 { return 0.5 - min(1, log(speed) / log(range.lowerBound)) / 2 }
        return 0.5 + min(1, log(speed) / log(range.upperBound)) / 2
    }

    static func speed(at position: Double, in range: ClosedRange<Double>) -> Double {
        if abs(position - 0.5) < snap { return 1 }
        if position < 0.5 { return pow(range.lowerBound, (0.5 - position) * 2) }
        return pow(range.upperBound, (position - 0.5) * 2)
    }
}
