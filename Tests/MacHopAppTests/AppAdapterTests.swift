import AppKit
import CoreBluetooth
import Testing
@testable import MacHopApp
@testable import MacHopCore

/// Builds real CGEvents in memory. Nothing is posted, so no permission is needed.
private func makeEvent(_ build: (CGEventSource?) -> CGEvent?) throws -> CGEvent {
    try #require(build(CGEventSource(stateID: .privateState)))
}

@MainActor
@Suite("CGEvent conversion")
struct EventConversionTests {
    @Test("Pointer motion keeps location and device delta")
    func pointerMotion() throws {
        let event = try makeEvent { CGEvent(mouseEventSource: $0, mouseType: .mouseMoved,
                                            mouseCursorPosition: CGPoint(x: 1511, y: 400), mouseButton: .left) }
        event.setIntegerValueField(.mouseEventDeltaX, value: 7)
        event.setIntegerValueField(.mouseEventDeltaY, value: -3)
        #expect(InputEvent(event, type: .mouseMoved) == .pointerMoved(location: Point(x: 1511, y: 400), delta: Point(x: 7, y: -3)))
        #expect(InputEvent(event, type: .leftMouseDragged) == .pointerMoved(location: Point(x: 1511, y: 400), delta: Point(x: 7, y: -3)))
    }

    @Test("Buttons, including extra buttons", arguments: [
        (CGEventType.leftMouseDown, 0, true), (.leftMouseUp, 0, false), (.rightMouseDown, 1, true),
        (.rightMouseUp, 1, false), (.otherMouseDown, 2, true), (.otherMouseDown, 4, true), (.otherMouseUp, 4, false)
    ])
    func buttons(type: CGEventType, number: Int, down: Bool) throws {
        let event = try makeEvent { CGEvent(mouseEventSource: $0, mouseType: type, mouseCursorPosition: .zero,
                                            mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center) }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        #expect(InputEvent(event, type: type) == .button(MouseButton(number: number), down: down, location: .zero))
    }

    @Test("Keys carry code, repeat flag and modifiers")
    func keys() throws {
        let down = try makeEvent { CGEvent(keyboardEventSource: $0, virtualKey: 0, keyDown: true) }
        down.flags = [.maskCommand, .maskShift]
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        guard case let .key(code, isDown, isRepeat, modifiers) = InputEvent(down, type: .keyDown) else {
            Issue.record("not a key event")
            return
        }
        #expect(code == 0 && isDown && isRepeat)
        #expect(modifiers.contains(.command) && modifiers.contains(.shift))
        let up = try makeEvent { CGEvent(keyboardEventSource: $0, virtualKey: 53, keyDown: false) }
        #expect(InputEvent(up, type: .keyUp) == .key(code: 53, down: false, isRepeat: false, modifiers: ModifierFlags(rawValue: up.flags.rawValue)))
    }

    @Test("Modifier changes")
    func modifiers() throws {
        let event = try makeEvent { CGEvent(keyboardEventSource: $0, virtualKey: 56, keyDown: true) }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: ModifierFlags([.shift, .leftShift]).rawValue)
        #expect(InputEvent(event, type: .flagsChanged) == .modifierChanged(code: 56, modifiers: [.shift, .leftShift]))
    }

    @Test("Trackpad scrolling keeps phases and momentum; wheels are line-based")
    func scrolling() throws {
        let trackpad = try makeEvent { CGEvent(scrollWheelEvent2Source: $0, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0) }
        trackpad.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        trackpad.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        guard case let .scroll(input) = InputEvent(trackpad, type: .scrollWheel) else {
            Issue.record("not a scroll event")
            return
        }
        #expect(input.continuous && input.phase == .began && input.momentum == .none)
        #expect(input.dy < 0)

        let momentum = try makeEvent { CGEvent(scrollWheelEvent2Source: $0, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0) }
        momentum.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        momentum.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        guard case let .scroll(tail) = InputEvent(momentum, type: .scrollWheel) else { return }
        #expect(tail.phase == .none && tail.momentum == .changed)

        let wheel = try makeEvent { CGEvent(scrollWheelEvent2Source: $0, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0) }
        guard case let .scroll(lines) = InputEvent(wheel, type: .scrollWheel) else { return }
        #expect(!lines.continuous && lines.dy == 2 && lines.phase == .none)
    }

    @Test("The tap listens to keyboard, pointer, scroll, gesture and media-key events")
    func tapMask() {
        let mask = InputEvent.tapMask
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel, .leftMouseDown, .otherMouseDragged] {
            #expect(mask & (1 << CGEventMask(type.rawValue)) != 0)
        }
        // 14: system-defined events, which carry the media keys. The session passes them
        // to the Mac unless the user sends media keys to the iPhone.
        for raw: UInt32 in [14, 18, 29, 30, 31, 32, 33] { #expect(mask & (1 << CGEventMask(raw)) != 0) }
    }

    @Test("Media keys convert from system-defined events; other system events pass untouched")
    func mediaKeyConversion() throws {
        func event(code: Int, state: Int, repeat isRepeat: Bool = false, subtype: Int16 = 8) throws -> CGEvent {
            let data1 = (code << 16) | (state << 8) | (isRepeat ? 1 : 0)
            let ns = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil,
                                                     subtype: subtype, data1: data1, data2: -1))
            return try #require(ns.cgEvent)
        }
        let type = try #require(CGEventType(rawValue: 14))
        #expect(InputEvent(try event(code: 0, state: 0x0A), type: type) == .mediaKey(.volumeUp, down: true, isRepeat: false))
        #expect(InputEvent(try event(code: 1, state: 0x0B), type: type) == .mediaKey(.volumeDown, down: false, isRepeat: false))
        #expect(InputEvent(try event(code: 7, state: 0x0A, repeat: true), type: type) == .mediaKey(.mute, down: true, isRepeat: true))
        #expect(InputEvent(try event(code: 16, state: 0x0A), type: type) == .mediaKey(.playPause, down: true, isRepeat: false))
        #expect(InputEvent(try event(code: 2, state: 0x0A), type: type) == .other, "brightness stays with the Mac")
        #expect(InputEvent(try event(code: 0, state: 0x0A, subtype: 7), type: type) == .other, "not an aux control button")
    }
}

@MainActor
@Suite("Bluetooth GATT tree")
struct GATTTests {
    func services(_ variant: HIDProfile.Variant) -> [CBMutableService] {
        HIDPeripheral(transport: HIDTransport(profile: HIDProfile(variant), scheduler: MainScheduler())).buildServices()
    }

    func expanded(_ short: String) -> CBUUID { CBUUID(string: "0000\(short)-0000-1000-8000-00805F9B34FB") }

    @Test("Battery, Device Information and HID services, in that order", arguments: HIDProfile.Variant.allCases)
    func serviceOrder(variant: HIDProfile.Variant) throws {
        let tree = services(variant)
        #expect(tree.map(\.uuid) == [expanded("180F"), expanded("180A"), expanded("1812")])
        let hid = try #require(tree.last)
        #expect(hid.includedServices?.first === tree.first)
    }

    @Test("Compatibility profile reproduces the proven characteristic layout")
    func compatibilityLayout() throws {
        let hid = try #require(services(.compatibility).last?.characteristics as? [CBMutableCharacteristic])
        #expect(hid.map(\.uuid) == ["2A4C", "2A4E", "2A4A", "2A33", "2A22", "2A32", "2A4B",
                                     "2A4D", "2A4D", "2A4D", "2A4D", "2A4D", "2A4D"].map(expanded))
        let references = hid.compactMap { characteristic -> [UInt8]? in
            guard let descriptor = characteristic.descriptors?.first(where: { $0.uuid == expanded("2908") }),
                  let value = descriptor.value as? Data else { return nil }
            return Array(value)
        }
        // System, consumer, mouse, keyboard, LED output, separate wheel.
        #expect(references == [[5, 1], [6, 1], [1, 1], [2, 1], [3, 2], [7, 1]])
    }

    @Test("Every input report notifies with encryption; the map is the profile's", arguments: HIDProfile.Variant.allCases)
    func reportCharacteristics(variant: HIDProfile.Variant) throws {
        let hid = try #require(services(variant).last?.characteristics as? [CBMutableCharacteristic])
        let map = try #require(hid.first { $0.uuid == expanded("2A4B") })
        #expect(map.value == Data(HIDProfile(variant).reportMap))
        let inputs = hid.filter { characteristic in
            characteristic.uuid == expanded("2A4D") && characteristic.properties.contains(.notifyEncryptionRequired)
        }
        #expect(inputs.count == HIDProfile(variant).inputReportIDs.count)
        for input in inputs {
            #expect(input.permissions == .readEncryptionRequired)
            #expect(!input.properties.contains(.notify), "unencrypted notifications must never be offered")
        }
        let control = try #require(hid.first { $0.uuid == expanded("2A4C") })
        #expect(control.properties == .writeWithoutResponse)
        #expect(control.permissions == .writeEncryptionRequired)
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test("Settings saved before gestures existed still load, with gestures on")
    func olderSettingsDecode() throws {
        let saved = Data("""
        {"profile":"compatibility","paused":false,"session":{"scroll":{"reversed":false,"horizontal":true,"speed":1,"momentum":true},
        "edgeResistance":6,"layout":{"aspectRatio":0.46,"verticalPosition":0.37,"size":620,"displayID":1,"orientation":"portrait","side":"right"}}}
        """.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: saved)
        #expect(settings.session.phoneGestures)
        #expect(settings.session.pointerSpeed == 1)
        #expect(!settings.session.mediaKeysToPhone)
        #expect(settings.session.scroll.style == .drag)
        #expect(settings.session.layout.size == 620)
    }

    @Test("The setup guide opens for new users, not for people who already chose an iPhone")
    func setupGuideAtLaunch() throws {
        var fresh = AppSettings.defaultSettings(mainDisplay: 1)
        #expect(fresh.needsSetup)
        fresh.phoneID = UUID()
        #expect(!fresh.needsSetup, "settings from before the guide existed, with an iPhone chosen")
        fresh.setupFinished = false
        #expect(fresh.needsSetup, "Finish Later shows the guide again next time")
        fresh.setupFinished = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(fresh))
        #expect(!decoded.needsSetup)
    }

    @Test("Speed sliders: normal is the middle, snaps there, and reaches both ends")
    func speedSlider() {
        let range = SessionSettings.pointerSpeedRange
        #expect(SpeedSlider.position(for: 1, in: range) == 0.5)
        #expect(SpeedSlider.speed(at: 0.5, in: range) == 1)
        #expect(SpeedSlider.speed(at: 0.52, in: range) == 1, "near the middle snaps to normal")
        #expect(abs(SpeedSlider.speed(at: 0, in: range) - range.lowerBound) < 1e-9)
        #expect(abs(SpeedSlider.speed(at: 1, in: range) - range.upperBound) < 1e-9)
        for speed in [0.5, 0.8, 1.3, 2.0] {
            #expect(abs(SpeedSlider.speed(at: SpeedSlider.position(for: speed, in: range), in: range) - speed) < 1e-9)
        }
    }

    @Test("Settings round-trip through storage")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "machop.tests.\(UUID().uuidString)"))
        var settings = AppSettings.defaultSettings(mainDisplay: 7)
        settings.phoneID = UUID()
        settings.session.scroll.speed = 2
        settings.profile = .standard
        settings.save(defaults: defaults)
        #expect(AppSettings.load(defaults: defaults, mainDisplay: 1) == settings)
    }
}
