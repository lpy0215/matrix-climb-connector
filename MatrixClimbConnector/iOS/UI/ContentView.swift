import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: ClimbMillBluetoothManager
    @EnvironmentObject private var workout: PhoneWorkoutMirrorManager

    var body: some View {
        NavigationStack {
            Group {
                if bluetooth.connectionState == .connected || workout.isWorkoutActive {
                    WorkoutDashboardView()
                } else {
                    DeviceDiscoveryView()
                }
            }
            .navigationTitle("Matrix ClimbMill")
        }
        .task {
            bluetooth.startScanning()
        }
    }
}
