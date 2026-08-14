import Foundation

/// Fields parsed from an FTMS Step Climber Data (0x2ACF) notification or an
/// assembled data record.
///
/// SPM and Matrix energy remain machine-provided diagnostic values. HealthKit
/// active energy comes from Apple Watch and is never replaced by these values.
struct StepClimberMetrics: Codable, Equatable, Sendable {
    var flags: UInt16
    var receivedAt: Date
    var floors: UInt16?
    var stepCount: UInt16?
    var stepsPerMinute: UInt16?
    var averageStepRate: UInt16?
    var positiveElevationGainMeters: Double?
    var totalEnergyKcal: UInt16?
    var energyPerHourKcal: UInt16?
    var energyPerMinuteKcal: UInt8?
    var heartRateBPM: UInt8?
    var metabolicEquivalent: Double?
    var elapsedTimeSeconds: UInt16?
    var remainingTimeSeconds: UInt16?

    init(
        flags: UInt16,
        receivedAt: Date = .now,
        floors: UInt16? = nil,
        stepCount: UInt16? = nil,
        stepsPerMinute: UInt16? = nil,
        averageStepRate: UInt16? = nil,
        positiveElevationGainMeters: Double? = nil,
        totalEnergyKcal: UInt16? = nil,
        energyPerHourKcal: UInt16? = nil,
        energyPerMinuteKcal: UInt8? = nil,
        heartRateBPM: UInt8? = nil,
        metabolicEquivalent: Double? = nil,
        elapsedTimeSeconds: UInt16? = nil,
        remainingTimeSeconds: UInt16? = nil
    ) {
        self.flags = flags
        self.receivedAt = receivedAt
        self.floors = floors
        self.stepCount = stepCount
        self.stepsPerMinute = stepsPerMinute
        self.averageStepRate = averageStepRate
        self.positiveElevationGainMeters = positiveElevationGainMeters
        self.totalEnergyKcal = totalEnergyKcal
        self.energyPerHourKcal = energyPerHourKcal
        self.energyPerMinuteKcal = energyPerMinuteKcal
        self.heartRateBPM = heartRateBPM
        self.metabolicEquivalent = metabolicEquivalent
        self.elapsedTimeSeconds = elapsedTimeSeconds
        self.remainingTimeSeconds = remainingTimeSeconds
    }

    /// Applies a later fragment over earlier fields from the same FTMS data
    /// record. Callers must not merge across record or connection boundaries.
    func merging(over previous: StepClimberMetrics?) -> StepClimberMetrics {
        guard let previous else { return self }
        return StepClimberMetrics(
            flags: flags,
            receivedAt: receivedAt,
            floors: floors ?? previous.floors,
            stepCount: stepCount ?? previous.stepCount,
            stepsPerMinute: stepsPerMinute ?? previous.stepsPerMinute,
            averageStepRate: averageStepRate ?? previous.averageStepRate,
            positiveElevationGainMeters: positiveElevationGainMeters ?? previous.positiveElevationGainMeters,
            totalEnergyKcal: totalEnergyKcal ?? previous.totalEnergyKcal,
            energyPerHourKcal: energyPerHourKcal ?? previous.energyPerHourKcal,
            energyPerMinuteKcal: energyPerMinuteKcal ?? previous.energyPerMinuteKcal,
            heartRateBPM: heartRateBPM ?? previous.heartRateBPM,
            metabolicEquivalent: metabolicEquivalent ?? previous.metabolicEquivalent,
            elapsedTimeSeconds: elapsedTimeSeconds ?? previous.elapsedTimeSeconds,
            remainingTimeSeconds: remainingTimeSeconds ?? previous.remainingTimeSeconds
        )
    }
}
