import Foundation

struct RecordedMachineSample: Codable, Equatable, Sendable {
    var rawPacketHex: String
    var parsedFragment: StepClimberMetrics
    var accumulatedMetrics: StepClimberMetrics
}

struct WorkoutRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var peripheralIdentifier: UUID
    var deviceName: String
    var machineSamples: [RecordedMachineSample]
    var watchSamples: [WatchWorkoutSnapshot]
}
