import XCTest
@testable import YamiboXCore
@testable import YamiboXUI

/// Focused pure-function coverage for `LocalFavoriteLibraryDerivation`,
/// exercised directly through `Inputs`/`derive(_:)` rather than through the
/// full `FavoriteLibraryOrganizer` — both are internal, but visible here via
/// `@testable import YamiboXUI`, exactly like `FavoriteLibraryOrganizerTests`
/// already reaches other internal types in this module.
final class LocalFavoriteLibraryDerivationTests: XCTestCase {
    /// Regression test for the collection preview mosaic not merging smart-
    /// card manga groups: before the fix, every `FavoriteItem` became its own
    /// tile regardless of the virtual merged smart-card grouping the main
    /// card list already applies (smart-comic-mode decision #5), so 2
    /// favorited chapters of the same resolved-directory manga produced 2
    /// separate tiles instead of 1. This asserts the exact tile count and
    /// exact titles/covers, which would have failed against that bug (3
    /// tiles, with the manga's 2 chapters showing as 2 separate title/cover
    /// slots instead of 1 shared one).
    func testCollectionPreviewTilesCollapsesResolvedMangaGroupIntoOneTileWhileOtherItemsStayIndividual() throws {
        var document = FavoriteLibraryDocument()
        let category = document.defaultCategory
        let collection = document.createCollection(categoryID: category.id, name: "预览合并测试合集")
        let collectionLocations: [FavoriteLocation] = [
            .category(category.id),
            .collection(categoryID: category.id, collectionID: collection.id)
        ]

        let directory = MangaDirectory(
            cleanBookName: "预览合并测试漫画",
            strategy: .links,
            sourceKey: "chapter:2001",
            chapters: [
                MangaChapter(tid: "2001", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "2002", rawTitle: "第二话", chapterNumber: 2)
            ]
        )

        // Oldest to newest: normal item first, then the manga group's two
        // chapters, most-recent chapter last — so the merged group's tile
        // should sort ahead of the normal item's tile (freshest-of-any-member
        // recency), and the two manga chapters must collapse into ONE tile,
        // not two.
        let normalUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let firstChapterUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let secondChapterUpdatedAt = Date(timeIntervalSince1970: 3_000)

        let normalItem = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "3001"),
            title: "普通收藏帖子",
            locations: collectionLocations,
            updatedAt: normalUpdatedAt
        )
        let firstChapterItem = try FavoriteItem(
            target: .mangaThread(threadID: "2001"),
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: collectionLocations,
            updatedAt: firstChapterUpdatedAt
        )
        let secondChapterItem = try FavoriteItem(
            target: .mangaThread(threadID: "2002"),
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: collectionLocations,
            updatedAt: secondChapterUpdatedAt
        )
        document.upsertItem(normalItem)
        document.upsertItem(firstChapterItem)
        document.upsertItem(secondChapterItem)

        let normalCoverURL = try XCTUnwrap(URL(string: "https://example.com/normal-cover.jpg"))
        let perThreadCoverURL = try XCTUnwrap(URL(string: "https://example.com/per-thread-cover.jpg"))
        let sharedMangaCoverURL = try XCTUnwrap(URL(string: "https://example.com/shared-manga-cover.jpg"))

        let inputs = LocalFavoriteLibraryDerivation.Inputs(
            document: document,
            selectedCategoryID: category.id,
            selectedCollectionID: nil,
            filter: LocalFavoriteFilterState(),
            readingProgress: [],
            coverURLsByKey: [
                .thread(tid: "3001"): normalCoverURL,
                // A resolved-directory group's tile must use the SHARED
                // `.smartManga` cover, not either member's own per-thread
                // cover — these thread covers must be ignored by the fix.
                .thread(tid: "2001"): perThreadCoverURL,
                .thread(tid: "2002"): perThreadCoverURL,
                .smartManga(cleanBookName: directory.cleanBookName): sharedMangaCoverURL
            ],
            textCoverForcedKeys: [],
            mangaDirectoriesByTID: [
                "2001": directory,
                "2002": directory
            ],
            boardReaderSettings: BoardReaderSettings()
        )

        let derived = LocalFavoriteLibraryDerivation.derive(inputs)
        let tiles = try XCTUnwrap(derived.collectionPreviewTiles[collection.id])

        XCTAssertEqual(tiles.count, 2, "2 favorited chapters of the same smart-merged manga must collapse into 1 tile, not 2")
        XCTAssertEqual(
            tiles,
            [
                LocalFavoriteCollectionPreviewTile(coverURL: sharedMangaCoverURL, title: directory.cleanBookName),
                LocalFavoriteCollectionPreviewTile(coverURL: normalCoverURL, title: normalItem.resolvedDisplayTitle)
            ]
        )
    }

    /// The dedup/collapse above must NOT extend to a mode-on `.mangaThread`
    /// favorite whose directory has NOT resolved locally yet: the main card
    /// list itself only merges once an actual `MangaDirectory` has resolved
    /// (`LocalFavoriteLibraryProjection.rawGroupedFavorites` puts an
    /// unresolved favorite in `standalone` regardless of what its locally-
    /// guessed `MangaTitleCleaner.cleanBookName` title happens to be — two
    /// unresolved favorites are never shown as one card just because they
    /// guess the same name). This preview mosaic must not summarize the
    /// collection as more merged than its own card list actually shows, so
    /// two such favorites must still produce two separate tiles — each with
    /// its own per-thread cover — even though both tiles' titles happen to
    /// read identically.
    func testCollectionPreviewTilesKeepsUnresolvedMangaFavoritesSeparateEvenWhenLocalCleanTitlesMatch() throws {
        var document = FavoriteLibraryDocument()
        let category = document.defaultCategory
        let collection = document.createCollection(categoryID: category.id, name: "未解析预览合并测试合集")
        let collectionLocations: [FavoriteLocation] = [
            .category(category.id),
            .collection(categoryID: category.id, collectionID: collection.id)
        ]

        // Both raw titles clean to the same "未解析漫画" via
        // `MangaTitleCleaner.cleanBookName` (bracketed author prefix +
        // trailing "第N话" chapter marker both stripped) — mirrors
        // `FavoriteLibraryOrganizerTests
        // .testUnresolvedModeOnFavoriteUsingLocalCleanFallbackGetsSmartCardTreatmentAndOpensSingletonArchive`'s
        // own raw-title convention.
        let firstRawTitle = "【作者】未解析漫画 第1话"
        let secondRawTitle = "【作者】未解析漫画 第2话"
        XCTAssertEqual(MangaTitleCleaner.cleanBookName(firstRawTitle), "未解析漫画")
        XCTAssertEqual(MangaTitleCleaner.cleanBookName(secondRawTitle), "未解析漫画")

        let firstUpdatedAt = Date(timeIntervalSince1970: 1_000)
        let secondUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let firstItem = try FavoriteItem(
            target: .mangaThread(threadID: "4001"),
            title: firstRawTitle,
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: collectionLocations,
            updatedAt: firstUpdatedAt
        )
        let secondItem = try FavoriteItem(
            target: .mangaThread(threadID: "4002"),
            title: secondRawTitle,
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: collectionLocations,
            updatedAt: secondUpdatedAt
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)

        let firstItemCoverURL = try XCTUnwrap(URL(string: "https://example.com/unresolved-first-cover.jpg"))
        let secondItemCoverURL = try XCTUnwrap(URL(string: "https://example.com/unresolved-second-cover.jpg"))

        let inputs = LocalFavoriteLibraryDerivation.Inputs(
            document: document,
            selectedCategoryID: category.id,
            selectedCollectionID: nil,
            filter: LocalFavoriteFilterState(),
            readingProgress: [],
            coverURLsByKey: [
                .thread(tid: "4001"): firstItemCoverURL,
                .thread(tid: "4002"): secondItemCoverURL
            ],
            textCoverForcedKeys: [],
            // No `mangaDirectoriesByTID` entries at all — neither favorite's
            // directory has resolved locally.
            mangaDirectoriesByTID: [:],
            boardReaderSettings: BoardReaderSettings()
        )

        let derived = LocalFavoriteLibraryDerivation.derive(inputs)
        let tiles = try XCTUnwrap(derived.collectionPreviewTiles[collection.id])

        XCTAssertEqual(tiles.count, 2, "2 unresolved favorites must NOT collapse just because they guess the same local-clean title")
        XCTAssertEqual(tiles.map(\.title), ["未解析漫画", "未解析漫画"])
        // Sorted most-recent-first (each item's own `updatedAt`, since
        // neither is part of a resolved group), each keeping its OWN
        // per-thread cover rather than either being silently absorbed.
        XCTAssertEqual(tiles.map(\.coverURL), [secondItemCoverURL, firstItemCoverURL])
    }
}
