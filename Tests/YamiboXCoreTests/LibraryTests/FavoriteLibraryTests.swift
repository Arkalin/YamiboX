import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func localFirstFavoriteLibraryInitializesWithDefaultFavoriteCategory() {
    let document = FavoriteLibraryDocument()

    #expect(document.categories.count == 1)
    #expect(document.defaultCategory.isDefault)
    #expect(document.defaultCategory.id == FavoriteCategory.defaultID)
    #expect(document.defaultCategory.name == FavoriteCategory.defaultStorageName)
    #expect(document.defaultCategory.displayName == L10n.string("favorites.default_category"))
    #expect(document.items.isEmpty)
}

@Test func localFirstFavoriteLibraryNormalizesLegacyLocalizedDefaultCategoryName() {
    let legacyDefault = FavoriteCategory(
        id: FavoriteCategory.defaultID,
        name: "默认",
        manualOrder: 99,
        isDefault: true
    )
    let document = FavoriteLibraryDocument(categories: [legacyDefault])

    #expect(document.categories.count == 1)
    #expect(document.defaultCategory.id == FavoriteCategory.defaultID)
    #expect(document.defaultCategory.isDefault)
    #expect(document.defaultCategory.name == FavoriteCategory.defaultStorageName)
    #expect(document.defaultCategory.displayName == L10n.string("favorites.default_category"))
}

@Test func favoriteItemIdentityComesFromStableContentTarget() throws {
    let normal = FavoriteContentTarget(kind: .normalThread, threadID: "319")
    let sameNormal = FavoriteContentTarget(kind: .normalThread, threadID: "319")
    let novel = FavoriteContentTarget(kind: .novelThread, threadID: "319")
    let manga = FavoriteContentTarget(mangaCleanBookName: "Clean Manga")
    let stableManga = FavoriteContentTarget(mangaID: "links:9001", mangaCleanBookName: "Clean Manga")

    #expect(normal.id == sameNormal.id)
    #expect(normal.id != novel.id)
    #expect(manga.id == "manga-title:Clean Manga")
    #expect(stableManga.id == "manga-title:links:9001")
    #expect(stableManga.mangaCleanBookName == "Clean Manga")
}

@Test func favoriteItemIdentityDecodesLegacyMangaTitlePayloads() throws {
    let decoder = JSONDecoder()
    // The reading-progress-side `FavoriteContentTarget.mangaTitle` kind/wire
    // format is untouched by smart-comic-mode — still "mangaTitle".
    let targetData = Data(#"{"kind":"mangaTitle","cleanBookName":"Legacy Manga"}"#.utf8)
    // `FavoriteSourceGroup.mangaTitle` was renamed to `.smartManga`, and its
    // wire format was renamed along with it (design decision #9) — no
    // shipped user data exists yet to stay backward-compatible with.
    let sourceGroupData = Data(#"{"smartManga":{"cleanBookName":"Legacy Manga"}}"#.utf8)

    let target = try decoder.decode(FavoriteContentTarget.self, from: targetData)
    let sourceGroup = try decoder.decode(FavoriteSourceGroup.self, from: sourceGroupData)

    #expect(target == FavoriteContentTarget(mangaCleanBookName: "Legacy Manga"))
    #expect(target.mangaCleanBookName == "Legacy Manga")
    #expect(sourceGroup == .smartManga(cleanBookName: "Legacy Manga"))
}

@Test func favoriteItemRequiresAtLeastOneFavoriteLocation() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "320")

    #expect(throws: YamiboPersistenceError.self) {
        _ = try FavoriteItem(target: target, title: "No location", locations: [])
    }
}

@Test func localFirstFavoriteLibraryPersistsItemMetadataLocationsTagsAndRemoteMapping() async throws {
    let suiteName = "LocalFirstFavoriteLibraryTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let store = FavoriteLibraryStore(defaults: suite, key: "library")
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "321")
    var document = FavoriteLibraryDocument()
    let category = document.defaultCategory
    let tag = document.createTag(name: "本地标签", color: .blue)
    let item = try FavoriteItem(
        target: target,
        title: "远端标题",
        displayName: " 本地名 ",
        sourceGroup: .forumBoard(id: "fid-1", label: "版块"),
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-321", yamiboRemoteOrder: 7),
        locations: [.category(category.id)],
        tagIDs: [tag.id, tag.id]
    )
    document.upsertItem(item)

    try await store.save(document)

    let loaded = try await store.load()
    let loadedItem = try #require(loaded.items.first)
    #expect(loaded.defaultCategory.id == FavoriteCategory.defaultID)
    #expect(loadedItem.id == target.id)
    #expect(loadedItem.resolvedDisplayTitle == "本地名")
    #expect(loadedItem.remoteMapping?.yamiboFavoriteID == "remote-321")
    #expect(loadedItem.locations == [.category(category.id)])
    #expect(loadedItem.tagIDs == [tag.id])
}

@Test func updateRemoteMappingRefreshesKnownValuesAndKeepsPreviousOnNil() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "324")
    var document = FavoriteLibraryDocument()
    let item = try FavoriteItem(
        target: target,
        title: "本地收藏",
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-324", yamiboRemoteOrder: 5),
        locations: [.category(document.defaultCategory.id)]
    )
    document.upsertItem(item)

    let date = Date(timeIntervalSince1970: 200)
    document.updateRemoteMapping(for: target, yamiboFavoriteID: nil, yamiboRemoteOrder: 7, date: date)

    let remaining = try #require(document.items.first)
    #expect(remaining.id == target.id)
    #expect(remaining.remoteMapping?.yamiboFavoriteID == "remote-324")
    #expect(remaining.remoteMapping?.yamiboRemoteOrder == 7)
    #expect(remaining.remoteMapping?.lastSeenAt == date)
}

@Test func grdbFavoriteLibraryPersistsStructuredTidFirstLibraryAndIgnoresLegacyJSON() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
    let suiteName = "GRDBFavoriteLibraryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let legacyData = Data(#"{"items":[{"id":"legacy"}]}"#.utf8)
    defaults.set(legacyData, forKey: "library")
    let store = FavoriteLibraryStore(defaults: defaults, key: "library", databasePool: database)

    let fresh = try await store.load()
    #expect(fresh.defaultCategory.id == FavoriteCategory.defaultID)
    #expect(fresh.items.isEmpty)
    #expect(await store.hasStoredDocument() == false)
    let legacyDefaultsAfterLoad = try #require(UserDefaults(suiteName: suiteName))
    #expect(legacyDefaultsAfterLoad.data(forKey: "library") == legacyData)

    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "阅读")
    let collection = document.createCollection(categoryID: category.id, name: "合集", color: .blue)
    let tag = document.createTag(name: "标签", color: .green, date: Date(timeIntervalSince1970: 10))
    let target = FavoriteItemTarget(
        kind: .novelThread,
        threadID: "321"
    )
    let item = try FavoriteItem(
        target: target,
        title: "小说",
        displayName: "本地小说",
        sourceGroup: .forumBoard(id: "fid-1", label: "版块"),
        remoteMapping: FavoriteRemoteMapping(
            yamiboFavoriteID: "remote-321",
            yamiboRemoteOrder: 3,
            lastSeenAt: Date(timeIntervalSince1970: 20)
        ),
        locations: [
            .category(category.id),
            .collection(categoryID: category.id, collectionID: collection.id),
        ],
        tagIDs: [tag.id]
    )
    document.upsertItem(item)

    try await store.save(document)

    let loaded = try await store.load()
    let loadedItem = try #require(loaded.items.first)
    #expect(loadedItem.id == "thread:novel:321")
    #expect(loadedItem.target.threadID == "321")
    #expect(loaded.openRoute(for: loadedItem) == .novelDetail(threadID: "321"))
    #expect(loadedItem.locations == [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)])
    #expect(loadedItem.tagIDs == [tag.id])
    #expect(loadedItem.remoteMapping?.yamiboFavoriteID == "remote-321")
    #expect(await store.hasStoredDocument())

    let documentRow = try await database.read { db in
        try Row.fetchOne(db, sql: "SELECT id, document_json FROM favorite_library_document")
    }
    let row = try #require(documentRow)
    #expect(row["id"] as Int == 1)
    let documentJSON = row["document_json"] as String
    #expect(documentJSON.contains("canonicalURL") == false)
    let storedDocument = try JSONDecoder().decode(FavoriteLibraryDocument.self, from: Data(documentJSON.utf8))
    let storedItem = try #require(storedDocument.items.first)
    #expect(storedItem.id == "thread:novel:321")
    #expect(storedItem.target.kind == .novelThread)
    #expect(storedItem.target.threadID == "321")
    #expect(storedItem.locations == [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)])
    #expect(storedItem.tagIDs == [tag.id])
    #expect(storedItem.remoteMapping?.yamiboFavoriteID == "remote-321")
}

@Test func favoriteLibraryStoreUpdatePersistsTransformAndReturnsItsResult() async throws {
    let suiteName = "FavoriteLibraryStoreUpdateTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let store = FavoriteLibraryStore(defaults: suite, key: "library")
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "610")

    let created = try await store.update { document in
        let item = try FavoriteItem(
            target: target,
            title: "原子写入",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        return item
    }

    let loaded = try await store.load()
    #expect(created.id == target.id)
    #expect(loaded.items.map(\.id) == [target.id])
}

@Test func favoriteLibraryStoreUpdateRollsBackAndRethrowsWhenTransformFails() async throws {
    struct TransformAbort: Error {}
    let suiteName = "FavoriteLibraryStoreUpdateRollbackTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let store = FavoriteLibraryStore(defaults: suite, key: "library")
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "611")
    try await store.update { document in
        let item = try FavoriteItem(
            target: target,
            title: "既有收藏",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
    }

    // The caller's error must come back unchanged (not wrapped in
    // YamiboPersistenceError), and the aborted mutation must not persist.
    await #expect(throws: TransformAbort.self) {
        try await store.update { document in
            document.removeItem(target: target)
            throw TransformAbort()
        }
    }

    let loaded = try await store.load()
    #expect(loaded.items.map(\.id) == [target.id])
}

@Test func favoriteLibraryStoreConcurrentUpdatesLoseNoWrites() async throws {
    let suiteName = "FavoriteLibraryStoreConcurrencyTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let store = FavoriteLibraryStore(defaults: suite, key: "library")
    let threadIDs = (700 ..< 720).map(String.init)

    // Every read-modify-write runs inside one store transaction, so parallel
    // writers must not overwrite each other's items (the lost-update race
    // that load-modify-save callers used to have).
    try await withThrowingTaskGroup(of: Void.self) { group in
        for threadID in threadIDs {
            group.addTask {
                try await store.update { document in
                    let item = try FavoriteItem(
                        target: FavoriteItemTarget(kind: .normalThread, threadID: threadID),
                        title: "并发收藏 \(threadID)",
                        locations: [.category(document.defaultCategory.id)]
                    )
                    document.upsertItem(item)
                }
            }
        }
        try await group.waitForAll()
    }

    let loaded = try await store.load()
    #expect(loaded.items.count == threadIDs.count)
    #expect(Set(loaded.items.compactMap(\.target.threadID)) == Set(threadIDs))
}
