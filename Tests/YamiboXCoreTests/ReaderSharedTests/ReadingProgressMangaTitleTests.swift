import Foundation
import Testing
@testable import YamiboXCore

// Moved out of the deleted FavoriteMangaItemPathTests.swift during the
// smart-comic-mode Phase A type refactor (2026-07-08): these three tests
// exercise ReadingProgressStore's directory-level `.mangaTitle` rename/
// retarget mechanism, which is completely unaffected by the favorites-side
// FavoriteItemTarget split (decision #9's second correction) — the rest of
// that file tested the deleted `addMangaTitleFavorite`/
// `importMangaChapterFavorite` favorites mechanism and was dropped entirely,
// but these reading-progress-only cases are still valid regression coverage
// for behavior that was explicitly kept "原样不动" (unchanged).

@Test func mangaDirectoryRenameMigratesReadingProgressMangaTitleKey() async throws {
    let suite = try #require(UserDefaults(suiteName: "FavoriteMangaItemPathTests.\(UUID().uuidString)"))
    let store = ReadingProgressStore(defaults: suite, key: "progress")

    _ = try await store.saveMangaTitle(
        cleanBookName: "Old Title",
        chapterThreadID: "525",
        chapterTitle: "第5话",
        pageIndex: 4
    )
    try await store.migrateMangaTitleKey(from: "Old Title", to: "New Title")

    let oldRecord = await store.load(for: FavoriteContentTarget(mangaCleanBookName: "Old Title"))
    let newRecord = await store.load(for: FavoriteContentTarget(mangaCleanBookName: "New Title"))
    #expect(oldRecord == nil)
    #expect(newRecord?.manga?.chapterThreadID == "525")
    #expect(newRecord?.manga?.chapterView == 1)
    #expect(newRecord?.manga?.mangaPageIndex == 4)
}

@Test func mangaDirectoryRenameUpdatesStableReadingProgressDisplayNameInPlace() async throws {
    let suite = try #require(UserDefaults(suiteName: "FavoriteMangaStableProgressTests.\(UUID().uuidString)"))
    let store = ReadingProgressStore(defaults: suite, key: "progress")
    let target = FavoriteContentTarget(mangaID: "links:source", mangaCleanBookName: "Old Title")

    _ = try await store.saveMangaTitle(
        cleanBookName: "Old Title",
        chapterThreadID: "526",
        chapterView: 2,
        chapterTitle: "第6话",
        pageIndex: 5,
        mangaID: "links:source"
    )
    try await store.migrateMangaTitleKey(from: "Old Title", to: "New Title")

    let oldDisplayTargetRecord = await store.load(for: target)
    let renamedTarget = FavoriteContentTarget(mangaID: "links:source", mangaCleanBookName: "New Title")
    let renamedRecord = await store.load(for: renamedTarget)
    #expect(oldDisplayTargetRecord?.contentTarget?.mangaCleanBookName == "New Title")
    #expect(renamedRecord?.manga?.chapterThreadID == "526")
    #expect(renamedRecord?.manga?.chapterView == 2)
    #expect(renamedRecord?.manga?.mangaPageIndex == 5)
}

@Test func mangaReadingProgressRetargetsChapterFallbackWhenDirectoryIdentityAppears() async throws {
    let suite = try #require(UserDefaults(suiteName: "FavoriteMangaProgressRetargetTests.\(UUID().uuidString)"))
    let store = ReadingProgressStore(defaults: suite, key: "progress")

    _ = try await store.saveMangaTitle(
        cleanBookName: "Stable Title",
        chapterThreadID: "527",
        chapterTitle: "第7话",
        pageIndex: 1,
        mangaID: "chapter:527"
    )
    _ = try await store.saveMangaTitle(
        cleanBookName: "Stable Title",
        chapterThreadID: "527",
        chapterTitle: "第7话",
        pageIndex: 2,
        mangaID: "links:first-post-9001"
    )

    let chapterRecord = await store.load(for: FavoriteContentTarget(mangaID: "chapter:527", mangaCleanBookName: "Stable Title"))
    let stableRecord = await store.load(for: FavoriteContentTarget(mangaID: "links:first-post-9001", mangaCleanBookName: "Stable Title"))
    #expect(chapterRecord == nil)
    #expect(stableRecord?.manga?.mangaPageIndex == 2)
}
