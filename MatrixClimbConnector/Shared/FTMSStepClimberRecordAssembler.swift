import Foundation

/// Reassembles one FTMS Step Climber Data record from one or more
/// characteristic notifications.
struct FTMSStepClimberRecordAssembler {
    enum Output: Equatable, Sendable {
        case awaitingMoreData(
            fragment: StepClimberMetrics,
            partialRecord: StepClimberMetrics
        )
        case completed(
            fragment: StepClimberMetrics,
            record: StepClimberMetrics
        )
        case discarded(fragment: StepClimberMetrics)

        var fragment: StepClimberMetrics {
            switch self {
            case let .awaitingMoreData(fragment, _),
                 let .completed(fragment, _),
                 let .discarded(fragment):
                return fragment
            }
        }

        var accumulatedMetrics: StepClimberMetrics {
            switch self {
            case let .awaitingMoreData(_, partialRecord):
                return partialRecord
            case let .completed(_, record):
                return record
            case let .discarded(fragment):
                return fragment
            }
        }

        var completedRecord: StepClimberMetrics? {
            guard case let .completed(_, record) = self else { return nil }
            return record
        }
    }

    private static let moreDataFlag: UInt16 = 1 << 0
    private var pendingRecord: StepClimberMetrics?
    private var isDiscardingUntilBoundary = false

    /// Parses and appends a notification. A malformed notification discards
    /// the pending record because the remaining fragments can no longer be
    /// known to form a complete record.
    mutating func ingest(_ data: Data, receivedAt: Date = .now) throws -> Output {
        do {
            let fragment = try FTMSStepClimberParser.parse(data, receivedAt: receivedAt)

            if isDiscardingUntilBoundary {
                if fragment.flags & Self.moreDataFlag == 0 {
                    isDiscardingUntilBoundary = false
                }
                return .discarded(fragment: fragment)
            }

            var accumulated = fragment.merging(over: pendingRecord)
            accumulated.flags = (pendingRecord?.flags ?? 0) | fragment.flags

            if fragment.flags & Self.moreDataFlag != 0 {
                pendingRecord = accumulated
                return .awaitingMoreData(fragment: fragment, partialRecord: accumulated)
            }

            accumulated.flags &= ~Self.moreDataFlag
            pendingRecord = nil
            return .completed(fragment: fragment, record: accumulated)
        } catch {
            let wasCollecting = pendingRecord != nil || isDiscardingUntilBoundary
            pendingRecord = nil
            switch data.first.map({ $0 & UInt8(Self.moreDataFlag) != 0 }) {
            case .some(true):
                isDiscardingUntilBoundary = true
            case .some(false):
                isDiscardingUntilBoundary = false
            case .none:
                isDiscardingUntilBoundary = wasCollecting
            }
            throw error
        }
    }

    /// Discards an incomplete record after link loss or a connection change.
    mutating func reset() {
        pendingRecord = nil
        isDiscardingUntilBoundary = false
    }
}
