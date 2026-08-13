import CoreBluetooth
import Foundation

enum MachineCompatibility: Equatable {
    case candidate
    case advertisedFTMS
    case verifying
    case compatible
    case incompatible(String)
}

struct DiscoveredFitnessMachine: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisesFTMS: Bool
    var isRecentlyUsed: Bool
    var compatibility: MachineCompatibility
    var lastSeen: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.rssi == rhs.rssi &&
            lhs.advertisesFTMS == rhs.advertisesFTMS &&
            lhs.isRecentlyUsed == rhs.isRecentlyUsed &&
            lhs.compatibility == rhs.compatibility
    }
}
