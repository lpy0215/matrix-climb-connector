import XCTest
@testable import MatrixClimbConnector

final class WorkoutMessageCodecTests: XCTestCase {
    func testMachineMetricsRoundTrip() throws {
        let metrics = StepClimberMetrics(
            flags: 0x000A,
            receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            floors: 8,
            stepCount: 144,
            stepsPerMinute: 72,
            positiveElevationGainMeters: 18.4
        )
        let encoded = try WorkoutMessageCodec.encode(.machineMetrics(metrics))
        let decoded = try WorkoutMessageCodec.decode(encoded)
        XCTAssertEqual(decoded, .machineMetrics(metrics))
    }
}
