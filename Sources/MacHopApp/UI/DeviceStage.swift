// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import MacHopCore

/// A drawing of the Mac's displays with the iPhone beside the chosen one, as
/// MacHop arranges them. With `onArrange`, the iPhone can be dragged to any exposed
/// display edge, like the display arrangement in System Settings.
struct DeviceStage: View {
    enum Status: Equatable { case offline, ready, controlling }

    let displays: [Display]
    let layout: PhoneLayout
    var status: Status = .ready
    /// Called with the new arrangement when a dragged iPhone is dropped.
    var onArrange: ((PhoneLayout) -> Void)?

    /// The iPhone's centre in global display coordinates while it is dragged.
    @State private var dragCentre: Point?
    /// Where the drag grabbed the iPhone, relative to its centre (global points).
    @State private var grab = Point.zero

    var body: some View {
        GeometryReader { proxy in
            let map = StageMap(size: proxy.size, displays: displays, layout: layout)
            let target = dragCentre.flatMap { ScreenLink.snappedLayout(centre: $0, base: layout, displays: displays) }
            Canvas { context, _ in
                draw(in: &context, map: map, target: target)
            }
            .contentShape(Rectangle())
            .gesture(drag(map: map), including: onArrange == nil ? .none : .all)
            .onContinuousHover { phase in
                guard onArrange != nil, dragCentre == nil else { return }
                if case .active(let point) = phase, let phone = phoneRect(map: map), phone.insetBy(dx: -6, dy: -6).contains(point) {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    private func phoneRect(map: StageMap) -> CGRect? {
        ScreenLink(layout: layout, displays: displays).map { placedPhone($0, map: map) }
    }

    /// The phone as drawn: a few points clear of the Mac, like real devices side by side.
    private func placedPhone(_ link: ScreenLink, map: StageMap) -> CGRect {
        map.view(link.phone).offsetBy(dx: link.side == .right ? Self.gap : -Self.gap, dy: 0)
    }

    private static let gap = 7.0

    private func drag(map: StageMap) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let point = map.global(value.location)
                if dragCentre == nil {
                    guard let link = ScreenLink(layout: layout, displays: displays),
                          placedPhone(link, map: map).insetBy(dx: -6, dy: -6).contains(value.startLocation) else { return }
                    let start = map.global(value.startLocation)
                    grab = Point(x: start.x - link.phone.midX, y: start.y - link.phone.midY)
                }
                NSCursor.closedHand.set()
                dragCentre = Point(x: point.x - grab.x, y: point.y - grab.y)
            }
            .onEnded { _ in
                defer {
                    dragCentre = nil
                    NSCursor.arrow.set()
                }
                guard let centre = dragCentre,
                      let snapped = ScreenLink.snappedLayout(centre: centre, base: layout, displays: displays) else { return }
                withAnimation(.snappy) { onArrange?(snapped) }
            }
    }

    private func draw(in context: inout GraphicsContext, map: StageMap, target: PhoneLayout?) {
        let shown = target ?? layout
        guard let link = ScreenLink(layout: shown, displays: displays) else {
            context.draw(Text("Drag your iPhone beside a screen edge").foregroundStyle(.secondary),
                         at: CGPoint(x: map.size.width / 2, y: map.size.height / 2))
            return
        }
        for display in displays {
            drawDisplay(map.view(display.frame), chosen: display.id == shown.displayID,
                        builtIn: CGDisplayIsBuiltin(display.id) != 0, in: &context)
        }
        // The shared edge.
        let x = link.side == .right ? link.display.maxX : link.display.minX
        for span in link.openSpans {
            let r = map.view(MacHopCore.Rect(x: x, y: span.lowerBound, width: 0, height: span.upperBound - span.lowerBound))
                .offsetBy(dx: (link.side == .right ? 1 : -1) * Self.gap / 2, dy: 0)
            var edge = Path()
            edge.move(to: CGPoint(x: r.minX, y: r.minY + 2))
            edge.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2))
            switch status {
            case .offline:
                context.stroke(edge, with: .color(.secondary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
            case .ready, .controlling:
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: status == .controlling ? 6 : 4))
                    glow.stroke(edge, with: .color(.accentColor.opacity(0.9)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
                context.stroke(edge, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        if let centre = dragCentre {
            // Where it will snap, then the iPhone itself following the pointer.
            let ghost = placedPhone(link, map: map)
            context.stroke(Path(roundedRect: ghost, cornerRadius: min(ghost.width, ghost.height) * 0.16),
                           with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let size = link.phone
            let free = map.view(MacHopCore.Rect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                                                width: size.width, height: size.height))
            context.opacity = 0.9
            drawPhone(free, landscape: shown.orientation == .landscape, in: &context)
        } else {
            drawPhone(placedPhone(link, map: map), landscape: shown.orientation == .landscape, in: &context)
        }
    }

    /// A Mac display: a MacBook (thin bezel on an aluminium base) for the built-in
    /// screen, a monitor on a stand otherwise. Calm wallpaper on the chosen display.
    private func drawDisplay(_ rect: CGRect, chosen: Bool, builtIn: Bool, in context: inout GraphicsContext) {
        let aluminium = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(white: 0.86), Color(white: 0.70)]),
            startPoint: CGPoint(x: rect.midX, y: rect.maxY), endPoint: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.08))
        if builtIn {
            // Base: a little wider than the lid, with the opening notch.
            let height = max(4, rect.height * 0.045)
            let base = CGRect(x: rect.minX - rect.width * 0.055, y: rect.maxY - 1, width: rect.width * 1.11, height: height)
            context.fill(Path(roundedRect: base, cornerRadii: RectangleCornerRadii(topLeading: 1, bottomLeading: height * 0.7,
                                                                                    bottomTrailing: height * 0.7, topTrailing: 1)),
                         with: aluminium)
            let notch = CGRect(x: rect.midX - rect.width * 0.08, y: base.minY, width: rect.width * 0.16, height: height * 0.32)
            context.fill(Path(roundedRect: notch, cornerRadii: RectangleCornerRadii(bottomLeading: notch.height,
                                                                                     bottomTrailing: notch.height)),
                         with: .color(Color(white: 0.62)))
        } else {
            // Stand: a neck and a foot.
            let neck = CGRect(x: rect.midX - rect.width * 0.06, y: rect.maxY, width: rect.width * 0.12, height: rect.height * 0.1)
            context.fill(Path(neck), with: aluminium)
            let foot = CGRect(x: rect.midX - rect.width * 0.15, y: neck.maxY - 1, width: rect.width * 0.3, height: max(3, rect.height * 0.025))
            context.fill(Path(roundedRect: foot, cornerRadius: foot.height / 2), with: aluminium)
        }
        let radius = max(3, min(rect.width, rect.height) * 0.04)
        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(Color(white: 0.10)))
        let bezel = max(2, min(rect.width, rect.height) * 0.02)
        let screen = rect.insetBy(dx: bezel, dy: bezel)
        let colours: [Color] = chosen
            ? [Color(red: 0.62, green: 0.78, blue: 1.00), Color(red: 0.55, green: 0.62, blue: 0.97), Color(red: 0.68, green: 0.62, blue: 0.94)]
            : [Color(white: 0.55), Color(white: 0.42)]
        context.fill(Path(roundedRect: screen, cornerRadius: max(1, radius - bezel)),
                     with: .linearGradient(Gradient(colors: colours), startPoint: CGPoint(x: screen.minX, y: screen.minY),
                                           endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
        // Menu bar.
        let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: max(2, screen.height * 0.035))
        context.fill(Path(roundedRect: bar, cornerRadii: RectangleCornerRadii(topLeading: max(1, radius - bezel),
                                                                               topTrailing: max(1, radius - bezel))),
                     with: .color(.white.opacity(0.35)))
    }

    private func drawPhone(_ rect: CGRect, landscape: Bool, in context: inout GraphicsContext) {
        let radius = min(rect.width, rect.height) * 0.16
        let body = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(body, with: .color(Color(white: 0.08)))
        context.stroke(body, with: .color(Color(white: 0.45)), lineWidth: 1)
        let bezel = max(2, min(rect.width, rect.height) * 0.045)
        let screen = rect.insetBy(dx: bezel, dy: bezel)
        let lit = status != .offline
        let colours: [Color] = lit
            ? [Color(red: 0.22, green: 0.52, blue: 0.98), Color(red: 0.30, green: 0.28, blue: 0.86)]
            : [Color(white: 0.28), Color(white: 0.20)]
        context.fill(Path(roundedRect: screen, cornerRadius: max(1, radius - bezel)),
                     with: .linearGradient(Gradient(colors: colours), startPoint: CGPoint(x: screen.minX, y: screen.minY),
                                           endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
        // Dynamic Island.
        let island = landscape
            ? CGRect(x: screen.minX + screen.width * 0.03, y: screen.midY - screen.height * 0.15,
                     width: screen.width * 0.035, height: screen.height * 0.3)
            : CGRect(x: screen.midX - screen.width * 0.15, y: screen.minY + screen.height * 0.025,
                     width: screen.width * 0.3, height: screen.height * 0.035)
        context.fill(Path(roundedRect: island, cornerRadius: min(island.width, island.height) / 2), with: .color(.black))
        if status == .controlling {
            // The AssistiveTouch pointer.
            let d = min(screen.width, screen.height) * 0.12
            let dot = CGRect(x: screen.midX - d / 2, y: screen.midY - d / 2, width: d, height: d)
            context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.55)))
            context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.25)), lineWidth: 1)
        }
    }
}

/// A capsule with a coloured dot: the connection state at a glance.
struct StatusPill: View {
    let text: String
    let colour: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(colour.opacity(0.14), in: Capsule())
    }
}

/// Maps global display coordinates to the stage and back. The frame leaves room for
/// the iPhone on every side of every display, so it stays put while the iPhone moves.
private struct StageMap {
    let size: CGSize
    let origin: Point
    let scale: Double
    let offset: CGPoint

    init(size: CGSize, displays: [Display], layout: PhoneLayout) {
        self.size = size
        var union = displays.first?.frame ?? MacHopCore.Rect(x: 0, y: 0, width: 1512, height: 982)
        for display in displays { union = union.union(display.frame) }
        let phone = layout.phoneSize
        let room = MacHopCore.Rect(x: union.minX - phone.width - 16, y: union.minY - phone.height * 0.35,
                                   width: union.width + 2 * (phone.width + 16), height: union.height + phone.height * 0.7)
        let pad = 10.0
        scale = min((size.width - 2 * pad) / room.width, (size.height - 2 * pad) / room.height)
        origin = Point(x: room.minX, y: room.minY)
        offset = CGPoint(x: (size.width - room.width * scale) / 2, y: (size.height - room.height * scale) / 2)
    }

    func view(_ r: MacHopCore.Rect) -> CGRect {
        CGRect(x: offset.x + (r.minX - origin.x) * scale, y: offset.y + (r.minY - origin.y) * scale,
               width: r.width * scale, height: r.height * scale)
    }

    func global(_ p: CGPoint) -> Point {
        Point(x: origin.x + (p.x - offset.x) / scale, y: origin.y + (p.y - offset.y) / scale)
    }
}

extension MacHopCore.Rect {
    func union(_ other: MacHopCore.Rect) -> MacHopCore.Rect {
        let minX = Swift.min(self.minX, other.minX), minY = Swift.min(self.minY, other.minY)
        let maxX = Swift.max(self.maxX, other.maxX), maxY = Swift.max(self.maxY, other.maxY)
        return MacHopCore.Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension AppModel {
    var stageState: DeviceStage.Status {
        switch status {
        case .controlling: .controlling
        case .ready: .ready
        default: .offline
        }
    }

    /// Colour for the status pill.
    var statusColour: Color {
        switch status {
        case .ready, .controlling: .green
        case .connecting, .waitingForPhone, .choosePhone, .paused, .blocked: .orange
        default: .red
        }
    }
}
