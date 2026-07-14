import Foundation
import Testing
@testable import YamiboXCore

/// Pins each disk artifact to its intended root: offline-cache holds
/// user-requested downloads the system must never purge, so it stays under the
/// Application Support root with the backup exclusion marker, while the
/// regenerable `yamibo-cache` projections live under the purgeable Caches
/// root. Everything else under the Application Support root (yamibox.sqlite,
/// favorite-background, like-images) is user data that participates in
/// backups.
@Suite("AppTests: Cache Directory Locations")
struct YamiboAppContextCacheLocationTests {
    @Test func offlineCacheLivesUnderApplicationSupportRootAndIsExcludedFromBackup() throws {
        let rootDirectory = makeTemporaryDirectory(prefix: "app-support")
        let cachesRoot = makeTemporaryDirectory(prefix: "caches")

        _ = YamiboAppContext(grdbRootDirectory: rootDirectory, cachesRootDirectory: cachesRoot)

        let offlineCacheDirectory = rootDirectory.appendingPathComponent("offline-cache", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: offlineCacheDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: cachesRoot.appendingPathComponent("offline-cache", isDirectory: true).path))

        let offlineCacheResourceValues = try offlineCacheDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(offlineCacheResourceValues.isExcludedFromBackup == true)
        let rootResourceValues = try rootDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(rootResourceValues.isExcludedFromBackup != true)
    }

    @Test func yamiboCacheLivesUnderCachesRoot() async throws {
        let rootDirectory = makeTemporaryDirectory(prefix: "app-support")
        let cachesRoot = makeTemporaryDirectory(prefix: "caches")
        let appContext = YamiboAppContext(grdbRootDirectory: rootDirectory, cachesRootDirectory: cachesRoot)

        try await appContext.novelReaderCacheStore.save(
            NovelReaderProjection(
                threadID: "cache-location",
                view: 1,
                maxView: 1,
                segments: [.text("cache location", chapterTitle: nil)]
            )
        )

        let projectionDirectory = YamiboDatabase.cacheDirectoryURL(rootDirectory: cachesRoot)
            .appendingPathComponent(NovelReaderProjectionStore.projectionNamespace, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: projectionDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent(YamiboDatabase.cacheDirectoryName, isDirectory: true).path))
    }

    @Test func favoriteBackgroundAndLikeImagesStayUnderApplicationSupportRoot() {
        let rootDirectory = makeTemporaryDirectory(prefix: "app-support")
        let cachesRoot = makeTemporaryDirectory(prefix: "caches")

        _ = YamiboAppContext(grdbRootDirectory: rootDirectory, cachesRootDirectory: cachesRoot)

        #expect(!FileManager.default.fileExists(atPath: cachesRoot.appendingPathComponent("favorite-background", isDirectory: true).path))
        #expect(!FileManager.default.fileExists(atPath: cachesRoot.appendingPathComponent("like-images", isDirectory: true).path))
    }
}

private func makeTemporaryDirectory(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("yamibo-app-context-cache-location-\(prefix)-\(UUID().uuidString)", isDirectory: true)
}
