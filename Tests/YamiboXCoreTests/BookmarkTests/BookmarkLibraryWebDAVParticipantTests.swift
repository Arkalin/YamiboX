import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

private func testAnchor(offset: Int = 0) -> BookmarkAnchorPayload {
    .novel(
        NovelBookmarkAnchor(
            chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
            displayedTextOffset: offset,
            view: 1,
            chapterOrdinal: 0
        )
    )
}

@Test func bookmarkLibraryWebDAVParticipantExportsLocalItemsWhenNoRemote() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkWebDAVTestDatabasePool(prefix: "bookmark-webdav-export"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "700")
    try await store.toggle(workKey: workKey, anchor: testAnchor(), excerptText: "首行快照")

    let data = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "acct")
    let payload = try JSONDecoder().decode(BookmarkLibraryWebDAVPayload.self, from: data)

    #expect(payload.items.count == 1)
    #expect(payload.items.first?.excerptText == "首行快照")
    #expect(payload.tombstones.isEmpty)
}

@Test func bookmarkLibraryWebDAVParticipantMergeDoesNotResurrectLocallyDeletedBookmark() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkWebDAVTestDatabasePool(prefix: "bookmark-webdav-tombstone"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "701")
    let anchor = testAnchor(offset: 42)
    let addedAt = Date(timeIntervalSince1970: 1_000)
    let deletedAt = Date(timeIntervalSince1970: 2_000)

    let added = try await store.toggle(workKey: workKey, anchor: anchor, date: addedAt)
    try await store.delete(id: added.item.id, date: deletedAt)

    // The remote still carries the pre-deletion snapshot (older `updatedAt`,
    // no tombstone) — as if another device synced before this device's
    // deletion ever reached it.
    let staleRemoteItem = BookmarkItem(
        id: added.item.id,
        workKey: workKey,
        anchor: anchor,
        createdAt: addedAt,
        updatedAt: addedAt
    )
    let remotePayload = BookmarkLibraryWebDAVPayload(updatedAt: addedAt, items: [staleRemoteItem], tombstones: [:])
    let remoteData = try JSONEncoder().encode(remotePayload)

    let data = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")
    let merged = try JSONDecoder().decode(BookmarkLibraryWebDAVPayload.self, from: data)

    #expect(merged.items.contains { $0.id == added.item.id } == false)
    #expect(merged.tombstones[added.item.id] != nil)
    #expect(await store.bookmarks(for: workKey).isEmpty)
}

@Test func bookmarkLibraryWebDAVParticipantAppliesNewRemoteBookmarkLocally() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkWebDAVTestDatabasePool(prefix: "bookmark-webdav-newremote"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "702")
    let remoteItem = BookmarkItem(id: "remote-only", workKey: workKey, anchor: testAnchor(), excerptText: "远端专属")
    let remotePayload = BookmarkLibraryWebDAVPayload(updatedAt: .now, items: [remoteItem], tombstones: [:])
    let remoteData = try JSONEncoder().encode(remotePayload)

    _ = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")

    #expect(await store.bookmarks(for: workKey).contains { $0.id == "remote-only" })
}

@Test func bookmarkLibraryWebDAVPayloadRejectsUnknownVersion() throws {
    // The version guard is what lets a future payload change fail loudly on an
    // old client instead of being silently flattened, so it must stay strict.
    let json = #"{"version":99,"updatedAt":0,"items":[],"tombstones":{}}"#
    let data = try #require(json.data(using: .utf8))

    #expect(throws: WebDAVSyncError.self) {
        _ = try JSONDecoder().decode(BookmarkLibraryWebDAVPayload.self, from: data)
    }
}

@Test func bookmarkLibraryWebDAVParticipantMarksDatasetDirtyAfterADeleteAlone() async throws {
    let store = BookmarkStore(databasePool: try makeBookmarkWebDAVTestDatabasePool(prefix: "bookmark-webdav-fingerprint"))
    let participant = BookmarkLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "703")
    let added = try await store.toggle(workKey: workKey, anchor: testAnchor())

    let afterAdd = await participant.localFingerprint()
    try await store.delete(id: added.item.id)
    let afterDelete = await participant.localFingerprint()

    // The fingerprint covers soft-deleted rows too; otherwise deleting the only
    // bookmark would leave the dataset looking unchanged and never upload.
    #expect(afterAdd != nil)
    #expect(afterAdd != afterDelete)
}

private func makeBookmarkWebDAVTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}
