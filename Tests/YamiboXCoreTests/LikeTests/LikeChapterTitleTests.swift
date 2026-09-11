import Foundation
import Testing
@preconcurrency import GRDB
@testable import YamiboXCore

@Suite struct LikeChapterTitleTests {
    @Test func codingKeepsSnapshotAndAcceptsLegacyPayload() throws {
        let item = textItem(title: "  Chapter One\n")
        let data = try JSONEncoder().encode(item)
        #expect(try JSONDecoder().decode(LikeItem.self, from: data).chapterTitle == "Chapter One")
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "chapterTitle")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(LikeItem.self, from: legacy).chapterTitle == nil)
        #expect(textItem(title: " \n ").chapterTitle == nil)
    }

    @Test func migrationRetainsExistingRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try DatabasePool(path: root.appendingPathComponent("legacy.sqlite").path)
        var migrator = DatabaseMigrator()
        LikeDatabaseSchema.registerMigrations(in: &migrator)
        try migrator.migrate(pool, upTo: "like.v7.sync-deletions")
        let anchorJSON = String(decoding: try JSONEncoder().encode(textItem().anchor), as: UTF8.self)
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO like_items (id, work_kind, work_id, kind, excerpt_text, anchor_json, created_at, updated_at)
                VALUES ('text', 'novel', '100', 'text', 'excerpt', ?, 1000, 1000)
                """, arguments: [anchorJSON])
        }
        try migrator.migrate(pool)
        let item = try #require(await LikeStore(databasePool: pool).like(id: "text"))
        #expect(item.excerptText == "excerpt")
        #expect(item.chapterTitle == nil)
        #expect(item.createdAt == Date(timeIntervalSince1970: 1000))
    }

    @Test func backfillIsIdempotentAndPreservesUserEditsAndOrdering() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var original = textItem()
        original.chapterOrdinal = 4
        original.style = .pink
        original.note = "Keep this note"
        try await fixture.store.replaceAll([original])
        let before = try #require(await fixture.store.like(id: original.id))
        let participant = LikeLibraryWebDAVParticipant(store: fixture.store)
        let fingerprint = try await participant.readLocalFingerprint()
        var snapshot = before
        snapshot.chapterTitle = "  Chapter One \n"
        #expect(try await fixture.store.resolveChapterTitles([snapshot]))
        #expect(try await participant.readLocalFingerprint() != fingerprint)
        #expect(try await fixture.store.resolveChapterTitles([snapshot]) == false)
        snapshot.chapterTitle = "Replacement must not win"
        #expect(try await fixture.store.resolveChapterTitles([snapshot]) == false)
        var expected = before
        expected.chapterTitle = "Chapter One"
        #expect(await fixture.store.like(id: original.id) == expected)
        let reopened = LikeStore(databasePool: try YamiboDatabase.openPool(rootDirectory: fixture.root))
        #expect(await reopened.like(id: original.id) == expected)
    }

    @Test func backfillRejectsStaleAnchorsAndDeletedRows() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = textItem()
        try await fixture.store.replaceAll([item])
        var stale = textItem(chapter: "other", title: "Wrong chapter")
        #expect(try await fixture.store.resolveChapterTitles([stale]) == false)
        stale = item
        stale.workKey = .novel(threadID: "other")
        stale.chapterTitle = "Wrong work"
        #expect(try await fixture.store.resolveChapterTitles([stale]) == false)
        try await fixture.store.delete(id: item.id, date: item.updatedAt.addingTimeInterval(1))
        stale = item
        stale.chapterTitle = "Deleted chapter"
        #expect(try await fixture.store.resolveChapterTitles([stale]) == false)
        #expect(await fixture.store.like(id: item.id) == nil)
    }

    @Test func cachedTitlesUseExactPageAuthorAndSegmentThenSurviveEviction() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let items = [textItem(), imageItem(), textItem(id: "second", chapter: "second"), textItem(id: "missing", chapter: "missing")]
        try await fixture.store.replaceAll(items)
        try await fixture.cache.save(projection(author: "wrong-author", title: "Wrong author"))
        try await fixture.cache.save(projection(view: 1, title: "Wrong page"))
        #expect(await fixture.dependencies.resolveChapterInfo(for: items, work: work).isEmpty)
        try await fixture.cache.save(projection())
        let titles = await fixture.dependencies.resolveChapterInfo(for: items, work: work)
        #expect(titles == ["text": "Chapter One", "image": "Illustration", "second": "Chapter Two"])
        #expect(await fixture.store.like(id: "missing")?.chapterTitle == nil)
        try await fixture.cache.clearAll()
        let stored = await fixture.store.likes(for: work)
        #expect(await fixture.dependencies.resolveChapterInfo(for: stored, work: work) == titles)
    }

    @Test func readingAChapterBackfillsBothKindsWithoutADiskCache() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let items = [textItem(), imageItem(), textItem(id: "other-page", view: 9)]
        try await fixture.store.replaceAll(items)
        await LikeChapterInfoResolver.backfillNovelChapterTitles(in: projection(), store: fixture.store)
        #expect(await fixture.store.like(id: "text")?.chapterTitle == "Chapter One")
        #expect(await fixture.store.like(id: "image")?.chapterTitle == "Illustration")
        #expect(await fixture.store.like(id: "other-page")?.chapterTitle == nil)
    }

    @Test func mangaBackfillsFromDirectoryButKeepsCapturedTitle() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let manga = LikeWorkKey.mangaTitle(cleanBookName: "Manga")
        let item = LikeItem(id: "manga", workKey: manga, kind: .image, anchor: .mangaImage(.init(chapterTID: "22", pageLocalIndex: 0)))
        try await fixture.store.replaceAll([item])
        let directory = MangaDirectory(cleanBookName: "Manga", strategy: .links, sourceKey: "22", chapters: [
            MangaChapter(tid: "22", rawTitle: " Chapter 22 ", chapterNumber: 22)
        ])
        try await fixture.dependencies.mangaDirectoryStore.saveDirectory(directory)
        #expect(await fixture.dependencies.resolveChapterInfo(for: [item], work: manga) == [item.id: "Chapter 22"])
        let stored = try #require(await fixture.store.like(id: item.id))
        #expect(LikeChapterInfoResolver.mangaChapterInfo(for: [stored], directory: nil) == [item.id: "Chapter 22"])
    }

    @Test func textCaptureAndMergeRetainChapterSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let service = NovelTextLikeCaptureService(likeStore: fixture.store)
        let first = try await service.like(request(end: 4, title: "Chapter One"))
        guard case let .added(item) = first else { Issue.record("Expected added"); return }
        #expect(item.chapterTitle == "Chapter One")
        let repeated = try await service.like(request(end: 4, title: "Changed title"))
        guard case let .alreadyLiked(duplicate) = repeated else { Issue.record("Expected duplicate"); return }
        #expect(duplicate.id == item.id)
        #expect(duplicate.chapterTitle == "Chapter One")
        let merged = try await service.like(request(end: 8, title: nil))
        guard case let .merged(union) = merged else { Issue.record("Expected merged"); return }
        #expect(union.chapterTitle == "Chapter One")
        #expect(union.id == item.id)
        #expect(await fixture.store.likes(for: work).count == 1)
    }

    @Test func bothImageCaptureServicesPersistTitlesAndFillLegacyDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let novel = NovelImageLikeCaptureService(likeStore: fixture.store, likeImageStore: fixture.dependencies.likeImageStore)
        guard case let .novelImage(anchor) = imageItem().anchor else { return }
        let first = try await novel.like(workKey: work, anchor: anchor, sourceImageURL: nil, imageData: { Data([1]) })
        guard case let .added(item) = first else { Issue.record("Expected image"); return }
        let repeated = try await novel.like(workKey: work, anchor: anchor, sourceImageURL: nil, chapterTitle: "Illustration", imageData: {
            Issue.record("Duplicate must not reload image bytes")
            return Data()
        })
        guard case let .alreadyLiked(filled) = repeated else { Issue.record("Expected existing image"); return }
        #expect(filled.id == item.id)
        #expect(await fixture.store.like(id: item.id)?.chapterTitle == "Illustration")
        let manga = MangaImageLikeCaptureService(likeStore: fixture.store, likeImageStore: fixture.dependencies.likeImageStore)
        let result = try await manga.like(workKey: .mangaTitle(cleanBookName: "Manga"), anchor: .init(chapterTID: "22", pageLocalIndex: 1), sourceImageURL: nil, chapterTitle: "Chapter 22", imageData: { Data([2]) })
        guard case let .added(mangaItem) = result else { Issue.record("Expected manga image"); return }
        #expect(await fixture.store.like(id: mangaItem.id)?.chapterTitle == "Chapter 22")
    }

    @Test(arguments: [-1.0, 0.0, 1.0])
    func syncFillsMissingTitlesInBothDirectionsWithoutOverridingEdits(timeDelta: Double) {
        let local = textItem(title: "Chapter One")
        var remote = textItem()
        remote.updatedAt = local.updatedAt.addingTimeInterval(timeDelta)
        remote.note = "Remote note"
        remote.style = .blue
        let payload = LikeLibraryWebDAVPayload(updatedAt: remote.updatedAt, items: [remote], tombstones: [:])
        let merged = LikeLibraryWebDAVMerger().merge(localSnapshot: [local], remote: payload, updatedAt: .now)
        #expect(merged.payload.items.first?.chapterTitle == "Chapter One")
        #expect(merged.payload.items.first?.note == (timeDelta > 0 ? "Remote note" : nil))
        #expect(merged.payload.items.first?.updatedAt == max(local.updatedAt, remote.updatedAt))
        let reverse = LikeLibraryWebDAVMerger().merge(localSnapshot: [remote], remote: .init(updatedAt: local.updatedAt, items: [local], tombstones: [:]), updatedAt: .now)
        #expect(reverse.payload.items.first?.chapterTitle == "Chapter One")
    }

    @Test func syncDoesNotTransferTitlesAcrossAnchorsOrResurrectDeletedItems() {
        let local = textItem(title: "Chapter One")
        var other = textItem(chapter: "other")
        other.updatedAt = local.updatedAt.addingTimeInterval(1)
        let merger = LikeLibraryWebDAVMerger()
        let mismatch = merger.merge(localSnapshot: [local], remote: .init(updatedAt: .now, items: [other], tombstones: [:]), updatedAt: .now)
        #expect(mismatch.payload.items.first?.chapterTitle == nil)
        let deletedAt = local.updatedAt.addingTimeInterval(2)
        let deleted = merger.merge(localSnapshot: [local], remote: .init(updatedAt: .now, items: [textItem()], tombstones: [local.id: deletedAt]), updatedAt: .now)
        #expect(deleted.payload.items.isEmpty)
        #expect(deleted.payload.tombstones[local.id] == deletedAt)
    }

    @Test func syncedSnapshotDisplaysOnColdDeviceAndRequestsUploadAfterBackfill() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let participant = LikeLibraryWebDAVParticipant(store: fixture.store)
        let legacy = LikeLibraryWebDAVPayload(updatedAt: .now, items: [textItem()], tombstones: [:])
        let data = try JSONEncoder().encode(legacy)
        _ = try await participant.applyRemoteSnapshot(data)
        var snapshot = textItem(title: "Chapter One")
        snapshot.note = "Not a user edit"
        try await fixture.store.resolveChapterTitles([snapshot])
        let reapplied = try await participant.applyRemoteSnapshot(data)
        #expect(reapplied.requiresUpload)
        let exported = try await participant.mergeAndExportSnapshot(remoteData: data, updatedAt: .now, accountUID: "")
        let decoded = try JSONDecoder().decode(LikeLibraryWebDAVPayload.self, from: exported.data)
        #expect(decoded.version == LikeLibraryWebDAVPayload.currentVersion)
        #expect(decoded.items.first?.note == nil)
        #expect(decoded.items.first?.chapterTitle == "Chapter One")
        #expect(await fixture.dependencies.resolveChapterInfo(for: decoded.items, work: work) == ["text": "Chapter One"])
    }
}

private let work = LikeWorkKey.novel(threadID: "100")

private func textItem(id: String = "text", chapter: String = "first", view: Int = 2, title: String? = nil) -> LikeItem {
    LikeItem(id: id, workKey: work, kind: .text, excerptText: "excerpt", anchor: .novelText(.init(
        chapterIdentity: .init(rawValue: chapter), textSegmentIdentity: .init(rawValue: "\(chapter)#text:0"),
        range: .init(location: 0, length: 4), view: view, resolvedAuthorID: "author"
    )), chapterTitle: title, createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000))
}

private func imageItem() -> LikeItem {
    LikeItem(id: "image", workKey: work, kind: .image, anchor: .novelImage(.init(
        chapterIdentity: .init(rawValue: "first"), imageSegmentIdentity: "first#image:0", view: 2, resolvedAuthorID: "author"
    )))
}

private func request(end: Int, title: String?) -> NovelTextLikeCaptureRequest {
    let chapter = NovelChapterIdentity(rawValue: "first")
    let segment = NovelTextSegmentIdentity(rawValue: "first#text:0")
    return NovelTextLikeCaptureRequest(workKey: work,
        start: .init(chapterIdentity: chapter, textSegmentIdentity: segment, displayedTextOffset: 0, progressInTextRange: 0),
        end: .init(chapterIdentity: chapter, textSegmentIdentity: segment, displayedTextOffset: end, progressInTextRange: 0),
        excerptText: "excerpt", view: 2, resolvedAuthorID: "author", chapterTitle: title)
}

private func projection(view: Int = 2, author: String = "author", title: String = "Chapter One") -> NovelReaderProjection {
    NovelReaderProjection(threadID: work.id, view: view, maxView: 9, resolvedAuthorID: author,
        segments: [.text("excerpt", chapterTitle: title), .image(URL(string: "https://example.com/image.png")!, chapterTitle: "Illustration"), .text("second", chapterTitle: "Chapter Two")],
        segmentSemantics: [
            .init(chapterIdentity: .init(rawValue: "first"), textSegmentIdentity: .init(rawValue: "first#text:0")),
            .init(chapterIdentity: .init(rawValue: "first"), textSegmentIdentity: .init(rawValue: "first#image:0")),
            .init(chapterIdentity: .init(rawValue: "second"), textSegmentIdentity: .init(rawValue: "second#text:0"))
        ])
}

private struct Fixture {
    let root: URL
    let store: LikeStore
    let cache: NovelReaderProjectionStore
    let dependencies: LikeDependencies

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("like-chapters-\(UUID().uuidString)")
        let pool = try YamiboDatabase.openPool(rootDirectory: root)
        store = LikeStore(databasePool: pool)
        cache = NovelReaderProjectionStore(databasePool: pool, rootDirectory: root)
        dependencies = LikeDependencies(likeStore: store, likeImageStore: LikeImageStore(baseDirectory: root.appendingPathComponent("images")), bookmarkStore: BookmarkStore(databasePool: pool), mangaDirectoryStore: MangaDirectoryStore(databasePool: pool), novelReaderCacheStore: cache)
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
