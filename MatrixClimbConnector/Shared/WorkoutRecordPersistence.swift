import Foundation

enum WorkoutRecordCheckpointState: String, Codable, Equatable, Sendable {
    case active
    case interrupted
    case cancelledLaunchPending
    case pendingCompletion
}

struct WorkoutRecordCheckpoint: Codable, Equatable, Sendable {
    var record: WorkoutRecord
    var checkpointedAt: Date
    var state: WorkoutRecordCheckpointState
    var mirroredSessionStartDate: Date? = nil
}

struct WorkoutRecordDiagnosticExport: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var completedRecords: [WorkoutRecord]
    var pendingCheckpoint: WorkoutRecordCheckpoint?
    var persistenceError: String?
    var context: [String: String]
    var unreadableStorageFilesBase64: [String: String] = [:]
}

enum WorkoutRecordPersistenceError: LocalizedError, Equatable {
    case applicationSupportDirectoryUnavailable
    case unexpectedStorageFile

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            "The Application Support directory is unavailable."
        case .unexpectedStorageFile:
            "The requested file is outside the workout storage set."
        }
    }
}

struct WorkoutRecordPersistence {
    typealias AtomicWriter = (_ data: Data, _ url: URL) throws -> Void

    let directoryURL: URL
    let completedRecordsURL: URL
    let checkpointURL: URL

    private let fileManager: FileManager
    private let writer: AtomicWriter

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        writer: @escaping AtomicWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.writer = writer
        completedRecordsURL = directoryURL.appendingPathComponent("workout-records.json")
        checkpointURL = directoryURL.appendingPathComponent("active-workout-record.json")
    }

    static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WorkoutRecordPersistenceError.applicationSupportDirectoryUnavailable
        }
        return applicationSupport.appendingPathComponent(
            "MatrixClimbConnector",
            isDirectory: true
        )
    }

    func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func loadCompletedRecords() throws -> [WorkoutRecord] {
        guard fileManager.fileExists(atPath: completedRecordsURL.path) else { return [] }
        let data = try Data(contentsOf: completedRecordsURL)
        return try Self.decoder.decode([WorkoutRecord].self, from: data)
    }

    func loadCheckpoint() throws -> WorkoutRecordCheckpoint? {
        guard fileManager.fileExists(atPath: checkpointURL.path) else { return nil }
        let data = try Data(contentsOf: checkpointURL)
        return try Self.decoder.decode(WorkoutRecordCheckpoint.self, from: data)
    }

    func writeCompletedRecords(_ records: [WorkoutRecord]) throws {
        try prepareDirectory()
        try writer(Self.encoder.encode(records), completedRecordsURL)
    }

    func writeCheckpoint(_ checkpoint: WorkoutRecordCheckpoint) throws {
        try prepareDirectory()
        try writer(Self.encoder.encode(checkpoint), checkpointURL)
    }

    func removeCheckpoint() throws {
        guard fileManager.fileExists(atPath: checkpointURL.path) else { return }
        try fileManager.removeItem(at: checkpointURL)
    }

    func readStorageFile(_ url: URL) throws -> Data {
        try validateStorageFile(url)
        return try Data(contentsOf: url)
    }

    @discardableResult
    func quarantineStorageFile(_ url: URL, at date: Date) throws -> URL {
        try validateStorageFile(url)
        guard fileManager.fileExists(atPath: url.path) else { return url }
        try prepareDirectory()

        let timestamp = Int(date.timeIntervalSince1970 * 1_000)
        var destination = directoryURL.appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(timestamp)"
        )
        if fileManager.fileExists(atPath: destination.path) {
            destination = directoryURL.appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(timestamp)-\(UUID().uuidString)"
            )
        }
        try fileManager.moveItem(at: url, to: destination)
        return destination
    }

    func encodeDiagnosticExport(_ export: WorkoutRecordDiagnosticExport) throws -> Data {
        try Self.encodeDiagnosticExport(export)
    }

    static func encodeDiagnosticExport(_ export: WorkoutRecordDiagnosticExport) throws -> Data {
        try encoder.encode(export)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func validateStorageFile(_ url: URL) throws {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL == completedRecordsURL.standardizedFileURL
                || standardizedURL == checkpointURL.standardizedFileURL
        else {
            throw WorkoutRecordPersistenceError.unexpectedStorageFile
        }
    }
}
