import XCTest
@testable import MatrixClimbConnector

final class FTMSStepClimberParserTests: XCTestCase {
    func testParsesObserved01FELayout() throws {
        let packet = Data([
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

        let result = try FTMSStepClimberParser.parse(packet)

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
        XCTAssertThrowsError(
            try FTMSStepClimberParser.parse(Data([0x00, 0x02]))
        ) { error in
            XCTAssertEqual(error as? FTMSStepClimberParseError, .reservedFlagsSet(0x0200))
        }
    }

    func testPartialNotificationMergesOverLastKnownMetrics() throws {
        let complete = try FTMSStepClimberParser.parse(Data([
            0x02, 0x00,
            0x04, 0x00,
            0x64, 0x00,
            0x50, 0x00
        ]))
        let continuation = try FTMSStepClimberParser.parse(Data([
            0x03, 0x00,
            0x52, 0x00
        ]))
        let merged = continuation.merging(over: complete)

        XCTAssertEqual(merged.floors, 4)
        XCTAssertEqual(merged.stepCount, 100)
        XCTAssertEqual(merged.stepsPerMinute, 82)
    }
}
