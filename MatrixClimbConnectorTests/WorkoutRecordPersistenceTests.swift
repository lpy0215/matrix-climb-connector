import Foundation
import XCTest
@testable import MatrixClimbConnector

final class WorkoutRecordPersistenceTests: XCTestCase {
    func testMissingFilesLoadAsEmptyAndCheckpointRemovalIsIdempotent() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)

        XCTAssertEqual(try persistence.loadCompletedRecords(), [])
        XCTAssertNil(try persistence.loadCheckpoint())
        XCTAssertNoThrow(try persistence.removeCheckpoint())
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.completedRecordsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.checkpointURL.path))
    }

    func testLoadsLegacyCompletedRecordArrayAndWritesTheSameTopLevelShape() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        try persistence.prepareDirectory()

        let first = makeRecord()
        let legacyData = try recordEncoder.encode([first])
        try legacyData.write(to: persistence.completedRecordsURL, options: .atomic)

        XCTAssertEqual(try persistence.loadCompletedRecords(), [first])

        let second = makeRecord(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            deviceName: "Matrix Test 2"
        )
        try persistence.writeCompletedRecords([second, first])

        XCTAssertEqual(try persistence.loadCompletedRecords(), [second, first])
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: persistence.completedRecordsURL)
        )
        XCTAssertEqual((json as? [Any])?.count, 2)
    }

    func testCheckpointRoundTripsEveryStateAndCanBeRemoved() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let record = makeRecord()

        let active = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_030),
            state: .active
        )
        try persistence.writeCheckpoint(active)
        XCTAssertEqual(try persistence.loadCheckpoint(), active)

        let interrupted = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_040),
            state: .interrupted
        )
        try persistence.writeCheckpoint(interrupted)
        XCTAssertEqual(try persistence.loadCheckpoint(), interrupted)

        let cancelledLaunch = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_045),
            state: .cancelledLaunchPending
        )
        try persistence.writeCheckpoint(cancelledLaunch)
        XCTAssertEqual(try persistence.loadCheckpoint(), cancelledLaunch)

        let pendingCompletion = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_050),
            state: .pendingCompletion,
            mirroredSessionStartDate: Date(timeIntervalSince1970: 1_700_000_005)
        )
        try persistence.writeCheckpoint(pendingCompletion)
        XCTAssertEqual(try persistence.loadCheckpoint(), pendingCompletion)

        try persistence.removeCheckpoint()
        XCTAssertNil(try persistence.loadCheckpoint())
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.checkpointURL.path))
        XCTAssertNoThrow(try persistence.removeCheckpoint())
    }

    func testDiagnosticExportRoundTripsEveryField() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let record = makeRecord()
        let checkpoint = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_040),
            state: .interrupted
        )
        let export = WorkoutRecordDiagnosticExport(
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
            completedRecords: [record],
            pendingCheckpoint: checkpoint,
            persistenceError: "Injected disk failure",
            context: [
                "appVersion": "0.1",
                "commit": "abcdef0",
            ]
        )

        let data = try persistence.encodeDiagnosticExport(export)
        let decoded = try recordDecoder.decode(WorkoutRecordDiagnosticExport.self, from: data)

        XCTAssertEqual(decoded, export)
    }

    func testCorruptJSONIsRejectedWithoutChangingEitherFile() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        try persistence.prepareDirectory()
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: persistence.completedRecordsURL, options: .atomic)
        try corruptData.write(to: persistence.checkpointURL, options: .atomic)

        XCTAssertThrowsError(try persistence.loadCompletedRecords()) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertThrowsError(try persistence.loadCheckpoint()) { error in
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(try Data(contentsOf: persistence.completedRecordsURL), corruptData)
        XCTAssertEqual(try Data(contentsOf: persistence.checkpointURL), corruptData)
    }

    func testWriteFailuresArePropagatedWithoutCreatingDestinationFiles() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var attempts: [(data: Data, url: URL)] = []
        let persistence = WorkoutRecordPersistence(
            directoryURL: directoryURL,
            writer: { data, url in
                attempts.append((data, url))
                throw InjectedWriteError.failed
            }
        )
        let record = makeRecord()
        let checkpoint = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: Date(timeIntervalSince1970: 1_700_000_040),
            state: .active
        )

        XCTAssertThrowsError(try persistence.writeCompletedRecords([record])) { error in
            XCTAssertTrue(error is InjectedWriteError)
        }
        XCTAssertThrowsError(try persistence.writeCheckpoint(checkpoint)) { error in
            XCTAssertTrue(error is InjectedWriteError)
        }

        XCTAssertEqual(attempts.map { $0.url }, [
            persistence.completedRecordsURL,
            persistence.checkpointURL,
        ])
        XCTAssertEqual(
            try recordDecoder.decode([WorkoutRecord].self, from: attempts[0].data),
            [record]
        )
        XCTAssertEqual(
            try recordDecoder.decode(WorkoutRecordCheckpoint.self, from: attempts[1].data),
            checkpoint
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.completedRecordsURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.checkpointURL.path))
    }

    func testQuarantinePreservesCorruptStorageBytes() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        try persistence.prepareDirectory()
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: persistence.checkpointURL, options: .atomic)

        XCTAssertEqual(
            try persistence.readStorageFile(persistence.checkpointURL),
            corruptData
        )
        let backupURL = try persistence.quarantineStorageFile(
            persistence.checkpointURL,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.checkpointURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), corruptData)
        XCTAssertTrue(backupURL.lastPathComponent.hasPrefix(
            "active-workout-record.json.corrupt-"
        ))
    }

    private enum InjectedWriteError: Error {
        case failed
    }

    private var recordEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var recordDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeTemporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MatrixClimbConnectorPersistenceTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeRecord(
        id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        deviceName: String = "Matrix Test"
    ) -> WorkoutRecord {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let parsedFragment = StepClimberMetrics(
            flags: 0x01C0,
            receivedAt: receivedAt,
            floors: 12,
            stepCount: 1_234,
            metabolicEquivalent: 8.3,
            elapsedTimeSeconds: 600,
            remainingTimeSeconds: 300
        )
        let accumulatedMetrics = StepClimberMetrics(
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
        let machineSample = RecordedMachineSample(
            rawPacketHex: "C0 01 0C 00 D2 04 53 58 02 2C 01",
            parsedFragment: parsedFragment,
            accumulatedMetrics: accumulatedMetrics
        )
        let watchSample = WatchWorkoutSnapshot(
            heartRateBPM: 121.5,
            activeEnergyKcal: 42.25,
            state: "running",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )

        return WorkoutRecord(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            peripheralIdentifier: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!,
            deviceName: deviceName,
            machineSamples: [machineSample],
            watchSamples: [watchSample]
        )
    }
}
