import Foundation
import XCTest
@testable import MatrixClimbConnector

final class FTMSStepClimberRecordAssemblerTests: XCTestCase {
    func testReplayEmitsSinglePacketRecordImmediately() throws {
        var assembler = FTMSStepClimberRecordAssembler()
        let receivedAt = Date(timeIntervalSince1970: 1)

        let output = try assembler.ingest(fullPacket, receivedAt: receivedAt)

        guard case let .completed(fragment, record) = output else {
            return XCTFail("Expected a complete single-notification record")
        }
        XCTAssertEqual(fragment, expectedFullRecord(receivedAt: receivedAt))
        XCTAssertEqual(record, expectedFullRecord(receivedAt: receivedAt))
    }

    func testReplayAssemblesTwoFragments() throws {
        var assembler = FTMSStepClimberRecordAssembler()
        let firstReceivedAt = Date(timeIntervalSince1970: 1)
        let finalReceivedAt = Date(timeIntervalSince1970: 2)

        let firstOutput = try assembler.ingest(twoFragmentStart, receivedAt: firstReceivedAt)
        guard case let .awaitingMoreData(fragment, partialRecord) = firstOutput else {
            return XCTFail("Expected the first notification to remain pending")
        }
        XCTAssertEqual(fragment, partialRecord)
        XCTAssertEqual(partialRecord.flags, 0x000F)
        XCTAssertNil(partialRecord.floors)
        XCTAssertNil(partialRecord.stepCount)
        XCTAssertEqual(partialRecord.stepsPerMinute, 84)
        XCTAssertEqual(partialRecord.averageStepRate, 80)
        XCTAssertEqual(partialRecord.positiveElevationGainMeters ?? -1, 21.1, accuracy: 0.0001)

        let finalOutput = try assembler.ingest(twoFragmentFinal, receivedAt: finalReceivedAt)
        guard case let .completed(_, record) = finalOutput else {
            return XCTFail("Expected the final notification to complete the record")
        }
        XCTAssertEqual(record, expectedFullRecord(receivedAt: finalReceivedAt))
    }

    func testThreeFragmentReplaySurvivesCodecRoundTrip() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        XCTAssertNil(try assembler.ingest(threeFragmentStart).completedRecord)
        XCTAssertNil(try assembler.ingest(threeFragmentMiddle).completedRecord)
        let finalReceivedAt = Date(timeIntervalSince1970: 3)
        let record = try XCTUnwrap(
            assembler.ingest(threeFragmentFinal, receivedAt: finalReceivedAt).completedRecord
        )

        XCTAssertEqual(record, expectedFullRecord(receivedAt: finalReceivedAt))
        let encoded = try WorkoutMessageCodec.encode(.machineMetrics(record))
        XCTAssertEqual(try WorkoutMessageCodec.decode(encoded), .machineMetrics(record))
    }

    func testReplayKeepsConsecutiveRecordsSeparate() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        let first = try XCTUnwrap(assembler.ingest(fullPacket).completedRecord)
        let secondReceivedAt = Date(timeIntervalSince1970: 2)
        let second = try XCTUnwrap(
            assembler.ingest(nextRecord, receivedAt: secondReceivedAt).completedRecord
        )

        XCTAssertEqual(first.floors, 12)
        XCTAssertEqual(second.flags, 0x0002)
        XCTAssertEqual(second.receivedAt, secondReceivedAt)
        XCTAssertEqual(second.floors, 13)
        XCTAssertEqual(second.stepCount, 1_250)
        XCTAssertEqual(second.stepsPerMinute, 85)
        XCTAssertNil(second.averageStepRate)
        XCTAssertNil(second.positiveElevationGainMeters)
        XCTAssertNil(second.totalEnergyKcal)
        XCTAssertNil(second.energyPerHourKcal)
        XCTAssertNil(second.energyPerMinuteKcal)
        XCTAssertNil(second.heartRateBPM)
        XCTAssertNil(second.metabolicEquivalent)
        XCTAssertNil(second.elapsedTimeSeconds)
        XCTAssertNil(second.remainingTimeSeconds)
    }

    func testMalformedFinalDropsPendingRecordAndRecovers() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        XCTAssertNil(try assembler.ingest(threeFragmentStart).completedRecord)
        XCTAssertThrowsError(try assembler.ingest(malformedFinal)) { error in
            XCTAssertEqual(
                error as? FTMSStepClimberParseError,
                .truncated(field: "Energy Per Hour", expectedBytes: 2, remainingBytes: 0)
            )
        }

        let receivedAt = Date(timeIntervalSince1970: 3)
        let recovered = try XCTUnwrap(
            assembler.ingest(minimalFinal, receivedAt: receivedAt).completedRecord
        )
        XCTAssertEqual(recovered.flags, 0)
        XCTAssertEqual(recovered.receivedAt, receivedAt)
        XCTAssertEqual(recovered.floors, 13)
        XCTAssertEqual(recovered.stepCount, 1_250)
        XCTAssertNil(recovered.stepsPerMinute)
        XCTAssertNil(recovered.averageStepRate)
    }

    func testMalformedMiddleDiscardsThroughRecordBoundary() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        XCTAssertNil(try assembler.ingest(threeFragmentStart).completedRecord)
        XCTAssertThrowsError(try assembler.ingest(malformedMiddle)) { error in
            XCTAssertEqual(
                error as? FTMSStepClimberParseError,
                .truncated(field: "Energy Per Hour", expectedBytes: 2, remainingBytes: 0)
            )
        }

        let discardedFinal = try assembler.ingest(threeFragmentFinal)
        guard case .discarded = discardedFinal else {
            return XCTFail("Expected the rest of the malformed record to be discarded")
        }
        XCTAssertNil(discardedFinal.completedRecord)

        let recovered = try XCTUnwrap(assembler.ingest(minimalFinal).completedRecord)
        XCTAssertEqual(recovered.floors, 13)
        XCTAssertEqual(recovered.stepCount, 1_250)
        XCTAssertNil(recovered.stepsPerMinute)
        XCTAssertNil(recovered.averageStepRate)
    }

    func testDisconnectResetDropsPendingFragments() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        XCTAssertNil(try assembler.ingest(threeFragmentStart).completedRecord)
        assembler.reset()

        let recovered = try XCTUnwrap(assembler.ingest(minimalFinal).completedRecord)
        XCTAssertEqual(recovered.floors, 13)
        XCTAssertEqual(recovered.stepCount, 1_250)
        XCTAssertNil(recovered.stepsPerMinute)
        XCTAssertNil(recovered.averageStepRate)
    }

    func testDisconnectResetClearsDiscardState() throws {
        var assembler = FTMSStepClimberRecordAssembler()

        XCTAssertNil(try assembler.ingest(threeFragmentStart).completedRecord)
        XCTAssertThrowsError(try assembler.ingest(malformedMiddle))
        assembler.reset()

        let recovered = try XCTUnwrap(assembler.ingest(minimalFinal).completedRecord)
        XCTAssertEqual(recovered.floors, 13)
        XCTAssertEqual(recovered.stepCount, 1_250)
    }

    private func expectedFullRecord(receivedAt: Date) -> StepClimberMetrics {
        StepClimberMetrics(
            flags: 0x01FE,
            receivedAt: receivedAt,
            floors: 12,
            stepCount: 1_234,
            stepsPerMinute: 84,
            averageStepRate: 80,
            positiveElevationGainMeters: 21.1,
            totalEnergyKcal: 150,
            energyPerHourKcal: 360,
            energyPerMinuteKcal: 6,
            heartRateBPM: 120,
            metabolicEquivalent: 8.3,
            elapsedTimeSeconds: 600,
            remainingTimeSeconds: 300
        )
    }

    private var fullPacket: Data {
        Data([
            0xFE, 0x01,
            0x0C, 0x00,
            0xD2, 0x04,
            0x54, 0x00,
            0x50, 0x00,
            0xD3, 0x00,
            0x96, 0x00,
            0x68, 0x01,
            0x06,
            0x78,
            0x53,
            0x58, 0x02,
            0x2C, 0x01,
        ])
    }

    private var twoFragmentStart: Data {
        Data([
            0x0F, 0x00,
            0x54, 0x00,
            0x50, 0x00,
            0xD3, 0x00,
        ])
    }

    private var twoFragmentFinal: Data {
        Data([
            0xF0, 0x01,
            0x0C, 0x00,
            0xD2, 0x04,
            0x96, 0x00,
            0x68, 0x01,
            0x06,
            0x78,
            0x53,
            0x58, 0x02,
            0x2C, 0x01,
        ])
    }

    private var threeFragmentStart: Data {
        Data([
            0x07, 0x00,
            0x54, 0x00,
            0x50, 0x00,
        ])
    }

    private var threeFragmentMiddle: Data {
        Data([
            0x39, 0x00,
            0xD3, 0x00,
            0x96, 0x00,
            0x68, 0x01,
            0x06,
            0x78,
        ])
    }

    private var threeFragmentFinal: Data {
        Data([
            0xC0, 0x01,
            0x0C, 0x00,
            0xD2, 0x04,
            0x53,
            0x58, 0x02,
            0x2C, 0x01,
        ])
    }

    private var nextRecord: Data {
        Data([
            0x02, 0x00,
            0x0D, 0x00,
            0xE2, 0x04,
            0x55, 0x00,
        ])
    }

    private var minimalFinal: Data {
        Data([
            0x00, 0x00,
            0x0D, 0x00,
            0xE2, 0x04,
        ])
    }

    private var malformedFinal: Data {
        Data([
            0x10, 0x00,
            0x01, 0x00,
            0x02, 0x00,
            0x64, 0x00,
        ])
    }

    private var malformedMiddle: Data {
        Data([
            0x11, 0x00,
            0x64, 0x00,
        ])
    }
}
