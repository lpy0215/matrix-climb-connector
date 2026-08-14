import SwiftUI

struct WorkoutDashboardView: View {
    @EnvironmentObject private var bluetooth: ClimbMillBluetoothManager
    @EnvironmentObject private var workout: PhoneWorkoutMirrorManager
    @EnvironmentObject private var recordStore: WorkoutRecordStore
    @State private var showStopWaitingConfirmation = false

    private var workoutIsActive: Bool {
        workout.isWorkoutActive
    }

    var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Device", value: bluetooth.selectedDeviceName ?? "Unknown")
                LabeledContent("BLE", value: bluetooth.connectionState.label)
                LabeledContent("Watch workout", value: workout.mirroredSessionState)
            }

            Section("Matrix FTMS") {
                metricGrid
                if let parserError = bluetooth.parserError {
                    Text(parserError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Apple Watch / HealthKit") {
                LabeledContent("Heart rate", value: formattedWatchHeartRate)
                LabeledContent("Active energy", value: formattedWatchEnergy)
            }

            if let error = workout.errorMessage {
                Section("Workout error") {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                if workoutIsActive {
                    if workout.isWaitingForWatch {
                        Button("Cancel workout launch", role: .destructive) {
                            workout.cancelPendingWorkoutLaunch()
                        }
                    } else if workout.canEndWorkout {
                        Button("End and save workout", role: .destructive) {
                            workout.endWorkout()
                        }
                    } else {
                        Button("Stop waiting for Watch", role: .destructive) {
                            showStopWaitingConfirmation = true
                        }
                    }
                } else {
                    Button("Start stair-climbing workout") {
                        guard let id = bluetooth.selectedMachineID,
                              let name = bluetooth.selectedDeviceName else { return }
                        workout.startWorkout(
                            peripheralID: id,
                            deviceName: name,
                            initialMachineMetrics: bluetooth.metrics
                        )
                    }
                    .disabled(
                        recordStore.hasPendingRecord
                            || recordStore.hasCorruptStorage
                            || workout.hasUnresolvedCancelledLaunch
                    )
                }
                Button("Disconnect", role: .destructive) {
                    bluetooth.disconnect()
                }
            }

            if let raw = bluetooth.rawPacketHex {
                Section("Latest raw 0x2ACF") {
                    Text(raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .confirmationDialog(
            "Stop waiting for Apple Watch?",
            isPresented: $showStopWaitingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop waiting and preserve local record", role: .destructive) {
                workout.stopWaitingForWatchReconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only stops waiting on the iPhone. It cannot guarantee that a workout still running on Apple Watch will stop.")
        }
    }

    private var metricGrid: some View {
        let metrics = bluetooth.metrics
        return Grid(horizontalSpacing: 20, verticalSpacing: 16) {
            GridRow {
                MetricCell(title: "Floors", value: metrics?.floors.map { String($0) } ?? "--")
                MetricCell(title: "Steps", value: metrics?.stepCount.map { String($0) } ?? "--")
                MetricCell(title: "SPM", value: metrics?.stepsPerMinute.map { String($0) } ?? "--")
            }
            GridRow {
                MetricCell(title: "Elevation", value: formattedElevation)
                MetricCell(title: "Matrix kcal", value: metrics?.totalEnergyKcal.map { String($0) } ?? "--")
                MetricCell(title: "Elapsed", value: MetricFormatters.duration(metrics?.elapsedTimeSeconds))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedElevation: String {
        guard let value = bluetooth.metrics?.positiveElevationGainMeters else { return "--" }
        return value.formatted(.number.precision(.fractionLength(1))) + " m"
    }

    private var formattedWatchHeartRate: String {
        guard let value = workout.watchSnapshot?.heartRateBPM else { return "--" }
        return value.formatted(.number.precision(.fractionLength(0))) + " bpm"
    }

    private var formattedWatchEnergy: String {
        guard let value = workout.watchSnapshot?.activeEnergyKcal else { return "--" }
        return value.formatted(.number.precision(.fractionLength(1))) + " kcal"
    }

}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
