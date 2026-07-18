import Foundation
import Testing
@testable import YamiboXCore

@Test func favoriteLibraryWebDAVPayloadExcludesProgressAuthLogsAndCoverBytes() throws {
    let payload = FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 1),
        accountUID: "uid",
        library: FavoriteLibraryDocument()
    )

    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["library"] != nil)
    #expect(object["readingProgress"] == nil)
    #expect(object["auth"] == nil)
    #expect(object["logs"] == nil)
    #expect(object["coverBytes"] == nil)
}

/// `locations` and `tagIDs` are each last-writer-wins by their own dedicated
/// clock (`FavoriteItem.locationsUpdatedAt`/`tagIDsUpdatedAt`), not a union
/// — see `FavoriteLibraryWebDAVMerger.mergeItems`'s own doc comment for why
/// a union (subtracting a tombstone set nothing in the codebase ever wrote
/// to) let a favorite moved — or a tag removed — on one device silently
/// reappear on the next sync. Unlike the item's overall `updatedAt`, these
/// two clocks are independent, so this test bumps both explicitly to keep
/// "remote is older on both fields" unambiguous.
@Test func favoriteLibraryWebDAVMergeTagIDsUseLastWriterWinsAlongsideLocations() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "1001")
    let baseDate = Date(timeIntervalSince1970: 10)
    var localDocument = FavoriteLibraryDocument()
    let category = localDocument.createCategory(name: "分类")
    let collection = localDocument.createCollection(categoryID: category.id, name: "合集")
    let tag = localDocument.createTag(name: "标签", color: .blue)
    let localItem = try FavoriteItem(
        target: target,
        title: "主题",
        locations: [.category(category.id)],
        tagIDs: [tag.id],
        updatedAt: baseDate.addingTimeInterval(5)
    )
    localDocument.upsertItem(localItem)

    var remoteDocument = localDocument
    var remoteItem = localItem
    remoteItem.locations = [.collection(categoryID: category.id, collectionID: collection.id)]
    remoteItem.tagIDs = []
    remoteItem.updatedAt = baseDate
    remoteItem.locationsUpdatedAt = baseDate
    remoteItem.tagIDsUpdatedAt = baseDate
    remoteDocument.items = [remoteItem]

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(5), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(10)
    )

    let item = try #require(merged.library.items.first)
    // Local is newer on both fields' own clocks, so its whole `locations`
    // and `tagIDs` win outright — the remote's (older, stale) collection
    // membership and empty tag list are discarded entirely rather than
    // unioned in.
    #expect(item.locations == [.category(category.id)])
    #expect(item.tagIDs == [tag.id])
}

/// Regression test for the design gap the per-field clocks fix: before
/// them, `locations` and `tagIDs` shared one last-writer-wins decision keyed
/// on the item's overall `updatedAt`, so two devices making legitimate,
/// non-conflicting edits to *different* fields could clobber each other —
/// whichever device's edit happened to be chronologically later would win
/// both fields, silently discarding the other device's unrelated change.
@Test func favoriteLibraryWebDAVMergeKeepsConcurrentNonConflictingLocationAndTagEditsFromBothSides() throws {
    var sharedDocument = FavoriteLibraryDocument()
    let originalCategory = sharedDocument.defaultCategory
    let newCategory = sharedDocument.createCategory(name: "新分类")
    let tag = sharedDocument.createTag(name: "标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "7001")
    let baseDate = Date(timeIntervalSince1970: 900)
    let item = try FavoriteItem(target: target, title: "收藏", locations: [.category(originalCategory.id)], updatedAt: baseDate)
    sharedDocument.upsertItem(item)

    // Local moves the item to a new category at T+60.
    var localDocument = sharedDocument
    localDocument.addLocation(.category(newCategory.id), to: target, date: baseDate.addingTimeInterval(60))
    localDocument.removeLocation(.category(originalCategory.id), from: target, date: baseDate.addingTimeInterval(60))

    // Remote, unaware of the move, tags the same item later at T+120 — a
    // legitimate, unrelated, chronologically later edit that under the old
    // shared-clock design would have won outright and silently reverted
    // local's move.
    var remoteDocument = sharedDocument
    remoteDocument.assignTag(id: tag.id, to: target, date: baseDate.addingTimeInterval(120))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(60), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    let mergedItem = try #require(merged.library.items.first { $0.target == target })
    // Both edits survive: local's move AND remote's (chronologically later,
    // but unrelated) tag.
    #expect(mergedItem.locations == [.category(newCategory.id)])
    #expect(mergedItem.tagIDs == [tag.id])
}

/// Ties (equal `updatedAt` on both sides) favor local, mirroring
/// `newerItem`'s own tie-breaking convention for same-side duplicates.
@Test func favoriteLibraryWebDAVMergeLocationsTieFavorsLocal() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "1001b")
    let tiedDate = Date(timeIntervalSince1970: 10)
    var localDocument = FavoriteLibraryDocument()
    let localCategory = localDocument.createCategory(name: "本地分类")
    let remoteCategory = localDocument.createCategory(name: "远端分类")
    let localItem = try FavoriteItem(target: target, title: "主题", locations: [.category(localCategory.id)], updatedAt: tiedDate)
    localDocument.upsertItem(localItem)

    var remoteDocument = localDocument
    var remoteItem = localItem
    remoteItem.locations = [.category(remoteCategory.id)]
    remoteDocument.items = [remoteItem]

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: tiedDate, library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: tiedDate, library: remoteDocument),
        updatedAt: tiedDate.addingTimeInterval(1)
    )

    let item = try #require(merged.library.items.first)
    #expect(item.locations == [.category(localCategory.id)])
}

/// Direct regression test for the favorites-page bug this last-writer-wins
/// design replaced the union+tombstone one to fix: a favorite moved to a new
/// category on this device, followed by a sync round whose remote payload is
/// still the stale pre-move snapshot (the previous upload), must not leave
/// the item sitting in both the old and new location.
@Test func favoriteLibraryWebDAVMergeDoesNotReviveLocationRemovedByANewerLocalMove() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9001")
    let baseDate = Date(timeIntervalSince1970: 100)

    var remoteDocument = FavoriteLibraryDocument()
    let source = remoteDocument.createCategory(name: "原分类")
    let destination = remoteDocument.createCategory(name: "新分类")
    let itemBeforeMove = try FavoriteItem(
        target: target,
        title: "被移动的收藏",
        locations: [.category(source.id)],
        updatedAt: baseDate
    )
    remoteDocument.upsertItem(itemBeforeMove)

    var localDocument = remoteDocument
    var moved = itemBeforeMove
    moved.locations = [.category(destination.id)]
    moved.updatedAt = baseDate.addingTimeInterval(60)
    localDocument.items = [moved]

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    let item = try #require(merged.library.items.first { $0.target == target })
    #expect(item.locations == [.category(destination.id)])
}

/// Whole-record deletions (category/collection/tag/item) are the same class
/// of bug the locations fix above addresses, but for existence rather than a
/// field: a stale peer that still has the id would otherwise revive it via
/// the plain union-by-id merge — see `FavoriteLibraryDocument`'s
/// `deletedItemIDs`/etc. doc comment and each `mergeCategories`/
/// `mergeCollections`/`mergeTags`/`mergeItems` tombstone check.
@Test func favoriteLibraryWebDAVMergeDoesNotReviveCategoryDeletedSincePriorSync() throws {
    let baseDate = Date(timeIntervalSince1970: 200)
    var remoteDocument = FavoriteLibraryDocument()
    let category = remoteDocument.createCategory(name: "待删除分类")

    var localDocument = remoteDocument
    localDocument.deleteCategory(id: category.id, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.categories.contains { $0.id == category.id } == false)
}

@Test func favoriteLibraryWebDAVMergeDoesNotReviveCollectionDissolvedSincePriorSync() throws {
    let baseDate = Date(timeIntervalSince1970: 200)
    var remoteDocument = FavoriteLibraryDocument()
    let category = remoteDocument.createCategory(name: "分类")
    let collection = remoteDocument.createCollection(categoryID: category.id, name: "待解散合集")

    var localDocument = remoteDocument
    localDocument.dissolveCollection(id: collection.id, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.collections.contains { $0.id == collection.id } == false)
}

@Test func favoriteLibraryWebDAVMergeDoesNotReviveTagDeletedSincePriorSync() throws {
    let baseDate = Date(timeIntervalSince1970: 200)
    var remoteDocument = FavoriteLibraryDocument()
    let tag = remoteDocument.createTag(name: "待删除标签", color: .blue)

    var localDocument = remoteDocument
    localDocument.deleteTag(id: tag.id, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.tags.contains { $0.id == tag.id } == false)
}

/// A tag deleted (and tombstoned) on one device can still be present in
/// another device's item — its own `tagIDsUpdatedAt` may be later, so the
/// merge picks that side's *whole* `tagIDs` array via last-writer-wins,
/// which would otherwise carry the now-nonexistent tag id forward as a
/// dangling reference forever (`locations` already gets this same
/// cross-validation against valid categories/collections; `tagIDs` used to
/// only be deduplicated, never validated against the live `tags` list).
@Test func favoriteLibraryWebDAVMergeStripsDanglingTagIDsAfterMergingATagDeletedOnTheOtherSide() throws {
    var sharedDocument = FavoriteLibraryDocument()
    let tag = sharedDocument.createTag(name: "待删除标签", color: .blue)
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "9301")
    let baseDate = Date(timeIntervalSince1970: 1300)
    let item = try FavoriteItem(
        target: target,
        title: "收藏",
        locations: [.category(sharedDocument.defaultCategory.id)],
        tagIDs: [tag.id],
        updatedAt: baseDate
    )
    sharedDocument.upsertItem(item)

    // Remote deletes the tag — tombstoned, and remote's own copy of the
    // item's tagIDs is cleaned up there too, but local never sees any of it.
    var remoteDocument = sharedDocument
    remoteDocument.deleteTag(id: tag.id, date: baseDate.addingTimeInterval(60))

    // Local, unaware of the deletion, has a later `tagIDsUpdatedAt` on its
    // (stale, still-tagged) copy of the item — forcing local's tagIDs to win
    // the last-writer-wins race despite the tag being gone everywhere else.
    var localDocument = sharedDocument
    localDocument.items[0].tagIDsUpdatedAt = baseDate.addingTimeInterval(120)

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(60), library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.tags.contains { $0.id == tag.id } == false)
    let mergedItem = try #require(merged.library.items.first { $0.target == target })
    #expect(mergedItem.tagIDs.contains(tag.id) == false)
}

@Test func favoriteLibraryWebDAVMergeDoesNotReviveItemDeletedSincePriorSync() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "5001")
    let baseDate = Date(timeIntervalSince1970: 200)
    var remoteDocument = FavoriteLibraryDocument()
    let item = try FavoriteItem(target: target, title: "待删除收藏", locations: [.category(remoteDocument.defaultCategory.id)], updatedAt: baseDate)
    remoteDocument.upsertItem(item)

    var localDocument = remoteDocument
    localDocument.removeItem(target: target, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.items.contains { $0.target == target } == false)
    #expect(merged.library.deletedItemIDs[target.id] != nil)
}

/// A thread's target id is content-derived (`FavoriteItemTarget.id`), so
/// un-favoriting then re-favoriting the same thread reuses the same id and
/// must be able to outrun its own (now stale) deletion tombstone — the
/// tombstone must not permanently blackhole a legitimately re-added item.
@Test func favoriteLibraryWebDAVMergeKeepsItemReFavoritedAfterItsOwnOlderDeletionTombstone() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "5002")
    let baseDate = Date(timeIntervalSince1970: 300)

    // Remote is stale: still has the original, never-deleted copy.
    var remoteDocument = FavoriteLibraryDocument()
    let originalItem = try FavoriteItem(target: target, title: "旧标题", locations: [.category(remoteDocument.defaultCategory.id)], updatedAt: baseDate)
    remoteDocument.upsertItem(originalItem)

    // Local: un-favorited, then re-favorited the same thread later.
    var localDocument = remoteDocument
    localDocument.removeItem(target: target, date: baseDate.addingTimeInterval(60))
    let readdedItem = try FavoriteItem(
        target: target,
        title: "新标题",
        locations: [.category(localDocument.defaultCategory.id)],
        updatedAt: baseDate.addingTimeInterval(120)
    )
    localDocument.upsertItem(readdedItem)

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(180), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(180)
    )

    let item = try #require(merged.library.items.first { $0.target == target })
    #expect(item.title == "新标题")
    #expect(merged.library.deletedItemIDs[target.id] == nil)
}

/// `retargetItem` changes an item's identity (target ids double as item
/// ids) — the abandoned old id must be tombstoned like any other item
/// removal, or a stale peer still holding the pre-retarget copy (e.g. this
/// device's own prior WebDAV upload) would be revived as a duplicate
/// favorite on the next sync.
@Test func favoriteLibraryWebDAVMergeDoesNotReviveItemUnderItsOldRetargetedID() throws {
    let oldTarget = FavoriteItemTarget(kind: .normalThread, threadID: "6001")
    let newTarget = FavoriteItemTarget(kind: .novelThread, threadID: "6001")
    let baseDate = Date(timeIntervalSince1970: 400)

    var remoteDocument = FavoriteLibraryDocument()
    let original = try FavoriteItem(target: oldTarget, title: "原分类收藏", locations: [.category(remoteDocument.defaultCategory.id)], updatedAt: baseDate)
    remoteDocument.upsertItem(original)

    var localDocument = remoteDocument
    localDocument.retargetItem(from: oldTarget, to: newTarget, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.items.contains { $0.target == oldTarget } == false)
    #expect(merged.library.items.contains { $0.target == newTarget })
}

/// `deleteCategory` only cascade-tombstones the collections it already
/// knows about; a collection a peer created under the same category
/// concurrently — before ever syncing that deletion — has no tombstone of
/// its own. `mergeCollections` must still exclude it once its category is
/// gone post-merge, or it becomes a permanently orphaned, UI-unreachable row
/// that gets re-encoded on every future sync.
@Test func favoriteLibraryWebDAVMergeExcludesCollectionOrphanedByCascadeCategoryDeletion() throws {
    let baseDate = Date(timeIntervalSince1970: 400)
    var sharedDocument = FavoriteLibraryDocument()
    let category = sharedDocument.createCategory(name: "共享分类")

    var remoteDocument = sharedDocument
    let orphanCollection = remoteDocument.createCollection(categoryID: category.id, name: "并发创建的合集")

    var localDocument = sharedDocument
    localDocument.deleteCategory(id: category.id, date: baseDate.addingTimeInterval(60))

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: baseDate.addingTimeInterval(120), library: localDocument),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: baseDate, library: remoteDocument),
        updatedAt: baseDate.addingTimeInterval(120)
    )

    #expect(merged.library.categories.contains { $0.id == category.id } == false)
    #expect(merged.library.collections.contains { $0.id == orphanCollection.id } == false)
}

/// `displayName` and `remoteMapping` each merge by their own dedicated
/// per-field clock (`FavoriteItem.displayNameUpdatedAt`/`remoteMappingUpdatedAt`),
/// independent of the item's overall `updatedAt` — so even though remote's
/// payload/item is newer overall, a field whose own clock says local is
/// more recent must still resolve to local's value.
@Test func favoriteLibraryWebDAVMergeUsesFieldDomainClocks() throws {
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "1002")
    let localClock = Date(timeIntervalSince1970: 20)
    let remoteClock = Date(timeIntervalSince1970: 30)
    let localItem = try FavoriteItem(
        target: target,
        title: "主题",
        displayName: "本地名",
        forumID: "10",
        forumName: "本地版块",
        contentUpdatedAt: Date(timeIntervalSince1970: 100),
        remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "local"),
        locations: [.category(FavoriteCategory.defaultID)],
        updatedAt: localClock,
        displayNameUpdatedAt: remoteClock,
        remoteMappingUpdatedAt: localClock
    )
    var remoteItem = localItem
    remoteItem.displayName = "远端名"
    remoteItem.forumID = "10"
    remoteItem.forumName = "远端版块"
    remoteItem.contentUpdatedAt = Date(timeIntervalSince1970: 200)
    remoteItem.remoteMapping = FavoriteRemoteMapping(yamiboFavoriteID: "remote")
    remoteItem.updatedAt = remoteClock
    remoteItem.displayNameUpdatedAt = localClock
    remoteItem.remoteMappingUpdatedAt = remoteClock

    let merged = FavoriteLibraryWebDAVMerger().merge(
        local: FavoriteLibraryWebDAVPayload(updatedAt: localClock, library: FavoriteLibraryDocument(items: [localItem])),
        remote: FavoriteLibraryWebDAVPayload(updatedAt: remoteClock, library: FavoriteLibraryDocument(items: [remoteItem])),
        updatedAt: remoteClock.addingTimeInterval(1)
    )

    let item = try #require(merged.library.items.first)
    // displayName's own clock favors local (remoteClock > localClock on
    // local's side) even though remote's item is otherwise newer.
    #expect(item.displayName == "本地名")
    #expect(item.forumID == "10")
    #expect(item.forumName == "本地版块")
    #expect(item.contentUpdatedAt == Date(timeIntervalSince1970: 200))
    // remoteMapping's own clock favors remote.
    #expect(item.remoteMapping?.yamiboFavoriteID == "remote")
}

@Test func readingProgressWebDAVMergeUsesStableTargetIdentityAndNewestRecord() throws {
    let target = FavoriteContentTarget(mangaCleanBookName: "清理后的书名")
    let older = ReadingProgressRecord(
        contentTarget: target,
        threadID: "1101",
        kind: .manga,
        updatedAt: Date(timeIntervalSince1970: 10),
        manga: MangaReadingProgressRecord(
            chapterThreadID: "1101",
            lastChapter: "第一话",
            mangaPageIndex: 1,
            mangaPageCount: 8
        )
    )
    var newer = older
    newer.updatedAt = Date(timeIntervalSince1970: 20)
    newer.manga = MangaReadingProgressRecord(
        chapterThreadID: "1101",
        lastChapter: "第一话",
        mangaPageIndex: 7,
        mangaPageCount: 10
    )

    let merged = ReadingProgressWebDAVMerger().merge(
        local: ReadingProgressWebDAVPayload(updatedAt: older.updatedAt, records: [older]),
        remote: ReadingProgressWebDAVPayload(updatedAt: newer.updatedAt, records: [newer]),
        updatedAt: Date(timeIntervalSince1970: 30)
    )

    let record = try #require(merged.records.first)
    #expect(record.id == target.id)
    #expect(record.manga?.mangaPageIndex == 7)
    #expect(record.manga?.mangaPageCount == 10)
}

@Test func readingProgressWebDAVPayloadWritesTidFirstSchemaWithoutURLFields() throws {
    let payload = ReadingProgressWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 40),
        records: [
            ReadingProgressRecord(
                contentTarget: FavoriteContentTarget(kind: .novelThread, threadID: "1201"),
                threadID: "1201",
                kind: .novel,
                updatedAt: Date(timeIntervalSince1970: 41),
                novel: NovelReadingProgressRecord(lastView: 4, lastChapter: "第四章")
            ),
            ReadingProgressRecord(
                contentTarget: FavoriteContentTarget(mangaID: "manga-1", mangaCleanBookName: "漫画"),
                threadID: "1201",
                kind: .manga,
                updatedAt: Date(timeIntervalSince1970: 42),
                manga: MangaReadingProgressRecord(
                    chapterThreadID: "1202",
                    chapterView: 2,
                    lastChapter: "第二话",
                    mangaPageIndex: 3,
                    mangaPageCount: 8
                )
            ),
        ]
    )

    let data = try JSONEncoder().encode(payload)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try #require(object["records"] as? [[String: Any]])
    let novelRecord = try #require(records.first { ($0["kind"] as? String) == ReadingProgressKind.novel.rawValue })
    let mangaRecord = try #require(records.first { ($0["kind"] as? String) == ReadingProgressKind.manga.rawValue })
    let novelTarget = try #require(novelRecord["contentTarget"] as? [String: Any])
    let manga = try #require(mangaRecord["manga"] as? [String: Any])

    #expect(object["version"] as? Int == ReadingProgressWebDAVPayload.currentVersion)
    #expect(novelTarget["threadID"] as? String == "1201")
    #expect(mangaRecord["threadID"] as? String == "1201")
    #expect(manga["chapterThreadID"] as? String == "1202")
    #expect(manga["chapterView"] as? Int == 2)

    let decoded = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: data)
    #expect(decoded.records.count == 2)
    #expect(decoded.records.first { $0.kind == .novel }?.threadID == "1201")
    #expect(decoded.records.first { $0.kind == .manga }?.manga?.chapterThreadID == "1202")
    #expect(decoded.records.first { $0.kind == .manga }?.manga?.chapterView == 2)
}

/// A payload written by a pre-this-increment build still carries the
/// now-removed top-level `tombstones`/`clocks` envelope keys (superseded by
/// `FavoriteLibraryDocument`'s own tombstones and `FavoriteItem`'s own
/// per-field clocks) — decoding must tolerate and ignore them rather than
/// fail, or the last payload any such build ever wrote would become
/// unreadable the moment this build ships.
@Test func favoriteLibraryWebDAVPayloadToleratesLegacyTombstonesAndClocksEnvelopeKeys() throws {
    let legacyPayload = Data(
        """
        {
          "version": 2,
          "updatedAt": 50,
          "library": { "categories": [], "collections": [], "items": [], "tags": [] },
          "tombstones": { "removedLocationsByTargetID": {}, "removedTagIDsByTargetID": {} },
          "clocks": { "displayNameUpdatedAtByTargetID": {}, "remoteMappingUpdatedAtByTargetID": {} }
        }
        """.utf8
    )

    let decoded = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: legacyPayload)
    #expect(decoded.version == 2)
    #expect(decoded.updatedAt == Date(timeIntervalSinceReferenceDate: 50))
    #expect(decoded.library.items.isEmpty)
}

/// Payloads written before revisions existed carry no `syncRevision`; they
/// must keep decoding (revision nil), and the service-injected envelope field
/// must round-trip through each payload's decoder.
@Test func webDAVPayloadEnvelopesTolerateMissingSyncRevisionAndRoundTripInjectedOnes() throws {
    let exported = try JSONEncoder().encode(FavoriteLibraryWebDAVPayload(
        updatedAt: Date(timeIntervalSince1970: 1),
        accountUID: "uid",
        library: FavoriteLibraryDocument()
    ))
    // Participants export without a revision, so the wire format is identical
    // to what pre-revision builds wrote; decoding it must yield a nil
    // revision instead of failing.
    let exportedObject = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
    #expect(exportedObject["syncRevision"] == nil)
    let decodedLegacy = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: exported)
    #expect(decodedLegacy.syncRevision == nil)

    // The sync service stamps the revision into the exported envelope; the
    // stamped payload must decode with the revision and unchanged content.
    let stamped = WebDAVPayloadEnvelope.injectingSyncRevision(7, into: exported)
    let decodedStamped = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: stamped)
    #expect(decodedStamped.syncRevision == 7)
    #expect(decodedStamped.library == decodedLegacy.library)
    #expect(decodedStamped.updatedAt == decodedLegacy.updatedAt)
    #expect(decodedStamped.accountUID == "uid")

    let stampedProgress = WebDAVPayloadEnvelope.injectingSyncRevision(
        9,
        into: try JSONEncoder().encode(ReadingProgressWebDAVPayload(updatedAt: Date(timeIntervalSince1970: 2), records: []))
    )
    #expect(try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: stampedProgress).syncRevision == 9)

    let stampedLikes = WebDAVPayloadEnvelope.injectingSyncRevision(
        11,
        into: try JSONEncoder().encode(LikeLibraryWebDAVPayload(updatedAt: Date(timeIntervalSince1970: 3), items: [], tombstones: [:]))
    )
    #expect(try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: stampedLikes).syncRevision == 11)

    let stampedAppSettings = WebDAVPayloadEnvelope.injectingSyncRevision(
        13,
        into: try JSONEncoder().encode(AppSettingsWebDAVPayload(
            updatedAt: Date(timeIntervalSince1970: 4),
            appSettings: WebDAVSyncedAppSettings(homePage: .forum, webBrowser: WebBrowserSettings())
        ))
    )
    #expect(try JSONDecoder().decode(AppSettingsWebDAVPayload.self, from: stampedAppSettings).syncRevision == 13)

    // Non-JSON-object data degrades to the unstamped bytes instead of failing
    // the round.
    let notAnObject = Data("[1, 2, 3]".utf8)
    #expect(WebDAVPayloadEnvelope.injectingSyncRevision(1, into: notAnObject) == notAnObject)
}

/// A settings blob stored by a pre-revision build has no revision dictionaries
/// (and possibly none of the later bookkeeping fields at all). It must decode
/// with defaults instead of failing — a decode failure would reset the store
/// and silently drop the user's WebDAV credentials.
@Test func webDAVSyncSettingsDecodePreRevisionBlobsPreservingCredentialsAndBookkeeping() throws {
    let preRevisionBlob = Data(
        """
        {
          "baseURLString": "https://dav.example.com",
          "username": "admin",
          "password": "secret",
          "isAutoSyncEnabled": true,
          "localUpdatedAt": 1000,
          "dirtyDatasetIDs": ["favoriteLibrary"],
          "lastSyncedFingerprintByDatasetID": {"favoriteLibrary": "abc"},
          "lastAppliedRemoteUpdatedAtByDatasetID": {"favoriteLibrary": 900}
        }
        """.utf8
    )
    let decoded = try JSONDecoder().decode(WebDAVSyncSettings.self, from: preRevisionBlob)
    #expect(decoded.baseURLString == "https://dav.example.com")
    #expect(decoded.username == "admin")
    #expect(decoded.password == "secret")
    #expect(decoded.isAutoSyncEnabled)
    #expect(decoded.localUpdatedAt == Date(timeIntervalSinceReferenceDate: 1000))
    #expect(decoded.dirtyDatasetIDs == ["favoriteLibrary"])
    #expect(decoded.lastSyncedFingerprintByDatasetID == ["favoriteLibrary": "abc"])
    #expect(decoded.lastAppliedRemoteUpdatedAtByDatasetID == ["favoriteLibrary": Date(timeIntervalSinceReferenceDate: 900)])
    #expect(decoded.localRevisionByDatasetID.isEmpty)
    #expect(decoded.lastAppliedRemoteRevisionByDatasetID.isEmpty)

    // Even older shape: only the credential fields exist.
    let minimalBlob = Data(
        """
        {
          "baseURLString": "https://dav.example.com",
          "username": "admin",
          "password": "secret",
          "isAutoSyncEnabled": false
        }
        """.utf8
    )
    let minimal = try JSONDecoder().decode(WebDAVSyncSettings.self, from: minimalBlob)
    #expect(minimal.username == "admin")
    #expect(minimal.dirtyDatasetIDs.isEmpty)
    #expect(minimal.localRevisionByDatasetID.isEmpty)
    #expect(minimal.lastAppliedRemoteRevisionByDatasetID.isEmpty)

    // Round-trip: the revision dictionaries survive encode/decode.
    var withRevisions = decoded
    withRevisions.localRevisionByDatasetID = ["favoriteLibrary": 3]
    withRevisions.lastAppliedRemoteRevisionByDatasetID = ["favoriteLibrary": 5]
    let roundTripped = try JSONDecoder().decode(
        WebDAVSyncSettings.self,
        from: try JSONEncoder().encode(withRevisions)
    )
    #expect(roundTripped == withRevisions)
}

@Test func localFirstWebDAVPayloadsRejectLegacyOrMissingVersions() throws {
    let legacyProgress = Data(
        """
        {
          "version": 1,
          "updatedAt": 0,
          "records": [
            {
              "threadID": "1301",
              "kind": "novel",
              "updatedAt": 0
            }
          ]
        }
        """.utf8
    )
    let missingVersionLibrary = Data(
        """
        {
          "updatedAt": 0,
          "library": {}
        }
        """.utf8
    )

    #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(1)) {
        _ = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: legacyProgress)
    }
    #expect(throws: WebDAVSyncError.unsupportedPayloadVersion(0)) {
        _ = try JSONDecoder().decode(FavoriteLibraryWebDAVPayload.self, from: missingVersionLibrary)
    }
}
