import Foundation
import XCTest
@testable import MatrixClimbConnector

#if canImport(UIKit)
@MainActor
final class WorkoutRecordStoreTests: XCTestCase {
    func testCheckpointCadenceAndMatchingSessionRecovery() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let recordID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var currentDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = WorkoutRecordStore(
            persistence: persistence,
            checkpointInterval: 5,
            now: { currentDate },
            makeUUID: { recordID }
        )

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test",
            at: currentDate
        ))
        currentDate.addTimeInterval(1)
        store.append(machine: makeMachineSample(at: currentDate))
        XCTAssertEqual(try persistence.loadCheckpoint()?.record.machineSamples.count, 0)

        currentDate.addTimeInterval(5)
        store.append(watch: makeWatchSnapshot(at: currentDate))
        let checkpoint = try XCTUnwrap(persistence.loadCheckpoint())
        XCTAssertEqual(checkpoint.record.machineSamples.count, 1)
        XCTAssertEqual(checkpoint.record.watchSamples.count, 1)

        let relaunchedStore = WorkoutRecordStore(
            persistence: persistence,
            now: { currentDate }
        )
        XCTAssertNil(relaunchedStore.activeRecord)
        XCTAssertEqual(relaunchedStore.recoveredCheckpoint, checkpoint)
        XCTAssertEqual(
            relaunchedStore.attachMirroredSession(
                startedAt: checkpoint.record.startedAt.addingTimeInterval(-10)
            ),
            .unavailable
        )
        XCTAssertEqual(
            relaunchedStore.attachMirroredSession(
                startedAt: checkpoint.record.startedAt.addingTimeInterval(121)
            ),
            .unavailable
        )
        XCTAssertTrue(relaunchedStore.resumeRecoveredRecord(
            matching: checkpoint.record.startedAt.addingTimeInterval(10)
        ))
        XCTAssertEqual(relaunchedStore.activeRecord?.id, recordID)
        XCTAssertNil(relaunchedStore.recoveredCheckpoint)
        XCTAssertEqual(
            try persistence.loadCheckpoint()?.mirroredSessionStartDate,
            checkpoint.record.startedAt.addingTimeInterval(10)
        )
        XCTAssertEqual(
            relaunchedStore.attachMirroredSession(
                startedAt: checkpoint.record.startedAt.addingTimeInterval(20)
            ),
            .unavailable
        )
    }

    func testFinishPersistsHistoryBeforeRemovingCheckpoint() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let store = WorkoutRecordStore(persistence: persistence)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(60)

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test",
            at: startedAt
        ))
        store.append(machine: makeMachineSample(at: startedAt.addingTimeInterval(5)))
        XCTAssertTrue(store.finish(at: endedAt))

        XCTAssertNil(store.activeRecord)
        XCTAssertNil(store.recoveredCheckpoint)
        XCTAssertNil(try persistence.loadCheckpoint())
        XCTAssertEqual(try persistence.loadCompletedRecords(), store.records)
        XCTAssertEqual(store.records.first?.endedAt, endedAt)
    }

    func testDirtyTailCheckpointsWithoutAnotherSample() async throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let store = WorkoutRecordStore(
            persistence: persistence,
            checkpointInterval: 0.05
        )
        let startedAt = Date()

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test",
            at: startedAt
        ))
        store.append(machine: makeMachineSample(at: startedAt.addingTimeInterval(1)))

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(try persistence.loadCheckpoint()?.record.machineSamples.count, 1)
    }

    func testHistoryWriteFailureKeepsPendingCompletionUntilRetry() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        var failHistoryWrites = true
        let persistence = WorkoutRecordPersistence(
            directoryURL: directoryURL,
            writer: { data, url in
                if failHistoryWrites && url.lastPathComponent == "workout-records.json" {
                    throw InjectedWriteError.failed
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let store = WorkoutRecordStore(persistence: persistence)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test",
            at: startedAt
        ))
        store.append(machine: makeMachineSample(at: startedAt.addingTimeInterval(5)))
        XCTAssertFalse(store.finish(at: startedAt.addingTimeInterval(60)))
        XCTAssertNil(store.activeRecord)
        XCTAssertEqual(store.recoveredCheckpoint?.state, .pendingCompletion)
        XCTAssertEqual(try persistence.loadCheckpoint()?.state, .pendingCompletion)
        XCTAssertTrue(try persistence.loadCompletedRecords().isEmpty)

        let relaunchedStore = WorkoutRecordStore(persistence: persistence)
        XCTAssertEqual(relaunchedStore.recoveredCheckpoint?.state, .pendingCompletion)
        XCTAssertTrue(relaunchedStore.canRetryPersistence)

        failHistoryWrites = false
        relaunchedStore.retryPersistence()

        XCTAssertNil(relaunchedStore.recoveredCheckpoint)
        XCTAssertNil(relaunchedStore.persistenceError)
        XCTAssertNil(try persistence.loadCheckpoint())
        XCTAssertEqual(try persistence.loadCompletedRecords(), relaunchedStore.records)
        XCTAssertEqual(relaunchedStore.records.count, 1)
    }

    func testCurrentRecordRejectsAStaleMirroredSession() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let store = WorkoutRecordStore(persistence: persistence)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test",
            at: startedAt
        ))
        XCTAssertEqual(
            store.attachMirroredSession(startedAt: startedAt.addingTimeInterval(-10)),
            .unavailable
        )
        XCTAssertEqual(
            store.attachMirroredSession(startedAt: startedAt.addingTimeInterval(121)),
            .unavailable
        )
        XCTAssertNil(try persistence.loadCheckpoint()?.mirroredSessionStartDate)
        let recordID = try XCTUnwrap(store.activeRecord?.id)
        XCTAssertEqual(
            store.attachMirroredSession(
                startedAt: startedAt.addingTimeInterval(300),
                currentLaunchRecordID: UUID()
            ),
            .unavailable
        )
        XCTAssertEqual(
            store.attachMirroredSession(
                startedAt: startedAt.addingTimeInterval(300),
                currentLaunchRecordID: recordID
            ),
            .current
        )
    }

    func testCancelledLaunchCheckpointSurvivesRelaunch() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        let store = WorkoutRecordStore(persistence: persistence)

        XCTAssertTrue(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test"
        ))
        store.interruptActiveRecord(state: .cancelledLaunchPending)

        XCTAssertNil(store.activeRecord)
        XCTAssertEqual(store.recoveredCheckpoint?.state, .cancelledLaunchPending)
        XCTAssertEqual(try persistence.loadCheckpoint()?.state, .cancelledLaunchPending)

        let relaunchedStore = WorkoutRecordStore(persistence: persistence)
        XCTAssertEqual(relaunchedStore.recoveredCheckpoint?.state, .cancelledLaunchPending)
        XCTAssertTrue(relaunchedStore.hasPendingRecord)
    }

    func testCorruptHistoryBlocksNewWorkoutWithoutOverwritingBytes() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        try persistence.prepareDirectory()
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: persistence.completedRecordsURL, options: .atomic)

        let store = WorkoutRecordStore(persistence: persistence)

        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(store.begin(
            peripheralID: peripheralID,
            deviceName: "Matrix Test"
        ))
        XCTAssertEqual(try Data(contentsOf: persistence.completedRecordsURL), corruptData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.checkpointURL.path))
    }

    func testCorruptHistoryCanBeQuarantinedAfterDiagnosticExport() throws {
        let directoryURL = makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let persistence = WorkoutRecordPersistence(directoryURL: directoryURL)
        try persistence.prepareDirectory()
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: persistence.completedRecordsURL, options: .atomic)
        let store = WorkoutRecordStore(persistence: persistence)

        let exportData = try XCTUnwrap(store.diagnosticExportData())
        let export = try recordDecoder.decode(WorkoutRecordDiagnosticExport.self, from: exportData)
        XCTAssertEqual(
            export.unreadableStorageFilesBase64["workout-records.json"],
            corruptData.base64EncodedString()
        )

        store.quarantineCorruptStorage()

        XCTAssertFalse(store.hasCorruptStorage)
        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(try persistence.loadCompletedRecords().isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            backups.filter { $0.lastPathComponent.hasPrefix("workout-records.json.corrupt-") }.count,
            1
        )
    }

    private enum InjectedWriteError: Error {
        case failed
    }

    private var peripheralID: UUID {
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    }

    private func makeTemporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MatrixClimbConnectorStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeMachineSample(at date: Date) -> RecordedMachineSample {
        let metrics = StepClimberMetrics(
            flags: 0,
            receivedAt: date,
            floors: 12,
            stepCount: 1_234
        )
        return RecordedMachineSample(
            rawPacketHex: "00 00 0C 00 D2 04",
            parsedFragment: metrics,
            accumulatedMetrics: metrics
        )
    }

    private func makeWatchSnapshot(at date: Date) -> WatchWorkoutSnapshot {
        WatchWorkoutSnapshot(
            heartRateBPM: 121.5,
            activeEnergyKcal: 42.25,
            state: "running",
            updatedAt: date
        )
    }

    private var recordDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
