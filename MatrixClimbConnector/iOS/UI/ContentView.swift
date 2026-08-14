import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var bluetooth: ClimbMillBluetoothManager
    @EnvironmentObject private var workout: PhoneWorkoutMirrorManager
    @EnvironmentObject private var recordStore: WorkoutRecordStore

    @State private var exportDocument: WorkoutRecordExportDocument?
    @State private var isExporting = false
    @State private var showDiscardConfirmation = false
    @State private var showQuarantineConfirmation = false
    @State private var showStopWaitingConfirmation = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if recordStore.recoveredCheckpoint != nil
                    || recordStore.persistenceError != nil
                    || workout.hasUnresolvedCancelledLaunch
                    || exportError != nil {
                    diagnosticsBanner
                }

                Group {
                    if bluetooth.connectionState == .connected {
                        WorkoutDashboardView()
                    } else {
                        DeviceDiscoveryView()
                            .safeAreaInset(edge: .bottom) {
                                if workout.isWorkoutActive {
                                    workoutRecoveryControls
                                }
                            }
                    }
                }
            }
            .navigationTitle("Matrix ClimbMill")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            prepareDiagnosticExport()
                        } label: {
                            Label("Export diagnostics JSON", systemImage: "square.and.arrow.up")
                        }

                        if recordStore.canRetryPersistence {
                            Button {
                                recordStore.retryPersistence()
                            } label: {
                                Label("Retry storage", systemImage: "arrow.clockwise")
                            }
                        }

                        if recordStore.hasCorruptStorage {
                            Button {
                                showQuarantineConfirmation = true
                            } label: {
                                Label("Preserve and reset damaged storage", systemImage: "archivebox")
                            }
                            .disabled(workout.isWorkoutActive)
                        }

                        if recordStore.recoveredCheckpoint != nil {
                            Divider()
                            Button("Discard recovered record", role: .destructive) {
                                showDiscardConfirmation = true
                            }
                            .disabled(discardIsUnavailable)
                        }
                    } label: {
                        Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "matrix-climb-diagnostics"
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case let .failure(error):
                exportError = "Exporting diagnostics failed: \(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "Discard recovered workout record?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(discardButtonTitle, role: .destructive) {
                discardRecoveredRecord()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(discardConfirmationMessage)
        }
        .confirmationDialog(
            "Preserve and reset damaged storage?",
            isPresented: $showQuarantineConfirmation,
            titleVisibility: .visible
        ) {
            Button("Preserve damaged files and reset", role: .destructive) {
                recordStore.quarantineCorruptStorage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Export diagnostics first. The unreadable files are included as Base64 and will also be kept in Application Support with a .corrupt timestamp.")
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
        .task {
            bluetooth.startScanning()
        }
    }

    private var diagnosticsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let checkpoint = recordStore.recoveredCheckpoint {
                Text(recoveredRecordTitle(for: checkpoint.state))
                    .font(.headline)
                Text("Export or discard it before starting another workout.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if workout.hasUnresolvedCancelledLaunch {
                Text(workout.isCancelledLaunchInSafetyWait
                     ? "Waiting 20 seconds for any late Watch session. A new workout remains blocked."
                     : workout.canConfirmCancelledLaunchResolved
                        ? "A cancelled Watch launch is unresolved. Check Apple Watch, then start the safety wait."
                        : "Waiting for the cancelled Watch launch request to finish. A new workout is blocked for now.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if let error = recordStore.persistenceError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let exportError {
                Text(exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Export JSON") {
                    prepareDiagnosticExport()
                }
                if recordStore.canRetryPersistence {
                    Button("Retry") {
                        recordStore.retryPersistence()
                    }
                }
                if recordStore.hasCorruptStorage {
                    Button("Preserve & reset", role: .destructive) {
                        showQuarantineConfirmation = true
                    }
                    .disabled(workout.isWorkoutActive)
                }
                if recordStore.recoveredCheckpoint != nil {
                    Button("Discard", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                    .disabled(discardIsUnavailable)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.12))
    }

    private var workoutRecoveryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workout.isWaitingForWatch
                 ? "Waiting for Apple Watch workout mirroring."
                 : "The Watch workout is active. Reconnect the same ClimbMill to resume Matrix data.")
                .font(.footnote)
            if let expectedDeviceName = recordStore.expectedDeviceName {
                Text("Expected machine: \(expectedDeviceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if workout.isWaitingForWatch || workout.canEndWorkout {
                Button(
                    workout.isWaitingForWatch ? "Cancel workout launch" : "End and save Watch workout",
                    role: .destructive
                ) {
                    if workout.isWaitingForWatch {
                        workout.cancelPendingWorkoutLaunch()
                    } else {
                        workout.endWorkout()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if workout.canStopWaitingForWatchReconnect {
                Button("Stop waiting for Watch", role: .destructive) {
                    showStopWaitingConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial)
    }

    private func prepareDiagnosticExport() {
        var context = [
            "bluetoothState": bluetooth.connectionState.label,
            "watchWorkoutState": workout.mirroredSessionState,
        ]
        if let selectedMachineID = bluetooth.selectedMachineID {
            context["peripheralIdentifier"] = selectedMachineID.uuidString
        }
        if let selectedDeviceName = bluetooth.selectedDeviceName {
            context["deviceName"] = selectedDeviceName
        }
        if let parserError = bluetooth.parserError {
            context["parserError"] = parserError
        }
        if let workoutError = workout.errorMessage {
            context["workoutError"] = workoutError
        }
        if let rawPacketHex = bluetooth.rawPacketHex {
            context["latestRawPacketHex"] = rawPacketHex
        }

        guard let data = recordStore.diagnosticExportData(context: context) else { return }
        exportDocument = WorkoutRecordExportDocument(data: data)
        exportError = nil
        isExporting = true
    }

    private var discardIsUnavailable: Bool {
        workout.isWorkoutActive
            || (workout.hasUnresolvedCancelledLaunch
                && !workout.canConfirmCancelledLaunchResolved)
    }

    private var discardButtonTitle: String {
        workout.hasUnresolvedCancelledLaunch
            ? "I checked Watch - start 20-second safety wait"
            : "Discard record"
    }

    private var discardConfirmationMessage: String {
        if workout.hasUnresolvedCancelledLaunch {
            return "Only continue after confirming on Apple Watch that no workout from the cancelled launch is running. After the safety wait finishes, confirm discard again."
        }
        return "Confirm that no related workout is still running on Apple Watch. Export first if you want to keep the local samples."
    }

    private func discardRecoveredRecord() {
        guard !discardIsUnavailable else { return }
        if workout.hasUnresolvedCancelledLaunch {
            workout.beginCancelledLaunchSafetyWait()
            return
        }
        recordStore.discardRecoveredRecord()
    }

    private func recoveredRecordTitle(for state: WorkoutRecordCheckpointState) -> String {
        switch state {
        case .active:
            "Recovered an in-progress local workout record."
        case .interrupted:
            "Recovered an interrupted local workout record."
        case .cancelledLaunchPending:
            "Recovered a record from a cancelled Watch launch."
        case .pendingCompletion:
            "A completed local workout record is waiting to be saved."
        }
    }
}

private struct WorkoutRecordExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
