// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// "Choose your iPhone": nearby Apple devices (iPhones first), with everything else
/// tucked away. Choosing closes it, and closing it stops the Bluetooth search.
struct PhonePicker: View {
    let model: AppModel
    /// The devices to list; nil means the live Bluetooth search (set only for design checks).
    var sample: [NearbyDevice]? = nil
    let close: () -> Void
    @State private var showingOthers: Bool

    init(model: AppModel, sample: [NearbyDevice]? = nil, showingOthers: Bool = false, close: @escaping () -> Void) {
        self.model = model
        self.sample = sample
        self.close = close
        _showingOthers = State(initialValue: showingOthers)
    }

    /// A fixed size: however many devices turn up, the list scrolls and Done stays in view.
    static let size = CGSize(width: 480, height: 460)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your iPhone").font(.system(size: 20, weight: .semibold))
                Text("Keep it unlocked and nearby, with Bluetooth on and signed in to the same Apple Account as this Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { list }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 2)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onExitCommand(perform: finish)
        .onAppear { if sample == nil && !model.isSearching { model.searchForPhones() } }
        .onDisappear { model.stopSearching() }
    }

    @ViewBuilder private var list: some View {
            Panel(padding: 0) {
                if apple.isEmpty {
                    HStack(spacing: 8) {
                        if model.isSearching { ProgressView().controlSize(.small) }
                        Text(model.isSearching ? "Looking for your iPhone…" : "No iPhone found.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                ForEach(Array(apple.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { RowDivider() }
                    row(device)
                }
            }
            if !others.isEmpty {
                DisclosureGroup(isExpanded: $showingOthers) {
                    Panel(padding: 0) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { RowDivider() }
                            row(device)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Other devices (\(others.count))").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
    }

    private var footer: some View {
        HStack {
            if model.isSearching {
                ProgressView().controlSize(.small)
                Text("Searching…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                Button("Search Again") { model.searchForPhones() }
            }
            Spacer()
            Button("Done", action: finish).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var devices: [NearbyDevice] { sample ?? model.nearby }
    private var apple: [NearbyDevice] { devices.filter { $0.isApple || $0.looksLikeIPhone } }
    private var others: [NearbyDevice] { devices.filter { !($0.isApple || $0.looksLikeIPhone) } }

    private func row(_ device: NearbyDevice) -> some View {
        HStack(spacing: 12) {
            IconTile(symbol: device.looksLikeIPhone ? "iphone" : device.isApple ? "apple.logo" : "dot.radiowaves.left.and.right",
                     size: 32)
            Text(device.name).font(.system(size: 14))
            Spacer()
            if device.id == model.settings.phoneID {
                Label(model.phoneReady ? "Connected" : "Chosen", systemImage: "checkmark")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                Button("Choose") {
                    model.choose(device)
                    finish()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func finish() {
        model.stopSearching()
        close()
    }
}
