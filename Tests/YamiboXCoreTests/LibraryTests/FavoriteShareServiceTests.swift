import Foundation
@preconcurrency import GRDB
import Testing
@testable import YamiboXCore
import YamiboXTestSupport

@Test func favoriteShareCodecAcceptsAndroidV2BOMAndUnknownFields() throws {
    let json = """
    {
      "schema": "yamibo.favorite-share",
      "schemaVersion": 2,
      "exportedAt": 1720000000123,
      "unknown": true,
      "folders": [{
        "name": "Android 收藏",
        "items": [{
          "targetType": "ThreadNovel",
          "targetId": 123,
          "authorId": 456,
          "title": "小说",
          "unknownItemField": "ignored"
        }]
      }]
    }
    """
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8)

    let package = try FavoriteShareCodec.decode(data)

    #expect(package.exportedAt == 1_720_000_000_123)
    #expect(package.folders.first?.items.first?.authorId == 456)
    let encoded = try FavoriteShareCodec.encode(package)
    let encodedText = try #require(String(data: encoded, encoding: .utf8))
    #expect(encodedText.contains("\n"))
    #expect(!encodedText.contains("unknownItemField"))
}

@Test func favoriteShareCodecOmitsEmptyOptionalFieldsAndRejectsInvalidFolders() throws {
    let package = FavoriteSharePackage(
        exportedAt: 1_720_000_000_123,
        folders: [.init(name: "A", items: [
            .init(targetType: "ThreadNormal", targetId: 1, title: "帖子")
        ])]
    )

    let encodedText = try #require(String(data: FavoriteShareCodec.encode(package), encoding: .utf8))
    #expect(!encodedText.contains("authorId"))
    #expect(!encodedText.contains("coverUrl"))
    #expect(!encodedText.contains("forumId"))
    #expect(throws: FavoriteShareError.emptyFolders) {
        try FavoriteShareCodec.encode(.init(exportedAt: 1, folders: []))
    }
    #expect(throws: FavoriteShareError.blankFolderName(1)) {
        try FavoriteShareCodec.encode(.init(exportedAt: 1, folders: [.init(name: "  ", items: [])]))
    }
}

@Test func favoriteShareExportFlattensCollectionsAndMapsThreadTypes() async throws {
    let fixture = try FavoriteShareFixture(prefix: "favorite-share-export")
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "导出分类")
    let collection = document.createCollection(categoryID: category.id, name: "合集", color: .blue)
    let normal = try FavoriteItem(
        target: .normalThread(threadID: "101"),
        title: "普通帖",
        forumID: "20",
        contentUpdatedAt: Date(timeIntervalSince1970: 500),
        locations: [.category(category.id)]
    )
    let novel = try FavoriteItem(
        target: .novelThread(threadID: "102"),
        title: "小说",
        locations: [.collection(categoryID: category.id, collectionID: collection.id)]
    )
    let manga = try FavoriteItem(
        target: .mangaThread(threadID: "103"),
        title: "漫画章节",
        forumID: "30",
        locations: [
            .category(category.id),
            .collection(categoryID: category.id, collectionID: collection.id)
        ]
    )
    document.upsertItem(normal)
    document.upsertItem(novel)
    document.upsertItem(manga)
    try await fixture.libraryStore.save(document)
    _ = try await fixture.coverStore.setAutomaticCover(
        URL(string: "https://example.com/cover.jpg")!,
        for: .thread(tid: "103")
    )

    let export = try await fixture.service.export(
        categoryIDs: [category.id],
        exportedAt: Date(timeIntervalSince1970: 1_000)
    )
    let package = try FavoriteShareCodec.decode(export.data)

    #expect(export.fileName == "yamibo-favorites-1000000.json")
    #expect(export.folderCount == 1)
    #expect(export.itemCount == 3)
    #expect(package.folders.first?.items.count == 3)
    #expect(package.folders.first?.items.first(where: { $0.targetId == 101 })?.targetType == "ThreadNormal")
    #expect(package.folders.first?.items.first(where: { $0.targetId == 102 })?.targetType == "ThreadNovel")
    let exportedManga = try #require(package.folders.first?.items.first(where: { $0.targetId == 103 }))
    #expect(exportedManga.targetType == "ThreadNormal")
    #expect(exportedManga.forumId == 30)
    #expect(exportedManga.coverUrl == "https://example.com/cover.jpg")
}

@Test func favoriteShareExportRejectsMissingCategoriesAndInvalidThreadIDs() async throws {
    let fixture = try FavoriteShareFixture(prefix: "favorite-share-invalid-export")
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "导出分类")
    document.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "not-a-number"),
        title: "无法互通",
        locations: [.category(category.id)]
    ))
    try await fixture.libraryStore.save(document)

    await #expect(throws: FavoriteShareError.missingExportCategories) {
        try await fixture.service.export(categoryIDs: [category.id, "missing"])
    }
    await #expect(throws: FavoriteShareError.invalidLocalItem("无法互通")) {
        try await fixture.service.export(categoryIDs: [category.id])
    }
}

@Test func favoriteSharePreviewCountsDuplicatesUnsupportedAndInvalidItems() async throws {
    let fixture = try FavoriteShareFixture(prefix: "favorite-share-preview")
    var document = FavoriteLibraryDocument()
    document.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "201"),
        title: "已有",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await fixture.libraryStore.save(document)
    let package = FavoriteSharePackage(
        exportedAt: 1,
        folders: [
            .init(name: "A", items: [
                .init(targetType: "ThreadNovel", targetId: 201, title: "跨类型重复"),
                .init(targetType: "ThreadNormal", targetId: 202, title: "漫画", forumId: 30),
                .init(targetType: "TagManga", targetId: 203, title: "Tag"),
                .init(targetType: "RssSearch", targetId: 204, title: "RSS"),
                .init(targetType: "ThreadNovel", targetId: 0, title: "无效")
            ])
        ]
    )

    let preview = try await fixture.service.previewImport(data: FavoriteShareCodec.encode(package))

    #expect(preview.folderCount == 1)
    #expect(preview.itemCount == 5)
    #expect(preview.duplicateCount == 1)
    #expect(preview.unsupportedCount == 2)
    #expect(preview.invalidCount == 1)
    #expect(preview.importableCount == 1)
}

@Test func favoriteShareCreateFoldersReusesExistingItemsAndResolvesNameCollisions() async throws {
    let fixture = try FavoriteShareFixture(prefix: "favorite-share-create-folders")
    var document = FavoriteLibraryDocument()
    _ = document.createCategory(name: "共享")
    _ = document.createCollection(categoryID: document.defaultCategory.id, name: "共享 (2)", color: .gray)
    document.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "301"),
        title: "本地标题",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await fixture.libraryStore.save(document)
    let package = FavoriteSharePackage(
        exportedAt: 1,
        folders: [
            .init(name: "共享", items: [
                .init(targetType: "ThreadNormal", targetId: 301, title: "共享标题"),
                .init(
                    targetType: "ThreadNormal",
                    targetId: 302,
                    title: "漫画章节",
                    coverUrl: "https://example.com/imported.jpg",
                    forumId: 30
                )
            ])
        ]
    )

    let result = try await fixture.service.importFavorites(
        data: FavoriteShareCodec.encode(package),
        target: .createFolders,
        date: Date(timeIntervalSince1970: 2_000)
    )
    let imported = try await fixture.libraryStore.load()
    let createdCategory = try #require(imported.categories.first(where: { $0.name == "共享 (3)" }))

    #expect(result.createdFolderCount == 1)
    #expect(result.createdItemCount == 1)
    #expect(result.reusedItemCount == 1)
    #expect(imported.items.first(where: { $0.target.threadID == "301" })?.title == "本地标题")
    #expect(imported.items.first(where: { $0.target.threadID == "301" })?.locations.contains(.category(createdCategory.id)) == true)
    #expect(imported.items.first(where: { $0.target.threadID == "302" })?.target.kind == .mangaThread)
    #expect(await fixture.coverStore.cover(for: .thread(tid: "302"))?.resolvedURL?.absoluteString == "https://example.com/imported.jpg")
}

@Test func favoriteShareAddToExistingFoldersSkipsLocalDuplicatesAndDeduplicatesPackage() async throws {
    let fixture = try FavoriteShareFixture(prefix: "favorite-share-existing-folders")
    var document = FavoriteLibraryDocument()
    let first = document.createCategory(name: "一")
    let second = document.createCategory(name: "二")
    document.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "401"),
        title: "已有",
        locations: [.category(document.defaultCategory.id)]
    ))
    try await fixture.libraryStore.save(document)
    let duplicateNewItem = FavoriteSharePackage.Item(targetType: "ThreadNovel", targetId: 402, title: "新小说")
    let package = FavoriteSharePackage(
        exportedAt: 1,
        folders: [
            .init(name: "A", items: [
                .init(targetType: "ThreadNormal", targetId: 401, title: "重复"),
                duplicateNewItem
            ]),
            .init(name: "B", items: [duplicateNewItem])
        ]
    )

    let result = try await fixture.service.importFavorites(
        data: FavoriteShareCodec.encode(package),
        target: .addToExistingFolders(categoryIDs: [first.id, second.id])
    )
    let imported = try await fixture.libraryStore.load()
    let existing = try #require(imported.items.first(where: { $0.target.threadID == "401" }))
    let created = try #require(imported.items.first(where: { $0.target.threadID == "402" }))

    #expect(result.createdItemCount == 1)
    #expect(result.skippedDuplicateCount == 1)
    #expect(!existing.locations.contains(.category(first.id)))
    #expect(Set(created.locations) == [.category(first.id), .category(second.id)])
}

@Test func favoriteShareImportTransactionFailureLeavesMainDataUntouched() async throws {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("favorite-share-rollback-\(UUID().uuidString)", isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: rootDirectory)
    let defaults = try YamiboTestDefaults.make(prefix: "favorite-share-rollback")
    let libraryStore = FavoriteLibraryStore(defaults: defaults, key: "library", databasePool: database)
    let service = FavoriteShareService(
        libraryStore: libraryStore,
        contentCoverStore: ContentCoverStore(databasePool: database),
        settingsStore: SettingsStore(defaults: defaults, key: "settings")
    )
    var original = FavoriteLibraryDocument()
    original.upsertItem(try FavoriteItem(
        target: .normalThread(threadID: "501"),
        title: "原有收藏",
        locations: [.category(original.defaultCategory.id)]
    ))
    try await libraryStore.save(original)
    try await database.write { db in
        try db.execute(sql: """
            CREATE TRIGGER fail_favorite_share_update
            BEFORE UPDATE ON favorite_library_document
            BEGIN
                SELECT RAISE(ABORT, 'forced favorite share failure');
            END
            """)
    }
    let package = FavoriteSharePackage(
        exportedAt: 1,
        folders: [.init(name: "新收藏夹", items: [
            .init(targetType: "ThreadNormal", targetId: 502, title: "不应写入")
        ])]
    )

    await #expect(throws: YamiboPersistenceError.self) {
        try await service.import(
            data: FavoriteShareCodec.encode(package),
            target: .createFolders
        )
    }
    let afterFailure = try await libraryStore.load()
    #expect(afterFailure == original)
}

private struct FavoriteShareFixture {
    let libraryStore: FavoriteLibraryStore
    let coverStore: ContentCoverStore
    let settingsStore: SettingsStore
    let service: FavoriteShareService

    init(prefix: String) throws {
        let defaults = try YamiboTestDefaults.make(prefix: prefix)
        libraryStore = FavoriteLibraryStore(defaults: defaults, key: "favorite-share-library")
        coverStore = ContentCoverStore(defaults: defaults, key: "favorite-share-covers")
        settingsStore = SettingsStore(defaults: defaults, key: "favorite-share-settings")
        service = FavoriteShareService(
            libraryStore: libraryStore,
            contentCoverStore: coverStore,
            settingsStore: settingsStore
        )
    }
}
