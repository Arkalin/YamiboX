import Foundation

struct NovelOfflineCachePreparedPayload: Sendable {
    var sourcePage: ForumThreadPage
    var request: NovelOfflineCacheWorkRequest
}

struct NovelOfflineCacheWorkProcessingStrategy: OfflineCacheWorkProcessingStrategy {
    private let store: any NovelOfflineCacheStoring
    private let sourcePageLoader: any NovelOfflineCacheSourcePageLoading

    init(
        store: any NovelOfflineCacheStoring,
        sourcePageLoader: any NovelOfflineCacheSourcePageLoading
    ) {
        self.store = store
        self.sourcePageLoader = sourcePageLoader
    }

    func prepare(_ work: OfflineCacheProcessingWork) async throws -> OfflineCachePreparedWork<NovelOfflineCachePreparedPayload> {
        let request = try novelWorkRequest(from: work)
        let prepared = try await sourcePageLoader.loadNovelOfflineCacheSourcePage(request)
        let targetImageURLs = work.retainsInlineImages
            ? Self.inlineImageURLs(in: prepared.projection)
            : work.targetImageURLs
        var sourcePageRequest = request
        sourcePageRequest.targetImageURLs = targetImageURLs

        return OfflineCachePreparedWork(
            workID: work.id,
            targetImageURLs: targetImageURLs,
            refererURL: YamiboRoute.threadByID(
                tid: request.threadID,
                page: request.view,
                authorID: request.authorID,
                reverse: false
            ).url,
            payload: NovelOfflineCachePreparedPayload(
                sourcePage: prepared.sourcePage,
                request: sourcePageRequest
            )
        )
    }

    func persistPreparedSource(_ preparedWork: OfflineCachePreparedWork<NovelOfflineCachePreparedPayload>) async throws {
        let request = preparedWork.payload.request
        try await store.saveNovelOfflineSourcePage(
            preparedWork.payload.sourcePage,
            request: request,
            updatedAt: .now,
            completesMatchingWork: preparedWork.targetImageURLs.isEmpty,
            preservesExistingImageReferencesWhenEmpty: preparedWork.targetImageURLs.isEmpty && !request.retainsInlineImages
        )
    }

    func finish(_ preparedWork: OfflineCachePreparedWork<NovelOfflineCachePreparedPayload>) async throws {
        guard !preparedWork.targetImageURLs.isEmpty else { return }
        try await store.finishNovelOfflineCacheWork(id: preparedWork.workID)
    }

    private func novelWorkRequest(from work: OfflineCacheProcessingWork) throws -> NovelOfflineCacheWorkRequest {
        guard work.entryID.readerKind == .novel,
              let components = NovelOfflineCacheEntry.entryKeyComponents(from: work.entryID.entryKey) else {
            throw YamiboError.parsingFailed(context: "Novel Offline Cache")
        }
        return NovelOfflineCacheWorkRequest(
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
