import Foundation
@preconcurrency import GRDB
@testable import YamiboXCore

func makeTestMangaStoreRoot(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

func makeTestMangaDirectoryStore(
    rootDirectory: URL? = nil,
    prefix: String = "grdb-manga-directory"
) throws -> MangaDirectoryStore {
    let rootDirectory = rootDirectory ?? makeTestMangaStoreRoot(prefix: prefix)
    return MangaDirectoryStore(
        databasePool: try YamiboDatabase.openPool(rootDirectory: rootDirectory.appendingPathComponent("grdb", isDirectory: true))
    )
}

func makeTestMangaReaderProjectionStore(
    rootDirectory: URL? = nil,
    prefix: String = "grdb-manga-reader-projection"
) throws -> MangaReaderProjectionStore {
    let rootDirectory = rootDirectory ?? makeTestMangaStoreRoot(prefix: prefix)
    return MangaReaderProjectionStore(
        databasePool: try YamiboDatabase.openPool(rootDirectory: rootDirectory.appendingPathComponent("grdb", isDirectory: true)),
        rootDirectory: rootDirectory
    )
}

func makeTestOfflineCacheStore(
    rootDirectory: URL? = nil,
    baseDirectory: URL? = nil,
    prefix: String = "grdb-manga-offline-cache"
) throws -> OfflineCacheStore {
    let rootDirectory = rootDirectory ?? makeTestMangaStoreRoot(prefix: prefix)
    return OfflineCacheStore(
        databasePool: try YamiboDatabase.openPool(rootDirectory: rootDirectory.appendingPathComponent("grdb", isDirectory: true)),
        baseDirectory: baseDirectory ?? rootDirectory.appendingPathComponent("offline-images", isDirectory: true)
    )
}
