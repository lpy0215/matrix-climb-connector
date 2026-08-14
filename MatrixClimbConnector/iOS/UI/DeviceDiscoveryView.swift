import SwiftUI

struct DeviceDiscoveryView: View {
    @EnvironmentObject private var bluetooth: ClimbMillBluetoothManager
    @EnvironmentObject private var workout: PhoneWorkoutMirrorManager
    @EnvironmentObject private var recordStore: WorkoutRecordStore

    var body: some View {
        List {
            Section {
                HStack {
                    Text(bluetooth.connectionState.label)
                    Spacer()
                    if bluetooth.connectionState == .scanning {
                        ProgressView()
                    }
                }

                Button(bluetooth.connectionState == .scanning ? "Stop scan" : "Scan again") {
                    if bluetooth.connectionState == .scanning {
                        bluetooth.stopScanning()
                    } else {
                        bluetooth.startScanning()
                    }
                }
            }

            Section("Nearby candidates") {
                if bluetooth.machines.isEmpty {
                    ContentUnavailableView(
                        "No fitness machines found",
                        systemImage: "figure.stair.stepper",
                        description: Text("Keep this screen open near the ClimbMill.")
                    )
                }

                ForEach(bluetooth.machines) { machine in
                    Button {
                        bluetooth.connect(to: machine)
                    } label: {
                        MachineRow(machine: machine)
                    }
                    .buttonStyle(.plain)
                    .disabled(connectionIsBusy || isWrongRecoveryMachine(machine))
                }
            }

            Section {
                Text("Signal strength is only a distance hint. Select the machine you are using; the app verifies FTMS 0x1826 and Step Climber Data 0x2ACF after connecting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .refreshable {
            bluetooth.startScanning()
        }
    }

    private var connectionIsBusy: Bool {
        switch bluetooth.connectionState {
        case .connecting, .discoveringServices, .discoveringCharacteristics, .enablingNotifications:
            true
        default:
            false
        }
    }

    private func isWrongRecoveryMachine(_ machine: DiscoveredFitnessMachine) -> Bool {
        let recoveryIsInProgress = workout.isWorkoutActive
            || recordStore.recoveredCheckpoint?.state == .active
        guard recoveryIsInProgress,
              let expectedPeripheralID = recordStore.expectedPeripheralIdentifier else {
            return false
        }
        return machine.id != expectedPeripheralID
    }
}

private struct MachineRow: View {
    let machine: DiscoveredFitnessMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(machine.name)
                    .font(.headline)
                Spacer()
                Text("\(machine.rssi) dBm")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                compatibilityLabel
                if machine.isRecentlyUsed {
                    Text("Recent")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var compatibilityLabel: some View {
        switch machine.compatibility {
        case .candidate:
            Label("Verify after connection", systemImage: "questionmark.circle")
        case .advertisedFTMS:
            Label("FTMS advertised", systemImage: "checkmark.circle")
        case .verifying:
            Label("Verifying capability", systemImage: "ellipsis.circle")
        case .compatible:
            Label("Compatible Step Climber", systemImage: "checkmark.seal")
        case let .incompatible(reason):
            Label(reason, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
        }
    }
}
