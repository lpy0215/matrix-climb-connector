import XCTest
@testable import MatrixClimbConnector

final class FTMSStepClimberParserTests: XCTestCase {
    func testParsesObserved01FELayout() throws {
        let result = try FTMSStepClimberParser.parse(observed01FEPacket)

        XCTAssertEqual(result.flags, 0x01FE)
        XCTAssertEqual(result.floors, 12)
        XCTAssertEqual(result.stepCount, 1234)
        XCTAssertEqual(result.stepsPerMinute, 84)
        XCTAssertEqual(result.averageStepRate, 80)
        XCTAssertEqual(result.positiveElevationGainMeters ?? -1, 21.1, accuracy: 0.0001)
        XCTAssertEqual(result.totalEnergyKcal, 150)
        XCTAssertEqual(result.energyPerHourKcal, 360)
        XCTAssertEqual(result.energyPerMinuteKcal, 6)
        XCTAssertEqual(result.heartRateBPM, 120)
        XCTAssertEqual(result.metabolicEquivalent ?? -1, 8.3, accuracy: 0.0001)
        XCTAssertEqual(result.elapsedTimeSeconds, 600)
        XCTAssertEqual(result.remainingTimeSeconds, 300)
    }

    func testRejectsPacketsShorterThanFlags() {
        for packet in [Data(), Data([0x00])] {
            XCTAssertThrowsError(try FTMSStepClimberParser.parse(packet)) { error in
                XCTAssertEqual(
                    error as? FTMSStepClimberParseError,
                    .missingFlags(actualBytes: packet.count)
                )
            }
        }
    }

    func testRejectsEveryTruncatedPrefixOfFullPacket() {
        let expectations: [(length: Int, field: String, expectedBytes: Int, remainingBytes: Int)] = [
            (2, "Floors", 2, 0),
            (3, "Floors", 2, 1),
            (4, "Step Count", 2, 0),
            (5, "Step Count", 2, 1),
            (6, "Steps Per Minute", 2, 0),
            (7, "Steps Per Minute", 2, 1),
            (8, "Average Step Rate", 2, 0),
            (9, "Average Step Rate", 2, 1),
            (10, "Positive Elevation Gain", 2, 0),
            (11, "Positive Elevation Gain", 2, 1),
            (12, "Total Energy", 2, 0),
            (13, "Total Energy", 2, 1),
            (14, "Energy Per Hour", 2, 0),
            (15, "Energy Per Hour", 2, 1),
            (16, "Energy Per Minute", 1, 0),
            (17, "Heart Rate", 1, 0),
            (18, "Metabolic Equivalent", 1, 0),
            (19, "Elapsed Time", 2, 0),
            (20, "Elapsed Time", 2, 1),
            (21, "Remaining Time", 2, 0),
            (22, "Remaining Time", 2, 1),
        ]

        for expectation in expectations {
            let packet = observed01FEPacket.prefix(expectation.length)
            XCTAssertThrowsError(try FTMSStepClimberParser.parse(Data(packet))) { error in
                XCTAssertEqual(
                    error as? FTMSStepClimberParseError,
                    .truncated(
                        field: expectation.field,
                        expectedBytes: expectation.expectedBytes,
                        remainingBytes: expectation.remainingBytes
                    ),
                    "Unexpected error for packet prefix of length \(expectation.length)"
                )
            }
        }
    }

    func testParsesMandatoryFieldsOnly() throws {
        let packet = Data([0x00, 0x00, 0x03, 0x00, 0x2A, 0x00])
        let result = try FTMSStepClimberParser.parse(packet)

        XCTAssertEqual(result.floors, 3)
        XCTAssertEqual(result.stepCount, 42)
        XCTAssertNil(result.stepsPerMinute)
    }

    func testMoreDataOmitsFloorsAndSteps() throws {
        let packet = Data([0x03, 0x00, 0x5A, 0x00])
        let result = try FTMSStepClimberParser.parse(packet)

        XCTAssertNil(result.floors)
        XCTAssertNil(result.stepCount)
        XCTAssertEqual(result.stepsPerMinute, 90)
    }

    func testRejectsTruncatedCompoundEnergyField() {
        let packet = Data([
            0x10, 0x00,
            0x01, 0x00,
            0x02, 0x00,
            0x64, 0x00
        ])

        XCTAssertThrowsError(try FTMSStepClimberParser.parse(packet)) { error in
            XCTAssertEqual(
                error as? FTMSStepClimberParseError,
                .truncated(field: "Energy Per Hour", expectedBytes: 2, remainingBytes: 0)
            )
        }
    }

    func testRejectsTrailingBytes() {
        XCTAssertThrowsError(
            try FTMSStepClimberParser.parse(Data([0, 0, 1, 0, 2, 0, 0xFF]))
        ) { error in
            XCTAssertEqual(error as? FTMSStepClimberParseError, .trailingBytes(1))
        }
    }

    func testRejectsReservedFlagBits() {
        for bit in 9...15 {
            let flags = UInt16(1 << bit)
            let packet = Data([UInt8(flags & 0x00FF), UInt8(flags >> 8)])
            XCTAssertThrowsError(try FTMSStepClimberParser.parse(packet)) { error in
                XCTAssertEqual(error as? FTMSStepClimberParseError, .reservedFlagsSet(flags))
            }
        }
    }

    func testMergeRetainsMissingFieldsAndReplacesPresentZeroValues() {
        let previous = StepClimberMetrics(
            flags: 0x01FE,
            receivedAt: Date(timeIntervalSince1970: 1),
            floors: 4,
            stepCount: 100,
            stepsPerMinute: 80,
            averageStepRate: 75,
            positiveElevationGainMeters: 21.1,
            totalEnergyKcal: 150,
            energyPerHourKcal: 360,
            energyPerMinuteKcal: 6,
            heartRateBPM: 120,
            metabolicEquivalent: 8.3,
            elapsedTimeSeconds: 600,
            remainingTimeSeconds: 300
        )
        let receivedAt = Date(timeIntervalSince1970: 2)
        let fragment = StepClimberMetrics(
            flags: 0x00AA,
            receivedAt: receivedAt,
            floors: 0,
            stepCount: 0,
            stepsPerMinute: 0,
            positiveElevationGainMeters: 0,
            heartRateBPM: 0,
            elapsedTimeSeconds: 0
        )

        XCTAssertEqual(
            fragment.merging(over: previous),
            StepClimberMetrics(
                flags: 0x00AA,
                receivedAt: receivedAt,
                floors: 0,
                stepCount: 0,
                stepsPerMinute: 0,
                averageStepRate: 75,
                positiveElevationGainMeters: 0,
                totalEnergyKcal: 150,
                energyPerHourKcal: 360,
                energyPerMinuteKcal: 6,
                heartRateBPM: 0,
                metabolicEquivalent: 8.3,
                elapsedTimeSeconds: 0,
                remainingTimeSeconds: 300
            )
        )
    }

    private var observed01FEPacket: Data {
        Data([
            0xFE, 0x01,       // flags: bits 1...8
            0x0C, 0x00,       // floors: 12
            0xD2, 0x04,       // steps: 1234
            0x54, 0x00,       // current SPM: 84
            0x50, 0x00,       // average SPM: 80
            0xD3, 0x00,       // elevation: 21.1 m
            0x96, 0x00,       // total energy: 150 kcal
            0x68, 0x01,       // energy/hour: 360 kcal
            0x06,             // energy/minute: 6 kcal
            0x78,             // machine HR: 120 bpm
            0x53,             // MET: 8.3
            0x58, 0x02,       // elapsed: 600 s
            0x2C, 0x01        // remaining: 300 s
        ])
    }
}
