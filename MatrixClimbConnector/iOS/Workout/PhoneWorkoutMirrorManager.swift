import Combine
import Foundation
import HealthKit

@MainActor
final class PhoneWorkoutMirrorManager: NSObject, ObservableObject {
    private enum CancelledLaunchState: Equatable {
        case none
        case waitingForCompletion
        case confirmOnWatch
        case quarantine
    }

    @Published private(set) var mirroredSessionState = "Not started"
    @Published private(set) var watchSnapshot: WatchWorkoutSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private var cancelledLaunchState = CancelledLaunchState.none

    let recordStore: WorkoutRecordStore

    private let healthStore = HKHealthStore()
    private var mirroredSession: HKWorkoutSession?
    private var latestMachineMetrics: StepClimberMetrics?
    private var launchTimeoutTask: Task<Void, Never>?
    private var launchAttemptID: UUID?
    private var cancelledLaunchAttemptID: UUID?
    private var cancelledLaunchTask: Task<Void, Never>?
    private var launchRequestSucceeded = false
    private var localRecordIsAttached = false
    private var needsFreshMachineMetrics = false

    var isWorkoutActive: Bool {
        mirroredSession != nil || recordStore.activeRecord != nil
    }

    var isWaitingForWatch: Bool {
        mirroredSession == nil
            && recordStore.activeRecord != nil
            && (mirroredSessionState == "Launching Apple Watch"
                || mirroredSessionState == "Watch launch delayed")
    }

    var canEndWorkout: Bool {
        mirroredSession != nil
    }

    var canStopWaitingForWatchReconnect: Bool {
        mirroredSession == nil
            && recordStore.activeRecord != nil
            && !isWaitingForWatch
    }

    var hasUnresolvedCancelledLaunch: Bool {
        cancelledLaunchState != .none
    }

    var canConfirmCancelledLaunchResolved: Bool {
        cancelledLaunchState == .confirmOnWatch
    }

    var isCancelledLaunchInSafetyWait: Bool {
        cancelledLaunchState == .quarantine
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

        if let checkpoint = recordStore.recoveredCheckpoint,
           checkpoint.state == .cancelledLaunchPending {
            cancelledLaunchAttemptID = checkpoint.record.id
            cancelledLaunchState = .confirmOnWatch
            mirroredSessionState = "Cancelled launch needs Watch check"
            errorMessage = "Check Apple Watch before resolving this cancelled launch."
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
        guard mirroredSession == nil else {
            errorMessage = "An Apple Watch workout session is already active."
            return
        }

        guard !hasUnresolvedCancelledLaunch else {
            errorMessage = "Resolve the cancelled Apple Watch launch before starting another workout."
            return
        }
        guard recordStore.begin(peripheralID: peripheralID, deviceName: deviceName) else {
            errorMessage = recordStore.persistenceError ?? "Unable to start the local workout record."
            return
        }
        guard let attemptID = recordStore.activeRecord?.id else {
            recordStore.interruptActiveRecord()
            errorMessage = "Unable to identify the local workout launch."
            return
        }
        launchAttemptID = attemptID
        launchRequestSucceeded = false
        latestMachineMetrics = initialMachineMetrics
        localRecordIsAttached = false
        needsFreshMachineMetrics = false
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
                  self.launchAttemptID == attemptID,
                  !self.localRecordIsAttached else { return }
            self.errorMessage = "Timed out waiting for Apple Watch workout mirroring."
            self.mirroredSessionState = "Watch launch delayed"
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .stairClimbing
        configuration.locationType = .indoor

        healthStore.startWatchApp(with: configuration) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if self.cancelledLaunchAttemptID == attemptID {
                    self.handleCancelledLaunchCompletion(success: success, error: error)
                    return
                }
                guard self.launchAttemptID == attemptID,
                      !self.localRecordIsAttached else { return }
                if let error {
                    self.launchTimeoutTask?.cancel()
                    self.launchAttemptID = nil
                    self.launchRequestSucceeded = false
                    self.errorMessage = error.localizedDescription
                    self.mirroredSessionState = "Launch failed"
                    self.recordStore.interruptActiveRecord()
                    self.localRecordIsAttached = false
                } else if !success {
                    self.launchTimeoutTask?.cancel()
                    self.launchAttemptID = nil
                    self.launchRequestSucceeded = false
                    self.errorMessage = "Apple Watch did not start the workout app."
                    self.mirroredSessionState = "Launch failed"
                    self.recordStore.interruptActiveRecord()
                    self.localRecordIsAttached = false
                } else {
                    self.launchRequestSucceeded = true
                }
            }
        }
    }

    func receiveMachineNotification(
        _ output: FTMSStepClimberRecordAssembler.Output,
        peripheralID: UUID,
        rawPacketHex: String
    ) {
        if let expectedPeripheralID = recordStore.expectedPeripheralIdentifier,
           expectedPeripheralID != peripheralID {
            errorMessage = "Reconnect the original ClimbMill before resuming Matrix workout data."
            return
        }
        if mirroredSession != nil,
           !localRecordIsAttached,
           recordStore.activeRecord == nil {
            errorMessage = "The Watch workout is active, but its local record could not be recovered."
            return
        }
        if recordStore.recoveredCheckpoint != nil && recordStore.activeRecord == nil {
            return
        }

        recordStore.append(machine: RecordedMachineSample(
            rawPacketHex: rawPacketHex,
            parsedFragment: output.fragment,
            accumulatedMetrics: output.accumulatedMetrics
        ))
        guard let completedRecord = output.completedRecord else { return }
        let wasWaitingForFreshMetrics = needsFreshMachineMetrics
        latestMachineMetrics = completedRecord
        needsFreshMachineMetrics = false
        if wasWaitingForFreshMetrics {
            errorMessage = nil
            if let mirroredSession {
                mirroredSessionState = Self.label(for: mirroredSession.state)
            }
        }
        if localRecordIsAttached {
            send(.machineMetrics(completedRecord))
        }
    }

    func cancelPendingWorkoutLaunch() {
        guard mirroredSession == nil,
              recordStore.activeRecord != nil,
              let attemptID = launchAttemptID else { return }
        launchTimeoutTask?.cancel()
        cancelledLaunchAttemptID = attemptID
        cancelledLaunchState = launchRequestSucceeded
            ? .confirmOnWatch
            : .waitingForCompletion
        launchAttemptID = nil
        launchRequestSucceeded = false
        recordStore.interruptActiveRecord(state: .cancelledLaunchPending)
        localRecordIsAttached = false
        needsFreshMachineMetrics = false
        latestMachineMetrics = nil
        mirroredSessionState = "Launch cancelled"
        errorMessage = canConfirmCancelledLaunchResolved
            ? "Confirm on Apple Watch that no workout is running before starting again."
            : "Waiting for the cancelled Watch launch request to settle."
        if cancelledLaunchState == .waitingForCompletion {
            scheduleCancelledLaunchSettleTimeout(for: attemptID)
        }
    }

    func beginCancelledLaunchSafetyWait() {
        guard canConfirmCancelledLaunchResolved,
              mirroredSession == nil,
              let attemptID = cancelledLaunchAttemptID else { return }
        cancelledLaunchTask?.cancel()
        cancelledLaunchState = .quarantine
        mirroredSessionState = "Cancelled launch safety wait"
        errorMessage = "Waiting 20 seconds for any late Watch session before allowing a new workout."
        cancelledLaunchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.cancelledLaunchAttemptID == attemptID,
                  self.cancelledLaunchState == .quarantine,
                  self.mirroredSession == nil else { return }
            self.cancelledLaunchTask = nil
            self.cancelledLaunchAttemptID = nil
            self.cancelledLaunchState = .none
            self.launchRequestSucceeded = false
            self.mirroredSessionState = "Cancelled launch safety wait complete"
            self.errorMessage = nil
        }
    }

    func stopWaitingForWatchReconnect() {
        guard canStopWaitingForWatchReconnect else { return }
        launchTimeoutTask?.cancel()
        launchAttemptID = nil
        launchRequestSucceeded = false
        recordStore.interruptActiveRecord()
        localRecordIsAttached = false
        needsFreshMachineMetrics = false
        latestMachineMetrics = nil
        mirroredSessionState = "Stopped waiting for Watch"
        errorMessage = "Stopped waiting locally. The workout may still be running on Apple Watch."
    }

    private func handleCancelledLaunchCompletion(success: Bool, error: Error?) {
        guard cancelledLaunchAttemptID != nil else { return }
        cancelledLaunchTask?.cancel()
        cancelledLaunchTask = nil
        if mirroredSession != nil {
            cancelledLaunchState = .confirmOnWatch
            mirroredSessionState = "Cancelled launch reached Watch"
            errorMessage = "End this Watch workout before starting another one."
            return
        }
        if error != nil || !success {
            clearCancelledLaunch()
            errorMessage = nil
            return
        }

        cancelledLaunchState = .confirmOnWatch
        mirroredSessionState = "Cancelled launch may reach Watch"
        errorMessage = "Check Apple Watch and end any workout from this cancelled launch before starting again."
    }

    private func scheduleCancelledLaunchSettleTimeout(for attemptID: UUID) {
        cancelledLaunchTask?.cancel()
        cancelledLaunchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.cancelledLaunchAttemptID == attemptID,
                  self.cancelledLaunchState == .waitingForCompletion else { return }
            self.cancelledLaunchTask = nil
            self.cancelledLaunchState = .confirmOnWatch
            self.mirroredSessionState = "Cancelled launch did not settle"
            self.errorMessage = "The Watch launch callback did not return. Check Apple Watch before starting the safety wait."
        }
    }

    private func clearCancelledLaunch() {
        cancelledLaunchTask?.cancel()
        cancelledLaunchTask = nil
        cancelledLaunchAttemptID = nil
        cancelledLaunchState = .none
        launchRequestSucceeded = false
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
        mirroredSession = session
        session.delegate = self

        if hasUnresolvedCancelledLaunch {
            launchTimeoutTask?.cancel()
            cancelledLaunchTask?.cancel()
            cancelledLaunchTask = nil
            cancelledLaunchState = .confirmOnWatch
            localRecordIsAttached = false
            mirroredSessionState = "Cancelled launch reached Watch"
            errorMessage = "End this Watch workout before starting another one."
            return
        }

        if let startDate = session.startDate {
            applyRecordAttachment(recordStore.attachMirroredSession(
                startedAt: startDate,
                currentLaunchRecordID: launchAttemptID
            ))
        } else {
            localRecordIsAttached = false
            mirroredSessionState = "Waiting for recovery"
            errorMessage = "Waiting for the mirrored Watch session start date to recover its local record."
        }

        if localRecordIsAttached,
           !needsFreshMachineMetrics,
           let latestMachineMetrics {
            send(.machineMetrics(latestMachineMetrics))
        }
    }

    private func applyRecordAttachment(_ attachment: MirroredWorkoutRecordAttachment) {
        switch attachment {
        case .current:
            launchTimeoutTask?.cancel()
            localRecordIsAttached = true
            launchAttemptID = nil
            launchRequestSucceeded = false
            mirroredSessionState = "Mirrored"
            if !needsFreshMachineMetrics {
                errorMessage = nil
            }
        case .recovered:
            launchTimeoutTask?.cancel()
            localRecordIsAttached = true
            launchAttemptID = nil
            launchRequestSucceeded = false
            needsFreshMachineMetrics = true
            latestMachineMetrics = nil
            mirroredSessionState = "Mirrored; reconnect ClimbMill"
            errorMessage = "Reconnect the same ClimbMill. A fresh complete FTMS record is required before Matrix data returns to the Watch."
        case .unavailable:
            localRecordIsAttached = false
            mirroredSessionState = "Recovery conflict"
            errorMessage = "The mirrored Watch workout does not match the pending local workout record. Export diagnostics before discarding anything."
        }
    }

    private func send(_ message: WorkoutMessage) {
        guard let mirroredSession else { return }
        do {
            let data = try WorkoutMessageCodec.encode(message)
            mirroredSession.sendToRemoteWorkoutSession(data: data) { [weak self] success, error in
                guard !success || error != nil else { return }
                Task { @MainActor in
                    guard let self, self.mirroredSession === mirroredSession else { return }
                    self.errorMessage = error?.localizedDescription ?? "Workout data was not delivered."
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
            guard self.mirroredSession === workoutSession else { return }

            if !self.hasUnresolvedCancelledLaunch,
               (toState == .running || toState == .paused),
               let startDate = workoutSession.startDate {
                self.applyRecordAttachment(
                    self.recordStore.attachMirroredSession(
                        startedAt: startDate,
                        currentLaunchRecordID: self.launchAttemptID
                    )
                )
            }

            if self.localRecordIsAttached {
                self.mirroredSessionState = Self.label(for: toState)
            }
            if toState == .ended {
                if self.hasUnresolvedCancelledLaunch {
                    self.clearCancelledLaunch()
                    self.mirroredSession = nil
                    self.latestMachineMetrics = nil
                    self.localRecordIsAttached = false
                    self.needsFreshMachineMetrics = false
                    self.mirroredSessionState = "Cancelled launch ended"
                    self.errorMessage = nil
                    return
                }
                if self.localRecordIsAttached {
                    self.launchTimeoutTask?.cancel()
                    self.launchAttemptID = nil
                    self.recordStore.finish(at: date)
                    self.latestMachineMetrics = nil
                    self.needsFreshMachineMetrics = false
                } else if self.launchAttemptID != nil {
                    self.mirroredSessionState = "Launching Apple Watch"
                } else {
                    self.mirroredSessionState = "Recovery conflict ended"
                }
                self.mirroredSession = nil
                self.localRecordIsAttached = false
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.mirroredSession === workoutSession else { return }
            if self.hasUnresolvedCancelledLaunch {
                self.clearCancelledLaunch()
                self.mirroredSession = nil
                self.latestMachineMetrics = nil
                self.localRecordIsAttached = false
                self.needsFreshMachineMetrics = false
                self.mirroredSessionState = "Cancelled launch failed"
                self.errorMessage = error.localizedDescription
                return
            }
            self.errorMessage = error.localizedDescription
            if self.localRecordIsAttached {
                self.launchTimeoutTask?.cancel()
                self.launchAttemptID = nil
                self.mirroredSessionState = "Failed"
                self.recordStore.interruptActiveRecord()
                self.latestMachineMetrics = nil
                self.needsFreshMachineMetrics = false
            } else if self.launchAttemptID != nil {
                self.mirroredSessionState = "Launching Apple Watch"
            } else {
                self.mirroredSessionState = "Recovery conflict failed"
            }
            self.mirroredSession = nil
            self.localRecordIsAttached = false
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in
            guard self.mirroredSession === workoutSession,
                  self.localRecordIsAttached else { return }
            for item in data {
                do {
                    guard case let .watchSnapshot(snapshot) = try WorkoutMessageCodec.decode(item) else {
                        continue
                    }
                    self.watchSnapshot = snapshot
                    self.recordStore.append(watch: snapshot)
                } catch {
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
            guard self.mirroredSession === workoutSession else { return }
            self.mirroredSession = nil
            if self.hasUnresolvedCancelledLaunch {
                self.cancelledLaunchState = .confirmOnWatch
                self.localRecordIsAttached = false
                self.mirroredSessionState = "Cancelled Watch launch disconnected"
                if let error { self.errorMessage = error.localizedDescription }
                return
            }
            self.mirroredSessionState = self.launchAttemptID != nil && !self.localRecordIsAttached
                ? "Launching Apple Watch"
                : "Watch reconnecting"
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
