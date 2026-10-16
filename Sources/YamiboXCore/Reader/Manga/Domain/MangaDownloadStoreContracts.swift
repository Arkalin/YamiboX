import Foundation

public protocol MangaDownloadStoring: DownloadUpdateObserving, DownloadImageAssetStoring {
    func mangaDownloadMembership(ownerName: String, tid: String) async -> MangaDownloadMembership?
    func mangaDownloadMemberships(threadID: String) async -> [MangaDownloadMembership]
    func mangaDownloadMemberships(forOwnerName ownerName: String) async -> [MangaDownloadMembership]
    func allMangaDownloadMemberships() async -> [MangaDownloadMembership]
    func saveMangaDownloadMembership(_ membership: MangaDownloadMembership) async throws
    func removeMangaDownloadMembership(ownerName: String, tid: String) async throws
    func removeMangaDownloadMemberships(forOwnerName ownerName: String) async throws
    func mangaDownloadDiskUsageByOwner() async -> [MangaDownloadOwnerUsage]
    func enqueueMangaDownloadWork(_ request: MangaDownloadWorkRequest) async throws -> MangaDownloadEnqueueResult
    func mangaDownloadState(ownerName: String, tid: String) async -> MangaDownloadState
    func mangaDownloadStates(ownerName: String) async -> [String: MangaDownloadState]
}

public extension MangaDownloadStoring {
    /// Unknown owners are resolved only by a unique, matching saved chapter,
    /// never by display title or an unrelated globally cached image.
    func mangaOfflineMembership(for request: MangaReaderProjectionRequest) async -> MangaDownloadMembership? {
        let matches = await mangaOfflineMembershipCandidates(for: request)
        return matches.count == 1 ? matches.first : nil
    }

    func mangaOfflineMembershipCandidates(for request: MangaReaderProjectionRequest) async -> [MangaDownloadMembership] {
        let candidates: [MangaDownloadMembership]
        if let ownerName = request.offlineOwnerName {
            candidates = await mangaDownloadMembership(ownerName: ownerName, tid: request.threadID).map { [$0] } ?? []
        } else {
            candidates = await mangaDownloadMemberships(threadID: request.threadID)
        }
        return candidates.filter { membership in
            membership.tid == request.threadID &&
                membership.sourcePage.thread.tid == request.threadID &&
                (membership.sourcePage.pageNavigation?.currentPage ?? 1) == request.view &&
                (request.authorID == nil || membership.sourcePage.posts.first?.author.uid?.nilIfBlank == request.authorID)
        }
    }

    func mangaDownloadStates(ownerName: String) async -> [String: MangaDownloadState] {
        var states: [String: MangaDownloadState] = [:]
        for membership in await mangaDownloadMemberships(forOwnerName: ownerName) {
            states[membership.tid] = await mangaDownloadState(ownerName: ownerName, tid: membership.tid)
        }
        if let queue = self as? any DownloadQueueStoring,
           let works = try? await queue.downloadQueueWorks() {
            for work in works where work.entryID.readerKind == .manga && work.entryID.ownerKey == ownerName {
                if states[work.entryID.entryKey] != .downloaded { states[work.entryID.entryKey] = .downloading }
            }
        }
        return states
    }
}
