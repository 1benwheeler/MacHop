// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import MacHopCore

/// Which page the main window shows. Shared with the app delegate so the menu
/// bar can open a particular page or the setup guide.
@Observable
final class Navigation {
    enum Page: Hashable, CaseIterable {
        case phone, gestures, scrolling, settings
    }

    var page: Page = .phone
    var showingSetup = false
}

/// MacHop's window: a sidebar of pages, and the setup guide in place of the page when open.
struct MainView: View {
    let model: AppModel
    @Bindable var navigation: Navigation
    var showAbout: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, navigation: navigation, showAbout: showAbout)
                .frame(width: 250)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if navigation.showingSetup {
                    SetupGuideView(model: model) { navigation.showingSetup = false }
                } else {
                    page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .frame(minWidth: 860, minHeight: 600)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch navigation.page {
        case .phone: PhonePage(model: model)
        case .gestures: GesturesPage(model: model) { navigation.showingSetup = true }
        case .scrolling: ScrollingPage(model: model)
        case .settings: SettingsPage(model: model)
        }
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    let model: AppModel
    @Bindable var navigation: Navigation
    let showAbout: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 46)
            header.padding(.horizontal, 18).padding(.bottom, 22)
            item(.phone, "My iPhone", "iphone")
            item(.gestures, "Gestures", "hand.draw")
            item(.scrolling, "Scrolling", "arrow.up.and.down")
            item(.settings, "Settings", "gearshape")
            Spacer()
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 22).padding(.bottom, 10)
            link("Setup Guide", "checklist") {
                navigation.showingSetup = true
            }
            link("About MacHop", "info.circle", action: showAbout)
            Text("Version \(Self.version)")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 1), Color(red: 0.42, green: 0.3, blue: 0.95)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "iphone").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("IPHONE").font(.system(size: 11, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
                Text(model.settings.phoneID == nil ? "Not set up" : model.phoneName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(model.statusColour).frame(width: 7, height: 7)
                    Text(shortStatus).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var shortStatus: String {
        switch model.status {
        case .controlling: "In use"
        case .ready: "Connected"
        case .paused: "Off"
        case .connecting, .waitingForPhone: "Connecting…"
        case .phoneAsleep: "Asleep"
        case .choosePhone: "Not set up"
        case .blocked: "On hold"
        default: "Needs attention"
        }
    }

    private func item(_ page: Navigation.Page, _ title: String, _ symbol: String) -> some View {
        let selected = page == navigation.page && !navigation.showingSetup
        return Button {
            navigation.showingSetup = false
            navigation.page = page
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 22)
                Text(title).font(.system(size: 15, weight: selected ? .medium : .regular))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: selected ? .black.opacity(0.05) : .clear, radius: 2, y: 1)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 26).offset(x: -8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 14)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func link(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 22)
                Text(title).font(.system(size: 14))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }

    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
}

// MARK: Page frame

/// The common page layout: header, a hairline, then content on the canvas.
private struct PageFrame<Content: View>: View {
    let overline: String
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(overline: overline, title: title, subtitle: subtitle)
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 22)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 26)
            }
        }
    }
}

private func sectionTitle(_ text: String) -> some View {
    Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
}

// MARK: My iPhone

private struct PhonePage: View {
    let model: AppModel
    @State private var showingPhones = false

    var body: some View {
        PageFrame(overline: "Your iPhone",
                  title: model.settings.phoneID == nil ? "Connect your iPhone" : model.phoneName,
                  subtitle: StatusText.detail(model)) {
            Panel(padding: 0) {
                DeviceStage(displays: model.displays, layout: model.settings.session.layout, status: model.stageState) { layout in
                    model.update { $0.session.layout = layout }
                }
                .frame(height: 180)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .accessibilityLabel("Arrangement: your Mac's screens and your iPhone")
                .accessibilityValue(arrangementDescription)
                .accessibilityActions {
                    Button("Move iPhone to the left side") { model.update { $0.session.layout.side = .left } }
                    Button("Move iPhone to the right side") { model.update { $0.session.layout.side = .right } }
                    Button("Move iPhone to the top") { model.update { $0.session.layout.side = .top } }
                    Button(model.settings.session.layout.side.isHorizontal ? "Move iPhone left" : "Move iPhone up") { nudge(-0.1) }
                    Button(model.settings.session.layout.side.isHorizontal ? "Move iPhone right" : "Move iPhone down") { nudge(0.1) }
                }
                Text("Drag your iPhone to where it sits beside your Mac.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 10)
                HStack(spacing: 10) {
                    StatusPill(text: StatusText.title(model), colour: model.statusColour)
                    if let notice = model.notice {
                        Text(notice).font(.system(size: 12.5)).foregroundStyle(.orange).lineLimit(2)
                    }
                    Spacer()
                    // The connection lives here too: which iPhone, and what to do in this state.
                    if model.settings.phoneID != nil { Button("Change iPhone…") { showingPhones = true } }
                    primaryActions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            Panel { ArrangementControls(model: model) }
        }
        .sheet(isPresented: $showingPhones) {
            PhonePicker(model: model) { showingPhones = false }
        }
    }

    private func nudge(_ amount: Double) {
        model.update { $0.session.layout.edgePosition = min(1, max(0, $0.session.layout.edgePosition + amount)) }
    }

    private var arrangementDescription: String {
        let layout = model.settings.session.layout
        let percent = Int(layout.edgePosition * 100)
        return layout.side == .top ? "iPhone above the screen, \(percent) percent of the way across"
            : "iPhone on the \(layout.side.rawValue) of the screen, \(percent) percent of the way down"
    }

    @ViewBuilder private var primaryActions: some View {
        switch model.status {
        case .needsAccessibility: Button("Allow Access…") { model.requestAccessibility() }.buttonStyle(.borderedProminent)
        case .bluetoothDenied: Button("Open Bluetooth Settings…") { model.openBluetoothSettings() }
        case .controlling: Button("Return to Mac") { model.returnToMac() }
        case .connecting, .waitingForPhone: Button("Reconnect") { model.reconnect() }
        case .paused: Button("Turn On") { model.togglePause() }.buttonStyle(.borderedProminent)
        case .choosePhone: Button("Choose iPhone…") { showingPhones = true }.buttonStyle(.borderedProminent)
        default: Button("Turn Off") { model.togglePause() }
        }
    }
}

/// What the drawing doesn't set: the iPhone's size and orientation, pointer speed and edge resistance.
struct ArrangementControls: View {
    let model: AppModel

    var body: some View {
        SettingRow(symbol: "iphone", title: "iPhone model",
                   detail: "Sets its real shape and size on screen.") {
            Picker("iPhone model", selection: Binding(get: { model.settings.screen ?? .automatic },
                                                      set: { model.setScreen($0) })) {
                ForEach(IPhoneScreen.allCases, id: \.self) { choice in
                    Text(choice == .automatic ? model.detectedModelName.map { "Automatic (\($0))" } ?? "Automatic"
                                              : choice.title).tag(choice)
                }
            }
            .labelsHidden().frame(width: 250)
        }
        RowDivider()
        SettingRow(symbol: "rectangle.portrait.rotate", title: "Orientation",
                   detail: "Match the drawing to your iPhone, Dynamic Island and all.") {
            HStack(spacing: 8) {
                Picker("Orientation", selection: model.binding(\.session.layout.orientation)) {
                    Text("Portrait").tag(Orientation.portrait)
                    Text("Landscape").tag(Orientation.landscape)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Button {
                    withAnimation(.snappy) { model.update { $0.session.layout.flipped.toggle() } }
                } label: {
                    Label("Flip", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Turn your iPhone around in the drawing")
            }
        }
        RowDivider()
        SettingRow(symbol: "cursorarrow.motionlines", title: "Pointer speed on iPhone",
                   detail: "How far the pointer moves on your iPhone.") {
            SpeedSlider(speed: model.binding(\.session.pointerSpeed), range: SessionSettings.pointerSpeedRange)
                .frame(width: 250)
        }
        RowDivider()
        SettingRow(symbol: "hand.raised", title: "Edge resistance", detail: "How hard you push before crossing.") {
            Picker("Edge resistance", selection: model.binding(\.session.edgeResistance)) {
                Text("None").tag(0.0)
                Text("Low").tag(6.0)
                Text("Medium").tag(18.0)
                Text("High").tag(40.0)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
        }
    }
}

// MARK: Gestures

private struct GesturesPage: View {
    let model: AppModel
    let openSetup: () -> Void

    var body: some View {
        PageFrame(overline: "Trackpad", title: "iPhone Gestures",
                  subtitle: "While you're on your iPhone, swipe with three fingers, just like on an iPad.") {
            HStack(spacing: 16) {
                tile("arrow.up", "Home", "Swipe up")
                tile("rectangle.stack", "App Switcher", "Swipe up and hold")
                tile("bell", "Notification Centre", "Swipe down")
            }
            .opacity(model.settings.session.phoneGestures ? 1 : 0.45)
            Panel {
                SettingRow(symbol: "hand.draw", title: "iPhone gestures",
                           detail: "Mission Control stays blocked while you're on your iPhone either way.") {
                    Toggle("iPhone gestures", isOn: model.binding(\.session.phoneGestures)).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(symbol: "checklist", title: "One-time setup on your iPhone",
                           detail: "Home works straight away. For the App Switcher and Notification Centre, your iPhone needs to learn the swipes once; the guide walks you through it in about a minute.") {
                    Button("Set Up…", action: openSetup)
                }
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: symbol, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .medium))
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: Scrolling

private struct ScrollingPage: View {
    let model: AppModel

    var body: some View {
        let style = model.settings.session.scroll.style
        PageFrame(overline: "Trackpad", title: "Scrolling",
                  subtitle: "iPhone can't scroll quite like a Mac, so choose how two-finger scrolling works on it.") {
            Panel {
                choice(.drag, symbol: "hand.point.up.left.and.text", title: "Drag",
                       detail: "Smooth, like a finger, but the pointer moves with the page.")
                RowDivider()
                choice(.wheel, symbol: "computermouse", title: "Scroll wheel",
                       detail: "The pointer stays still while the page moves, in small steps. Swiping up from the bottom of the iPhone goes straight Home.")
                RowDivider()
                choice(.off, symbol: "nosign", title: "Off",
                       detail: "Two-finger scrolling does nothing on the iPhone. Scroll by holding the button and dragging.")
            }
            Panel {
                Group {
                    SettingRow(symbol: "speedometer", title: "Speed") {
                        SpeedSlider(speed: model.binding(\.session.scroll.speed), range: 0.25...4)
                            .frame(width: 250)
                    }
                    RowDivider()
                    SettingRow(symbol: "arrow.up.arrow.down", title: "Reverse direction on iPhone") {
                        Toggle("Reverse", isOn: model.binding(\.session.scroll.reversed)).toggleStyle(.switch).labelsHidden()
                    }
                    if style == .drag {
                        RowDivider()
                        SettingRow(symbol: "arrow.left.and.right", title: "Horizontal scrolling") {
                            Toggle("Horizontal", isOn: model.binding(\.session.scroll.horizontal)).toggleStyle(.switch).labelsHidden()
                        }
                    }
                }
                .disabled(style == .off)
                .opacity(style == .off ? 0.5 : 1)
            }
        }
    }

    /// One way of scrolling, chosen by clicking anywhere on its row.
    private func choice(_ value: ScrollStyle, symbol: String, title: String, detail: String) -> some View {
        let selected = model.settings.session.scroll.style == value
        return Button {
            model.update { $0.session.scroll.style = value }
        } label: {
            SettingRow(symbol: symbol, title: title, detail: detail) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Settings

private struct SettingsPage: View {
    let model: AppModel
    @State private var showingAdvanced = false

    var body: some View {
        PageFrame(overline: "MacHop", title: "Settings") {
            Panel {
                SettingRow(symbol: "power", title: "Open at login") {
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                // On means on, matching the switch in the menu bar.
                SettingRow(symbol: "power.circle", title: "Control your iPhone from this Mac",
                           detail: "When this is off, your keyboard and trackpad stay on your Mac.") {
                    Toggle("Control your iPhone from this Mac", isOn: Binding(get: { !model.settings.paused },
                                                   set: { on in model.update { $0.paused = !on } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(symbol: "moon.zzz", title: "Wake your iPhone when you move onto it",
                           detail: "When this is off, a sleeping iPhone stays asleep until you wake it.") {
                    Toggle("Wake your iPhone", isOn: Binding(get: { model.settings.wakesPhone == true },
                                                             set: { on in model.update { $0.wakesPhone = on } }))
                        .toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(symbol: "speaker.wave.2", title: "Volume and media keys control iPhone",
                           detail: "While you're on your iPhone, the volume, mute and play keys control it instead of this Mac.") {
                    Toggle("Media keys", isOn: model.binding(\.session.mediaKeysToPhone)).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingRow(symbol: "arrow.left.arrow.right", title: "Jump to your iPhone and back",
                           detail: "Press ⌃⌥⌘⎋ to return to your Mac at any time.") {
                    KeyCaps(keys: "⌃⌥⌘I")
                }
                if !model.accessibilityGranted {
                    RowDivider()
                    SettingRow(symbol: "lock", title: "Accessibility access needed") {
                        Button("Allow…") { model.requestAccessibility() }
                    }
                }
            }
            sectionTitle("Advanced")
            Panel {
                SettingRow(symbol: "keyboard", title: "Keyboard and pointer layout",
                           detail: "Changing it briefly reconnects your iPhone. Compatibility is the one tested on iPhone.") {
                    Picker("Layout", selection: model.binding(\.profile)) {
                        Text("Compatibility").tag(HIDProfile.Variant.compatibility)
                        Text("Standard").tag(HIDProfile.Variant.standard)
                        Text("Relative pointer").tag(HIDProfile.Variant.relative)
                    }
                    .labelsHidden().frame(width: 170)
                }
                RowDivider()
                SettingRow(symbol: "chart.bar", title: "Diagnostics",
                           detail: "\(model.subscriptions) input reports subscribed · \(model.stats.submitted) sent, \(model.stats.coalesced) coalesced · \(model.stats.backpressureEvents) backpressure, \(model.stats.stalls) stalls") {
                    EmptyView()
                }
            }
        }
    }
}

/// A keyboard shortcut, shown as a key cap.
private struct KeyCaps: View {
    let keys: String

    var body: some View {
        Text(keys).font(.system(size: 14, weight: .medium)).monospaced()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 7))
    }
}

extension AppModel {
    /// A binding that writes through `update`, so every change is saved and applied.
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}
