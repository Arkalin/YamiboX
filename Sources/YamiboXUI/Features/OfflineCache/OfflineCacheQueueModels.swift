import Foundation
import YamiboXCore

struct OfflineCacheQueueOwnerGroup: Hashable, Identifiable {
    var id: OfflineCacheGroupID
    var readerKind: OfflineCacheReaderKind
    var ownerName: String
    var title: String
    var chapterCount: Int
    var progressFraction: Double
    var progressText: String
    var percentageText: String
    var currentSpeedText: String?
    var failureStatusText: String?
    var chapters: [OfflineCacheQueueChapterRow]

    init(group: OfflineCacheQueueGroup) {
        let rows = group.works.map(OfflineCacheQueueChapterRow.init(work:))
        let completedImageCount = group.works.reduce(0) { $0 + $1.progress.completedUnitCount }
        let targetImageCount = group.works.reduce(0) { $0 + $1.progress.targetUnitCount }
        let currentBytesPerSecond = group.works.reduce(0) { $0 + $1.currentBytesPerSecond }
        id = group.id
        readerKind = group.id.readerKind
        ownerName = group.title
        title = group.title
        chapterCount = rows.count
        progressFraction = targetImageCount > 0
            ? min(max(Double(completedImageCount) / Double(targetImageCount), 0), 1)
            : 0
        if targetImageCount > 0 {
            progressText = L10n.string(
                "mine.offline_queue.image_progress_format",
                completedImageCount,
                targetImageCount
            )
        } else {
            progressText = L10n.string("mine.offline_queue.preparing")
        }
        percentageText = L10n.string(
            "mine.offline_queue.percent_format",
            Int((progressFraction * 100).rounded())
        )
        currentSpeedText = OfflineCacheQueueSpeedText.make(bytesPerSecond: currentBytesPerSecond)
        failureStatusText = rows.first { $0.failureStatusText != nil }?.failureStatusText
        chapters = rows
    }
}

struct OfflineCacheQueueChapterRow: Hashable, Identifiable {
    var id: OfflineCacheWorkID
    var groupID: OfflineCacheGroupID
    var entryID: OfflineCacheEntryID
    var readerKind: OfflineCacheReaderKind
    var ownerName: String
    var tid: String
    var title: String
    var completedImageCount: Int
    var targetImageCount: Int
    var progressFraction: Double
    var progressText: String
    var percentageText: String
    var failureStatusText: String?
    var speedText: String?

    init(work: OfflineCacheQueueWorkProjection) {
        id = work.id
        groupID = work.groupID
        entryID = work.entryID
        readerKind = work.id.readerKind
        ownerName = work.ownerTitle
        tid = work.entryID.entryKey
        title = work.title.isEmpty ? work.entryID.entryKey : work.title
        completedImageCount = work.progress.completedUnitCount
        targetImageCount = work.progress.targetUnitCount
        progressFraction = work.progress.fractionCompleted
        if targetImageCount > 0 {
            progressText = L10n.string(
                "mine.offline_queue.image_progress_format",
                completedImageCount,
                targetImageCount
            )
        } else {
            progressText = L10n.string("mine.offline_queue.preparing")
        }
        percentageText = L10n.string(
            "mine.offline_queue.percent_format",
            Int((progressFraction * 100).rounded())
        )
        if work.state == .failed {
            failureStatusText = work.failureMessage?.isEmpty == false
                ? work.failureMessage
                : L10n.string("mine.offline_queue.failed")
        } else {
            failureStatusText = nil
        }
        speedText = OfflineCacheQueueSpeedText.make(bytesPerSecond: work.currentBytesPerSecond)
    }
}

private enum OfflineCacheQueueSpeedText {
    static func make(bytesPerSecond: Int) -> String? {
        guard bytesPerSecond > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        return L10n.string(
            "mine.offline_queue.speed_format",
            formatter.string(fromByteCount: Int64(bytesPerSecond))
        )
    }
}
