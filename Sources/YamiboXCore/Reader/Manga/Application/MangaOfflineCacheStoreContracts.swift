import Foundation

public protocol MangaOfflineCacheStoring: OfflineCacheUpdateObserving, OfflineCacheImageAssetStoring {
    func mangaOfflineCacheMembership(ownerName: String, tid: String) async -> MangaOfflineCacheMembership?
    func mangaOfflineCacheMemberships(forOwnerName ownerName: String) async -> [MangaOfflineCacheMembership]
    func allMangaOfflineCacheMemberships() async -> [MangaOfflineCacheMembership]
    func saveMangaOfflineCacheMembership(_ membership: MangaOfflineCacheMembership) async throws
    func removeMangaOfflineCacheMembership(ownerName: String, tid: String) async throws
    func removeMangaOfflineCacheMemberships(forOwnerName ownerName: String) async throws
    func renameMangaOfflineCacheOwner(from oldOwnerName: String, to newOwnerName: String) async throws
    func mangaOfflineCacheDiskUsageByOwner() async -> [MangaOfflineCacheOwnerUsage]
    func enqueueMangaOfflineCacheWork(_ request: MangaOfflineCacheWorkRequest) async throws -> MangaOfflineCacheEnqueueResult
    func mangaOfflineCacheState(ownerName: String, tid: String) async -> MangaOfflineCacheState
}
