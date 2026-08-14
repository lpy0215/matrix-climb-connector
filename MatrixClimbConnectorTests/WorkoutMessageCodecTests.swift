import XCTest
@testable import MatrixClimbConnector

final class WorkoutMessageCodecTests: XCTestCase {
    func testMachineMetricsRoundTrip() throws {
        let metrics = StepClimberMetrics(
            flags: 0x01FE,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            floors: 8,
            stepCount: 144,
            stepsPerMinute: 72,
            averageStepRate: 70,
            positiveElevationGainMeters: 18.4,
            totalEnergyKcal: 150,
            energyPerHourKcal: 360,
            energyPerMinuteKcal: 6,
            heartRateBPM: 121,
            metabolicEquivalent: 8.3,
            elapsedTimeSeconds: 600,
            remainingTimeSeconds: 300
        )
        let encoded = try WorkoutMessageCodec.encode(.machineMetrics(metrics))
        let decoded = try WorkoutMessageCodec.decode(encoded)
        XCTAssertEqual(decoded, .machineMetrics(metrics))
    }

    func testWatchSnapshotRoundTrip() throws {
        let snapshot = WatchWorkoutSnapshot(
            heartRateBPM: 121.5,
            activeEnergyKcal: 42.25,
            state: "running",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoded = try WorkoutMessageCodec.encode(.watchSnapshot(snapshot))
        let decoded = try WorkoutMessageCodec.decode(encoded)

        XCTAssertEqual(decoded, .watchSnapshot(snapshot))
    }

    func testDecodesStableWatchSnapshotWireFixture() throws {
        let data = Data(
            #"{"watchSnapshot":{"_0":{"heartRateBPM":121.5,"activeEnergyKcal":42.25,"state":"running","updatedAt":1700000000123}}}"#.utf8
        )

        let decoded = try WorkoutMessageCodec.decode(data)
        guard case let .watchSnapshot(snapshot) = decoded else {
            return XCTFail("Expected a watch snapshot message")
        }

        XCTAssertEqual(snapshot.heartRateBPM, 121.5)
        XCTAssertEqual(snapshot.activeEnergyKcal, 42.25)
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.000_001)
    }
}
