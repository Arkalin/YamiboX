import Foundation

public protocol MangaDownloadStoring: DownloadUpdateObserving, DownloadImageAssetStoring {
    func mangaDownloadMembership(ownerName: String, tid: String) async -> MangaDownloadMembership?
    func mangaDownloadMemberships(forOwnerName ownerName: String) async -> [MangaDownloadMembership]
    func allMangaDownloadMemberships() async -> [MangaDownloadMembership]
    func saveMangaDownloadMembership(_ membership: MangaDownloadMembership) async throws
    func removeMangaDownloadMembership(ownerName: String, tid: String) async throws
    func removeMangaDownloadMemberships(forOwnerName ownerName: String) async throws
    func mangaDownloadDiskUsageByOwner() async -> [MangaDownloadOwnerUsage]
    func enqueueMangaDownloadWork(_ request: MangaDownloadWorkRequest) async throws -> MangaDownloadEnqueueResult
    func mangaDownloadState(ownerName: String, tid: String) async -> MangaDownloadState
}
