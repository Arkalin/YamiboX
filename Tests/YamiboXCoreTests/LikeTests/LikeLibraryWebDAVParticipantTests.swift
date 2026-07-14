import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Test func likeLibraryWebDAVParticipantExportsLocalItemsWhenNoRemote() async throws {
    let store = LikeStore(databasePool: try makeLikeWebDAVTestDatabasePool(prefix: "like-webdav-export"))
    let participant = LikeLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "700")

    try await store.upsertTextLike(
        workKey: workKey,
        anchor: NovelTextLikeAnchor(
            chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
            textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
            range: NovelCharacterRange(location: 0, length: 4),
            view: 1,
            resolvedAuthorID: nil
        ),
        excerptText: "你好世界"
    )

    let data = try await participant.mergeAndExport(remoteData: nil, updatedAt: .now, accountUID: "acct")
    let payload = try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: data)

    #expect(payload.items.count == 1)
    #expect(payload.items.first?.excerptText == "你好世界")
    #expect(payload.tombstones.isEmpty)
}

@Test func likeLibraryWebDAVParticipantMergeDoesNotResurrectLocallyDeletedItem() async throws {
    let store = LikeStore(databasePool: try makeLikeWebDAVTestDatabasePool(prefix: "like-webdav-tombstone"))
    let participant = LikeLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "测试漫画")
    let anchor = LikeAnchorPayload.mangaImage(MangaImageLikeAnchor(chapterTID: "900", pageLocalIndex: 3))
    let sourceURL = try #require(URL(string: "https://img.example.com/page.jpg"))
    let addedAt = Date(timeIntervalSince1970: 1_000)
    let deletedAt = Date(timeIntervalSince1970: 2_000)

    let item = try await store.upsertImageLike(
        id: "shared-id",
        workKey: workKey,
        anchor: anchor,
        sourceImageURL: sourceURL,
        date: addedAt
    )
    try await store.delete(id: item.id, date: deletedAt)

    // The remote still carries the pre-deletion snapshot (older `updatedAt`, no tombstone) —
    // as if another device synced before this device's deletion ever reached it.
    let staleRemoteItem = LikeItem(
        id: "shared-id",
        workKey: workKey,
        kind: .image,
        sourceImageURL: sourceURL,
        anchor: anchor,
        createdAt: addedAt,
        updatedAt: addedAt
    )
    let remotePayload = LikeLibraryWebDAVPayload(updatedAt: addedAt, items: [staleRemoteItem], tombstones: [:])
    let remoteData = try JSONEncoder().encode(remotePayload)

    let data = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")
    let merged = try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: data)

    #expect(merged.items.contains { $0.id == "shared-id" } == false)
    #expect(merged.tombstones["shared-id"] != nil)
    #expect(await store.likes(for: workKey).isEmpty)

    let stillKnownLocally = await store.allIncludingDeleted()
    #expect(stillKnownLocally.first { $0.id == "shared-id" }?.deletedAt != nil)
}

@Test func likeLibraryWebDAVParticipantAppliesNewRemoteItemLocally() async throws {
    let store = LikeStore(databasePool: try makeLikeWebDAVTestDatabasePool(prefix: "like-webdav-newremote"))
    let participant = LikeLibraryWebDAVParticipant(store: store)
    let workKey = LikeWorkKey.novel(threadID: "701")
    let anchor = NovelTextLikeAnchor(
        chapterIdentity: NovelChapterIdentity(rawValue: "chapter-1"),
        textSegmentIdentity: NovelTextSegmentIdentity(rawValue: "chapter-1#text:0"),
        range: NovelCharacterRange(location: 0, length: 4),
        view: 1,
        resolvedAuthorID: nil
    )
    let remoteItem = LikeItem(id: "remote-only", workKey: workKey, kind: .text, excerptText: "远端专属", anchor: .novelText(anchor))
    let remotePayload = LikeLibraryWebDAVPayload(updatedAt: .now, items: [remoteItem], tombstones: [:])
    let remoteData = try JSONEncoder().encode(remotePayload)

    _ = try await participant.mergeAndExport(remoteData: remoteData, updatedAt: .now, accountUID: "acct")

    let likes = await store.likes(for: workKey)
    #expect(likes.contains { $0.id == "remote-only" })
}

@Test func likeLibraryWebDAVPayloadJSONExcludesLocalImageFileNameField() throws {
    // LikeItem never gained a local-image-filename field (LikeImageStore resolves bytes
    // purely by `LikeItem.id`), so this guards against ever adding one back to the
    // payload without excluding it — the whole point of ADR-0049's "bytes never sync".
    let workKey = LikeWorkKey.mangaTitle(cleanBookName: "本机文件测试")
    let anchor = LikeAnchorPayload.mangaImage(MangaImageLikeAnchor(chapterTID: "1", pageLocalIndex: 0))
    let sourceURL = try #require(URL(string: "https://img.example.com/page.jpg"))
    let item = LikeItem(workKey: workKey, kind: .image, sourceImageURL: sourceURL, anchor: anchor)
    let payload = LikeLibraryWebDAVPayload(updatedAt: .now, items: [item], tombstones: [:])

    let data = try JSONEncoder().encode(payload)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.localizedCaseInsensitiveContains("fileName") == false)
    // Substring-matching the raw JSON text would false-fail here: JSONEncoder
    // escapes "/" to "\/" by default, so round-trip through the decoder instead.
    let decoded = try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: data)
    #expect(decoded.items.first?.sourceImageURL == sourceURL)
}

private func makeLikeWebDAVTestDatabasePool(prefix: String) throws -> DatabasePool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    return try YamiboDatabase.openPool(rootDirectory: root)
}
