import Foundation

public struct DownloadRunID: Hashable, Sendable {
    public let rawValue: UUID
    public init() { rawValue = UUID() }
}

/// Bytes belong to one network attempt, not to a persisted download entry.
struct DownloadTransferProgress: Sendable {
    var receivedBytes: Int64
    var expectedBytes: Int64

    var fraction: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

public enum DownloadWorkPhase: Sendable {
    case preparing, transferring, saving
}

struct DownloadWorkProgress: Sendable {
    var phase: DownloadWorkPhase = .preparing
    var fraction: Double = 0
    var receivedBytes: Int64 = 0
    var hasUnknownLength = false
}

public struct DownloadQueueRunProgress: Sendable {
    public var completedWorkCount: Int
    public var totalWorkCount: Int
    public var currentTitle: String
    public var phase: DownloadWorkPhase
    public var currentWorkFraction: Double
    public var receivedBytes: Int64
    public var hasUnknownLength: Bool

    public var fractionCompleted: Double {
        guard totalWorkCount > 0 else { return 0 }
        return min(1, max(0, (Double(completedWorkCount) + currentWorkFraction) / Double(totalWorkCount)))
    }
}

/// Cancellation is bound to the original executor and run, never resolved
/// from the current account when a delayed system callback arrives.
public protocol DownloadQueueRunObserving: Sendable {
    func queueRunDidStart(
        id: DownloadRunID,
        progress: DownloadQueueRunProgress,
        pause: @escaping @Sendable () async -> Void
    ) async
    func queueRunDidUpdateProgress(id: DownloadRunID, progress: DownloadQueueRunProgress) async
    func queueRunDidFinish(id: DownloadRunID, success: Bool) async
}
