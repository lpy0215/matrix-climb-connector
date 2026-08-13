import Combine
import Foundation

@MainActor
final class WorkoutRecordStore: ObservableObject {
    @Published private(set) var records: [WorkoutRecord] = []

    private var activeRecord: WorkoutRecord?
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let directory = applicationSupport.appendingPathComponent(
            "MatrixClimbConnector",
            isDirectory: true
        )
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("workout-records.json")
        load()
    }

    func begin(peripheralID: UUID, deviceName: String, at date: Date = .now) {
        activeRecord = WorkoutRecord(
            id: UUID(),
            startedAt: date,
            endedAt: date,
            peripheralIdentifier: peripheralID,
            deviceName: deviceName,
            machineSamples: [],
            watchSamples: []
        )
    }

    func append(machine sample: RecordedMachineSample) {
        activeRecord?.machineSamples.append(sample)
    }

    func append(watch snapshot: WatchWorkoutSnapshot) {
        activeRecord?.watchSamples.append(snapshot)
    }

    func finish(at date: Date = .now) {
        guard var record = activeRecord else { return }
        record.endedAt = date
        records.insert(record, at: 0)
        activeRecord = nil
        persist()
    }

    func discardActiveRecord() {
        activeRecord = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.recordDecoder.decode([WorkoutRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.recordEncoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var recordEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var recordDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
