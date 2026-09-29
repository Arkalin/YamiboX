import Foundation

public protocol NovelDownloadStoring: DownloadUpdateObserving {
    func saveNovelDownloadEntry(_ entry: NovelDownloadEntry) async throws
    func novelDownloadEntry(id: DownloadEntryID) async -> NovelDownloadEntry?
    func allNovelDownloadEntries() async -> [NovelDownloadEntry]
    func saveNovelOfflineSourcePage(
        _ sourcePage: ForumThreadPage,
        request: NovelDownloadWorkRequest,
        updatedAt: Date,
        completesMatchingWork: Bool,
        preservesExistingImageReferencesWhenEmpty: Bool
    ) async throws
    func novelOfflineSourcePage(
        ownerTitle: String,
        threadID: String,
        view: Int,
        authorID: String?
    ) async -> ForumThreadPage?
    func novelOfflineSourcePageSnapshot(
        threadID: String,
        view: Int,
        authorID: String?
    ) async -> NovelOfflineSourcePageSnapshot?
    func novelDownloadViewsSnapshot(
        ownerTitle: String,
        threadID: String,
        authorID: String?
    ) async -> NovelDownloadViewsSnapshot
    func removeNovelDownloadViews(
        _ views: Set<Int>,
        ownerTitle: String,
        threadID: String,
        authorID: String?
    ) async throws
    func enqueueNovelDownloadWork(_ request: NovelDownloadWorkRequest) async throws -> NovelDownloadEnqueueResult
    func enqueueNovelDownloadUpdateWork(_ request: NovelDownloadWorkRequest) async throws -> NovelDownloadEnqueueResult
    func finishNovelDownloadWork(id: DownloadWorkID) async throws
}
