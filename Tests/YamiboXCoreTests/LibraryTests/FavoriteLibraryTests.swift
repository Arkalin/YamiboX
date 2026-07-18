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

/// An item persisted before `locationsUpdatedAt`/`tagIDsUpdatedAt`/
/// `displayNameUpdatedAt`/`remoteMappingUpdatedAt` existed has none of those
/// keys. Decoding must default each to the item's own `updatedAt` rather
/// than failing — a decode failure here would corrupt every existing user's
/// favorites on first launch after the update. Builds the legacy blob by
/// encoding a real item and stripping the four new keys, rather than
/// hand-writing JSON, so this doesn't depend on knowing every nested type's
/// exact (synthesized) wire format.
@Test func favoriteItemDecodesPreFieldClockBlobsDefaultingToUpdatedAt() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "321")
    let item = try FavoriteItem(
        target: target,
        title: "旧收藏",
        locations: [.category(FavoriteCategory.defaultID)],
        updatedAt: Date(timeIntervalSince1970: 50)
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(item)) as? [String: Any]
    )
    for key in ["locationsUpdatedAt", "tagIDsUpdatedAt", "displayNameUpdatedAt", "remoteMappingUpdatedAt"] {
        #expect(object[key] != nil)
        object.removeValue(forKey: key)
    }
    let legacyItem = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(FavoriteItem.self, from: legacyItem)
    #expect(decoded.updatedAt == item.updatedAt)
    #expect(decoded.locationsUpdatedAt == item.updatedAt)
    #expect(decoded.tagIDsUpdatedAt == item.updatedAt)
    #expect(decoded.displayNameUpdatedAt == item.updatedAt)
    #expect(decoded.remoteMappingUpdatedAt == item.updatedAt)
}

/// Every mutator that touches `locations`/`tagIDs` must bump only its own
/// dedicated clock, not the others — `FavoriteLibraryWebDAVMerger` relies on
/// this independence to keep concurrent edits to different fields on
/// different devices from clobbering each other (see the merger's own doc
/// comment on why `locations`/`tagIDs` stopped sharing the item's overall
/// `updatedAt`).
@Test func locationAndTagMutatorsBumpOnlyTheirOwnFieldClock() throws {
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "分类")
    let tag = document.createTag(name: "标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9106")
    let baseDate = Date(timeIntervalSince1970: 1000)
    let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(document.defaultCategory.id)], updatedAt: baseDate)
    document.upsertItem(item)
    let tagIDsUpdatedAtBeforeLocationEdit = try #require(document.items.first).tagIDsUpdatedAt

    document.addLocation(.category(category.id), to: target, date: baseDate.addingTimeInterval(1))
    var current = try #require(document.items.first)
    #expect(current.locationsUpdatedAt == baseDate.addingTimeInterval(1))
    #expect(current.tagIDsUpdatedAt == tagIDsUpdatedAtBeforeLocationEdit)

    let locationsUpdatedAtBeforeTagEdit = current.locationsUpdatedAt
    document.assignTag(id: tag.id, to: target, date: baseDate.addingTimeInterval(2))
    current = try #require(document.items.first)
    #expect(current.tagIDsUpdatedAt == baseDate.addingTimeInterval(2))
    #expect(current.locationsUpdatedAt == locationsUpdatedAtBeforeTagEdit)
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

/// `addLocation`/`removeLocation` must only bump `locationsUpdatedAt` on a
/// genuine change — a no-op add (already a member) or a no-op remove (not a
/// member) must not spuriously outrun a real, unsynced edit from another
/// device in the next `FavoriteLibraryWebDAVMerger` round. `addLocation` is
/// called unconditionally on every full pull-sync
/// (`FavoriteRemoteSync.swift`'s `apply { doc in doc.addLocation(...) }`),
/// so a missing guard here is live, not theoretical.
@Test func addAndRemoveLocationDoNotBumpLocationsClockOnNoOpEdits() throws {
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "分类")
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9107")
    let baseDate = Date(timeIntervalSince1970: 1200)
    let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(category.id)], updatedAt: baseDate)
    document.upsertItem(item)
    let locationsUpdatedAtBefore = try #require(document.items.first).locationsUpdatedAt

    // Already a member — no-op add.
    document.addLocation(.category(category.id), to: target, date: baseDate.addingTimeInterval(1))
    #expect(try #require(document.items.first).locationsUpdatedAt == locationsUpdatedAtBefore)

    // Not a member — no-op remove.
    let otherCategory = document.createCategory(name: "另一分类")
    document.removeLocation(.category(otherCategory.id), from: target, date: baseDate.addingTimeInterval(2))
    #expect(try #require(document.items.first).locationsUpdatedAt == locationsUpdatedAtBefore)

    // A genuine add still bumps the clock.
    document.addLocation(.category(otherCategory.id), to: target, date: baseDate.addingTimeInterval(3))
    #expect(try #require(document.items.first).locationsUpdatedAt == baseDate.addingTimeInterval(3))
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

/// Every whole-record deletion path must record a tombstone —
/// `FavoriteLibraryWebDAVMerger` relies on these to keep a deletion from
/// being silently revived by a stale peer's union-by-id copy of the same id
/// (see `FavoriteLibraryDocument`'s `deletedItemIDs`/etc. doc comment).
@Test func favoriteLibraryDocumentDeletionsRecordTombstones() throws {
    let date = Date(timeIntervalSince1970: 500)
    var document = FavoriteLibraryDocument()
    let category = document.createCategory(name: "分类")
    let collection = document.createCollection(categoryID: category.id, name: "合集")
    let tag = document.createTag(name: "标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9101")
    let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(category.id)], updatedAt: date)
    document.upsertItem(item)

    document.dissolveCollection(id: collection.id, date: date.addingTimeInterval(1))
    #expect(document.deletedCollectionIDs[collection.id] == date.addingTimeInterval(1))

    document.deleteTag(id: tag.id, date: date.addingTimeInterval(2))
    #expect(document.deletedTagIDs[tag.id] == date.addingTimeInterval(2))

    document.removeItem(target: target, date: date.addingTimeInterval(3))
    #expect(document.deletedItemIDs[target.id] == date.addingTimeInterval(3))

    document.deleteCategory(id: category.id, date: date.addingTimeInterval(4))
    #expect(document.deletedCategoryIDs[category.id] == date.addingTimeInterval(4))
}

/// `retargetItem` abandons `oldTarget.id` (target ids double as item ids) —
/// that id must be tombstoned like any other item removal, or a stale peer
/// still holding the pre-retarget copy would be revived as a duplicate
/// favorite on the next sync. If `newTarget.id` happens to carry a stale
/// tombstone from an earlier deletion, retargeting into it must clear that
/// tombstone too, or the retargeted favorite would fail its own resurrection
/// check and vanish on the next merge.
@Test func retargetItemTombstonesTheAbandonedIDAndClearsAnyStaleTombstoneOnTheNewID() throws {
    var document = FavoriteLibraryDocument()
    let oldTarget = FavoriteItemTarget(kind: .normalThread, threadID: "9104")
    let newTarget = FavoriteItemTarget(kind: .novelThread, threadID: "9104")
    let date = Date(timeIntervalSince1970: 700)

    // newTarget.id previously belonged to a deleted item.
    let previouslyDeleted = try FavoriteItem(target: newTarget, title: "旧收藏", locations: [.category(document.defaultCategory.id)], updatedAt: date)
    document.upsertItem(previouslyDeleted)
    document.removeItem(target: newTarget, date: date.addingTimeInterval(1))
    #expect(document.deletedItemIDs[newTarget.id] != nil)

    let item = try FavoriteItem(target: oldTarget, title: "待重定向", locations: [.category(document.defaultCategory.id)], updatedAt: date.addingTimeInterval(2))
    document.upsertItem(item)

    document.retargetItem(from: oldTarget, to: newTarget, date: date.addingTimeInterval(3))

    #expect(document.deletedItemIDs[oldTarget.id] == date.addingTimeInterval(3))
    #expect(document.deletedItemIDs[newTarget.id] == nil)
    #expect(document.items.map(\.id) == [newTarget.id])
    #expect(document.items.first?.updatedAt == date.addingTimeInterval(3))
}

/// `assignTag`/`unassignTag` must bump `item.updatedAt` like every other
/// locations/tagIDs mutator — `FavoriteLibraryWebDAVMerger` resolves tagIDs
/// by last-writer-wins on this timestamp, so a silent non-bump would let a
/// stale peer's copy win the tie and undo the (un)assignment on next sync.
@Test func assignAndUnassignTagBumpUpdatedAt() throws {
    var document = FavoriteLibraryDocument()
    let tag = document.createTag(name: "标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9105")
    let baseDate = Date(timeIntervalSince1970: 800)
    let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(document.defaultCategory.id)], updatedAt: baseDate)
    document.upsertItem(item)

    document.assignTag(id: tag.id, to: target, date: baseDate.addingTimeInterval(1))
    #expect(document.items.first?.tagIDs == [tag.id])
    #expect(document.items.first?.updatedAt == baseDate.addingTimeInterval(1))

    document.unassignTag(id: tag.id, from: target, date: baseDate.addingTimeInterval(2))
    #expect(document.items.first?.tagIDs.isEmpty == true)
    #expect(document.items.first?.updatedAt == baseDate.addingTimeInterval(2))
}

/// Re-favoriting a thread reuses its (content-derived) target id — the
/// tombstone `removeItem` wrote for the earlier un-favorite must not keep
/// blackholing it once it's alive again.
@Test func upsertItemClearsAnyStaleDeletionTombstoneForTheSameTarget() throws {
    var document = FavoriteLibraryDocument()
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9102")
    let first = try FavoriteItem(target: target, title: "收藏", locations: [.category(document.defaultCategory.id)])
    document.upsertItem(first)
    document.removeItem(target: target)
    #expect(document.deletedItemIDs[target.id] != nil)

    let readded = try FavoriteItem(target: target, title: "重新收藏", locations: [.category(document.defaultCategory.id)])
    document.upsertItem(readded)

    #expect(document.deletedItemIDs[target.id] == nil)
    #expect(document.items.map(\.id) == [target.id])
}

/// `FavoriteLibraryStore.save` routes every write through `canonicalized()`,
/// which reconstructs the document to re-sort collections/tags — it must
/// carry deletion tombstones through that reconstruction rather than reset
/// them, or every tombstone would vanish the moment it's first persisted.
@Test func favoriteLibraryStoreRoundTripsDeletionTombstonesThroughSave() async throws {
    let suiteName = "FavoriteLibraryStoreTombstoneTests.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    let store = FavoriteLibraryStore(defaults: suite, key: "library")
    let date = Date(timeIntervalSince1970: 600)

    try await store.update { document in
        let category = document.createCategory(name: "待删除分类")
        let tag = document.createTag(name: "待删除标签", color: .blue)
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9103")
        let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(category.id)], updatedAt: date)
        document.upsertItem(item)
        document.removeItem(target: target, date: date.addingTimeInterval(1))
        document.deleteTag(id: tag.id, date: date.addingTimeInterval(2))
        document.deleteCategory(id: category.id, date: date.addingTimeInterval(3))
    }

    let reloaded = try await store.load()
    #expect(reloaded.deletedItemIDs.isEmpty == false)
    #expect(reloaded.deletedTagIDs.isEmpty == false)
    #expect(reloaded.deletedCategoryIDs.isEmpty == false)
}

/// A document persisted by an older build has no `deletedItemIDs`/etc. keys
/// at all (added when whole-record deletions started being tombstoned).
/// Decoding must default them to empty rather than failing — a decode
/// failure here would corrupt `FavoriteLibraryStore.load()` for every
/// existing user on first launch after the update.
@Test func favoriteLibraryDocumentDecodesPreTombstoneBlobsWithEmptyDefaults() throws {
    let legacyDocument = Data(
        """
        {
          "categories": [],
          "collections": [],
          "items": [],
          "tags": []
        }
        """.utf8
    )
    let decoded = try JSONDecoder().decode(FavoriteLibraryDocument.self, from: legacyDocument)
    #expect(decoded.categories.isEmpty)
    #expect(decoded.deletedItemIDs.isEmpty)
    #expect(decoded.deletedCategoryIDs.isEmpty)
    #expect(decoded.deletedCollectionIDs.isEmpty)
    #expect(decoded.deletedTagIDs.isEmpty)
}

/// `normalizedItem` cross-validates `tagIDs` against the live `tags` array,
/// mirroring the validation `locations` already gets against valid
/// categories/collections — a dangling tag id (one with no matching entry
/// in `tags`, e.g. surviving a peer's deletion via `FavoriteLibraryWebDAVMerger`'s
/// last-writer-wins `tagIDs` merge) must be dropped, not just deduplicated.
@Test func favoriteLibraryDocumentStripsTagIDsNotPresentInTags() throws {
    var document = FavoriteLibraryDocument()
    let tag = document.createTag(name: "标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9302")
    let item = try FavoriteItem(
        target: target,
        title: "收藏",
        locations: [.category(document.defaultCategory.id)],
        tagIDs: [tag.id, "dangling-tag-id"]
    )
    document.upsertItem(item)

    let stored = try #require(document.items.first)
    #expect(stored.tagIDs == [tag.id])
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
