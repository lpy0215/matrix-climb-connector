import Foundation

enum MetricFormatters {
    static func duration(_ seconds: UInt16?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}
