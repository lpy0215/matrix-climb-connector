import SwiftUI

@main
struct MatrixClimbConnectorApp: App {
    @StateObject private var bluetooth: ClimbMillBluetoothManager
    @StateObject private var workout: PhoneWorkoutMirrorManager

    init() {
        let bluetooth = ClimbMillBluetoothManager()
        let workout = PhoneWorkoutMirrorManager()
        bluetooth.onMetrics = { [weak workout] parsed, accumulated, rawPacketHex in
            workout?.receiveMachineMetrics(
                parsedFragment: parsed,
                accumulatedMetrics: accumulated,
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
