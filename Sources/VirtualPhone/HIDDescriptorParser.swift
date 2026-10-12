// SPDX-License-Identifier: AGPL-3.0-only

/// A parsed HID report field (one Main item), following HID 1.11 §6.2.2.
public struct HIDField: Equatable, Sendable {
    public enum Kind: Sendable { case input, output, feature }

    public var kind: Kind
    public var reportID: UInt8
    public var usagePage: UInt16
    /// Explicit usages (32-bit extended: page << 16 | id), one per element when variable.
    public var usages: [UInt32]
    public var usageMinimum: UInt32?
    public var usageMaximum: UInt32?
    public var bitOffset: Int
    public var size: Int
    public var count: Int
    public var logicalMinimum: Int64
    public var logicalMaximum: Int64
    public var flags: UInt32

    public var isConstant: Bool { flags & 0x01 != 0 }
    public var isVariable: Bool { flags & 0x02 != 0 }
    public var isRelative: Bool { flags & 0x04 != 0 }
    public var isSigned: Bool { logicalMinimum < 0 }

    /// The usage of element `index` of a variable field.
    public func usage(at index: Int) -> UInt32? {
        if !usages.isEmpty { return usages[min(index, usages.count - 1)] }
        if let minimum = usageMinimum { return minimum + UInt32(index) }
        return nil
    }
}

public struct HIDReportLayout: Equatable, Sendable {
    public var reportID: UInt8
    public var kind: HIDField.Kind
    public var fields: [HIDField]
    public var bitLength: Int
    public var byteLength: Int { (bitLength + 7) / 8 }
}

public struct HIDDescriptor: Sendable {
    public private(set) var reports: [HIDReportLayout] = []
    /// Spec deviations that a lenient host tolerates (e.g. a one-byte logical
    /// maximum such as 0xDD that is negative when read as signed).
    public private(set) var warnings: [String] = []

    public enum ParseError: Error, Equatable {
        case truncated(offset: Int)
        case unbalancedCollection(offset: Int)
        case mainItemWithoutReportSize(offset: Int)
        case longItemUnsupported(offset: Int)
    }

    public func input(_ reportID: UInt8) -> HIDReportLayout? {
        reports.first { $0.reportID == reportID && $0.kind == .input }
    }

    public init(bytes: [UInt8]) throws {
        struct Globals {
            var usagePage: UInt16 = 0
            var logicalMinimum: Int64 = 0
            var logicalMaximum: Int64 = 0
            var logicalMaximumUnsigned: Int64 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        var globals = Globals()
        var stack: [Globals] = []
        var usages: [UInt32] = []
        var usageMinimum: UInt32?
        var usageMaximum: UInt32?
        var depth = 0
        var offsets: [String: Int] = [:]   // "kind:id" -> bit offset
        var layouts: [String: HIDReportLayout] = [:]
        var order: [String] = []

        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]
            if prefix == 0xFE { throw ParseError.longItemUnsupported(offset: index) }
            let sizeCode = Int(prefix & 0x03)
            let dataSize = sizeCode == 3 ? 4 : sizeCode
            guard index + dataSize < bytes.count else { throw ParseError.truncated(offset: index) }
            var unsigned: UInt32 = 0
            for i in 0..<dataSize { unsigned |= UInt32(bytes[index + 1 + i]) << (8 * i) }
            let signed: Int64 = switch dataSize {
            case 1: Int64(Int8(truncatingIfNeeded: unsigned))
            case 2: Int64(Int16(truncatingIfNeeded: unsigned))
            case 4: Int64(Int32(bitPattern: unsigned))
            default: 0
            }
            let tag = prefix & 0xFC
            switch tag {
            // Main items
            case 0x80, 0x90, 0xB0:
                guard globals.reportSize > 0 else { throw ParseError.mainItemWithoutReportSize(offset: index) }
                let kind: HIDField.Kind = tag == 0x80 ? .input : tag == 0x90 ? .output : .feature
                let key = "\(kind):\(globals.reportID)"
                if layouts[key] == nil {
                    layouts[key] = HIDReportLayout(reportID: globals.reportID, kind: kind, fields: [], bitLength: 0)
                    order.append(key)
                }
                var maximum = globals.logicalMaximum
                if globals.logicalMinimum >= 0 && maximum < globals.logicalMinimum {
                    warnings.append("Report \(globals.reportID): logical maximum \(maximum) is below minimum " +
                                    "\(globals.logicalMinimum); read as unsigned \(globals.logicalMaximumUnsigned)")
                    maximum = globals.logicalMaximumUnsigned
                }
                let field = HIDField(kind: kind, reportID: globals.reportID, usagePage: globals.usagePage,
                                     usages: usages, usageMinimum: usageMinimum, usageMaximum: usageMaximum,
                                     bitOffset: offsets[key, default: 0], size: globals.reportSize,
                                     count: globals.reportCount, logicalMinimum: globals.logicalMinimum,
                                     logicalMaximum: maximum, flags: unsigned)
                offsets[key, default: 0] += globals.reportSize * globals.reportCount
                layouts[key]!.fields.append(field)
                layouts[key]!.bitLength = offsets[key, default: 0]
                usages = []
                usageMinimum = nil
                usageMaximum = nil
            case 0xA0:
                depth += 1
                usages = []
                usageMinimum = nil
                usageMaximum = nil
            case 0xC0:
                depth -= 1
                if depth < 0 { throw ParseError.unbalancedCollection(offset: index) }
            // Global items
            case 0x04: globals.usagePage = UInt16(truncatingIfNeeded: unsigned)
            case 0x14: globals.logicalMinimum = signed
            case 0x24:
                globals.logicalMaximum = signed
                globals.logicalMaximumUnsigned = Int64(unsigned)
            case 0x34, 0x44, 0x54, 0x64: break  // physical range and units: not needed here
            case 0x74: globals.reportSize = Int(unsigned)
            case 0x84: globals.reportID = UInt8(truncatingIfNeeded: unsigned)
            case 0x94: globals.reportCount = Int(unsigned)
            case 0xA4: stack.append(globals)
            case 0xB4: if let restored = stack.popLast() { globals = restored }
            // Local items: usages carry the current page unless given as 32-bit extended.
            case 0x08: usages.append(Self.extended(unsigned, size: dataSize, page: globals.usagePage))
            case 0x18: usageMinimum = Self.extended(unsigned, size: dataSize, page: globals.usagePage)
            case 0x28: usageMaximum = Self.extended(unsigned, size: dataSize, page: globals.usagePage)
            default: break
            }
            index += 1 + dataSize
        }
        if depth != 0 { throw ParseError.unbalancedCollection(offset: bytes.count) }
        reports = order.compactMap { layouts[$0] }
    }

    private static func extended(_ value: UInt32, size: Int, page: UInt16) -> UInt32 {
        size == 4 ? value : (UInt32(page) << 16) | (value & 0xFFFF)
    }
}

extension HIDField {
    /// Reads element `index` from a report payload (little-endian bit order).
    public func value(at index: Int, in bytes: [UInt8]) -> Int64 {
        let start = bitOffset + index * size
        var raw: UInt64 = 0
        for bit in 0..<size {
            let position = start + bit
            let byte = position / 8
            guard byte < bytes.count else { break }
            if bytes[byte] >> UInt8(position % 8) & 1 == 1 { raw |= 1 << UInt64(bit) }
        }
        if isSigned && size < 64 && raw & (1 << UInt64(size - 1)) != 0 {
            return Int64(bitPattern: raw | ~((1 << UInt64(size)) - 1))
        }
        return Int64(bitPattern: raw)
    }
}
