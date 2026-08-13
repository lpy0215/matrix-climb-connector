import Combine
import Foundation
import HealthKit

@MainActor
final class WatchWorkoutManager: NSObject, ObservableObject {
    static let shared = WatchWorkoutManager()

    @Published private(set) var state = "Not started"
    @Published private(set) var heartRateBPM: Double?
    @Published private(set) var activeEnergyKcal: Double?
    @Published private(set) var machineMetrics: StepClimberMetrics?
    @Published private(set) var errorMessage: String?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isFinishing = false
    private var isStarting = false
    private var preparationContinuation: CheckedContinuation<Void, Error>?

    private override init() {
        super.init()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit is unavailable."
            return false
        }

        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.flightsClimbed)
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned)
        ]

        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
            return true
        } catch {
            errorMessage = "HealthKit authorization failed: \(error.localizedDescription)"
            return false
        }
    }

    func start(configuration incoming: HKWorkoutConfiguration? = nil) async {
        guard session == nil else { return }
        guard await requestAuthorization() else {
            state = "Authorization failed"
            return
        }

        let configuration = incoming ?? Self.stairClimbingConfiguration()
        configuration.activityType = .stairClimbing
        configuration.locationType = .indoor
        isStarting = true

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )

            // Flights are supplied by FTMS. Disabling automatic Watch flight
            // collection avoids creating a second, wrist-derived value.
            source.disableCollection(for: HKQuantityType(.flightsClimbed))
            builder.dataSource = source
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            isFinishing = false
            heartRateBPM = nil
            activeEnergyKcal = nil
            machineMetrics = nil
            errorMessage = nil

            // Preparing first makes mirroring reliable on recent iOS/watchOS
            // releases while preserving Apple's primary/mirrored session model.
            try await prepare(session)
            try await session.startMirroringToCompanionDevice()

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            isStarting = false
            state = "Running"
            sendSnapshot()
        } catch {
            isStarting = false
            errorMessage = "Workout start failed: \(error.localizedDescription)"
            state = "Failed"
            preparationContinuation?.resume(throwing: error)
            preparationContinuation = nil
            session?.end()
            cleanup()
        }
    }

    func end() {
        guard let session, !isFinishing else { return }
        isFinishing = true
        state = "Ending"
        sendSnapshot()
        session.stopActivity(with: .now)
    }

    func recoverActiveWorkout() {
        healthStore.recoverActiveWorkoutSession { [weak self] recoveredSession, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = "Workout recovery failed: \(error.localizedDescription)"
                    return
                }
                guard let recoveredSession else { return }

                let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
                let configuration = recoveredSession.workoutConfiguration
                let source = HKLiveWorkoutDataSource(
                    healthStore: self.healthStore,
                    workoutConfiguration: configuration
                )
                source.disableCollection(for: HKQuantityType(.flightsClimbed))
                recoveredBuilder.dataSource = source
                recoveredSession.delegate = self
                recoveredBuilder.delegate = self
                self.session = recoveredSession
                self.builder = recoveredBuilder
                self.state = Self.label(for: recoveredSession.state)

                do {
                    try await recoveredSession.startMirroringToCompanionDevice()
                } catch {
                    self.errorMessage = "Workout mirroring recovery failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func stairClimbingConfiguration() -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .stairClimbing
        configuration.locationType = .indoor
        return configuration
    }

    private func prepare(_ session: HKWorkoutSession) async throws {
        if session.state == .prepared || session.state == .running { return }
        try await withCheckedThrowingContinuation { continuation in
            preparationContinuation = continuation
            session.prepare()
        }
    }

    private func finishPreparationIfNeeded(for state: HKWorkoutSessionState) {
        guard state == .prepared || state == .running,
              let continuation = preparationContinuation else { return }
        preparationContinuation = nil
        continuation.resume()
    }

    private func addFinalMachineData(
        to builder: HKLiveWorkoutBuilder,
        end: Date
    ) async -> [String] {
        guard let metrics = machineMetrics, let start = builder.startDate else { return [] }
        var warnings: [String] = []

        if let elevation = metrics.positiveElevationGainMeters {
            do {
                try await builder.addMetadata([
                    HKMetadataKeyElevationAscended: HKQuantity(
                        unit: .meter(),
                        doubleValue: elevation
                    )
                ])
            } catch {
                warnings.append("elevation: \(error.localizedDescription)")
            }
        }

        if let floors = metrics.floors {
            let flightsType = HKQuantityType(.flightsClimbed)
            let sample = HKQuantitySample(
                type: flightsType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(floors)),
                start: start,
                end: end
            )
            do {
                try await builder.add([sample])
            } catch {
                warnings.append("flights climbed: \(error.localizedDescription)")
            }
        }
        return warnings
    }

    private func finishWorkout(at end: Date) async {
        guard let builder else { return }
        // A denied optional quantity type must not prevent the single workout
        // itself from being finalized and saved.
        let machineDataWarnings = await addFinalMachineData(to: builder, end: end)
        do {
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            state = "Saved"
            if !machineDataWarnings.isEmpty {
                errorMessage = "Workout saved, but some Matrix fields were not added: " +
                    machineDataWarnings.joined(separator: "; ")
            }
        } catch {
            errorMessage = "Workout save failed: \(error.localizedDescription)"
            state = "Save failed"
        }
        sendSnapshot()
        session?.end()
    }

    private func updateStatistics(_ statistics: HKStatistics?) {
        guard let statistics else { return }
        switch statistics.quantityType {
        case HKQuantityType(.heartRate):
            let unit = HKUnit.count().unitDivided(by: .minute())
            heartRateBPM = statistics.mostRecentQuantity()?.doubleValue(for: unit)
        case HKQuantityType(.activeEnergyBurned):
            activeEnergyKcal = statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
        default:
            return
        }
    }

    private func sendSnapshot() {
        guard let session else { return }
        let snapshot = WatchWorkoutSnapshot(
            heartRateBPM: heartRateBPM,
            activeEnergyKcal: activeEnergyKcal,
            state: state,
            updatedAt: .now
        )
        do {
            let data = try WorkoutMessageCodec.encode(.watchSnapshot(snapshot))
            session.sendToRemoteWorkoutSession(data: data) { _, _ in }
        } catch {
            errorMessage = "Workout message encoding failed: \(error.localizedDescription)"
        }
    }

    private func cleanup() {
        if let continuation = preparationContinuation {
            preparationContinuation = nil
            continuation.resume(throwing: WorkoutPreparationError.interrupted)
        }
        session = nil
        builder = nil
        isFinishing = false
        isStarting = false
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.finishPreparationIfNeeded(for: toState)
            self.state = Self.label(for: toState)
            self.sendSnapshot()
            if toState == .stopped {
                self.isFinishing = true
                await self.finishWorkout(at: date)
            } else if toState == .ended {
                self.cleanup()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            let startHandlesFailure = self.isStarting
            if let continuation = self.preparationContinuation {
                self.preparationContinuation = nil
                continuation.resume(throwing: error)
            }
            self.errorMessage = error.localizedDescription
            self.state = "Failed"
            self.sendSnapshot()

            if startHandlesFailure { return }

            switch workoutSession.state {
            case .running, .paused:
                self.isFinishing = true
                workoutSession.stopActivity(with: .now)
            case .notStarted, .prepared:
                workoutSession.end()
            case .stopped, .ended:
                break
            @unknown default:
                workoutSession.end()
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        for item in data {
            do {
                let message = try WorkoutMessageCodec.decode(item)
                Task { @MainActor in
                    switch message {
                    case let .machineMetrics(metrics):
                        self.machineMetrics = metrics
                    case .watchSnapshot:
                        break
                    }
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = "iPhone message decoding failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func label(for state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: "Not started"
        case .running: "Running"
        case .ended: "Ended"
        case .paused: "Paused"
        case .prepared: "Prepared"
        case .stopped: "Stopped"
        @unknown default: "Unknown"
        }
    }
}

private enum WorkoutPreparationError: LocalizedError {
    case interrupted

    var errorDescription: String? {
        "Workout preparation was interrupted."
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor in
            for type in collectedTypes {
                guard let quantityType = type as? HKQuantityType else { continue }
                self.updateStatistics(workoutBuilder.statistics(for: quantityType))
            }
            self.sendSnapshot()
        }
    }
}
