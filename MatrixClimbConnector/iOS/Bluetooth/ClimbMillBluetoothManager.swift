import Combine
import CoreBluetooth
import Foundation

enum ClimbMillConnectionState: Equatable {
    case bluetoothUnavailable(String)
    case scanning
    case idle
    case connecting
    case discoveringServices
    case discoveringCharacteristics
    case enablingNotifications
    case connected
    case failed(String)

    var label: String {
        switch self {
        case let .bluetoothUnavailable(reason): "Bluetooth unavailable: \(reason)"
        case .scanning: "Scanning"
        case .idle: "Disconnected"
        case .connecting: "Connecting"
        case .discoveringServices, .discoveringCharacteristics: "Verifying FTMS"
        case .enablingNotifications: "Enabling Step Climber notifications"
        case .connected: "Connected"
        case let .failed(reason): "Failed: \(reason)"
        }
    }
}

@MainActor
final class ClimbMillBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var machines: [DiscoveredFitnessMachine] = []
    @Published private(set) var connectionState: ClimbMillConnectionState = .idle
    @Published private(set) var selectedMachineID: UUID?
    @Published private(set) var selectedDeviceName: String?
    @Published private(set) var metrics: StepClimberMetrics?
    @Published private(set) var parserError: String?
    @Published private(set) var rawPacketHex: String?

    var onMetrics: ((StepClimberMetrics, StepClimberMetrics, String) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var stepClimberCharacteristic: CBCharacteristic?
    private var scanRequested = false

    private let defaults: UserDefaults
    private let recentPeripheralKey = "recentCompatibleClimbMillPeripheralIdentifier"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func startScanning() {
        scanRequested = true
        guard central.state == .poweredOn else { return }
        selectedMachineID = nil
        selectedDeviceName = nil
        metrics = nil
        parserError = nil
        rawPacketHex = nil
        machines.removeAll()
        peripherals.removeAll()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        connectionState = .scanning
    }

    func stopScanning() {
        scanRequested = false
        central.stopScan()
        if connectionState == .scanning {
            connectionState = .idle
        }
    }

    func connect(to machine: DiscoveredFitnessMachine) {
        guard let peripheral = peripherals[machine.id] else {
            connectionState = .failed("Peripheral is no longer available; scan again.")
            return
        }

        central.stopScan()
        scanRequested = false
        selectedMachineID = machine.id
        selectedDeviceName = machine.name
        stepClimberCharacteristic = nil
        parserError = nil
        updateCompatibility(for: machine.id, to: .verifying)
        connectionState = .connecting
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func disconnect() {
        guard let id = selectedMachineID, let peripheral = peripherals[id] else {
            connectionState = .idle
            return
        }
        if let characteristic = stepClimberCharacteristic, characteristic.isNotifying {
            peripheral.setNotifyValue(false, for: characteristic)
        }
        central.cancelPeripheralConnection(peripheral)
    }

    private var recentPeripheralID: UUID? {
        guard let raw = defaults.string(forKey: recentPeripheralKey) else { return nil }
        return UUID(uuidString: raw)
    }

    private func rememberSuccessfulConnection(_ peripheral: CBPeripheral) {
        defaults.set(peripheral.identifier.uuidString, forKey: recentPeripheralKey)
        for index in machines.indices {
            machines[index].isRecentlyUsed = machines[index].id == peripheral.identifier
        }
    }

    private func updateCompatibility(for id: UUID, to compatibility: MachineCompatibility) {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].compatibility = compatibility
    }

    private func failCompatibility(_ peripheral: CBPeripheral, reason: String) {
        updateCompatibility(for: peripheral.identifier, to: .incompatible(reason))
        connectionState = .failed(reason)
        central.cancelPeripheralConnection(peripheral)
    }

    private func sortMachines() {
        // RSSI is deliberately advisory only. The app never auto-selects a machine.
        machines.sort {
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func isCandidateName(_ name: String?) -> Bool {
        guard let normalized = name?.uppercased(), !normalized.isEmpty else { return false }
        return normalized.hasPrefix("CTM") ||
            normalized.contains("MATRIX") ||
            normalized.contains("CLIMBMILL") ||
            normalized.contains("STEP CLIMBER")
    }

    private static func containsFTMS(_ advertisementData: [String: Any]) -> Bool {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let solicited = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        return (advertised + overflow + solicited).contains(FTMSUUIDs.fitnessMachineService) ||
            serviceData.keys.contains(FTMSUUIDs.fitnessMachineService)
    }
}

extension ClimbMillBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.scanRequested { self.startScanning() }
            case .poweredOff:
                self.connectionState = .bluetoothUnavailable("powered off")
            case .unauthorized:
                self.connectionState = .bluetoothUnavailable("permission denied")
            case .unsupported:
                self.connectionState = .bluetoothUnavailable("not supported")
            case .resetting:
                self.connectionState = .bluetoothUnavailable("resetting")
            case .unknown:
                self.connectionState = .bluetoothUnavailable("unknown state")
            @unknown default:
                self.connectionState = .bluetoothUnavailable("unknown state")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let advertisesFTMS = Self.containsFTMS(advertisementData)
            guard advertisesFTMS || Self.isCandidateName(localName ?? peripheral.name) else { return }

            let name = localName ?? peripheral.name ?? "Unnamed fitness machine"
            let rssi = RSSI.intValue == 127 ? -127 : RSSI.intValue
            self.peripherals[peripheral.identifier] = peripheral
            let status: MachineCompatibility = advertisesFTMS ? .advertisedFTMS : .candidate

            if let index = self.machines.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.machines[index].name = name
                self.machines[index].rssi = rssi
                self.machines[index].advertisesFTMS = advertisesFTMS
                self.machines[index].lastSeen = .now
                if self.machines[index].compatibility == .candidate, advertisesFTMS {
                    self.machines[index].compatibility = .advertisedFTMS
                }
            } else {
                self.machines.append(DiscoveredFitnessMachine(
                    id: peripheral.identifier,
                    name: name,
                    rssi: rssi,
                    advertisesFTMS: advertisesFTMS,
                    isRecentlyUsed: peripheral.identifier == self.recentPeripheralID,
                    compatibility: status,
                    lastSeen: .now
                ))
            }
            self.sortMachines()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectionState = .discoveringServices
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectionState = .failed(error?.localizedDescription ?? "Unable to connect.")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.stepClimberCharacteristic = nil
            if case .failed = self.connectionState {
                // Preserve the concrete capability failure instead of replacing
                // it with a generic disconnected state after cancellation.
                return
            } else if let error {
                self.connectionState = .failed("Disconnected: \(error.localizedDescription)")
            } else {
                self.connectionState = .idle
            }
        }
    }
}

extension ClimbMillBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.failCompatibility(peripheral, reason: "Service discovery failed: \(error.localizedDescription)")
                return
            }
            guard let ftms = peripheral.services?.first(where: {
                $0.uuid == FTMSUUIDs.fitnessMachineService
            }) else {
                self.failCompatibility(peripheral, reason: "Fitness Machine Service 0x1826 is absent.")
                return
            }

            self.connectionState = .discoveringCharacteristics
            peripheral.discoverCharacteristics(nil, for: ftms)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.failCompatibility(peripheral, reason: "Characteristic discovery failed: \(error.localizedDescription)")
                return
            }
            guard service.uuid == FTMSUUIDs.fitnessMachineService,
                  let characteristic = service.characteristics?.first(where: {
                      $0.uuid == FTMSUUIDs.stepClimberData
                  }) else {
                self.failCompatibility(peripheral, reason: "Step Climber Data 0x2ACF is absent.")
                return
            }
            guard characteristic.properties.contains(.notify) else {
                self.failCompatibility(peripheral, reason: "Step Climber Data 0x2ACF does not support Notify.")
                return
            }

            self.stepClimberCharacteristic = characteristic
            self.connectionState = .enablingNotifications
            peripheral.setNotifyValue(true, for: characteristic)

            if let feature = service.characteristics?.first(where: {
                $0.uuid == FTMSUUIDs.fitnessMachineFeature && $0.properties.contains(.read)
            }) {
                peripheral.readValue(for: feature)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == FTMSUUIDs.stepClimberData else { return }
            if let error {
                self.failCompatibility(peripheral, reason: "Could not enable 0x2ACF Notify: \(error.localizedDescription)")
                return
            }
            guard characteristic.isNotifying else {
                self.failCompatibility(peripheral, reason: "0x2ACF Notify was not enabled.")
                return
            }

            self.updateCompatibility(for: peripheral.identifier, to: .compatible)
            self.rememberSuccessfulConnection(peripheral)
            self.connectionState = .connected
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == FTMSUUIDs.stepClimberData else { return }
            if let error {
                self.parserError = "0x2ACF notification error: \(error.localizedDescription)"
                return
            }
            guard let data = characteristic.value else {
                self.parserError = "0x2ACF notification had no value."
                return
            }

            let rawPacketHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            self.rawPacketHex = rawPacketHex
            do {
                let parsed = try FTMSStepClimberParser.parse(data)
                let accumulated = parsed.merging(over: self.metrics)
                self.metrics = accumulated
                self.parserError = nil
                self.onMetrics?(parsed, accumulated, rawPacketHex)
            } catch {
                self.parserError = error.localizedDescription
            }
        }
    }
}
