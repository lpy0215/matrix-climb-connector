import Foundation

enum FTMSStepClimberParseError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missingFlags(actualBytes: Int)
    case reservedFlagsSet(UInt16)
    case truncated(field: String, expectedBytes: Int, remainingBytes: Int)
    case trailingBytes(Int)

    var description: String {
        switch self {
        case let .missingFlags(actualBytes):
            return "Step Climber Data needs two flag bytes; received \(actualBytes)."
        case let .reservedFlagsSet(flags):
            return String(format: "Step Climber Data has reserved flag bits set: 0x%04X.", flags)
        case let .truncated(field, expectedBytes, remainingBytes):
            return "\(field) needs \(expectedBytes) byte(s); only \(remainingBytes) remain."
        case let .trailingBytes(count):
            return "Step Climber Data has \(count) unexpected trailing byte(s)."
        }
    }

    var errorDescription: String? { description }
}

/// Bluetooth SIG GATT Specification Supplement, Step Climber Data (0x2ACF).
enum FTMSStepClimberParser {
    static func parse(_ data: Data, receivedAt: Date = .now) throws -> StepClimberMetrics {
        guard data.count >= 2 else {
            throw FTMSStepClimberParseError.missingFlags(actualBytes: data.count)
        }

        var reader = LittleEndianReader(data: data)
        let flags = try reader.readUInt16(field: "Flags")
        guard flags & 0xFE00 == 0 else {
            throw FTMSStepClimberParseError.reservedFlagsSet(flags)
        }
        var metrics = StepClimberMetrics(flags: flags, receivedAt: receivedAt)

        // In FTMS data characteristics, bit 0 is inverted: 0 means that the
        // mandatory part of the data record is present in this notification.
        if flags & (1 << 0) == 0 {
            metrics.floors = try reader.readUInt16(field: "Floors")
            metrics.stepCount = try reader.readUInt16(field: "Step Count")
        }
        if flags & (1 << 1) != 0 {
            metrics.stepsPerMinute = try reader.readUInt16(field: "Steps Per Minute")
        }
        if flags & (1 << 2) != 0 {
            metrics.averageStepRate = try reader.readUInt16(field: "Average Step Rate")
        }
        if flags & (1 << 3) != 0 {
            let raw = try reader.readUInt16(field: "Positive Elevation Gain")
            metrics.positiveElevationGainMeters = Double(raw) / 10.0
        }
        if flags & (1 << 4) != 0 {
            metrics.totalEnergyKcal = try reader.readUInt16(field: "Total Energy")
            metrics.energyPerHourKcal = try reader.readUInt16(field: "Energy Per Hour")
            metrics.energyPerMinuteKcal = try reader.readUInt8(field: "Energy Per Minute")
        }
        if flags & (1 << 5) != 0 {
            metrics.heartRateBPM = try reader.readUInt8(field: "Heart Rate")
        }
        if flags & (1 << 6) != 0 {
            let raw = try reader.readUInt8(field: "Metabolic Equivalent")
            metrics.metabolicEquivalent = Double(raw) / 10.0
        }
        if flags & (1 << 7) != 0 {
            metrics.elapsedTimeSeconds = try reader.readUInt16(field: "Elapsed Time")
        }
        if flags & (1 << 8) != 0 {
            metrics.remainingTimeSeconds = try reader.readUInt16(field: "Remaining Time")
        }

        // RFU bits contain no fields. Rejecting leftover bytes avoids silently
        // accepting a shifted or vendor-specific layout as valid FTMS data.
        guard reader.remainingBytes == 0 else {
            throw FTMSStepClimberParseError.trailingBytes(reader.remainingBytes)
        }
        return metrics
    }
}

private struct LittleEndianReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var remainingBytes: Int { bytes.count - offset }

    mutating func readUInt8(field: String) throws -> UInt8 {
        try require(1, field: field)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16(field: String) throws -> UInt16 {
        try require(2, field: field)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func require(_ count: Int, field: String) throws {
        guard remainingBytes >= count else {
            throw FTMSStepClimberParseError.truncated(
                field: field,
                expectedBytes: count,
                remainingBytes: remainingBytes
            )
        }
    }
}
