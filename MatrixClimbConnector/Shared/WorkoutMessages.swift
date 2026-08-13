import Foundation

struct WatchWorkoutSnapshot: Codable, Equatable, Sendable {
    var heartRateBPM: Double?
    var activeEnergyKcal: Double?
    var state: String
    var updatedAt: Date
}

enum WorkoutMessage: Codable, Equatable, Sendable {
    case machineMetrics(StepClimberMetrics)
    case watchSnapshot(WatchWorkoutSnapshot)
}

enum WorkoutMessageCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func encode(_ message: WorkoutMessage) throws -> Data {
        try encoder.encode(message)
    }

    static func decode(_ data: Data) throws -> WorkoutMessage {
        try decoder.decode(WorkoutMessage.self, from: data)
    }
}
