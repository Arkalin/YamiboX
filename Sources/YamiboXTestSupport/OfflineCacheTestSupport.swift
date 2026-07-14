import Foundation
import YamiboXCore

public typealias TestOfflineCacheStoring = OfflineCacheStoreCore & MangaOfflineCacheStoring & NovelOfflineCacheStoring & YamiboOfflineImageDataProviding

public extension OfflineCacheQueueWorkProjection {
    var workID: String { id.rawValue }
    var ownerName: String { entryID.ownerKey }
    var tid: String { entryID.entryKey }
    var chapterTitle: String { title }
}

public extension OfflineCacheProcessingWork {
    var workID: String { id.rawValue }
    var ownerName: String { entryID.ownerKey }
    var tid: String { entryID.entryKey }
    var chapterTitle: String { title }
    var progress: OfflineCacheProgress {
        OfflineCacheProgress(
            completedUnitCount: completedImageURLs.count,
            targetUnitCount: targetImageURLs.count
        )
    }
}

public extension OfflineCacheQueueStoring {
    func mangaQueueWorkProjections() async -> [OfflineCacheQueueWorkProjection] {
        await offlineCacheQueueWorks().filter { $0.id.readerKind == .manga }
    }

    func mangaQueueWork(ownerName: String, tid: String) async -> OfflineCacheProcessingWork? {
        let workID = await offlineCacheQueueWorks().first {
            $0.id.readerKind == .manga &&
                $0.entryID.ownerKey == ownerName &&
                $0.entryID.entryKey == tid
        }?.id
        guard let workID else { return nil }
        return await offlineCacheProcessingWork(id: workID)
    }

    func mangaQueueWorks() async -> [OfflineCacheProcessingWork] {
        var works: [OfflineCacheProcessingWork] = []
        for projection in await offlineCacheQueueWorks() where projection.id.readerKind == .manga {
            if let work = await offlineCacheProcessingWork(id: projection.id) {
                works.append(work)
            }
        }
        return works
    }

    func updateOfflineCacheWorkProgress(
        ownerName: String,
        tid: String,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL],
        currentBytesPerSecond: Int? = nil
    ) async throws {
        guard let work = await mangaQueueWork(ownerName: ownerName, tid: tid) else { return }
        try await updateOfflineCacheWorkProgress(
            id: work.id,
            targetImageURLs: targetImageURLs,
            completedImageURLs: completedImageURLs,
            currentBytesPerSecond: currentBytesPerSecond
        )
    }

    func prepareOfflineCacheWorkForRun(
        ownerName: String,
        tid: String,
        targetImageURLs: [URL]?,
        completedImageURLs: [URL]
    ) async throws {
        guard let work = await mangaQueueWork(ownerName: ownerName, tid: tid) else { return }
        try await prepareOfflineCacheWorkForRun(
            id: work.id,
            targetImageURLs: targetImageURLs,
            completedImageURLs: completedImageURLs
        )
    }

    func markOfflineCacheWorkFailed(ownerName: String, tid: String, message: String?) async throws {
        guard let work = await mangaQueueWork(ownerName: ownerName, tid: tid) else { return }
        try await markOfflineCacheWorkFailed(id: work.id, message: message)
    }
}
