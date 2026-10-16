// SPDX-License-Identifier: AGPL-3.0-only
// The GATT layout (service and characteristic order, properties, encryption and
// the expanded 128-bit form of the reserved HID service UUID) follows the layout
// proven on the test iPhone, adapted from BT Remote by jqssun (AGPL-3.0-only,
// https://github.com/jqssun/darwin-bt-remote). See THIRD-PARTY-NOTICES.md.
import CoreBluetooth
import MacHopCore

/// Publishes the Mac as a Bluetooth LE keyboard and pointer (HID over GATT).
///
/// The phone is the HID host: it subscribes to input reports and the transport
/// sends notifications. All queueing, ordering and pacing live in `HIDTransport`.
final class HIDPeripheral: NSObject, CBPeripheralManagerDelegate, NotificationSink {
    enum State: Equatable {
        case starting
        case off
        case unauthorized
        case unsupported
        case failed(String)
        /// Services published; waiting for the phone to subscribe.
        case waiting
        /// The phone subscribed to this many input reports.
        case connected(subscriptions: Int)
    }

    private(set) var state: State = .starting {
        didSet { if state != oldValue { onStateChange?() } }
    }
    var onStateChange: (() -> Void)?
    private(set) var servicesPublished = false
    var onServicesPublished: (() -> Void)?

    let transport: HIDTransport
    /// Only this phone may subscribe; nil accepts the first subscriber.
    var allowedCentral: UUID?
    var onCentralSubscribed: ((UUID) -> Void)?
    private(set) var subscribedCentral: UUID?

    private var manager: CBPeripheralManager?
    private var central: CBCentral?
    private var pendingServices: [CBMutableService] = []
    private var inputs: [UInt8: CBMutableCharacteristic] = [:]
    private var reportIDs: [ObjectIdentifier: UInt8] = [:]
    private var lastValues: [UInt8: Data] = [:]
    /// Values served on read for characteristics without a static value.
    private var values: [ObjectIdentifier: Data] = [:]
    /// Characteristics the phone may write (Protocol Mode, LED outputs).
    private var writable: Set<ObjectIdentifier> = []
    /// Feature report characteristics, by report ID (for logging what the host sets).
    private var featureIDs: [ObjectIdentifier: UInt8] = [:]
    private weak var reportMap: CBMutableCharacteristic?
    private var controlPoint: CBMutableCharacteristic?
    private var retryDelay = 1.0

    init(transport: HIDTransport) {
        self.transport = transport
        super.init()
        transport.sink = self
    }

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil,
                                      options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }

    func stop() {
        if let manager, manager.state == .poweredOn {
            manager.stopAdvertising()
            manager.removeAllServices()
        }
        manager?.delegate = nil
        manager = nil
        resetLink()
        servicesPublished = false
        state = .starting
    }

    // MARK: NotificationSink

    func submit(_ bytes: [UInt8], reportID: UInt8) -> Bool {
        guard let manager, let central, let characteristic = inputs[reportID] else { return true }
        let data = Data(bytes)
        lastValues[reportID] = data
        return manager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
    }

    // MARK: Publication

    private static func uuid(_ short: String) -> CBUUID {
        // The expanded spelling of SIG-assigned UUIDs. CoreBluetooth refuses to
        // publish the reserved HID service under its 16-bit form.
        CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB")
    }

    private static let hidService = uuid("1812")

    private func publish() {
        guard let manager else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        resetLink()
        servicesPublished = false
        pendingServices = buildServices()
        addNextService()
    }

    private func addNextService() {
        guard let manager else { return }
        if pendingServices.isEmpty {
            servicesPublished = true
            manager.startAdvertising([CBAdvertisementDataLocalNameKey: "MacHop",
                                      CBAdvertisementDataServiceUUIDsKey: [Self.hidService]])
            state = .waiting
            Log.bluetooth.notice("HID services published (\(self.transport.profile.variant.rawValue, privacy: .public))")
            onServicesPublished?()
            return
        }
        manager.add(pendingServices.removeFirst())
    }

    func buildServices() -> [CBMutableService] {
        let profile = transport.profile
        inputs.removeAll()
        reportIDs.removeAll()
        values.removeAll()
        writable.removeAll()
        featureIDs.removeAll()

        let battery = CBMutableService(type: Self.uuid("180F"), primary: true)
        let level = CBMutableCharacteristic(type: Self.uuid("2A19"), properties: [.read, .notifyEncryptionRequired],
                                            value: nil, permissions: .readEncryptionRequired)
        if profile.base == .compatibility {
            // The proven map carries a battery report (ID 4) that references this characteristic.
            level.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"), value: Data([4, 1]))]
        }
        values[ObjectIdentifier(level)] = Data([100])
        battery.characteristics = [level]

        let device = CBMutableService(type: Self.uuid("180A"), primary: true)
        device.characteristics = [
            CBMutableCharacteristic(type: Self.uuid("2A29"), properties: .read,
                                    value: Data("MacHop".utf8), permissions: .readable),
            CBMutableCharacteristic(type: Self.uuid("2A24"), properties: .read,
                                    value: Data("MacHop \(profile.variant.rawValue)".utf8), permissions: .readable),
            // PnP ID: Bluetooth SIG vendor source, vendor 0xFFFF (unassigned), product 1, version 1.0.
            CBMutableCharacteristic(type: Self.uuid("2A50"), properties: .read,
                                    value: Data([1, 0xFF, 0xFF, 1, 0, 0, 1]), permissions: .readable)
        ]

        let hid = CBMutableService(type: Self.hidService, primary: true)
        hid.includedServices = [battery]
        let control = CBMutableCharacteristic(type: Self.uuid("2A4C"), properties: .writeWithoutResponse,
                                              value: nil, permissions: .writeEncryptionRequired)
        controlPoint = control
        let mode = CBMutableCharacteristic(type: Self.uuid("2A4E"), properties: [.read, .writeWithoutResponse],
                                           value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        values[ObjectIdentifier(mode)] = Data([1])
        writable.insert(ObjectIdentifier(mode))
        // HID Information: bcdHID 1.11, no country code, remote wake + normally connectable.
        let info = CBMutableCharacteristic(type: Self.uuid("2A4A"), properties: .read,
                                           value: Data([0x11, 0x01, 0x00, 0x03]), permissions: .readEncryptionRequired)
        let bootMouse = CBMutableCharacteristic(type: Self.uuid("2A33"), properties: [.read, .notifyEncryptionRequired],
                                                value: nil, permissions: .readEncryptionRequired)
        values[ObjectIdentifier(bootMouse)] = Data(repeating: 0, count: 3)
        let bootKeyboard = CBMutableCharacteristic(type: Self.uuid("2A22"), properties: [.read, .notifyEncryptionRequired],
                                                   value: nil, permissions: .readEncryptionRequired)
        values[ObjectIdentifier(bootKeyboard)] = Data(repeating: 0, count: 8)
        let bootOutput = CBMutableCharacteristic(type: Self.uuid("2A32"), properties: [.read, .write, .writeWithoutResponse],
                                                 value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        values[ObjectIdentifier(bootOutput)] = Data([0])
        writable.insert(ObjectIdentifier(bootOutput))
        // Served on request (not as a fixed value) so MacHop can log when the iPhone reads it.
        let map = CBMutableCharacteristic(type: Self.uuid("2A4B"), properties: .read,
                                          value: nil, permissions: .readEncryptionRequired)
        values[ObjectIdentifier(map)] = Data(profile.reportMap)
        reportMap = map
        // External Report Reference: the map may refer to the Battery Level characteristic.
        map.descriptors = [CBMutableDescriptor(type: Self.uuid("2907"), value: Data([0x19, 0x2A]))]

        var reports: [CBMutableCharacteristic] = []
        let leds = CBMutableCharacteristic(type: Self.uuid("2A4D"), properties: [.read, .write, .writeWithoutResponse],
                                           value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
        leds.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"), value: Data([profile.keyboardLEDReportID, 2]))]
        values[ObjectIdentifier(leds)] = Data([0])
        writable.insert(ObjectIdentifier(leds))
        for id in profile.inputReportIDs {
            let report = CBMutableCharacteristic(type: Self.uuid("2A4D"), properties: [.read, .notifyEncryptionRequired],
                                                 value: nil, permissions: .readEncryptionRequired)
            report.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"), value: Data([id, 1]))]
            inputs[id] = report
            reportIDs[ObjectIdentifier(report)] = id
            reports.append(report)
            // The proven layout publishes the LED output right after the keyboard input.
            if id == profile.keyboardReportID { reports.append(leds) }
        }
        // Feature reports (the experimental high-resolution wheel's multiplier).
        for (id, initial) in profile.featureReports.sorted(by: { $0.key < $1.key }) {
            let feature = CBMutableCharacteristic(type: Self.uuid("2A4D"), properties: [.read, .write],
                                                  value: nil, permissions: [.readEncryptionRequired, .writeEncryptionRequired])
            feature.descriptors = [CBMutableDescriptor(type: Self.uuid("2908"), value: Data([id, 3]))]
            values[ObjectIdentifier(feature)] = Data(initial)
            writable.insert(ObjectIdentifier(feature))
            featureIDs[ObjectIdentifier(feature)] = id
            reports.append(feature)
        }
        hid.characteristics = [control, mode, info, bootMouse, bootKeyboard, bootOutput, map] + reports
        return [battery, device, hid]
    }

    private func resetLink() {
        central = nil
        subscribedCentral = nil
        lastValues.removeAll()
        transport.reset()
    }

    private func updateConnectedState() {
        guard servicesPublished else { return }
        let count = transport.subscribedReports.count
        state = count == 0 ? .waiting : .connected(subscriptions: count)
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn:
            retryDelay = 1
            publish()
        case .poweredOff:
            resetLink()
            servicesPublished = false
            state = .off
        case .unauthorized:
            resetLink()
            servicesPublished = false
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        default:
            resetLink()
            servicesPublished = false
            state = .starting
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        if let error {
            Log.bluetooth.error("Publishing a service failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Bluetooth could not publish the keyboard and pointer: \(error.localizedDescription)")
            pendingServices.removeAll()
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.manager?.state == .poweredOn else { return }
                    self.publish()
                }
            }
            return
        }
        addNextService()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            Log.bluetooth.notice("Advertising did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager, let id = reportIDs[ObjectIdentifier(characteristic)] else { return }
        if let allowedCentral, central.identifier != allowedCentral {
            Log.bluetooth.notice("Ignored a subscription from a device that is not the chosen iPhone")
            return
        }
        if self.central?.identifier != central.identifier {
            // A different (or first) subscriber: start from a clean slate.
            if self.central != nil { transport.reset() }
            self.central = central
            subscribedCentral = central.identifier
            peripheral.setDesiredConnectionLatency(.low, for: central)
            onCentralSubscribed?(central.identifier)
        }
        transport.subscribed(id)
        updateConnectedState()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager, central.identifier == self.central?.identifier,
              let id = reportIDs[ObjectIdentifier(characteristic)] else { return }
        transport.unsubscribed(id)
        if transport.subscribedReports.isEmpty {
            self.central = nil
            subscribedCentral = nil
        }
        updateConnectedState()
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        transport.radioIsReady()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager else { return }
        let key = ObjectIdentifier(request.characteristic)
        let value: Data?
        if let id = reportIDs[key] {
            // The last report reveals what's held (e.g. a key), so only the chosen iPhone may read it.
            if let owner = subscribedCentral ?? allowedCentral, request.central.identifier != owner {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                return
            }
            value = lastValues[id] ?? Data(transport.profile.neutralPayload(for: id))
        } else {
            if let id = featureIDs[key] { Log.bluetooth.notice("iPhone read feature report \(id)") }
            if request.characteristic === reportMap, request.offset == 0 { Log.bluetooth.notice("iPhone read the report map") }
            value = values[key]
        }
        guard let value else {
            peripheral.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, let first = requests.first else { return }
        // Validate the whole batch before applying any of it; respond exactly once.
        // Only the chosen iPhone may write: another bonded device suspending (e.g.
        // an iPad locking) must not take input away from the phone in use.
        let owner = subscribedCentral ?? allowedCentral
        if let owner, requests.contains(where: { $0.central.identifier != owner }) {
            peripheral.respond(to: first, withResult: .insufficientAuthorization)
            return
        }
        for request in requests {
            let key = ObjectIdentifier(request.characteristic)
            let known = request.characteristic === controlPoint || writable.contains(key)
            guard known, request.offset == 0, let value = request.value, value.count == 1 else {
                peripheral.respond(to: first, withResult: known ? .invalidAttributeValueLength : .writeNotPermitted)
                return
            }
        }
        for request in requests {
            guard let value = request.value else { continue }
            if request.characteristic === controlPoint {
                // HID Control Point: 0 = Suspend, 1 = Exit Suspend (e.g. phone locked/unlocked).
                transport.setSuspended(value[0] == 0)
                Log.bluetooth.notice("iPhone \(value[0] == 0 ? "suspended" : "resumed", privacy: .public) HID input")
            } else {
                if let id = featureIDs[ObjectIdentifier(request.characteristic)] {
                    Log.bluetooth.notice("iPhone set feature report \(id) to \(value[0])")
                }
                values[ObjectIdentifier(request.characteristic)] = value
            }
        }
        peripheral.respond(to: first, withResult: .success)
    }
}
