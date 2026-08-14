import Combine
import Foundation

enum MirroredWorkoutRecordAttachment: Equatable {
    case current
    case recovered
    case unavailable
}

@MainActor
final class WorkoutRecordStore: ObservableObject {
    @Published private(set) var records: [WorkoutRecord] = []
    @Published private(set) var activeRecord: WorkoutRecord?
    @Published private(set) var recoveredCheckpoint: WorkoutRecordCheckpoint?
    @Published private(set) var persistenceError: String?
    @Published private(set) var hasCorruptStorage = false

    private let persistence: WorkoutRecordPersistence?
    private let checkpointInterval: TimeInterval
    private let now: () -> Date
    private let makeUUID: () -> UUID

    private var lastCheckpointAt: Date?
    private var checkpointIsDirty = false
    private var checkpointTask: Task<Void, Never>?
    private var activeMirroredSessionStartDate: Date?
    private var loadFailed = false
    private var corruptStorageURLs: [URL] = []

    var hasPendingRecord: Bool {
        activeRecord != nil || recoveredCheckpoint != nil
    }

    var canRetryPersistence: Bool {
        persistenceError != nil || recoveredCheckpoint?.state == .pendingCompletion
    }

    var latestMachineMetrics: StepClimberMetrics? {
        activeRecord?.machineSamples.last?.accumulatedMetrics
    }

    var expectedPeripheralIdentifier: UUID? {
        activeRecord?.peripheralIdentifier
            ?? recoveredCheckpoint?.record.peripheralIdentifier
    }

    var expectedDeviceName: String? {
        activeRecord?.deviceName ?? recoveredCheckpoint?.record.deviceName
    }

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        checkpointInterval: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.checkpointInterval = checkpointInterval
        self.now = now
        self.makeUUID = makeUUID

        do {
            let resolvedDirectory: URL
            if let directoryURL {
                resolvedDirectory = directoryURL
            } else {
                resolvedDirectory = try WorkoutRecordPersistence.applicationSupportDirectory(
                    fileManager: fileManager
                )
            }
            persistence = WorkoutRecordPersistence(
                directoryURL: resolvedDirectory,
                fileManager: fileManager
            )
        } catch {
            persistence = nil
            persistenceError = "Preparing workout storage failed: \(error.localizedDescription)"
            loadFailed = true
        }

        loadFromDisk()
    }

    init(
        persistence: WorkoutRecordPersistence,
        checkpointInterval: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.persistence = persistence
        self.checkpointInterval = checkpointInterval
        self.now = now
        self.makeUUID = makeUUID
        loadFromDisk()
    }

    @discardableResult
    func begin(peripheralID: UUID, deviceName: String, at date: Date = .now) -> Bool {
        guard !loadFailed else {
            persistenceError = "Resolve the workout storage error before starting a new workout."
            return false
        }
        guard activeRecord == nil else {
            persistenceError = "A workout record is already active."
            return false
        }
        guard recoveredCheckpoint == nil else {
            persistenceError = "Export or discard the recovered workout record before starting a new workout."
            return false
        }
        guard let persistence else {
            persistenceError = "Workout storage is unavailable."
            return false
        }

        let record = WorkoutRecord(
            id: makeUUID(),
            startedAt: date,
            endedAt: date,
            peripheralIdentifier: peripheralID,
            deviceName: deviceName,
            machineSamples: [],
            watchSamples: []
        )
        let checkpointDate = now()
        let checkpoint = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: checkpointDate,
            state: .active,
            mirroredSessionStartDate: nil
        )

        do {
            try persistence.writeCheckpoint(checkpoint)
            activeRecord = record
            lastCheckpointAt = checkpointDate
            checkpointIsDirty = false
            activeMirroredSessionStartDate = nil
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Starting the workout record failed: \(error.localizedDescription)"
            return false
        }
    }

    func append(machine sample: RecordedMachineSample) {
        guard var record = activeRecord else { return }
        record.machineSamples.append(sample)
        record.endedAt = max(record.endedAt, sample.parsedFragment.receivedAt)
        activeRecord = record
        checkpointIsDirty = true
        checkpointAfterMutation()
    }

    func append(watch snapshot: WatchWorkoutSnapshot) {
        guard var record = activeRecord else { return }
        record.watchSamples.append(snapshot)
        record.endedAt = max(record.endedAt, snapshot.updatedAt)
        activeRecord = record
        checkpointIsDirty = true
        checkpointAfterMutation()
    }

    @discardableResult
    func checkpointNow(at date: Date? = nil) -> Bool {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard checkpointIsDirty, let record = activeRecord else { return true }
        guard let persistence else {
            persistenceError = "Workout storage is unavailable."
            return false
        }

        let checkpointDate = date ?? now()
        do {
            try persistence.writeCheckpoint(WorkoutRecordCheckpoint(
                record: record,
                checkpointedAt: checkpointDate,
                state: .active,
                mirroredSessionStartDate: activeMirroredSessionStartDate
            ))
            lastCheckpointAt = checkpointDate
            checkpointIsDirty = false
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Checkpointing the workout record failed: \(error.localizedDescription)"
            scheduleCheckpoint()
            return false
        }
    }

    @discardableResult
    func finish(at date: Date = .now) -> Bool {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard var record = activeRecord else { return true }
        guard let persistence else {
            persistenceError = "Workout storage is unavailable."
            return false
        }

        record.endedAt = max(record.endedAt, date)
        activeRecord = record
        checkpointIsDirty = true

        var updatedRecords = records.filter { $0.id != record.id }
        updatedRecords.insert(record, at: 0)

        do {
            try persistence.writeCompletedRecords(updatedRecords)
        } catch {
            let historyError = error
            let checkpoint = WorkoutRecordCheckpoint(
                record: record,
                checkpointedAt: now(),
                state: .pendingCompletion,
                mirroredSessionStartDate: activeMirroredSessionStartDate
            )
            var checkpointWriteFailed = false
            do {
                try persistence.writeCheckpoint(checkpoint)
                checkpointIsDirty = false
            } catch {
                checkpointWriteFailed = true
                persistenceError = "Saving the completed workout failed: \(historyError.localizedDescription). Updating its recovery checkpoint also failed: \(error.localizedDescription)"
            }
            activeRecord = nil
            activeMirroredSessionStartDate = nil
            recoveredCheckpoint = checkpoint
            if !checkpointWriteFailed {
                persistenceError = "Saving the completed workout failed: \(historyError.localizedDescription)"
            }
            return false
        }

        records = updatedRecords
        activeRecord = nil
        activeMirroredSessionStartDate = nil
        recoveredCheckpoint = nil
        checkpointIsDirty = false

        do {
            try persistence.removeCheckpoint()
            persistenceError = nil
        } catch {
            persistenceError = "The workout was saved, but clearing its recovery checkpoint failed: \(error.localizedDescription)"
        }
        return true
    }

    func interruptActiveRecord(
        at date: Date? = nil,
        state: WorkoutRecordCheckpointState = .interrupted
    ) {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard var record = activeRecord else { return }
        let checkpointDate = date ?? now()
        record.endedAt = max(record.endedAt, checkpointDate)
        let checkpoint = WorkoutRecordCheckpoint(
            record: record,
            checkpointedAt: checkpointDate,
            state: state,
            mirroredSessionStartDate: activeMirroredSessionStartDate
        )

        do {
            guard let persistence else {
                throw WorkoutRecordPersistenceError.applicationSupportDirectoryUnavailable
            }
            try persistence.writeCheckpoint(checkpoint)
            persistenceError = nil
            checkpointIsDirty = false
        } catch {
            persistenceError = "Preserving the interrupted workout failed: \(error.localizedDescription)"
            checkpointIsDirty = true
        }

        activeRecord = nil
        activeMirroredSessionStartDate = nil
        recoveredCheckpoint = checkpoint
    }

    func discardActiveRecord() {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard activeRecord != nil else { return }
        do {
            try persistence?.removeCheckpoint()
            activeRecord = nil
            activeMirroredSessionStartDate = nil
            checkpointIsDirty = false
            persistenceError = nil
        } catch {
            persistenceError = "Discarding the active workout record failed: \(error.localizedDescription)"
        }
    }

    func discardRecoveredRecord() {
        guard recoveredCheckpoint != nil else { return }
        do {
            try persistence?.removeCheckpoint()
            recoveredCheckpoint = nil
            persistenceError = nil
        } catch {
            persistenceError = "Discarding the recovered workout record failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func resumeRecoveredRecord(
        matching sessionStartDate: Date,
        tolerance: TimeInterval = 120
    ) -> Bool {
        switch attachMirroredSession(startedAt: sessionStartDate, legacyTolerance: tolerance) {
        case .current, .recovered:
            true
        case .unavailable:
            false
        }
    }

    @discardableResult
    func attachMirroredSession(
        startedAt sessionStartDate: Date,
        currentLaunchRecordID: UUID? = nil,
        legacyTolerance: TimeInterval = 120
    ) -> MirroredWorkoutRecordAttachment {
        guard !loadFailed else { return .unavailable }

        if let activeRecord {
            if let activeMirroredSessionStartDate {
                guard abs(activeMirroredSessionStartDate.timeIntervalSince(sessionStartDate)) <= 5 else {
                    return .unavailable
                }
            } else {
                let startOffset = sessionStartDate.timeIntervalSince(activeRecord.startedAt)
                guard startOffset >= -5 else {
                    return .unavailable
                }
                if currentLaunchRecordID != activeRecord.id,
                   startOffset > legacyTolerance {
                    return .unavailable
                }
            }
            activeMirroredSessionStartDate = sessionStartDate
            checkpointIsDirty = true
            _ = checkpointNow()
            return .current
        }

        guard let checkpoint = recoveredCheckpoint,
              checkpoint.state == .active
        else { return .unavailable }

        if let expectedStartDate = checkpoint.mirroredSessionStartDate {
            guard abs(expectedStartDate.timeIntervalSince(sessionStartDate)) <= 5 else {
                return .unavailable
            }
        } else {
            let startOffset = sessionStartDate.timeIntervalSince(checkpoint.record.startedAt)
            guard startOffset >= -5, startOffset <= legacyTolerance else {
                return .unavailable
            }
        }

        activeRecord = checkpoint.record
        activeMirroredSessionStartDate = sessionStartDate
        recoveredCheckpoint = nil
        lastCheckpointAt = checkpoint.checkpointedAt
        checkpointIsDirty = true
        _ = checkpointNow()
        return .recovered
    }

    func retryPersistence() {
        if loadFailed {
            loadFromDisk()
            return
        }
        if activeRecord != nil {
            checkpointIsDirty = true
            _ = checkpointNow()
            return
        }
        if let checkpoint = recoveredCheckpoint, let persistence {
            if checkpoint.state == .pendingCompletion {
                var updatedRecords = records.filter { $0.id != checkpoint.record.id }
                updatedRecords.insert(checkpoint.record, at: 0)
                do {
                    try persistence.writeCompletedRecords(updatedRecords)
                    records = updatedRecords
                    recoveredCheckpoint = nil
                    try persistence.removeCheckpoint()
                    persistenceError = nil
                } catch {
                    persistenceError = "Retrying the completed workout save failed: \(error.localizedDescription)"
                }
                return
            }
            do {
                try persistence.writeCheckpoint(checkpoint)
                persistenceError = nil
            } catch {
                persistenceError = "Retrying workout storage failed: \(error.localizedDescription)"
            }
            return
        }

        do {
            try persistence?.removeCheckpoint()
            persistenceError = nil
        } catch {
            persistenceError = "Retrying workout storage failed: \(error.localizedDescription)"
        }
    }

    func diagnosticExportData(
        context: [String: String] = [:],
        exportedAt: Date? = nil
    ) -> Data? {
        let exportDate = exportedAt ?? now()
        let pendingCheckpoint = activeRecord.map {
            WorkoutRecordCheckpoint(
                record: $0,
                checkpointedAt: exportDate,
                state: .active,
                mirroredSessionStartDate: activeMirroredSessionStartDate
            )
        } ?? recoveredCheckpoint

        var unreadableStorageFilesBase64: [String: String] = [:]
        if let persistence {
            do {
                for url in corruptStorageURLs {
                    unreadableStorageFilesBase64[url.lastPathComponent] = try persistence
                        .readStorageFile(url)
                        .base64EncodedString()
                }
            } catch {
                persistenceError = "Reading the damaged storage file for export failed: \(error.localizedDescription)"
                return nil
            }
        }

        let export = WorkoutRecordDiagnosticExport(
            schemaVersion: 1,
            exportedAt: exportDate,
            completedRecords: records,
            pendingCheckpoint: pendingCheckpoint,
            persistenceError: persistenceError,
            context: context,
            unreadableStorageFilesBase64: unreadableStorageFilesBase64
        )

        do {
            return try WorkoutRecordPersistence.encodeDiagnosticExport(export)
        } catch {
            persistenceError = "Encoding the diagnostic export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func quarantineCorruptStorage() {
        guard activeRecord == nil,
              let persistence,
              !corruptStorageURLs.isEmpty else { return }
        let quarantineDate = now()
        var errors: [String] = []

        for url in corruptStorageURLs {
            do {
                try persistence.quarantineStorageFile(url, at: quarantineDate)
            } catch {
                errors.append("Preserving \(url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }

        loadFromDisk()
        if !errors.isEmpty {
            let existingError = persistenceError.map { " \($0)" } ?? ""
            persistenceError = errors.joined(separator: " ") + existingError
        }
    }

    private func checkpointAfterMutation() {
        let currentDate = now()
        let elapsed = lastCheckpointAt.map { currentDate.timeIntervalSince($0) }
            ?? checkpointInterval
        if elapsed >= checkpointInterval {
            _ = checkpointNow(at: currentDate)
        } else {
            scheduleCheckpoint(after: checkpointInterval - elapsed)
        }
    }

    private func scheduleCheckpoint(after delay: TimeInterval? = nil) {
        guard checkpointIsDirty, activeRecord != nil, checkpointTask == nil else { return }
        let remainingDelay = delay ?? checkpointInterval
        let nanoseconds = UInt64(max(0, remainingDelay) * 1_000_000_000)

        checkpointTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            self.checkpointTask = nil
            _ = self.checkpointNow()
        }
    }

    private func loadFromDisk() {
        guard let persistence else { return }

        checkpointTask?.cancel()
        checkpointTask = nil
        loadFailed = false
        corruptStorageURLs = []
        hasCorruptStorage = false
        persistenceError = nil
        var errors: [String] = []

        do {
            records = try persistence.loadCompletedRecords()
        } catch {
            records = []
            loadFailed = true
            corruptStorageURLs.append(persistence.completedRecordsURL)
            errors.append("Loading saved workouts failed: \(error.localizedDescription)")
        }

        do {
            if let checkpoint = try persistence.loadCheckpoint() {
                if records.contains(where: { $0.id == checkpoint.record.id }) {
                    do {
                        try persistence.removeCheckpoint()
                    } catch {
                        errors.append("Clearing a stale workout checkpoint failed: \(error.localizedDescription)")
                    }
                    recoveredCheckpoint = nil
                } else {
                    recoveredCheckpoint = checkpoint
                }
            } else {
                recoveredCheckpoint = nil
            }
        } catch {
            recoveredCheckpoint = nil
            loadFailed = true
            corruptStorageURLs.append(persistence.checkpointURL)
            errors.append("Loading the workout recovery checkpoint failed: \(error.localizedDescription)")
        }

        hasCorruptStorage = !corruptStorageURLs.isEmpty
        if !errors.isEmpty {
            persistenceError = errors.joined(separator: " ")
        }
    }
}
