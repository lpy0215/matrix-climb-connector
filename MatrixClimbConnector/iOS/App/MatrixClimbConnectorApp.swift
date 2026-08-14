import SwiftUI

@main
struct MatrixClimbConnectorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bluetooth: ClimbMillBluetoothManager
    @StateObject private var workout: PhoneWorkoutMirrorManager

    init() {
        let bluetooth = ClimbMillBluetoothManager()
        let workout = PhoneWorkoutMirrorManager()
        bluetooth.onNotification = { [weak bluetooth, weak workout] output, rawPacketHex in
            guard let peripheralID = bluetooth?.selectedMachineID else { return }
            workout?.receiveMachineNotification(
                output,
                peripheralID: peripheralID,
                rawPacketHex: rawPacketHex
            )
        }
        _bluetooth = StateObject(wrappedValue: bluetooth)
        _workout = StateObject(wrappedValue: workout)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(workout)
                .environmentObject(workout.recordStore)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        workout.recordStore.checkpointNow()
                    }
                }
        }
    }
}
