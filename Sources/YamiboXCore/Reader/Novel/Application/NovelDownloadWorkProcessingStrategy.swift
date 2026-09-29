import Foundation

struct NovelDownloadPreparedPayload: Sendable {
    var sourcePage: ForumThreadPage
    var request: NovelDownloadWorkRequest
}

struct NovelDownloadWorkProcessingStrategy: DownloadWorkProcessingStrategy {
    private let store: any NovelDownloadStoring
    private let sourcePageLoader: any NovelDownloadSourcePageLoading

    init(
        store: any NovelDownloadStoring,
        sourcePageLoader: any NovelDownloadSourcePageLoading
    ) {
        self.store = store
        self.sourcePageLoader = sourcePageLoader
    }

    func prepare(_ work: DownloadProcessingWork) async throws -> DownloadPreparedWork<NovelDownloadPreparedPayload> {
        let request = try novelWorkRequest(from: work)
        let prepared = try await sourcePageLoader.loadNovelDownloadSourcePage(request)
        let targetImageURLs = work.retainsInlineImages
            ? Self.inlineImageURLs(in: prepared.projection)
            : work.targetImageURLs
        var sourcePageRequest = request
        sourcePageRequest.targetImageURLs = targetImageURLs

        return DownloadPreparedWork(
            workID: work.id,
            targetImageURLs: targetImageURLs,
            refererURL: YamiboRoute.threadByID(
                tid: request.threadID,
                page: request.view,
                authorID: request.authorID,
                reverse: false
            ).url,
            payload: NovelDownloadPreparedPayload(
                sourcePage: prepared.sourcePage,
                request: sourcePageRequest
            )
        )
    }

    func persistPreparedSource(_ preparedWork: DownloadPreparedWork<NovelDownloadPreparedPayload>) async throws {
        let request = preparedWork.payload.request
        try await store.saveNovelOfflineSourcePage(
            preparedWork.payload.sourcePage,
            request: request,
            updatedAt: .now,
            completesMatchingWork: preparedWork.targetImageURLs.isEmpty,
            preservesExistingImageReferencesWhenEmpty: preparedWork.targetImageURLs.isEmpty && !request.retainsInlineImages
        )
    }

    func finish(_ preparedWork: DownloadPreparedWork<NovelDownloadPreparedPayload>) async throws {
        guard !preparedWork.targetImageURLs.isEmpty else { return }
        try await store.finishNovelDownloadWork(id: preparedWork.workID)
    }

    private func novelWorkRequest(from work: DownloadProcessingWork) throws -> NovelDownloadWorkRequest {
        guard work.entryID.readerKind == .novel,
              let components = NovelDownloadEntry.entryKeyComponents(from: work.entryID.entryKey) else {
            throw YamiboError.parsingFailed(context: "Novel Offline Cache")
        }
        return NovelDownloadWorkRequest(
            ownerTitle: work.ownerTitle,
            title: work.title,
            threadID: components.threadID,
            view: components.view,
            authorID: components.authorID,
            targetImageURLs: work.targetImageURLs,
            retainsInlineImages: work.retainsInlineImages
        )
    }

    private static func inlineImageURLs(in projection: NovelReaderProjection) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        for segment in projection.segments {
            guard case let .image(url, _) = segment else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}
