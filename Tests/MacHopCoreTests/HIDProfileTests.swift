import CryptoKit
import Foundation
import Testing
@testable import MacHopCore
@testable import VirtualPhone

@Suite("HID profiles and encoding")
struct HIDProfileTests {
    static let allProfiles = HIDProfile.Variant.allCases.map(HIDProfile.init)

    @Test("Compatibility map is the proven layout with only the pointer's buttons widened to 8")
    func compatibilityMatchesProvenLayout() throws {
        let map = HIDProfile.compatibility.reportMap
        // Put back the proven 3-button declaration (plus 5 bits of padding)…
        let eightButtons: [UInt8] = [0x05, 0x09, 0x19, 0x01, 0x29, 0x08, 0x75, 0x01, 0x95, 0x08,
                                     0x15, 0x00, 0x25, 0x01, 0x81, 0x02]
        let threeButtons: [UInt8] = [0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x75, 0x01, 0x95, 0x03,
                                     0x15, 0x00, 0x25, 0x01, 0x81, 0x02, 0x95, 0x05, 0x81, 0x03]
        let start = try #require((0...(map.count - eightButtons.count)).first { Array(map[$0..<($0 + eightButtons.count)]) == eightButtons })
        let legacy = Array(map[..<start]) + threeButtons + Array(map[(start + eightButtons.count)...])
        // …and the result is byte-identical to the prototype's "profile 3", proven on the iPhone.
        let digest = SHA256.hash(data: Data(legacy)).map { String(format: "%02x", $0) }.joined()
        #expect(legacy.count == 260)
        #expect(digest == "8f4557d101358796c23cd59cb5d7606135be48c7c3711e0758b4e41890ae6989")
    }

    @Test("Every report map parses, and MacHop's own maps are spec-clean", arguments: allProfiles)
    func reportMapsParse(profile: HIDProfile) throws {
        let descriptor = try HIDDescriptor(bytes: profile.reportMap)
        if profile.variant == .compatibility {
            // The proven layout encodes some logical maxima in one signed byte (e.g. 0xDD).
            // iOS accepts it; the parser records it so the quirk stays visible.
            #expect(!descriptor.warnings.isEmpty)
        } else {
            #expect(descriptor.warnings.isEmpty, "\(descriptor.warnings)")
        }
        for id in profile.inputReportIDs {
            let layout = try #require(descriptor.input(id), "input report \(id) missing from map")
            #expect(layout.byteLength == profile.neutralPayload(for: id).count, "report \(id)")
        }
        #expect(profile.requiredInputReportIDs.isSubset(of: Set(profile.inputReportIDs)))
        let leds = descriptor.reports.first { $0.kind == .output && $0.reportID == profile.keyboardLEDReportID }
        #expect(leds?.byteLength == 1)
    }

    @Test("Encoded reports always match the lengths the map declares", arguments: allProfiles)
    func encodedLengthsMatchMap(profile: HIDProfile) throws {
        let descriptor = try HIDDescriptor(bytes: profile.reportMap)
        var encoder = HIDEncoder(profile: profile)
        let samples: [HIDReport] = [
            .keyboard(KeyboardReport(modifiers: 0xFF, keys: [4, 5, 6, 7, 8, 9])),
            .keyboard(.released),
            .pointer(PointerReport(buttons: 7, x: 0, y: 1)),
            .pointer(PointerReport(buttons: 0, x: 0.37, y: 0.61)),
            .scroll(ScrollReport(wheel: 300, pan: -300)),
            .scroll(ScrollReport(wheel: -1, pan: 1)),
            .consumer(ConsumerReport(usage: ConsumerReport.home)),
            .consumer(.released),
            .touch(TouchReport(contacts: [.init(id: 0, x: 0.4, y: 0.5, down: true), .init(id: 1, x: 0.6, y: 0.5, down: true)])),
            .touch(TouchReport(contacts: [.init(id: 0, x: 1, y: 1, down: false)]))
        ]
        for sample in samples {
            for part in encoder.encode(sample) {
                let layout = try #require(descriptor.input(part.reportID), "\(sample) used unknown report \(part.reportID)")
                #expect(part.bytes.count == layout.byteLength, "\(sample)")
            }
        }
    }

    @Test("Keyboard and pointer state round-trip through the virtual phone", arguments: allProfiles)
    func keyboardAndPointerRoundTrip(profile: HIDProfile) throws {
        let phone = try VirtualPhone(reportMap: profile.reportMap, screen: (400, 800))
        var encoder = HIDEncoder(profile: profile)
        func deliver(_ report: HIDReport) {
            for part in encoder.encode(report) { phone.receive(reportID: part.reportID, bytes: part.bytes) }
        }
        deliver(.keyboard(KeyboardReport(modifiers: 0x02, keys: [0x04])))   // Shift + a
        deliver(.keyboard(KeyboardReport(modifiers: 0x02, keys: [])))
        deliver(.keyboard(KeyboardReport(modifiers: 0, keys: [0x05, 0x06])))
        deliver(.keyboard(.released))
        #expect(phone.text == "Abc")
        #expect(phone.isIdle)

        if profile.isAbsolute {
            for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.25, 0.75), (0.5, 0.5)] {
                deliver(.pointer(PointerReport(buttons: 0, x: x, y: y)))
                #expect(abs(phone.pointer.x - x * 400) < 0.05)
                #expect(abs(phone.pointer.y - y * 800) < 0.05)
            }
        } else {
            deliver(.pointer(PointerReport(buttons: 0, x: 0.5, y: 0.5)))
            let start = phone.pointer
            deliver(.pointer(PointerReport(buttons: 0, x: 0.6, y: 0.4)))
            #expect(phone.pointer.x > start.x)
            #expect(phone.pointer.y < start.y)
        }
        deliver(.pointer(PointerReport(buttons: 1, x: 0.5, y: 0.5)))
        deliver(.pointer(PointerReport(buttons: 0, x: 0.5, y: 0.5)))
        #expect(phone.clicks.count == 1)
        #expect(phone.errors.isEmpty, "\(phone.errors)")
    }

    @Test("Every scroll amount arrives intact", arguments: allProfiles)
    func scrollAmountsArriveIntact(profile: HIDProfile) throws {
        let phone = try VirtualPhone(reportMap: profile.reportMap)
        var encoder = HIDEncoder(profile: profile)
        var expected = Point.zero
        for wheel in -300...300 {
            let pan = profile.supportsHorizontalScroll ? -wheel / 2 : 0
            for part in encoder.encode(.scroll(ScrollReport(wheel: wheel, pan: pan))) {
                #expect(part.bytes.allSatisfy { $0 != 0x80 }, "-128 is outside the logical range")
                phone.receive(reportID: part.reportID, bytes: part.bytes)
            }
            expected.y += Double(wheel)
            expected.x += Double(pan)
        }
        #expect(phone.scrollSteps == expected)
        #expect(phone.errors.isEmpty, "\(phone.errors)")
    }

    @Test("Consumer usages are encoded where the profile can carry them", arguments: allProfiles)
    func consumerUsages(profile: HIDProfile) throws {
        let phone = try VirtualPhone(reportMap: profile.reportMap)
        var encoder = HIDEncoder(profile: profile)
        for usage in [ConsumerReport.home, ConsumerReport.search, ConsumerReport.keyboardToggle, 0x00E9] {
            for part in encoder.encode(.consumer(ConsumerReport(usage: usage))) {
                phone.receive(reportID: part.reportID, bytes: part.bytes)
            }
            for part in encoder.encode(.consumer(.released)) { phone.receive(reportID: part.reportID, bytes: part.bytes) }
        }
        #expect(phone.consumerPresses == [ConsumerReport.home, ConsumerReport.search, ConsumerReport.keyboardToggle, 0x00E9])
        #expect(phone.consumerUsage == 0)
    }
}
