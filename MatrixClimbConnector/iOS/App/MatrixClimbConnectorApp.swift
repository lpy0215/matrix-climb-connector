import SwiftUI

@main
struct MatrixClimbConnectorApp: App {
    @StateObject private var bluetooth: ClimbMillBluetoothManager
    @StateObject private var workout: PhoneWorkoutMirrorManager

    init() {
        let bluetooth = ClimbMillBluetoothManager()
        let workout = PhoneWorkoutMirrorManager()
        bluetooth.onNotification = { [weak workout] output, rawPacketHex in
            workout?.receiveMachineNotification(
                output,
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
        }
    }
}
