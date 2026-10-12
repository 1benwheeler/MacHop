// SPDX-License-Identifier: AGPL-3.0-only
import CoreBluetooth
import MacHopCore

struct NearbyDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var signal: Int
    /// Made by Apple (its advert carries Apple's company ID, or the Mac already knows it).
    var isApple = false

    var looksLikeIPhone: Bool { name.localizedCaseInsensitiveContains("iphone") }
}

/// Keeps a Bluetooth LE link open from the Mac to the chosen iPhone.
///
/// The phone discovers the Mac's HID services over this link and subscribes to
/// them. CoreBluetooth connection requests never time out — they complete when
/// the phone comes into range — so the connector simply keeps one outstanding
/// whenever it is not connected, and starts a fresh one after any failure.
final class PhoneConnector: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum LinkState: Equatable {
        case off
        case noPhoneChosen
        case notFound
        case connecting
        case connected
    }

    private(set) var linkState: LinkState = .off {
        didSet { if linkState != oldValue { onChange?() } }
    }
    private(set) var nearby: [NearbyDevice] = []
    /// The linked iPhone's name, as it reports it (e.g. "Ben's iPhone").
    var linkedName: String? { linkState == .connected ? peripheral?.name : nil }
    /// The linked iPhone's model identifier (e.g. "iPhone16,1"), read from its Device
    /// Information service once per link. Nil until read, or if the phone doesn't say.
    private(set) var modelIdentifier: String?
    private(set) var isSearching = false
    var onChange: (() -> Void)?

    var phoneID: UUID? {
        didSet {
            guard phoneID != oldValue else { return }
            disconnect()
            update()
        }
    }
    /// The Mac's HID services must be published before the phone discovers them.
    var servicesReady = false {
        didSet { if servicesReady != oldValue { update() } }
    }

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var failures = 0
    private var connectedAt: Double?
    private var retryScheduled = false
    private var searchToken = 0

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Drops the current link and connects again, e.g. when the phone is linked
    /// but has not subscribed to input within a reasonable time.
    func reconnect() {
        Log.bluetooth.notice("Reconnecting to the iPhone")
        disconnect()
        update()
    }

    func startSearch(duration: Double = 20) {
        guard let manager, manager.state == .poweredOn else { return }
        nearby.removeAll()
        // Phones already linked to this Mac at the system level appear immediately.
        let services = ["D0611E78-BBB4-4591-A5F8-487910AE4366", "180A"].map(CBUUID.init(string:))
        for device in manager.retrieveConnectedPeripherals(withServices: services) {
            if let name = device.name { add(NearbyDevice(id: device.identifier, name: name, signal: 0, isApple: true)) }
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isSearching = true
        searchToken += 1
        let token = searchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.searchToken == token else { return }
                self.stopSearch()
            }
        }
        onChange?()
    }

    func stopSearch() {
        guard isSearching else { return }
        manager?.stopScan()
        isSearching = false
        searchToken += 1
        onChange?()
    }

    private func add(_ device: NearbyDevice) {
        if let index = nearby.firstIndex(where: { $0.id == device.id }) {
            var known = device
            known.isApple = device.isApple || nearby[index].isApple
            nearby[index] = known
        } else {
            nearby.append(device)
        }
        // iPhones first, then other Apple devices, then the rest; alphabetical within
        // each group, so the list doesn't jump around as signal strengths change.
        func rank(_ device: NearbyDevice) -> Int { device.looksLikeIPhone ? 0 : device.isApple ? 1 : 2 }
        nearby.sort { rank($0) != rank($1) ? rank($0) < rank($1)
                                           : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onChange?()
    }

    private func disconnect() {
        if let manager, let peripheral, manager.state == .poweredOn {
            manager.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        failures = 0
        connectedAt = nil
    }

    private func update() {
        guard let manager, manager.state == .poweredOn else {
            linkState = .off
            return
        }
        guard let phoneID else {
            linkState = .noPhoneChosen
            return
        }
        guard servicesReady else { return }
        if peripheral == nil {
            peripheral = manager.retrievePeripherals(withIdentifiers: [phoneID]).first
        }
        guard let peripheral else {
            // The system no longer knows this identifier (e.g. Bluetooth was reset).
            linkState = .notFound
            return
        }
        switch peripheral.state {
        case .connected:
            linkState = .connected
        case .connecting:
            linkState = .connecting
        default:
            manager.connect(peripheral, options: nil)
            linkState = .connecting
        }
    }

    private func retry() {
        // Immediate failures (e.g. an encryption error) back off; a plain
        // disconnection reconnects at once.
        let delay = failures == 0 ? 0.5 : min(30, Double(1 << min(failures, 5)))
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryScheduled = false
                self.update()
            }
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager else { return }
        if central.state != .poweredOn {
            peripheral = nil
            isSearching = false
        }
        update()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connectedAt = ProcessInfo.processInfo.systemUptime
        linkState = .connected
        Log.bluetooth.notice("Linked to the iPhone; waiting for it to subscribe")
        // Ask which iPhone this is (Device Information → Model Number), to size it on screen.
        peripheral.delegate = self
        peripheral.discoverServices([Self.deviceInformation])
    }

    private static let deviceInformation = CBUUID(string: "180A")
    private static let modelNumber = CBUUID(string: "2A24")

    // MARK: CBPeripheralDelegate (model number only)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral,
              let service = peripheral.services?.first(where: { $0.uuid == Self.deviceInformation }) else { return }
        peripheral.discoverCharacteristics([Self.modelNumber], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.modelNumber }) else { return }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.modelNumber,
              let data = characteristic.value, let model = String(data: data, encoding: .utf8) else { return }
        let trimmed = model.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        guard !trimmed.isEmpty, trimmed != modelIdentifier else { return }
        modelIdentifier = trimmed
        Log.bluetooth.notice("iPhone model: \(trimmed, privacy: .public)")
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        // A link that drops within seconds of connecting (e.g. the phone removed the
        // pairing) counts as a failure, so reconnecting backs off instead of churning.
        let lasted = connectedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        failures = lasted < 10 ? failures + 1 : 0
        connectedAt = nil
        Log.bluetooth.notice("iPhone link closed\(error.map { ": \($0.localizedDescription)" } ?? "", privacy: .public)")
        linkState = .connecting
        retry()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        failures += 1
        Log.bluetooth.notice("Could not link to the iPhone (attempt \(self.failures)): \(error?.localizedDescription ?? "unknown", privacy: .public)")
        linkState = .connecting
        retry()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard isSearching, let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Apple's Bluetooth company identifier, 0x004C, leads its manufacturer data.
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let isApple = maker.map { $0.count >= 2 && $0[$0.startIndex] == 0x4C && $0[$0.startIndex + 1] == 0x00 } ?? false
        add(NearbyDevice(id: peripheral.identifier, name: name, signal: rssi.intValue, isApple: isApple))
    }
}
