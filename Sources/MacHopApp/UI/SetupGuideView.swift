// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import SystemConfiguration
import MacHopCore

/// First-run setup, one step at a time. Each step ticks itself off when MacHop
/// can see it is done; the iPhone-side steps MacHop cannot see ask for a click.
struct SetupGuideView: View {
    let model: AppModel
    let onClose: () -> Void

    enum Step: Int, CaseIterable {
        case bluetooth, accessibility, phone, assistiveTouch, tryIt, gestures
    }

    @State private var assistiveTouchOn = false
    @State private var showingPhones = false
    @State private var gestureStart = ProcessInfo.processInfo.systemUptime
    @State private var gesturesSent: Set<InputSession.PhoneAction> = []
    @State private var gesturesSkipped = false
    @State private var openAtLogin = true
    @State private var expanded: Step?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                PageHeader(overline: "Set up MacHop",
                           title: requiredDone ? "You're all set" : "Connect your iPhone",
                           subtitle: "Use your Mac's keyboard and trackpad on your iPhone, as if it were another screen.")
                closeButton
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 22)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Step.allCases, id: \.self) { step in
                            row(step).id(step)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 24)
                }
                .onChange(of: current) { _, step in
                    withAnimation { scroller.scrollTo(step, anchor: .center) }
                }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .sheet(isPresented: $showingPhones) {
            PhonePicker(model: model) { showingPhones = false }
        }
        .onChange(of: model.lastPhoneAction?.time) { _, _ in
            if let sent = model.lastPhoneAction, sent.time >= gestureStart { gesturesSent.insert(sent.action) }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close setup")
    }

    private var footer: some View {
        HStack {
            Toggle("Open MacHop at login", isOn: $openAtLogin)
            Spacer()
            Button(requiredDone ? "Done" : "Finish Later") {
                if requiredDone {
                    model.update { $0.setupFinished = true }
                    if openAtLogin && !model.launchAtLogin { model.setLaunchAtLogin(true) }
                }
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
    }

    private func row(_ step: Step) -> some View {
        let done = isDone(step)
        let open = step == (expanded ?? current)
        return Panel(padding: 18) {
            Button {
                withAnimation(.snappy) { expanded = open ? nil : step }
            } label: {
                HStack(spacing: 14) {
                    IconTile(symbol: symbol(step), size: 40, tint: done ? .green : open ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(step)).font(.system(size: 15, weight: .medium))
                        if let summary = summary(step, done: done) {
                            Text(summary).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                            .accessibilityLabel("Done")
                    } else if optional(step) {
                        Text("Optional").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) { detail(step) }
                    .padding(.leading, 54)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .opacity(done || open || step.rawValue <= (current?.rawValue ?? Step.allCases.count) ? 1 : 0.55)
    }

    // MARK: Steps

    private var current: Step? { Step.allCases.first { !isDone($0) } }

    private var requiredDone: Bool {
        Step.allCases.filter { !optional($0) }.allSatisfy(isDone)
    }

    private func optional(_ step: Step) -> Bool { step == .gestures }

    private func isDone(_ step: Step) -> Bool {
        switch step {
        case .bluetooth:
            switch model.bluetooth {
            case .waiting, .connected: true
            default: false
            }
        case .accessibility: model.accessibilityGranted
        case .phone: model.settings.phoneID != nil && model.phoneReady
        case .assistiveTouch: assistiveTouchOn || model.settings.hasCrossed == true
        case .tryIt: model.settings.hasCrossed == true
        case .gestures: gesturesSkipped || gesturesSent.count == 3
        }
    }

    private func symbol(_ step: Step) -> String {
        switch step {
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .accessibility: "keyboard"
        case .phone: "iphone"
        case .assistiveTouch: "hand.point.up.left"
        case .tryIt: "cursorarrow.motionlines"
        case .gestures: "hand.draw"
        }
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .bluetooth: "Bluetooth"
        case .accessibility: "Keyboard and trackpad access"
        case .phone: "Your iPhone"
        case .assistiveTouch: "AssistiveTouch"
        case .tryIt: "Try it"
        case .gestures: "iPhone gestures"
        }
    }

    private func summary(_ step: Step, done: Bool) -> String? {
        switch step {
        case .phone where done: "Connected to \(model.phoneName)"
        case .gestures where gesturesSkipped: "Skipped"
        case .gestures where done: "Home, App Switcher and Notification Centre"
        case .gestures: "Swipe up for Home, like on an iPad"
        default: nil
        }
    }

    @ViewBuilder private func detail(_ step: Step) -> some View {
        switch step {
        case .bluetooth:
            explain("MacHop connects to your iPhone over Bluetooth, as a keyboard and pointer.")
            if model.bluetooth == .off {
                explain("Turn on Bluetooth from Control Centre.")
            } else if model.bluetooth == .unauthorized {
                Button("Open Bluetooth Settings…") { model.openBluetoothSettings() }
            } else if !isDone(.bluetooth) {
                waiting("Starting Bluetooth…")
            }
        case .accessibility:
            explain("To send your keyboard and trackpad to the iPhone, MacHop needs Accessibility access. It never records what you type.")
            if !isDone(.accessibility) {
                Button("Allow in System Settings…") { model.requestAccessibility() }.buttonStyle(.borderedProminent)
            }
        case .phone:
            phoneDetail
        case .assistiveTouch:
            explain("AssistiveTouch shows the pointer on your iPhone. On your iPhone, open:")
            SettingsPath(parts: ["Settings", "Accessibility", "Touch", "AssistiveTouch"], then: "and turn it on.")
            Button("It's On") { withAnimation { assistiveTouchOn = true } }.buttonStyle(.borderedProminent)
        case .tryIt:
            let side = model.settings.session.layout.side == .right ? "right" : "left"
            explain("Move the pointer past the \(side) edge of your screen. Come back the same way, or press ⌃⌥⌘⎋ at any time.")
            waiting("Waiting for you to move onto your iPhone…")
        case .gestures:
            gesturesDetail
        }
    }

    @ViewBuilder private var phoneDetail: some View {
        if model.settings.phoneID != nil {
            if model.phoneReady {
                Label("Connected to \(model.phoneName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                waiting("Connecting to \(model.phoneName)… Keep it nearby and unlocked.")
                HStack {
                    Button("Reconnect") { model.reconnect() }
                    Button("Choose Another iPhone…") { showingPhones = true }
                }
            }
        } else {
            explain("Your iPhone must be signed in to the same Apple Account as this Mac, with Bluetooth on.")
            Button("Choose Your iPhone…") { showingPhones = true }.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var gesturesDetail: some View {
        explain("Swipe with three fingers on your iPhone, as on an iPad: up for Home, up and hold for the App Switcher, down for Notification Centre. Your iPhone needs to learn them once, which takes about a minute.")
        explain(model.owner == .phone ? "On your iPhone, open:" : "Move onto your iPhone, then on your iPhone open:")
        SettingsPath(parts: ["Settings", "Accessibility", "Touch", "AssistiveTouch", "Devices", Self.macName,
                             "Customise Additional Buttons"])
        VStack(alignment: .leading, spacing: 8) {
            gestureStep(.home, "Swipe up with three fingers, then choose **Home**.")
            gestureStep(.appSwitcher, "Tap Customise Additional Buttons again. Swipe up and pause before lifting, then choose **App Switcher**.")
            gestureStep(.notificationCentre, "Once more, swipe down, then choose **Notification Centre**.")
        }
        HStack {
            Button("Skip") { withAnimation { gesturesSkipped = true } }
            if !gesturesSent.isEmpty {
                Button("Start Over") {
                    gesturesSent = []
                    gestureStart = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }

    private func gestureStep(_ action: InputSession.PhoneAction, _ text: LocalizedStringKey) -> some View {
        let sent = gesturesSent.contains(action)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: sent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(sent ? Color.green : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(sent ? "Sent" : "Waiting")
    }

    // MARK: Pieces

    private func explain(_ text: String) -> some View {
        Text(text).font(.system(size: 13.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 13.5)).foregroundStyle(.secondary)
        }
    }

    /// The Mac's name as the iPhone lists it under AssistiveTouch → Devices.
    static let macName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "your Mac"
}
