import CoreBluetooth

enum FTMSUUIDs {
    static let fitnessMachineService = CBUUID(string: "1826")
    static let fitnessMachineFeature = CBUUID(string: "2ACC")
    static let stepClimberData = CBUUID(string: "2ACF")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")
}
