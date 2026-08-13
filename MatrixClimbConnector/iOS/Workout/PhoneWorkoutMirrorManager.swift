import Combine
import Foundation
import HealthKit

@MainActor
final class PhoneWorkoutMirrorManager: NSObject, ObservableObject {
    @Published private(set) var mirroredSessionState = "Not started"
    @Published private(set) var watchSnapshot: WatchWorkoutSnapshot?
    @Published private(set) var errorMessage: String?

    let recordStore: WorkoutRecordStore

    private let healthStore = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?
    private var latestMachineMetrics: StepClimberMetrics?
    private var launchTimeoutTask: Task<Void, Never>?

    var isWorkoutActive: Bool {
        mirroredSession != nil || mirroredSessionState == "Launching Apple Watch"
    }

    override init() {
        recordStore = WorkoutRecordStore()
        super.init()

        // Apple can launch the iOS app in the background for this callback, so
        // register it immediately instead of waiting for a SwiftUI view.
        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            Task { @MainActor in
                self?.acceptMirroredSession(session)
            }
        }
    }

    func startWorkout(
        peripheralID: UUID,
        deviceName: String,
        initialMachineMetrics: StepClimberMetrics?
    ) {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "HealthKit is unavailable on this iPhone."
            return
        }

        recordStore.begin(peripheralID: peripheralID, deviceName: deviceName)
        latestMachineMetrics = initialMachineMetrics
        watchSnapshot = nil
        errorMessage = nil
        mirroredSessionState = "Launching Apple Watch"
        launchTimeoutTask?.cancel()
        launchTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.mirroredSession == nil,
                  self.mirroredSessionState == "Launching Apple Watch" else { return }
            self.errorMessage = "Timed out waiting for Apple Watch workout mirroring."
            self.mirroredSessionState = "Launch timed out"
            self.recordStore.discardActiveRecord()
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .stairClimbing
        configuration.locationType = .indoor

        healthStore.startWatchApp(with: configuration) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.launchTimeoutTask?.cancel()
                    self.errorMessage = error.localizedDescription
                    self.mirroredSessionState = "Launch failed"
                    self.recordStore.discardActiveRecord()
                } else if !success {
                    self.launchTimeoutTask?.cancel()
                    self.errorMessage = "Apple Watch did not start the workout app."
                    self.mirroredSessionState = "Launch failed"
                    self.recordStore.discardActiveRecord()
                }
            }
        }
    }

    func receiveMachineMetrics(
        parsedFragment: StepClimberMetrics,
        accumulatedMetrics: StepClimberMetrics,
        rawPacketHex: String
    ) {
        latestMachineMetrics = accumulatedMetrics
        recordStore.append(machine: RecordedMachineSample(
            rawPacketHex: rawPacketHex,
            parsedFragment: parsedFragment,
            accumulatedMetrics: accumulatedMetrics
        ))
        send(.machineMetrics(accumulatedMetrics))
    }

    func endWorkout() {
        guard let mirroredSession else {
            errorMessage = "No mirrored Apple Watch workout is active."
            return
        }
        // Stopping the mirrored session is propagated by HealthKit to the
        // primary Watch session. No custom transport command is needed.
        mirroredSession.stopActivity(with: .now)
        mirroredSessionState = "Ending"
    }

    private func acceptMirroredSession(_ session: HKWorkoutSession) {
        // Reconnection provides a new mirrored HKWorkoutSession instance.
        launchTimeoutTask?.cancel()
        mirroredSession = session
        session.delegate = self
        mirroredSessionState = "Mirrored"
        errorMessage = nil

        if let latestMachineMetrics {
            send(.machineMetrics(latestMachineMetrics))
        }
    }

    private func send(_ message: WorkoutMessage) {
        guard let mirroredSession else { return }
        do {
            let data = try WorkoutMessageCodec.encode(message)
            mirroredSession.sendToRemoteWorkoutSession(data: data) { [weak self] success, error in
                guard !success || error != nil else { return }
                Task { @MainActor in
                    self?.errorMessage = error?.localizedDescription ?? "Workout data was not delivered."
                }
            }
        } catch {
            errorMessage = "Workout message encoding failed: \(error.localizedDescription)"
        }
    }
}

extension PhoneWorkoutMirrorManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.mirroredSessionState = Self.label(for: toState)
            if toState == .ended {
                self.launchTimeoutTask?.cancel()
                self.recordStore.finish(at: date)
                self.mirroredSession = nil
                self.latestMachineMetrics = nil
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.launchTimeoutTask?.cancel()
            self.errorMessage = error.localizedDescription
            self.mirroredSessionState = "Failed"
            self.recordStore.finish()
            self.mirroredSession = nil
            self.latestMachineMetrics = nil
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        for item in data {
            do {
                guard case let .watchSnapshot(snapshot) = try WorkoutMessageCodec.decode(item) else {
                    continue
                }
                Task { @MainActor in
                    self.watchSnapshot = snapshot
                    self.recordStore.append(watch: snapshot)
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = "Watch message decoding failed: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        Task { @MainActor in
            self.mirroredSessionState = "Watch reconnecting"
            if let error { self.errorMessage = error.localizedDescription }
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
