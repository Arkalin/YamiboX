import Foundation

struct MangaDownloadPreparedPayload: Sendable {
    var ownerName: String
    var tid: String
    var chapterTitle: String
    var sourcePage: ForumThreadPage
}

struct MangaDownloadWorkProcessingStrategy: DownloadWorkProcessingStrategy {
    private let store: any MangaDownloadStoring
    private let readerProjectionLoader: any MangaReaderProjectionSnapshotLoading

    init(
        store: any MangaDownloadStoring,
        readerProjectionLoader: any MangaReaderProjectionSnapshotLoading
    ) {
        self.store = store
        self.readerProjectionLoader = readerProjectionLoader
    }

    func prepare(_ work: DownloadProcessingWork) async throws -> DownloadPreparedWork<MangaDownloadPreparedPayload> {
        guard work.id.readerKind == .manga else {
            throw YamiboError.parsingFailed(context: "Manga Offline Cache")
        }

        let tid = work.entryID.entryKey
        let snapshot = try await readerProjectionLoader.loadReaderProjectionSnapshot(
            MangaReaderProjectionRequest(threadID: tid, offlineOwnerName: work.entryID.ownerKey)
        )
        let targetImageURLs = snapshot.projection.imageURLs
        guard !targetImageURLs.isEmpty else {
            throw YamiboError.parsingFailed(context: "Manga Offline Cache")
        }

        return DownloadPreparedWork(
            workID: work.id,
            targetImageURLs: targetImageURLs,
            refererURL: Self.refererURL(for: snapshot.projection.sourceIdentity),
            payload: MangaDownloadPreparedPayload(
                ownerName: work.entryID.ownerKey,
                tid: tid,
                chapterTitle: work.title,
                sourcePage: snapshot.sourcePage
            )
        )
    }

    func persistPreparedSource(_ preparedWork: DownloadPreparedWork<MangaDownloadPreparedPayload>) async throws {}

    func finish(_ preparedWork: DownloadPreparedWork<MangaDownloadPreparedPayload>) async throws {
        let payload = preparedWork.payload
        try await store.saveMangaDownloadMembership(
            MangaDownloadMembership(
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
