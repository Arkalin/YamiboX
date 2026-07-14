import Foundation

struct MangaOfflineCachePreparedPayload: Sendable {
    var ownerName: String
    var tid: String
    var chapterTitle: String
    var sourcePage: ForumThreadPage
}

struct MangaOfflineCacheWorkProcessingStrategy: OfflineCacheWorkProcessingStrategy {
    private let store: any MangaOfflineCacheStoring
    private let readerProjectionLoader: any MangaReaderProjectionSnapshotLoading

    init(
        store: any MangaOfflineCacheStoring,
        readerProjectionLoader: any MangaReaderProjectionSnapshotLoading
    ) {
        self.store = store
        self.readerProjectionLoader = readerProjectionLoader
    }

    func prepare(_ work: OfflineCacheProcessingWork) async throws -> OfflineCachePreparedWork<MangaOfflineCachePreparedPayload> {
        guard work.id.readerKind == .manga else {
            throw YamiboError.parsingFailed(context: "Manga Offline Cache")
        }

        let tid = work.entryID.entryKey
        let snapshot = try await readerProjectionLoader.loadReaderProjectionSnapshot(
            MangaReaderProjectionRequest(threadID: tid)
        )
        let targetImageURLs = snapshot.projection.imageURLs
        guard !targetImageURLs.isEmpty else {
            throw YamiboError.parsingFailed(context: "Manga Offline Cache")
        }

        return OfflineCachePreparedWork(
            workID: work.id,
            targetImageURLs: targetImageURLs,
            refererURL: Self.refererURL(for: snapshot.projection.sourceIdentity),
            payload: MangaOfflineCachePreparedPayload(
                ownerName: work.entryID.ownerKey,
                tid: tid,
                chapterTitle: work.title,
                sourcePage: snapshot.sourcePage
            )
        )
    }

    func persistPreparedSource(_ preparedWork: OfflineCachePreparedWork<MangaOfflineCachePreparedPayload>) async throws {}

    func finish(_ preparedWork: OfflineCachePreparedWork<MangaOfflineCachePreparedPayload>) async throws {
        let payload = preparedWork.payload
        try await store.saveMangaOfflineCacheMembership(
            MangaOfflineCacheMembership(
                ownerName: payload.ownerName,
                tid: payload.tid,
                chapterTitle: payload.chapterTitle,
                imageURLs: preparedWork.targetImageURLs,
                sourcePage: payload.sourcePage
            )
        )
    }

    private static func refererURL(for sourceIdentity: MangaReaderProjectionSourceIdentity) -> URL {
        YamiboRoute.threadByID(
            tid: sourceIdentity.tid,
            page: sourceIdentity.view,
            authorID: sourceIdentity.authorID,
            reverse: false
        ).url
    }
}
