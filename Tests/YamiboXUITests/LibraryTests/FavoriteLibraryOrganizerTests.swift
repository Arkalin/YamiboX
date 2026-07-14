import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

@MainActor
final class FavoriteLibraryOrganizerTests: XCTestCase {
    func testSourceGroupFilterCountsRespectSearchAndTags() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-source-filter")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let boardA = FavoriteSourceGroup.forumBoard(id: "10", label: "版区A")
        let boardALegacy = FavoriteSourceGroup.forumBoard(id: "10", label: "旧版区A")
        let boardB = FavoriteSourceGroup.forumBoard(id: "20", label: "版区B")
        let boardAFilter = LocalFavoriteSourceFilter.forumBoard(id: "10", label: "版区A")
        let boardBFilter = LocalFavoriteSourceFilter.forumBoard(id: "20", label: "版区B")
        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "940")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "941")
        let thirdTarget = FavoriteItemTarget(kind: .normalThread, threadID: "942")
        let fourthTarget = FavoriteItemTarget(kind: .normalThread, threadID: "943")
        var document = try await localFavoriteLibraryStore.load()
        let tag = document.createTag(name: "筛选", color: .blue)
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "同名主题一",
            sourceGroup: boardA,
            locations: [.category(document.defaultCategory.id)],
            tagIDs: [tag.id]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "同名主题二",
            sourceGroup: boardB,
            locations: [.category(document.defaultCategory.id)],
            tagIDs: [tag.id]
        ))
        document.upsertItem(try FavoriteItem(
            target: thirdTarget,
            title: "其他主题",
            sourceGroup: boardA,
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: fourthTarget,
            title: "同名主题三",
            sourceGroup: boardALegacy,
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardAFilter], 3)
        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardBFilter], 1)

        organizer.filter.searchText = "同名"
        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardAFilter], 2)
        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardBFilter], 1)

        organizer.filter.selectedSourceFilters = [boardAFilter]
        XCTAssertEqual(Set(organizer.derived.cards.map(\.item.target)), [firstTarget, fourthTarget])

        organizer.filter.selectedSourceFilters = [boardBFilter]
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [secondTarget])

        organizer.filter.selectedSourceFilters = [boardAFilter, boardBFilter]
        XCTAssertEqual(Set(organizer.derived.cards.map(\.item.target)), [firstTarget, secondTarget, fourthTarget])

        organizer.filter.selectedSourceFilters = [boardBFilter]
        organizer.filter.selectedTagIDs = [tag.id]
        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardAFilter], 1)
        XCTAssertEqual(organizer.derived.sourceFilterEntryCounts[boardBFilter], 1)
    }

    /// Fix for the stale-state gap this file's Phase H review flagged:
    /// `FavoriteLibraryOrganizer` did not subscribe to
    /// `SettingsStore.didChangeNotification`, so toggling Smart Comic Mode
    /// while the Favorites tab was already loaded left the merged-card
    /// grouping stale until an unrelated favorite/progress/cover change
    /// happened to trigger a reload. This proves the live subscription
    /// re-derives grouping from a bare `settingsStore.save(...)` alone, with
    /// no explicit `organizer.reload()` call in between.
    func testSettingsStoreChangeLiveRefreshesMangaDirectoryGroupingWithoutManualReload() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-settings-live-refresh")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "实时刷新测试漫画",
            strategy: .links,
            sourceKey: "chapter:980",
            chapters: [
                MangaChapter(tid: "980", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "981", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "980")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "981")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "46",
            forumName: "关闭板块",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "46",
            forumName: "关闭板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()
        // `load()` assigning `selectedCategoryID`/`selectedCollectionID`
        // fires `persistNavigationState()`, which spawns its own
        // unstructured load-modify-save `Task` against this same
        // `settingsStore`. Letting that settle before this test does its own
        // concurrent load-modify-save below avoids a lost-update race where
        // that Task's save (started from a `settings` snapshot it read
        // before this test's own save below) would clobber this test's
        // change with stale data.
        try await Task.sleep(nanoseconds: 100_000_000)

        // fid "46" is off by default: no merge yet, two standalone cards.
        XCTAssertEqual(organizer.derived.cards.count, 2)
        XCTAssertFalse(organizer.derived.cards.contains { $0.isMergedGroup })

        // Flip the board's smart bit on directly through the settings store
        // — exactly what the Settings UI's toggle does — with no call to
        // `organizer.reload()` in between.
        var settings = await settingsStore.load()
        settings.boardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "46")
        try await settingsStore.save(settings)

        try await waitForOrganizerCondition {
            organizer.derived.cards.count == 1
        }
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == firstItem.id })
        XCTAssertTrue(mergedCard.isMergedGroup)
        XCTAssertEqual(mergedCard.mergedMembers?.map(\.target), [firstTarget, secondTarget])
    }

    /// `FavoriteLibraryOrganizer` is constructed once for the app's lifetime
    /// (the root `TabView` never tears down hidden tabs), so a favorites
    /// background changed from Settings must reach an already-loaded
    /// Favorites tab through the same live-refresh subscription proven above
    /// for board-reader settings — with no explicit `organizer.reload()`
    /// call in between, exactly mirroring what `SystemSettingsViewModel
    /// .applyFavoriteBackground` actually does (save image bytes, then save
    /// settings).
    func testSettingsStoreChangeLiveRefreshesFavoriteBackgroundWithoutManualReload() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-background-live-refresh")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let favoriteBackgroundImageStore = makeFavoriteBackgroundImageStore(suiteName: suiteName)

        let organizer = try makeOrganizer(
            settingsStore: settingsStore,
            favoriteBackgroundImageStore: favoriteBackgroundImageStore
        )
        await organizer.load()

        XCTAssertFalse(organizer.backgroundSettings.isEnabled)
        XCTAssertNil(organizer.backgroundImageData)

        let imageData = Data("test-background-bytes".utf8)
        let imageID = UUID().uuidString
        try await favoriteBackgroundImageStore.save(imageData, imageID: imageID)

        // Exactly what the Settings UI's apply flow does: save the image
        // bytes, then save the settings blob — no call to
        // `organizer.reload()` in between.
        var settings = await settingsStore.load()
        settings.favorites.background = FavoriteBackgroundSettings(isEnabled: true, imageID: imageID, blurRadius: 12)
        try await settingsStore.save(settings)

        try await waitForOrganizerCondition {
            organizer.backgroundSettings.isEnabled
        }
        XCTAssertEqual(organizer.backgroundSettings.imageID, imageID)
        XCTAssertEqual(organizer.backgroundSettings.blurRadius, 12)
        XCTAssertEqual(organizer.backgroundImageData, imageData)
    }

    /// Pluggable-reader-config decision #1: merged-card grouping is purely
    /// configuration-driven for ANY board — an arbitrary fid ("99", no
    /// factory entry) configured `.manga(smartEnabled: true)` merges its
    /// directory-sharing favorites exactly like the factory smart board, and
    /// removing that entry again (the settings overview's 移除 action, via a
    /// bare `settingsStore.save` → `reloadBoardReaderSettings` live refresh)
    /// dissolves the merged card back into independent ordinary cards with
    /// the stored favorites themselves untouched.
    func testArbitraryConfiguredBoardMergesAndEntryRemovalDissolvesWithoutDataLoss() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-arbitrary-board-merge")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "任意板块漫画",
            strategy: .links,
            sourceKey: "chapter:990",
            chapters: [
                MangaChapter(tid: "990", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "991", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "990")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "991")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "任意板块漫画 第一话",
            forumID: "99",
            forumName: "任意板块",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "任意板块漫画 第二话",
            forumID: "99",
            forumName: "任意板块",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        // Seeded before the organizer exists (no load-modify-save race with
        // `persistNavigationState()`): fid "99" configured manga + smart on.
        var seededBoardReader = BoardReaderSettings()
        seededBoardReader.setEntry(.init(mode: .manga(smartEnabled: true)), forumID: "99")
        try await settingsStore.save(AppSettings(boardReader: seededBoardReader))

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()
        // Let `load()`'s own `persistNavigationState()` background Task
        // settle before this test's concurrent settings save below.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Configured arbitrary board merges like any factory smart board.
        XCTAssertEqual(organizer.derived.cards.count, 1)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == firstItem.id })
        XCTAssertTrue(mergedCard.isMergedGroup)
        XCTAssertEqual(mergedCard.mergedMembers?.map(\.target), [firstTarget, secondTarget])

        // Remove the entry — exactly what the settings overview's 移除 does.
        var settings = await settingsStore.load()
        settings.boardReader.removeEntry(forumID: "99")
        try await settingsStore.save(settings)

        try await waitForOrganizerCondition {
            organizer.derived.cards.count == 2
        }
        XCTAssertFalse(organizer.derived.cards.contains { $0.isMergedGroup })
        XCTAssertTrue(organizer.derived.cards.allSatisfy { !$0.isModeOnMangaThread })
        // Dissolution is purely presentational: both favorites survive in
        // the stored library, completely unchanged.
        let storedItems = try await localFavoriteLibraryStore.load().items
        XCTAssertEqual(Set(storedItems.map(\.id)), [firstItem.id, secondItem.id])
        XCTAssertEqual(Set(storedItems.map(\.title)), ["任意板块漫画 第一话", "任意板块漫画 第二话"])
    }

    /// The manga reader's directory page can rename a `MangaDirectory` (e.g.
    /// correcting an auto-detected book name) via
    /// `MangaDirectoryStore.renameDirectory(from:to:)`. Before this fix,
    /// `MangaDirectoryStore` posted no change notification at all, so an
    /// already-open Favorites tab kept showing the merged card's OLD
    /// `cleanBookName` until some unrelated favorite/progress/cover/settings
    /// change happened to trigger a full reload. This proves the rename's
    /// effect on `resolvedTitle` is picked up live, from a bare
    /// `mangaDirectoryStore.renameDirectory(...)` call alone, with no
    /// explicit `organizer.reload()` in between — mirroring the sibling
    /// settings-store live-refresh test above.
    ///
    /// Also proves the sibling fix: `MangaDirectoryStore
    /// .renameRelatedStructuredMetadata` cascades the rename into the
    /// `reading_progress` table too (the directory-level progress record
    /// gets migrated to the new clean book name), so `reloadMangaDirectories()`
    /// must reload `readingProgress` in the same pass, not just
    /// `mangaDirectoriesByTID` — otherwise the card's `progressPercent` would
    /// go stale/missing immediately after the rename (the organizer's
    /// already-loaded `readingProgress` array would keep the OLD identity,
    /// which the renamed card's directory-progress lookup no longer matches)
    /// until some other reload happened to refresh it.
    func testMangaDirectoryStoreRenameLiveRefreshesResolvedTitleWithoutManualReload() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-directory-rename-live-refresh")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let readingProgressStore = ReadingProgressStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "reading-progress"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let originalName = "renamed-title-test"
        let directory = MangaDirectory(
            cleanBookName: originalName,
            strategy: .links,
            sourceKey: "chapter:990",
            chapters: [
                MangaChapter(tid: "990", rawTitle: "第一话", chapterNumber: 1),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // Directory-level ("third level", design decision #14) reading
        // progress, keyed by the directory's own `favoriteIdentity` — the
        // same record `LocalFavoriteLibraryProjection.progress(for:...)`
        // prefers over the representative member's own per-thread record.
        try await readingProgressStore.saveMangaTitle(
            cleanBookName: originalName,
            chapterThreadID: "990",
            chapterTitle: "第一话",
            pageIndex: 4,
            pageCount: 10,
            mangaID: directory.favoriteIdentity
        )

        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "990")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            readingProgressStore: readingProgressStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        let originalCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == item.id })
        XCTAssertEqual(originalCard.resolvedTitle, originalName)
        XCTAssertEqual(originalCard.progressPercent, 50)

        // Rename directly through the store — exactly what
        // `MangaDirectoryStore.renameDirectory(from:to:)` does when invoked
        // via `MangaReaderViewModel.renameDirectory` — with no call to
        // `organizer.reload()` in between.
        let newName = "renamed-title-test-v2"
        var renamedDirectory = directory
        renamedDirectory.cleanBookName = newName
        try await mangaDirectoryStore.renameDirectory(from: originalName, to: renamedDirectory)

        try await waitForOrganizerCondition {
            organizer.derived.cards.first { $0.id == item.id }?.resolvedTitle == newName
        }
        // The rename-cascaded progress record must still resolve under the
        // renamed identity, proving `readingProgress` was reloaded alongside
        // `mangaDirectoriesByTID` in the same live-refresh pass.
        let renamedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == item.id })
        XCTAssertEqual(renamedCard.progressPercent, 50)
    }

    /// The sibling half of the manga-directory live-refresh fix: favoriting
    /// an unresolved manga (a "local-clean fallback" smart card, no
    /// `MangaDirectory` yet) and then reading it resolves and saves a real
    /// `MangaDirectory` via `MangaDirectoryStore.saveDirectory(_:)` — not
    /// `renameDirectory`. Before this fix, `saveDirectory` posted no change
    /// notification at all, so an already-open Favorites tab kept showing
    /// the stale unresolved fallback card until some unrelated
    /// favorite/progress/cover/settings change happened to trigger a reload.
    /// This proves a bare `mangaDirectoryStore.saveDirectory(...)` call alone
    /// — no explicit `organizer.reload()` — is enough for the organizer to
    /// pick up the newly-resolved directory and show the resolved
    /// `cleanBookName`/merge.
    func testMangaDirectoryStoreSaveDirectoryLiveRefreshesPreviouslyUnresolvedFavoriteWithoutManualReload() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-save-directory-live-refresh")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)

        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "995")
        var document = try await localFavoriteLibraryStore.load()
        let rawTitle = "【作者】首次解析作品 第1话"
        let item = try FavoriteItem(
            target: target,
            title: rawTitle,
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        // No directory resolved locally yet at organizer construction time —
        // this favorite starts life on the local-clean fallback title.
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        let unresolvedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == item.id })
        XCTAssertNil(unresolvedCard.mangaDirectory)
        XCTAssertEqual(unresolvedCard.resolvedTitle, MangaTitleCleaner.cleanBookName(rawTitle))

        // Resolves and saves the directory directly through the store —
        // exactly what `MangaDirectoryWorkflow` does the first time the user
        // actually reads this favorite — with no call to
        // `organizer.reload()` in between.
        let resolvedName = "首次解析作品"
        let directory = MangaDirectory(
            cleanBookName: resolvedName,
            strategy: .links,
            sourceKey: "chapter:995",
            chapters: [
                MangaChapter(tid: "995", rawTitle: "第1话", chapterNumber: 1),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        try await waitForOrganizerCondition {
            organizer.derived.cards.first { $0.id == item.id }?.mangaDirectory != nil
        }
        let resolvedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == item.id })
        XCTAssertEqual(resolvedCard.mangaDirectory?.cleanBookName, resolvedName)
        XCTAssertEqual(resolvedCard.resolvedTitle, resolvedName)
    }

    func testLocalFirstTagsFilterDisplayAndBatchAssignment() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-tags")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "930")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "931")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "第一条",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "第二条",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        let createdTag = await organizer.createTag(name: "待读", color: .green)
        let tag = try XCTUnwrap(createdTag)
        await organizer.updateTags(for: firstTarget.id, tagIDs: [tag.id])

        XCTAssertEqual(organizer.derived.cards.first { $0.id == firstTarget.id }?.tags.map(\.name), ["待读"])

        organizer.filter.selectedTagIDs = [tag.id]
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget])

        organizer.filter.selectedTagIDs = []
        organizer.filter.searchText = "待读"
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget])

        await organizer.updateTag(id: tag.id, name: "已读", color: .purple)
        XCTAssertTrue(organizer.tags.contains { $0.id == tag.id && $0.name == "已读" && $0.color == .purple })

        organizer.filter.searchText = ""
        organizer.selection.toggleFavoriteSelection(id: secondTarget.id)
        await organizer.updateTagsForSelection([tag.id])
        XCTAssertFalse(organizer.selection.isSelectionMode)
        XCTAssertEqual(organizer.derived.cards.first { $0.id == secondTarget.id }?.tags.map(\.name), ["已读"])

        await organizer.deleteTag(id: tag.id)
        XCTAssertTrue(organizer.tags.isEmpty)
        let storedItems = try await localFavoriteLibraryStore.load().items
        XCTAssertTrue(storedItems.allSatisfy(\.tagIDs.isEmpty))
    }

    func testBatchSelectionCreatesMovesDissolvesAndDeletesEntries() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-batch-selection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let createdCategory = await organizer.createCategory(name: "分类A")
        let category = try XCTUnwrap(createdCategory)
        let createdExistingCollection = await organizer.createCollection(name: "旧合集", color: .gray)
        let existingCollection = try XCTUnwrap(createdExistingCollection)
        organizer.closeCollection()

        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "920")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "921")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "第一条",
            locations: [.category(category.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "第二条",
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: firstTarget.id)
        let createdMergedCollection = await organizer.createCollectionFromSelection(name: "合成合集", color: .green)
        let mergedCollection = try XCTUnwrap(createdMergedCollection)
        XCTAssertFalse(organizer.selection.isSelectionMode)
        let mergedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == firstTarget }
        XCTAssertTrue(mergedItem?.locations.contains(.collection(categoryID: category.id, collectionID: mergedCollection.id)) == true)

        organizer.closeCollection()
        let createdSecondCategory = await organizer.createCategory(name: "分类B")
        let secondCategory = try XCTUnwrap(createdSecondCategory)
        organizer.selectedCategoryID = category.id
        organizer.selection.toggleFavoriteSelection(id: secondTarget.id)
        organizer.toggleCollectionSelection(id: existingCollection.id)
        await organizer.moveSelectionToCategory(id: secondCategory.id)

        XCTAssertFalse(organizer.selection.isSelectionMode)
        XCTAssertEqual(organizer.selectedCategoryID, secondCategory.id)
        XCTAssertTrue(organizer.collections.contains { $0.id == existingCollection.id && $0.categoryID == secondCategory.id })
        let movedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == secondTarget }
        XCTAssertTrue(movedItem?.locations.contains(.category(secondCategory.id)) == true)
        XCTAssertFalse(movedItem?.locations.contains(.category(category.id)) == true)

        organizer.toggleCollectionSelection(id: existingCollection.id)
        await organizer.dissolveSelectedCollections()
        XCTAssertFalse(organizer.collections.contains { $0.id == existingCollection.id })

        organizer.selection.toggleFavoriteSelection(id: secondTarget.id)
        await organizer.deleteSelection(scope: .everywhere, removeRemote: false)
        let deletedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == secondTarget }
        XCTAssertNil(deletedItem)
    }

    func testSelectionCanAddAndRemoveIndividualFavoriteLocations() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-multi-location")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let createdSourceCategory = await organizer.createCategory(name: "分类A")
        let sourceCategory = try XCTUnwrap(createdSourceCategory)
        let createdDestinationCategory = await organizer.createCategory(name: "分类B")
        let destinationCategory = try XCTUnwrap(createdDestinationCategory)
        organizer.selectedCategoryID = destinationCategory.id
        let createdCollection = await organizer.createCollection(name: "合集B", color: .blue)
        let collection = try XCTUnwrap(createdCollection)
        organizer.selectedCategoryID = sourceCategory.id
        organizer.closeCollection()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "940")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "多路径收藏",
            locations: [.category(sourceCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: target.id)
        await organizer.addSelectionToCategory(id: destinationCategory.id)

        var loadedDocument = try await localFavoriteLibraryStore.load()
        var storedItem = try XCTUnwrap(loadedDocument.items.first { $0.target == target })
        XCTAssertTrue(storedItem.locations.contains(.category(sourceCategory.id)))
        XCTAssertTrue(storedItem.locations.contains(.category(destinationCategory.id)))

        organizer.selectedCategoryID = sourceCategory.id
        organizer.selection.toggleFavoriteSelection(id: target.id)
        await organizer.removeSelectionFromCurrentLocation()

        loadedDocument = try await localFavoriteLibraryStore.load()
        storedItem = try XCTUnwrap(loadedDocument.items.first { $0.target == target })
        XCTAssertFalse(storedItem.locations.contains(.category(sourceCategory.id)))
        XCTAssertTrue(storedItem.locations.contains(.category(destinationCategory.id)))

        organizer.selectedCategoryID = destinationCategory.id
        organizer.selection.toggleFavoriteSelection(id: target.id)
        await organizer.addSelectionToCollection(id: collection.id)

        loadedDocument = try await localFavoriteLibraryStore.load()
        storedItem = try XCTUnwrap(loadedDocument.items.first { $0.target == target })
        XCTAssertTrue(storedItem.locations.contains(.category(destinationCategory.id)))
        XCTAssertTrue(storedItem.locations.contains(.collection(categoryID: destinationCategory.id, collectionID: collection.id)))
    }

    func testDeleteSelectionCurrentLocationKeepsOtherLocationsAndSkipsRemoteDelete() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-location")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let createdSourceCategory = await organizer.createCategory(name: "分类A")
        let sourceCategory = try XCTUnwrap(createdSourceCategory)
        let createdDestinationCategory = await organizer.createCategory(name: "分类B")
        let destinationCategory = try XCTUnwrap(createdDestinationCategory)
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "952")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "多位置远端收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-952"),
            locations: [.category(sourceCategory.id), .category(destinationCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        organizer.selectedCategoryID = sourceCategory.id
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: target.id)
        await organizer.deleteSelection(scope: .currentLocation, removeRemote: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let storedItem = try XCTUnwrap(loadedDocument.items.first { $0.target == target })
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertFalse(storedItem.locations.contains(.category(sourceCategory.id)))
        XCTAssertTrue(storedItem.locations.contains(.category(destinationCategory.id)))
        XCTAssertEqual(recordedTargetIDs, [])
    }

    func testDeleteSelectionCurrentLocationDoesNotDissolveSelectedCollections() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-mixed-location")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let createdCategory = await organizer.createCategory(name: "分类A")
        let category = try XCTUnwrap(createdCategory)
        let createdCollection = await organizer.createCollection(name: "合集A", color: .blue)
        let collection = try XCTUnwrap(createdCollection)
        organizer.closeCollection()
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "956")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "多位置收藏",
            locations: [
                .category(category.id),
                .collection(categoryID: category.id, collectionID: collection.id)
            ]
        ))
        try await localFavoriteLibraryStore.save(document)
        organizer.selectedCategoryID = category.id
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: target.id)
        organizer.toggleCollectionSelection(id: collection.id)
        await organizer.deleteSelection(scope: .currentLocation, removeRemote: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        XCTAssertTrue(loadedDocument.collections.contains { $0.id == collection.id })
        let storedItem = try XCTUnwrap(loadedDocument.items.first { $0.target == target })
        XCTAssertFalse(storedItem.locations.contains(.category(category.id)))
        XCTAssertTrue(storedItem.locations.contains(.collection(categoryID: category.id, collectionID: collection.id)))
    }

    func testDeleteSelectionRemoteFailureRollsBackLocalDelete() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-rollback")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let recorder = FavoriteDeleteTestRecorder(error: YamiboError.favoriteDeleteFailed)
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "953")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "远端删除失败收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-953"),
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: target.id)
        await organizer.deleteSelection(scope: .everywhere, removeRemote: true)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNotNil(storedItem)
        XCTAssertEqual(recordedTargetIDs, [target.id])
        XCTAssertNotNil(organizer.errorMessage)
    }

    func testEverywhereDeleteFallsBackToRemoteFavoriteLookupWhenMappingIDIsMissing() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-fallback")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        LocalFavoriteDeleteTestURLProtocol.reset()
        defer { LocalFavoriteDeleteTestURLProtocol.reset() }
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            session: makeLocalFavoriteDeleteTestSession()
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "955")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "需要回查远端 ID 的收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: ""),
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.deleteItem(item, scope: .everywhere, removeRemote: true)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        XCTAssertNil(storedItem)
        XCTAssertNil(organizer.errorMessage)
        XCTAssertEqual(LocalFavoriteDeleteTestURLProtocol.deletedFavoriteIDs, ["997"])
    }

    func testLocalOnlyEverywhereDeleteDoesNotRequireRemoteLookup() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-local-only")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "954")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "纯本地收藏",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.deleteItem(item, scope: .everywhere, removeRemote: true)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        XCTAssertNil(storedItem)
        XCTAssertNil(organizer.errorMessage)
    }

    /// The favorites page's delete-everywhere must honor the SAME remembered
    /// "also remove from Yamibo?" choice as every quick-action entry point —
    /// a user who remembered "local only" on a detail page must never have
    /// this page silently delete the website favorite anyway.
    func testRequestDeleteEverywhereHonorsRememberedLocalOnlyChoice() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-request-delete-local-only")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        _ = try await settingsStore.update { settings in
            settings.favorites.removeRemotePromptEnabled = false
            settings.favorites.removeRemoteDefault = false
        }
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9701")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "记住仅本地的收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-9701"),
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.requestDeleteItem(item, scope: .everywhere)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(storedItem)
        XCTAssertTrue(recordedTargetIDs.isEmpty)
        XCTAssertNil(organizer.removeRemotePrompt)
        XCTAssertNil(organizer.errorMessage)
    }

    func testRequestDeleteEverywhereHonorsRememberedRemoveRemoteChoice() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-request-delete-remote")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        _ = try await settingsStore.update { settings in
            settings.favorites.removeRemotePromptEnabled = false
            settings.favorites.removeRemoteDefault = true
        }
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9702")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "记住同删远端的收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-9702"),
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.requestDeleteItem(item, scope: .everywhere)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(storedItem)
        XCTAssertEqual(recordedTargetIDs, [target.id])
        XCTAssertNil(organizer.removeRemotePrompt)
    }

    func testRequestDeleteEverywherePromptsThenConfirmAppliesAndRemembers() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-request-delete-prompt")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9703")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "需要询问的收藏",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-9703"),
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.requestDeleteItem(item, scope: .everywhere)

        // The prompt is the delete's remote-decision step: nothing may have
        // been deleted anywhere until the user answers.
        XCTAssertNotNil(organizer.removeRemotePrompt)
        let itemBeforeConfirm = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedBeforeConfirm = await recorder.recordedTargetIDs()
        XCTAssertNotNil(itemBeforeConfirm)
        XCTAssertTrue(recordedBeforeConfirm.isEmpty)

        await organizer.confirmRemoveRemotePrompt(removeRemote: true, remember: true)

        XCTAssertNil(organizer.removeRemotePrompt)
        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(storedItem)
        XCTAssertEqual(recordedTargetIDs, [target.id])
        let favorites = await settingsStore.load().favorites
        XCTAssertFalse(favorites.removeRemotePromptEnabled)
        XCTAssertTrue(favorites.removeRemoteDefault)
    }

    /// A favorite with no plausible Yamibo counterpart has nothing to ask
    /// about — the prompt must not appear even when asking is enabled.
    func testRequestDeleteEverywhereSkipsPromptWithoutRemoteCandidate() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-request-delete-no-candidate")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9704")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "纯本地无映射收藏",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        await organizer.requestDeleteItem(item, scope: .everywhere)

        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(organizer.removeRemotePrompt)
        XCTAssertNil(storedItem)
        XCTAssertTrue(recordedTargetIDs.isEmpty)
    }

    func testRequestDeleteSelectionPromptAppliesChoiceToWholeBatch() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-request-delete-selection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()

        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "9705")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "9706")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "批量删除收藏一",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-9705"),
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "批量删除收藏二",
            remoteMapping: FavoriteRemoteMapping(yamiboFavoriteID: "remote-9706"),
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: firstTarget.id)
        organizer.selection.toggleFavoriteSelection(id: secondTarget.id)
        await organizer.requestDeleteSelection(scope: .everywhere)

        XCTAssertNotNil(organizer.removeRemotePrompt)

        await organizer.confirmRemoveRemotePrompt(removeRemote: false, remember: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(loadedDocument.items.first { $0.target == firstTarget })
        XCTAssertNil(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertTrue(recordedTargetIDs.isEmpty)
        XCTAssertFalse(organizer.selection.isSelectionMode)
        // A one-off answer without "remember" must leave the ask-me switch on.
        let favorites = await settingsStore.load().favorites
        XCTAssertTrue(favorites.removeRemotePromptEnabled)
    }

    /// Regression guard for the correctness fix `smartMangaBulkDeleteEnabled`
    /// required: `requestDeleteSelection`'s "also delete from Yamibo?"
    /// decision must resolve from the SAME expanded candidate set
    /// `deleteSelection` is about to delete, not just the smart card's
    /// representative id. Here the representative item itself carries no
    /// remote mapping while its one archived sibling does — if the decision
    /// were resolved from the unexpanded selection, `canRemoveRemote` would
    /// wrongly read `false` (nothing plausible to ask about), the prompt
    /// would never appear, and the sibling's live Yamibo favorite would be
    /// deleted locally without ever being removed from the website.
    func testRequestDeleteSelectionEverywhereWithSmartCardExpandsRemoteDeleteCandidates() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-remote-candidate-expansion")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "远端候选展开测试漫画",
            strategy: .links,
            sourceKey: "chapter:5001",
            chapters: [
                MangaChapter(tid: "5001", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "5002", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "5001")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "5002")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let recorder = FavoriteDeleteTestRecorder()
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore,
            remoteFavoriteDeleteHandler: { items in
                try await recorder.record(items)
            }
        )
        await organizer.load()
        XCTAssertTrue(organizer.smartMangaBulkDeleteEnabled)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        // Whichever of the two members ended up as the card's representative
        // id stays without a remote mapping; the OTHER (archived, not
        // separately selected) member gets one — the scenario that only an
        // expanded candidate set can see.
        let representativeTarget = mergedCard.id == firstTarget.id ? firstTarget : secondTarget
        let siblingTarget = representativeTarget == firstTarget ? secondTarget : firstTarget
        var updatedDocument = try await localFavoriteLibraryStore.load()
        let siblingItem = try XCTUnwrap(updatedDocument.items.first { $0.target == siblingTarget })
        var siblingWithRemoteMapping = siblingItem
        siblingWithRemoteMapping.remoteMapping = FavoriteRemoteMapping(yamiboFavoriteID: "remote-\(siblingTarget.threadID ?? "")")
        updatedDocument.upsertItem(siblingWithRemoteMapping)
        try await localFavoriteLibraryStore.save(updatedDocument)
        await organizer.reload()

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        await organizer.requestDeleteSelection(scope: .everywhere)

        // The prompt must appear: the expanded candidate set includes the
        // sibling's remote mapping, so there IS something plausible to ask
        // about, even though the representative alone has none.
        XCTAssertNotNil(organizer.removeRemotePrompt)

        await organizer.confirmRemoveRemotePrompt(removeRemote: true, remember: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let recordedTargetIDs = await recorder.recordedTargetIDs()
        XCTAssertNil(loadedDocument.items.first { $0.target == firstTarget })
        XCTAssertNil(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertTrue(recordedTargetIDs.contains(siblingTarget.id))
    }

    /// Phase E gap (smart-comic-mode design doc, Phase E's "两个不构成缺陷、
    /// 但记录供参考的观察" note ①): every other test in this file builds its
    /// organizer via `makeOrganizer` with `mangaDirectoryStore: nil`, so
    /// `resolveMangaDirectories`/`scheduleMangaCoverBackfill` always
    /// short-circuit on the nil dependency and are only ever exercised by
    /// `LocalFavoriteLibraryProjectionTests`' pure-function tests, never
    /// through the organizer's real `load()`/`reload()` wiring. This test
    /// injects a genuine GRDB-backed `MangaDirectoryStore` (mirroring
    /// `LocalFavoriteOpenTargetResolverTests`' own helper) with real chapter
    /// data, favorites two `.mangaThread` chapters on a Smart-Comic-Mode-on
    /// board (fid "30", on by `BoardReaderSettings`'s own default) sharing
    /// that directory, and proves the full path from `load()`/`reload()`
    /// through to a merged `FavoriteCardProjection` actually resolves end to
    /// end — not just that the pure grouping function works when handed a
    /// pre-built `mangaDirectoriesByTID` dictionary directly.
    func testLoadWiresRealMangaDirectoryStoreIntoMergedFavoriteCardProjection() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-manga-directory-wiring")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "组织者集成测试漫画",
            strategy: .links,
            sourceKey: "chapter:970",
            chapters: [
                MangaChapter(tid: "970", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "971", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "970")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "971")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.count, 1)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == firstItem.id })
        XCTAssertTrue(mergedCard.isMergedGroup)
        XCTAssertEqual(mergedCard.mangaDirectory?.cleanBookName, "组织者集成测试漫画")
        XCTAssertEqual(mergedCard.mergedMembers?.map(\.target), [firstTarget, secondTarget])

        // `reload()` re-resolves directories independently of `load()` — a
        // background reload (e.g. from a favorite-store change notification)
        // must keep showing the merged card, not silently drop back to two
        // standalone favorites.
        await organizer.reload()
        XCTAssertEqual(organizer.derived.cards.count, 1)
        let reloadedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == firstItem.id })
        XCTAssertTrue(reloadedCard.isMergedGroup)
        XCTAssertEqual(reloadedCard.mergedMembers?.map(\.target), [firstTarget, secondTarget])
    }

    func testCollectionManagementFiltersMovesAndDissolvesFavorites() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-collections")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let createdCategory = await organizer.createCategory(name: "分类A")
        let category = try XCTUnwrap(createdCategory)
        let createdFirstCollection = await organizer.createCollection(name: "合集A", color: .blue)
        let firstCollection = try XCTUnwrap(createdFirstCollection)
        let createdSecondCollection = await organizer.createCollection(name: "合集B", color: .gray)
        let secondCollection = try XCTUnwrap(createdSecondCollection)

        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "910")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "911")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "合集内主题",
            locations: [
                .category(category.id),
                .collection(categoryID: category.id, collectionID: firstCollection.id)
            ]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "分类根主题",
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        XCTAssertEqual(organizer.derived.collectionEntryCounts[firstCollection.id], 1)
        organizer.openCollection(id: firstCollection.id)
        XCTAssertEqual(organizer.selectedCollection?.id, firstCollection.id)
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget])

        await organizer.updateCollection(id: firstCollection.id, name: "合集A+", color: .purple)
        XCTAssertTrue(organizer.collections.contains { $0.id == firstCollection.id && $0.name == "合集A+" && $0.color == .purple })

        await organizer.moveCollection(id: secondCollection.id, direction: .up)
        let sameCategoryCollections = organizer.collections
            .filter { $0.categoryID == category.id }
            .sorted { $0.manualOrder == $1.manualOrder ? $0.id < $1.id : $0.manualOrder < $1.manualOrder }
        XCTAssertEqual(sameCategoryCollections.first?.id, secondCollection.id)

        let createdSecondCategory = await organizer.createCategory(name: "分类B")
        let secondCategory = try XCTUnwrap(createdSecondCategory)
        await organizer.moveCollection(id: firstCollection.id, toCategoryID: secondCategory.id)
        organizer.openCollection(id: firstCollection.id)
        XCTAssertEqual(organizer.selectedCategoryID, secondCategory.id)
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget])
        let movedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == firstTarget }
        XCTAssertTrue(movedItem?.locations.contains(.collection(categoryID: secondCategory.id, collectionID: firstCollection.id)) == true)

        await organizer.dissolveCollection(id: firstCollection.id)
        XCTAssertNil(organizer.selectedCollection)
        XCTAssertFalse(organizer.collections.contains { $0.id == firstCollection.id })
        let dissolvedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == firstTarget }
        XCTAssertTrue(dissolvedItem?.locations.contains(.category(secondCategory.id)) == true)
        XCTAssertFalse(dissolvedItem?.locations.contains { $0.collectionID == firstCollection.id } == true)
    }

    /// `rootDerived` must keep reflecting the whole category (cards *and*
    /// collections) even while a collection is open, so the root favorites
    /// screen — which `NavigationStack` keeps mounted underneath the pushed
    /// collection detail page — never renders the same narrowed content as
    /// the detail page during an interactive edge-swipe-back gesture.
    func testRootDerivedStaysUnscopedWhileCollectionIsOpen() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-root-derived")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        let createdCategory = await organizer.createCategory(name: "分类A")
        let category = try XCTUnwrap(createdCategory)
        let createdCollection = await organizer.createCollection(name: "合集A", color: .blue)
        let collection = try XCTUnwrap(createdCollection)

        let collectionTarget = FavoriteItemTarget(kind: .normalThread, threadID: "920")
        let rootTarget = FavoriteItemTarget(kind: .normalThread, threadID: "921")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: collectionTarget,
            title: "合集内主题",
            locations: [
                .category(category.id),
                .collection(categoryID: category.id, collectionID: collection.id)
            ]
        ))
        document.upsertItem(try FavoriteItem(
            target: rootTarget,
            title: "分类根主题",
            locations: [.category(category.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        // `createCollection` above already opened the new collection; return
        // to the root scope so the "before opening" assertions below reflect
        // how a user would actually land on this screen.
        organizer.closeCollection()

        // Before opening the collection, `rootDerived` mirrors `derived`.
        XCTAssertEqual(organizer.rootDerived.cards.map(\.item.target), organizer.derived.cards.map(\.item.target))
        XCTAssertTrue(organizer.rootDerived.mixedEntries.contains { if case let .collection(c) = $0 { c.id == collection.id } else { false } })

        organizer.openCollection(id: collection.id)

        // `derived` (the pushed detail page's scope) narrows to the
        // collection's own member and drops sibling collections.
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [collectionTarget])
        XCTAssertFalse(organizer.derived.mixedEntries.contains { if case .collection = $0 { true } else { false } })

        // `rootDerived` (the root page's scope) must still show everything,
        // unaffected by the collection being open.
        XCTAssertEqual(Set(organizer.rootDerived.cards.map(\.item.target)), [collectionTarget, rootTarget])
        XCTAssertTrue(organizer.rootDerived.mixedEntries.contains { if case let .collection(c) = $0 { c.id == collection.id } else { false } })
    }

    /// A merged card's "查看归档收藏" detail page (`openMergedGroup`) must scope
    /// `derived.cards` to one standalone card per individual member — not a
    /// frozen id snapshot but a live re-resolve by directory identity, the
    /// same principle `openCollection`/`selectedCollectionID` already use —
    /// while `rootDerived` stays exactly as unscoped as it already is today,
    /// mirroring `testRootDerivedStaysUnscopedWhileCollectionIsOpen` above.
    func testOpenMergedGroupScopesCardsToIndividualMembersWhileRootDerivedStaysUnscoped() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-merged-group")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "归档收藏测试漫画",
            strategy: .links,
            sourceKey: "chapter:990",
            chapters: [
                MangaChapter(tid: "990", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "991", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "990")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "991")
        var document = try await localFavoriteLibraryStore.load()
        // Chinese-numeral chapter titles ("第一话"/"第二话") deliberately match
        // this file's existing merged-card fixtures — `MangaTitleCleaner
        // .cleanBookName`'s chapter-marker strip only matches ASCII digits,
        // so these pass through `resolvedTitle` unmodified, keeping the
        // "member's own raw title" assertion below a direct equality check.
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        // Before opening the merged group's detail page: a single merged
        // card in both `derived` and `rootDerived`.
        XCTAssertEqual(organizer.derived.cards.count, 1)
        XCTAssertTrue(organizer.derived.cards[0].isMergedGroup)
        XCTAssertEqual(organizer.rootDerived.cards.count, 1)
        XCTAssertTrue(organizer.rootDerived.cards[0].isMergedGroup)

        organizer.openMergedGroup(cleanBookName: directory.cleanBookName)

        // `derived` (the pushed detail page's scope) narrows to one
        // standalone card per member, each showing its own raw title rather
        // than the shared `cleanBookName`.
        XCTAssertEqual(organizer.derived.cards.count, 2)
        XCTAssertTrue(organizer.derived.cards.allSatisfy { !$0.isMergedGroup })
        XCTAssertEqual(Set(organizer.derived.cards.map(\.item.target)), [firstTarget, secondTarget])
        let firstCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == firstTarget })
        let secondCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == secondTarget })
        XCTAssertEqual(firstCard.resolvedTitle, "第一话")
        XCTAssertEqual(secondCard.resolvedTitle, "第二话")

        // `rootDerived` (the root page's scope) must still show the single
        // merged card, unaffected by the merged-group detail page being
        // open — same protection `rootDerived` already gives
        // `selectedCollectionID`.
        XCTAssertEqual(organizer.rootDerived.cards.count, 1)
        XCTAssertTrue(organizer.rootDerived.cards[0].isMergedGroup)
        XCTAssertEqual(organizer.rootDerived.cards[0].mergedMembers?.map(\.target), [firstTarget, secondTarget])
    }

    /// Regression test for the user-reported bug: opening a smart card's
    /// "查看归档收藏" archive detail page directly from the root list (the
    /// common path — `selectedCollectionID` stays `nil` throughout, unlike
    /// `testDeleteItemWhileMergedGroupDetailIsOpenRemovesOnlyThatMemberLeaving
    /// SiblingFavorited` below, which never opens a collection either but
    /// doesn't probe collections) must not leak the current category's
    /// sibling collections into the archive page's content or "select all" —
    /// mirrors `testRootDerivedStaysUnscopedWhileCollectionIsOpen`'s own
    /// collection-presence assertions, but for `selectedMergedGroupCleanBookName`
    /// instead of `selectedCollectionID`.
    func testOpenMergedGroupFromRootExcludesSiblingCollectionFromArchivePage() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-merged-group-excludes-collection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "归档收藏排除合集测试漫画",
            strategy: .links,
            sourceKey: "chapter:970",
            chapters: [
                MangaChapter(tid: "970", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "971", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        // A sibling collection in the same (default) category as the smart
        // card below — this is exactly what must NOT show up once the
        // archive page is open.
        let createdCollection = await organizer.createCollection(name: "同分类合集", color: .blue)
        let collection = try XCTUnwrap(createdCollection)
        organizer.closeCollection()

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "970")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "971")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()

        // Sanity: before opening the archive page, the collection is part of
        // the normal root scope.
        XCTAssertTrue(organizer.rootDerived.mixedEntries.contains { if case let .collection(c) = $0 { c.id == collection.id } else { false } })

        // Opened directly from the root list — `selectedCollectionID` never
        // becomes non-nil, only `selectedMergedGroupCleanBookName` does.
        organizer.openMergedGroup(cleanBookName: directory.cleanBookName)
        XCTAssertNil(organizer.selectedCollectionID)
        XCTAssertEqual(organizer.selectedMergedGroupCleanBookName, directory.cleanBookName)

        // The archive page's content must be exactly the two archived
        // members — no sibling collection mixed in.
        XCTAssertEqual(organizer.derived.cards.count, 2)
        XCTAssertFalse(organizer.derived.mixedEntries.contains { if case .collection = $0 { true } else { false } })

        // "Select all" on the archive page must only pick up the two
        // archived members, never the sibling collection.
        organizer.selectAllVisible()
        XCTAssertEqual(organizer.selection.selectedFavoriteIDs, Set([firstTarget.id, secondTarget.id]))
        XCTAssertTrue(organizer.selection.selectedCollectionIDs.isEmpty)
        XCTAssertTrue(organizer.isAllVisibleSelected)
    }

    /// Once a merged group's detail page is open, per-item management must
    /// actually work through the same single-item delete entry point every
    /// other favorite uses — deleting one member removes only that member,
    /// leaving its sibling favorited, and the (still-open) detail page's
    /// live re-resolve immediately reflects the change with no manual
    /// reopen — proving `memberScopeCleanBookName` really is identity-based
    /// scoping and not a frozen snapshot.
    func testDeleteItemWhileMergedGroupDetailIsOpenRemovesOnlyThatMemberLeavingSiblingFavorited() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-delete-in-merged-group-detail")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "归档收藏删除测试漫画",
            strategy: .links,
            sourceKey: "chapter:992",
            chapters: [
                MangaChapter(tid: "992", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "993", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "992")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "993")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        organizer.openMergedGroup(cleanBookName: directory.cleanBookName)
        XCTAssertEqual(organizer.derived.cards.count, 2)
        let firstCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == firstTarget })

        await organizer.deleteItem(firstCard.item, scope: .everywhere, removeRemote: false)
        XCTAssertNil(organizer.errorMessage)

        // Still open, still scoped — now showing only the sibling member.
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [secondTarget])
        XCTAssertEqual(organizer.selectedMergedGroupCleanBookName, directory.cleanBookName)
        let remainingTargets = Set(try await localFavoriteLibraryStore.load().items.map(\.target))
        XCTAssertEqual(remainingTargets, [secondTarget])
    }

    /// Regression test: `selectedMergedGroupCleanBookName`'s `didSet` must
    /// clear `selection` exactly like `selectedCollectionID`'s own `didSet`
    /// already does. Before this fix, opening a smart card's "查看归档收藏"
    /// detail page left a previously-selected smart card's id sitting in
    /// `selection.selectedFavoriteIDs` while its meaning silently flipped —
    /// `isSmartCardFavoriteID` always reports `false` while this page is
    /// open (by its own doc comment) — from "the whole archived group" to
    /// "just this one representative item, now treated as an ordinary card",
    /// which would make `deleteSelection` delete only the representative and
    /// orphan its siblings if the user tapped delete in that state. This
    /// proves both directions: opening the archive page clears the
    /// selection, and so does closing it from an already-open state.
    func testOpenAndCloseMergedGroupClearSelection() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-merged-group-clears-selection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "打开归档清空选择测试漫画",
            strategy: .links,
            sourceKey: "chapter:4141",
            chapters: [
                MangaChapter(tid: "4141", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4142", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4141")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4142")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        // Direction one: selecting the smart card, then opening its own
        // archive page, must clear the selection.
        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        XCTAssertTrue(organizer.selection.isSelectionMode)
        XCTAssertFalse(organizer.selection.selectedFavoriteIDs.isEmpty)

        organizer.openMergedGroup(cleanBookName: directory.cleanBookName)

        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.isEmpty)
        XCTAssertFalse(organizer.selection.isSelectionMode)

        // Direction two: selecting a member while the archive page is open,
        // then closing it, must also clear the selection.
        let memberCard = try XCTUnwrap(organizer.derived.cards.first)
        organizer.selection.toggleFavoriteSelection(id: memberCard.id)
        XCTAssertTrue(organizer.selection.isSelectionMode)
        XCTAssertFalse(organizer.selection.selectedFavoriteIDs.isEmpty)

        organizer.closeMergedGroup()

        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.isEmpty)
        XCTAssertFalse(organizer.selection.isSelectionMode)
    }

    /// A smart card CAN now end up in `selection.selectedFavoriteIDs` — the
    /// toolbar "select all" (`selectAllVisible()`) includes it exactly like
    /// any other card (2026-07-09 feature: selecting/bulk-acting on a smart
    /// card is equivalent to selecting/acting on every favorite archived
    /// under it, expanded transparently at execution time by
    /// `expandedSelectionFavoriteIDs` — see that function's own doc
    /// comment). This covers the two paths that don't go through
    /// `LocalFavoriteGridCard`/`LocalFavoriteItemRow`'s own tap-to-select
    /// handling: the toolbar "select all" (`selectAllVisible()`) and
    /// `isAllVisibleSelected`'s/`hasVisibleSelectableEntries`'s bookkeeping.
    /// Also covers a LONE resolved-directory favorite (`isMergedGroup ==
    /// false`, no sibling ever joined it) — `isModeOnMangaThread`, not
    /// `isMergedGroup`, is still the single source of truth for "is this a
    /// smart card", so a card that displays `resolvedTitle`'s cleaned book
    /// name is included in "select all" even when it never actually merged
    /// with anyone.
    func testSelectAllVisibleAndIsAllVisibleSelectedIncludeSmartCardsMergedOrNot() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-select-all-includes-merged")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "全选测试漫画",
            strategy: .links,
            sourceKey: "chapter:994",
            chapters: [
                MangaChapter(tid: "994", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "995", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)
        // A second, single-chapter directory — resolved locally, but never
        // joined by any sibling favorite, so it stays `isMergedGroup ==
        // false` while still being `isModeOnMangaThread == true`.
        let loneDirectory = MangaDirectory(
            cleanBookName: "全选测试孤本漫画",
            strategy: .links,
            sourceKey: "chapter:993",
            chapters: [
                MangaChapter(tid: "993", rawTitle: "第一话", chapterNumber: 1),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(loneDirectory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "994")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "995")
        let standaloneTarget = FavoriteItemTarget(kind: .normalThread, threadID: "996")
        let loneResolvedTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "993")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let standaloneItem = try FavoriteItem(
            target: standaloneTarget,
            title: "普通收藏",
            locations: [.category(document.defaultCategory.id)]
        )
        let loneResolvedItem = try FavoriteItem(
            target: loneResolvedTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        document.upsertItem(standaloneItem)
        document.upsertItem(loneResolvedItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        // One merged card (representative id == firstItem.id), one lone
        // resolved-directory card, plus one standalone card.
        XCTAssertEqual(organizer.derived.cards.count, 3)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })
        XCTAssertEqual(mergedCard.id, firstItem.id)
        let loneResolvedCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == loneResolvedItem.id })
        XCTAssertFalse(loneResolvedCard.isMergedGroup)
        XCTAssertTrue(loneResolvedCard.isModeOnMangaThread)
        XCTAssertNotNil(loneResolvedCard.mangaDirectory)

        organizer.selectAllVisible()

        // Every visible card was selected, including both smart cards — the
        // id that lands in `selectedFavoriteIDs` is still each card's own
        // representative id; expansion to archived members only happens at
        // bulk-operation execution time, not at selection time.
        XCTAssertEqual(
            organizer.selection.selectedFavoriteIDs,
            [standaloneItem.id, mergedCard.id, loneResolvedCard.id]
        )
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.contains(mergedCard.id))
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.contains(loneResolvedCard.id))

        // "Everything selectable" is already fully selected — both smart
        // cards count toward the total now.
        XCTAssertTrue(organizer.isAllVisibleSelected)
        XCTAssertTrue(organizer.hasVisibleSelectableEntries)
    }

    /// The actual fix, half one: a lone (never-merged) resolved-directory
    /// favorite already shows `resolvedTitle`'s cleaned book name (same as a
    /// genuinely merged card — see `FavoriteCardProjection.resolvedTitle`'s
    /// doc comment), so it must get the exact same smart-card treatment:
    /// `isModeOnMangaThread` (not `isMergedGroup`) is the gate the sparkles
    /// badge and its "查看归档收藏" detail page key off, and that detail page
    /// opens to exactly that one favorite. (Bulk selection itself no longer
    /// excludes a smart card — see `testSelectingSmartCardsBothLoneResolved
    /// AndMergedEntersSelection` and friends for that, 2026-07-09 feature.)
    func testLoneResolvedDirectoryFavoriteGetsSmartCardTreatmentWithoutBeingMerged() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-lone-resolved-smart-card")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "孤本解析漫画",
            strategy: .links,
            sourceKey: "chapter:996",
            chapters: [
                MangaChapter(tid: "996", rawTitle: "第一话", chapterNumber: 1),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "996")
        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: target,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.count, 1)
        let card = try XCTUnwrap(organizer.derived.cards.first)
        // Resolved directory, but never merged with any sibling.
        XCTAssertFalse(card.isMergedGroup)
        XCTAssertNil(card.mergedMembers)
        XCTAssertEqual(card.mangaDirectory?.cleanBookName, "孤本解析漫画")
        XCTAssertEqual(card.resolvedTitle, "孤本解析漫画")
        // The gate the UI actually reads for smart-card treatment.
        XCTAssertTrue(card.isModeOnMangaThread)

        // Selectable via "select all" exactly like a genuinely merged card.
        organizer.selectAllVisible()
        XCTAssertEqual(organizer.selection.selectedFavoriteIDs, [card.id])

        // "查看归档收藏" opens to exactly this one favorite.
        organizer.openMergedGroup(cleanBookName: card.resolvedTitle)
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [target])
    }

    /// The actual fix, half two: a mode-on `.mangaThread` favorite whose
    /// directory has never been resolved locally at all (still on the local
    /// `MangaTitleCleaner` fallback title) must get the exact same
    /// smart-card treatment, and its "查看归档收藏" detail page must open to
    /// exactly that one favorite too — a "singleton archive" with no
    /// resolved directory involved at all, requiring no special-casing in
    /// `cards(in:query:...)`'s member-scope filter.
    func testUnresolvedModeOnFavoriteUsingLocalCleanFallbackGetsSmartCardTreatmentAndOpensSingletonArchive() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-unresolved-smart-card")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )

        let target = FavoriteItemTarget(kind: .mangaThread, threadID: "997")
        var document = try await localFavoriteLibraryStore.load()
        let rawTitle = "【作者】未解析作品 第3话"
        let item = try FavoriteItem(
            target: target,
            title: rawTitle,
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)

        // No `mangaDirectoryStore` at all — this favorite's directory has
        // never been resolved locally, mirroring a synced-but-never-opened
        // favorite.
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.count, 1)
        let card = try XCTUnwrap(organizer.derived.cards.first)
        XCTAssertNil(card.mangaDirectory)
        XCTAssertFalse(card.isMergedGroup)
        XCTAssertTrue(card.isModeOnMangaThread)
        XCTAssertEqual(card.resolvedTitle, MangaTitleCleaner.cleanBookName(rawTitle))
        XCTAssertEqual(card.resolvedTitle, "未解析作品")
        XCTAssertNotEqual(card.resolvedTitle, rawTitle)

        // Selectable via "select all" exactly like a resolved/merged card.
        organizer.selectAllVisible()
        XCTAssertEqual(organizer.selection.selectedFavoriteIDs, [card.id])

        // "查看归档收藏" opens to exactly this one favorite — a singleton
        // archive, with no resolved directory involved at all.
        organizer.openMergedGroup(cleanBookName: card.resolvedTitle)
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [target])
    }

    /// Regression test for the actual user-reported bug ("查看归档收藏内显示的
    /// 不是原贴而是相同的智能卡片"): `card(for:...)` used to recompute
    /// `isModeOnMangaThread` from the raw item/`boardReaderSettings`
    /// regardless of which query path built the entry, so every card on the
    /// "查看归档收藏" archive page — despite being deliberately built as a
    /// forced-standalone `GroupedFavoriteEntry` (nil `members`/
    /// `mangaDirectory`) so it displays that member's own raw title and
    /// behaves like an ordinary, directly-manageable card — still came back
    /// `isModeOnMangaThread == true`. Since that single flag now drives BOTH
    /// `resolvedTitle`'s local-clean fallback AND every smart-card UI gate
    /// (sparkles badge, delete blocked in favor of another "查看归档收藏"
    /// button, excluded from bulk selection), every member's card
    /// independently cleaned down to the SAME shared book name and got the
    /// smart-card treatment — the whole archive page looked like N copies of
    /// one unmanageable smart card instead of N distinguishable,
    /// individually-manageable posts. This proves each scoped card is an
    /// ordinary card: `isModeOnMangaThread == false` and `resolvedTitle`
    /// equal to that specific item's own raw title, not the shared
    /// `cleanBookName` and not identical across members.
    func testOpenMergedGroupScopedCardsAreOrdinaryCardsNotSmartCards() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-archive-page-not-smart-cards")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "归档收藏非智能卡片测试漫画",
            strategy: .links,
            sourceKey: "chapter:998",
            chapters: [
                MangaChapter(tid: "998", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "999", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "998")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "999")
        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: firstTarget,
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        let secondItem = try FavoriteItem(
            target: secondTarget,
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(secondItem)
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        // Before opening the archive page: one merged smart card, correctly
        // mode-on.
        XCTAssertEqual(organizer.derived.cards.count, 1)
        XCTAssertTrue(organizer.derived.cards[0].isModeOnMangaThread)

        organizer.openMergedGroup(cleanBookName: directory.cleanBookName)

        // The archive page: one ordinary card per member.
        XCTAssertEqual(organizer.derived.cards.count, 2)
        let firstCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == firstTarget })
        let secondCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == secondTarget })

        // The actual bug: every scoped card must NOT get the smart-card
        // treatment, even though each member is itself a mode-on
        // `.mangaThread` favorite (that's WHY it matched the archive scope).
        XCTAssertFalse(firstCard.isModeOnMangaThread)
        XCTAssertFalse(secondCard.isModeOnMangaThread)

        // Each card shows its OWN distinguishing raw title, not the shared
        // book name, and not identical across members — proving the page
        // shows N distinguishable posts rather than N copies of the same
        // collapsed smart card.
        XCTAssertEqual(firstCard.resolvedTitle, "第一话")
        XCTAssertEqual(secondCard.resolvedTitle, "第二话")
        XCTAssertNotEqual(firstCard.resolvedTitle, directory.cleanBookName)
        XCTAssertNotEqual(secondCard.resolvedTitle, directory.cleanBookName)
        XCTAssertNotEqual(firstCard.resolvedTitle, secondCard.resolvedTitle)

        // Every resulting card in the scoped derivation is affected, not
        // just these two by coincidence.
        XCTAssertTrue(organizer.derived.cards.allSatisfy { !$0.isModeOnMangaThread })
    }

    // MARK: - Smart-card selection and bulk operations (2026-07-09 feature)

    /// A smart card — lone-resolved or genuinely merged alike — is now
    /// selectable exactly like any other card: its own representative id
    /// lands in `selection.selectedFavoriteIDs` on tap, same as before this
    /// feature only a non-smart card would.
    func testSelectingSmartCardsBothLoneResolvedAndMergedEntersSelection() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-select")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let mergedDirectory = MangaDirectory(
            cleanBookName: "可选中合并测试漫画",
            strategy: .links,
            sourceKey: "chapter:4001",
            chapters: [
                MangaChapter(tid: "4001", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4002", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(mergedDirectory)
        let loneDirectory = MangaDirectory(
            cleanBookName: "可选中孤本测试漫画",
            strategy: .links,
            sourceKey: "chapter:4010",
            chapters: [
                MangaChapter(tid: "4010", rawTitle: "第一话", chapterNumber: 1),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(loneDirectory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4001")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4002")
        let loneTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4010")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: loneTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()

        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })
        XCTAssertTrue(mergedCard.isModeOnMangaThread)
        let loneCard = try XCTUnwrap(organizer.derived.cards.first { $0.id == loneTarget.id })
        XCTAssertTrue(loneCard.isModeOnMangaThread)
        XCTAssertFalse(loneCard.isMergedGroup)

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        organizer.selection.toggleFavoriteSelection(id: loneCard.id)

        XCTAssertTrue(organizer.selection.isSelectionMode)
        XCTAssertEqual(organizer.selection.selectedFavoriteIDs, [mergedCard.id, loneCard.id])
    }

    /// Moving a selected smart card moves EVERY favorite archived under it,
    /// not just its representative member.
    func testMoveSelectionToCategoryWithSmartCardMovesEveryArchivedMember() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-move")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "批量移动测试漫画",
            strategy: .links,
            sourceKey: "chapter:4101",
            chapters: [
                MangaChapter(tid: "4101", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4102", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4101")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4102")
        var document = try await localFavoriteLibraryStore.load()
        let defaultCategoryID = document.defaultCategory.id
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        let createdCategory = await organizer.createCategory(name: "智能卡片移动目标分类")
        let targetCategory = try XCTUnwrap(createdCategory)
        // `createCategory` switches `selectedCategoryID` to the newly created
        // category as a side effect — switch back to where the smart card's
        // members actually live before selecting it, or `derived.cards`
        // (and `expandedSelectionFavoriteIDs`'s lookup into it) would be
        // scoped to the empty new category instead.
        organizer.selectedCategoryID = defaultCategoryID

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        await organizer.moveSelectionToCategory(id: targetCategory.id)

        XCTAssertFalse(organizer.selection.isSelectionMode)
        let loadedDocument = try await localFavoriteLibraryStore.load()
        let movedFirst = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let movedSecond = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertTrue(movedFirst.locations.contains(.category(targetCategory.id)))
        XCTAssertTrue(movedSecond.locations.contains(.category(targetCategory.id)))
        XCTAssertFalse(movedFirst.locations.contains(.category(defaultCategoryID)))
        XCTAssertFalse(movedSecond.locations.contains(.category(defaultCategoryID)))
    }

    /// Regression test for the move sheet's actual UI path:
    /// `selectionLocationState(_:)`/`setSelectionLocation(_:included:)` — the
    /// two methods `LocalFavoriteSelectionMoveSheet` actually calls — must
    /// route through `expandedSelectionFavoriteIDs` exactly like
    /// `moveSelectionToCategory` and friends already do, so a selected smart
    /// card's tri-state readout and location toggle both apply to EVERY
    /// archived member, not just its representative. Before this fix, only
    /// the representative member's own id was ever consulted (or moved),
    /// hiding the bug behind a card whose collection membership already
    /// matched: the representative alone carries a collection location the
    /// sibling doesn't, so the correct tri-state readout is `.some`, not
    /// `.all` — a bug that a test only checking the representative's own
    /// state could never catch.
    func testSetSelectionLocationAndSelectionLocationStateWithSmartCardExpandToEveryArchivedMember() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-move-sheet")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "移动面板测试漫画",
            strategy: .links,
            sourceKey: "chapter:4121",
            chapters: [
                MangaChapter(tid: "4121", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4122", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4121")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4122")
        var document = try await localFavoriteLibraryStore.load()
        let defaultCategoryID = document.defaultCategory.id
        // Only the earliest-chapter (representative) member carries this
        // collection location — the sibling doesn't — so the correct
        // tri-state readout across the whole archived group is `.some`, not
        // `.all`.
        let partialCollection = document.createCollection(categoryID: defaultCategoryID, name: "部分归属合集", color: .blue)
        // Neither archived member carries this second collection at all.
        let emptyCollection = document.createCollection(categoryID: defaultCategoryID, name: "空合集", color: .gray)
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [
                .category(defaultCategoryID),
                .collection(categoryID: defaultCategoryID, collectionID: partialCollection.id),
            ]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })
        XCTAssertEqual(mergedCard.id, firstTarget.id)

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)

        let partialLocation = FavoriteLocation.collection(categoryID: defaultCategoryID, collectionID: partialCollection.id)
        let emptyLocation = FavoriteLocation.collection(categoryID: defaultCategoryID, collectionID: emptyCollection.id)

        XCTAssertEqual(organizer.selectionLocationState(emptyLocation), .none)
        // The actual bug this fixes: only ONE of the two archived members
        // carries `partialLocation`, so the correct readout is `.some` — a
        // pre-fix, unexpanded readout (just the representative's own id,
        // which already has the location) would have wrongly reported `.all`.
        XCTAssertEqual(organizer.selectionLocationState(partialLocation), .some)

        await organizer.setSelectionLocation(partialLocation, included: true)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let firstStored = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let secondStored = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        // Every archived member now carries the location, not just the
        // representative — proving `setSelectionLocation` (the move sheet's
        // real code path) expands correctly.
        XCTAssertTrue(firstStored.locations.contains(partialLocation))
        XCTAssertTrue(secondStored.locations.contains(partialLocation))
        XCTAssertEqual(organizer.selectionLocationState(partialLocation), .all)
    }

    /// Creating a collection from a selection containing a smart card puts
    /// EVERY archived member into the new collection.
    func testCreateCollectionFromSelectionWithSmartCardIncludesEveryArchivedMember() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-create-collection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "创建合集测试漫画",
            strategy: .links,
            sourceKey: "chapter:4201",
            chapters: [
                MangaChapter(tid: "4201", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4202", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4201")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4202")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        let createdCollection = await organizer.createCollectionFromSelection(name: "智能卡片合集", color: .green)
        let collection = try XCTUnwrap(createdCollection)

        XCTAssertFalse(organizer.selection.isSelectionMode)
        let loadedDocument = try await localFavoriteLibraryStore.load()
        let firstStored = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let secondStored = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertTrue(firstStored.locations.contains(.collection(categoryID: collection.categoryID, collectionID: collection.id)))
        XCTAssertTrue(secondStored.locations.contains(.collection(categoryID: collection.categoryID, collectionID: collection.id)))
    }

    /// Bulk tag editing (`updateTagsForSelection`) with a smart card selected
    /// applies the new tags to EVERY archived member.
    func testUpdateTagsForSelectionWithSmartCardAppliesToEveryArchivedMember() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-bulk-tags")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "批量标签测试漫画",
            strategy: .links,
            sourceKey: "chapter:4301",
            chapters: [
                MangaChapter(tid: "4301", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4302", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4301")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4302")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let createdTag = await organizer.createTag(name: "批量标签", color: .blue)
        let tag = try XCTUnwrap(createdTag)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        await organizer.updateTagsForSelection([tag.id])

        XCTAssertFalse(organizer.selection.isSelectionMode)
        let loadedDocument = try await localFavoriteLibraryStore.load()
        let firstStored = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let secondStored = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertEqual(firstStored.tagIDs, [tag.id])
        XCTAssertEqual(secondStored.tagIDs, [tag.id])
    }

    /// The easy-to-miss single-item path: `updateTags(for:tagIDs:)` (the
    /// context-menu "标签" button, reachable for a smart card too) ALSO
    /// applies to every archived member, not just the one item id it was
    /// called with.
    func testUpdateTagsForSingleSmartCardRepresentativeAppliesToEveryArchivedMember() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-single-tags")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "单项标签测试漫画",
            strategy: .links,
            sourceKey: "chapter:4401",
            chapters: [
                MangaChapter(tid: "4401", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4402", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4401")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4402")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let createdTag = await organizer.createTag(name: "单项标签", color: .purple)
        let tag = try XCTUnwrap(createdTag)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })
        // The representative member's own id — not a selection at all.
        XCTAssertEqual(mergedCard.id, firstTarget.id)

        await organizer.updateTags(for: mergedCard.id, tagIDs: [tag.id])

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let firstStored = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let secondStored = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertEqual(firstStored.tagIDs, [tag.id])
        XCTAssertEqual(secondStored.tagIDs, [tag.id])
    }

    /// `deleteSelection` with a mix of a smart card id and a normal item id,
    /// with `smartMangaBulkDeleteEnabled` explicitly off (the setting's
    /// disabled path): the normal item is deleted, every one of the smart
    /// card's archived members is left untouched/still favorited, and
    /// `transientMessage` is set to explain the skip.
    func testDeleteSelectionSkipsSmartCardDeletesNormalItemAndSetsTransientMessage() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-delete-mixed")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        _ = try await settingsStore.update { settings in
            settings.favorites.smartMangaBulkDeleteEnabled = false
        }
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "混合删除测试漫画",
            strategy: .links,
            sourceKey: "chapter:4501",
            chapters: [
                MangaChapter(tid: "4501", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4502", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4501")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4502")
        let normalTarget = FavoriteItemTarget(kind: .normalThread, threadID: "4510")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: normalTarget, title: "普通收藏",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        organizer.selection.toggleFavoriteSelection(id: normalTarget.id)
        organizer.transientMessage = nil

        await organizer.deleteSelection(scope: .everywhere, removeRemote: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        XCTAssertNil(loadedDocument.items.first { $0.target == normalTarget })
        XCTAssertNotNil(loadedDocument.items.first { $0.target == firstTarget })
        XCTAssertNotNil(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertNotNil(organizer.transientMessage)
        XCTAssertFalse(organizer.selection.isSelectionMode)
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.isEmpty)
    }

    /// Backs `LocalFavoriteSelectionActionBar`'s delete-button visibility —
    /// per that view's own "hidden, not merely disabled" principle, with
    /// `smartMangaBulkDeleteEnabled` explicitly off (the setting's disabled
    /// path) a selection made up entirely of smart cards (which
    /// `deleteSelection` skips in that mode) must report nothing deletable,
    /// while a mixed selection still does since the normal item within it is
    /// actually deletable.
    func testHasDeletableSelectionExcludesSmartCardOnlySelectionButIncludesMixedSelection() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-has-deletable-selection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        _ = try await settingsStore.update { settings in
            settings.favorites.smartMangaBulkDeleteEnabled = false
        }
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "可删除性判断测试漫画",
            strategy: .links,
            sourceKey: "chapter:4601",
            chapters: [MangaChapter(tid: "4601", rawTitle: "第一话", chapterNumber: 1)]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let smartTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4601")
        let normalTarget = FavoriteItemTarget(kind: .normalThread, threadID: "4610")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: smartTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: normalTarget, title: "普通收藏",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()
        let smartCard = try XCTUnwrap(organizer.derived.cards.first { $0.isModeOnMangaThread })

        organizer.selection.toggleFavoriteSelection(id: smartCard.id)
        XCTAssertFalse(organizer.hasDeletableSelection)

        organizer.selection.toggleFavoriteSelection(id: normalTarget.id)
        XCTAssertTrue(organizer.hasDeletableSelection)

        organizer.selection.toggleFavoriteSelection(id: smartCard.id)
        XCTAssertTrue(organizer.hasDeletableSelection)
    }

    /// Enabled-path counterpart: with `smartMangaBulkDeleteEnabled` at its
    /// default (on), a selection made up entirely of smart cards IS fully
    /// deletable (every one of them expands to its whole archive), so the
    /// selection toolbar's delete button must show for it too instead of
    /// hiding as it does in the disabled path.
    func testHasDeletableSelectionIncludesSmartCardOnlySelectionWhenBulkDeleteEnabled() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-has-deletable-selection-enabled")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "可删除性判断启用测试漫画",
            strategy: .links,
            sourceKey: "chapter:4651",
            chapters: [MangaChapter(tid: "4651", rawTitle: "第一话", chapterNumber: 1)]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let smartTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4651")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: smartTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        XCTAssertTrue(organizer.smartMangaBulkDeleteEnabled)
        let smartCard = try XCTUnwrap(organizer.derived.cards.first { $0.isModeOnMangaThread })

        organizer.selection.toggleFavoriteSelection(id: smartCard.id)
        XCTAssertTrue(organizer.hasDeletableSelection)
    }

    /// Regression guard for a filter-driven variant of the same skip logic:
    /// `filter.searchText`'s own `didSet` deliberately never clears
    /// `selection` ("search is a plain live filter, not a session mode" —
    /// `LocalFavoriteBrowseSession`'s doc comment), so a smart card selected
    /// while visible can be scrolled clean out of `derived.cards` by a
    /// subsequent search before the user taps delete — the id stays
    /// selected, but a `derived.cards`-only lookup would no longer find it.
    /// `deleteSelection`'s skip check must still catch it in that state (it
    /// used to rely on `derived.cards.first(where:)`, which this search
    /// change defeats), or it would fall through to a lone,
    /// sibling-orphaning delete of just the representative item. Runs with
    /// `smartMangaBulkDeleteEnabled` explicitly off (the setting's disabled
    /// path) — see
    /// `testDeleteSelectionWithBulkDeleteEnabledExpandsAndDeletesEveryArchivedMemberEvenAfterSearchFiltersItOut`
    /// for the enabled-path counterpart.
    func testDeleteSelectionSkipsSmartCardEvenAfterSearchFiltersItOutOfDerivedCards() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-delete-filtered-out")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        _ = try await settingsStore.update { settings in
            settings.favorites.smartMangaBulkDeleteEnabled = false
        }
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "搜索过滤删除测试漫画",
            strategy: .links,
            sourceKey: "chapter:4901",
            chapters: [
                MangaChapter(tid: "4901", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4902", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4901")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4902")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.contains(mergedCard.id))

        // A search that matches nothing scrolls the smart card clean out of
        // `derived.cards` while it stays selected.
        organizer.filter.searchText = "这个搜索词不会匹配任何收藏"
        XCTAssertTrue(organizer.derived.cards.isEmpty)
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.contains(mergedCard.id))

        await organizer.deleteSelection(scope: .everywhere, removeRemote: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        // Both members survive — the smart card was skipped, not
        // individually deleted, even though it wasn't in `derived.cards`
        // when `deleteSelection` ran.
        XCTAssertNotNil(loadedDocument.items.first { $0.target == firstTarget })
        XCTAssertNotNil(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertNotNil(organizer.transientMessage)
        XCTAssertFalse(organizer.selection.isSelectionMode)
    }

    /// Enabled-path counterpart to
    /// `testDeleteSelectionSkipsSmartCardEvenAfterSearchFiltersItOutOfDerivedCards`:
    /// with `smartMangaBulkDeleteEnabled` at its default (on), the same
    /// scrolled-out-of-`derived.cards` smart card must still expand to every
    /// archived member and delete all of them — `deleteSelection`'s
    /// expansion path must use the same `derived.cards`-independent lookup
    /// as the skip path, not a `derived.cards.first(where:)` shortcut that a
    /// live search filter would defeat.
    func testDeleteSelectionWithBulkDeleteEnabledExpandsAndDeletesEveryArchivedMemberEvenAfterSearchFiltersItOut() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-bulk-delete-filtered-out")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "批量删除搜索过滤测试漫画",
            strategy: .links,
            sourceKey: "chapter:4903",
            chapters: [
                MangaChapter(tid: "4903", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4904", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4903")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4904")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        XCTAssertTrue(organizer.smartMangaBulkDeleteEnabled)
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        organizer.filter.searchText = "这个搜索词不会匹配任何收藏"
        XCTAssertTrue(organizer.derived.cards.isEmpty)

        await organizer.deleteSelection(scope: .everywhere, removeRemote: false)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        XCTAssertNil(loadedDocument.items.first { $0.target == firstTarget })
        XCTAssertNil(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertFalse(organizer.selection.isSelectionMode)
    }

    /// Same filtered-out-of-`derived.cards` scenario, but for the expansion
    /// path (`expandedSelectionFavoriteIDs`, exercised here via
    /// `moveSelectionToCategory`): a smart card selected and then scrolled
    /// out of view by a search must still expand to every archived member
    /// on move, not silently degrade to moving just its representative item.
    func testMoveSelectionToCategoryStillExpandsSmartCardEvenAfterSearchFiltersItOutOfDerivedCards() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-move-filtered-out")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "搜索过滤移动测试漫画",
            strategy: .links,
            sourceKey: "chapter:4911",
            chapters: [
                MangaChapter(tid: "4911", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4912", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4911")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4912")
        var document = try await localFavoriteLibraryStore.load()
        let defaultCategoryID = document.defaultCategory.id
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        let createdCategory = await organizer.createCategory(name: "搜索过滤移动目标分类")
        let targetCategory = try XCTUnwrap(createdCategory)
        organizer.selectedCategoryID = defaultCategoryID

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        organizer.filter.searchText = "这个搜索词不会匹配任何收藏"
        XCTAssertTrue(organizer.derived.cards.isEmpty)
        XCTAssertTrue(organizer.selection.selectedFavoriteIDs.contains(mergedCard.id))

        await organizer.moveSelectionToCategory(id: targetCategory.id)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let movedFirst = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let movedSecond = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        // Both members moved — the smart card still expanded correctly even
        // though it wasn't in `derived.cards` when the move ran.
        XCTAssertTrue(movedFirst.locations.contains(.category(targetCategory.id)))
        XCTAssertTrue(movedSecond.locations.contains(.category(targetCategory.id)))
    }

    /// Regression guard: the already-working case — a smart card whose
    /// members share a genuinely RESOLVED `MangaDirectory` — still shows the
    /// union of tags across every member, now computed by
    /// `cards(in:query:...)`'s own `archivedItems`-based union (Part B step
    /// 2) rather than `cardEntry(for:)`'s removed one.
    func testSmartCardTagsUnionAcrossResolvedDirectoryMembersRegression() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-tag-union-resolved")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "标签合并已解析漫画",
            strategy: .links,
            sourceKey: "chapter:4601",
            chapters: [
                MangaChapter(tid: "4601", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4602", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        let createdTagA = await organizer.createTag(name: "标签甲", color: .blue)
        let tagA = try XCTUnwrap(createdTagA)
        let createdTagB = await organizer.createTag(name: "标签乙", color: .pink)
        let tagB = try XCTUnwrap(createdTagB)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4601")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4602")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)], tagIDs: [tagA.id]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)], tagIDs: [tagB.id]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.load()

        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })
        XCTAssertTrue(mergedCard.isModeOnMangaThread)
        XCTAssertEqual(Set(mergedCard.tags.map(\.id)), Set([tagA.id, tagB.id]))
    }

    /// The actual new behavior under test: two mode-on `.mangaThread`
    /// favorites that never resolve to any `MangaDirectory` at all (both
    /// still on the independently-computed local-clean-fallback title) stay
    /// as two SEPARATE standalone cards — `cardEntry(for:)` never even sees
    /// them, since they never reach `rawGroupedFavorites`' resolved-directory
    /// grouping — yet both must now show the UNION of tags across every
    /// favorite sharing that guessed title, via the broader `archivedItems`
    /// membership `cards(in:query:...)` now unions from (Part B step 2).
    /// This is the case that was previously broken (each card showed only
    /// its own tags).
    func testSmartCardTagsUnionAcrossLocalCleanFallbackMembersWithoutResolvedDirectory() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-tag-union-fallback")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        let createdTagA = await organizer.createTag(name: "标签丙", color: .green)
        let tagA = try XCTUnwrap(createdTagA)
        let createdTagB = await organizer.createTag(name: "标签丁", color: .orange)
        let tagB = try XCTUnwrap(createdTagB)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4701")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4702")
        var document = try await localFavoriteLibraryStore.load()
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "【作者】未解析标签合并作品 第1话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)],
            tagIDs: [tagA.id]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "【作者】未解析标签合并作品 第2话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)],
            tagIDs: [tagB.id]
        ))
        try await localFavoriteLibraryStore.save(document)
        await organizer.load()

        // No `mangaDirectoryStore` at all — neither favorite's directory has
        // ever been resolved locally, so they stay two separate standalone
        // cards rather than merging.
        XCTAssertEqual(organizer.derived.cards.count, 2)
        let firstCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == firstTarget })
        let secondCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.target == secondTarget })
        XCTAssertNil(firstCard.mangaDirectory)
        XCTAssertNil(secondCard.mangaDirectory)
        XCTAssertFalse(firstCard.isMergedGroup)
        XCTAssertFalse(secondCard.isMergedGroup)
        XCTAssertTrue(firstCard.isModeOnMangaThread)
        XCTAssertTrue(secondCard.isModeOnMangaThread)
        XCTAssertEqual(firstCard.resolvedTitle, secondCard.resolvedTitle)

        XCTAssertEqual(Set(firstCard.tags.map(\.id)), Set([tagA.id, tagB.id]))
        XCTAssertEqual(Set(secondCard.tags.map(\.id)), Set([tagA.id, tagB.id]))
    }

    /// A normal (non-smart-card) item mixed into the same selection as a
    /// smart card is unaffected by the expansion — its own id, unexpanded,
    /// just moves normally alongside the smart card's expanded members.
    func testNormalItemMixedWithSmartCardSelectionMovesNormallyAlongsideExpandedMembers() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-mixed-move")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "混合移动测试漫画",
            strategy: .links,
            sourceKey: "chapter:4801",
            chapters: [
                MangaChapter(tid: "4801", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "4802", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        let firstTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4801")
        let secondTarget = FavoriteItemTarget(kind: .mangaThread, threadID: "4802")
        let normalTarget = FavoriteItemTarget(kind: .normalThread, threadID: "4810")
        var document = try await localFavoriteLibraryStore.load()
        let defaultCategoryID = document.defaultCategory.id
        document.upsertItem(try FavoriteItem(
            target: firstTarget, title: "第一话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget, title: "第二话", forumID: "30", forumName: "中文百合漫画区",
            locations: [.category(defaultCategoryID)]
        ))
        document.upsertItem(try FavoriteItem(
            target: normalTarget, title: "普通收藏",
            locations: [.category(defaultCategoryID)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore, mangaDirectoryStore: mangaDirectoryStore)
        await organizer.load()
        let mergedCard = try XCTUnwrap(organizer.derived.cards.first { $0.isMergedGroup })

        let createdCategory = await organizer.createCategory(name: "混合移动目标分类")
        let targetCategory = try XCTUnwrap(createdCategory)
        // See the matching comment in
        // `testMoveSelectionToCategoryWithSmartCardMovesEveryArchivedMember`
        // — `createCategory` leaves the new category selected, which would
        // scope `derived.cards` away from where these items actually live.
        organizer.selectedCategoryID = defaultCategoryID

        organizer.selection.toggleFavoriteSelection(id: mergedCard.id)
        organizer.selection.toggleFavoriteSelection(id: normalTarget.id)
        await organizer.moveSelectionToCategory(id: targetCategory.id)

        let loadedDocument = try await localFavoriteLibraryStore.load()
        let movedNormal = try XCTUnwrap(loadedDocument.items.first { $0.target == normalTarget })
        let movedFirst = try XCTUnwrap(loadedDocument.items.first { $0.target == firstTarget })
        let movedSecond = try XCTUnwrap(loadedDocument.items.first { $0.target == secondTarget })
        XCTAssertTrue(movedNormal.locations.contains(.category(targetCategory.id)))
        XCTAssertTrue(movedFirst.locations.contains(.category(targetCategory.id)))
        XCTAssertTrue(movedSecond.locations.contains(.category(targetCategory.id)))
    }

    func testCategoryManagementUpdatesLibraryCountsAndSelectedCategorySetting() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-categories")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore
        )
        await organizer.load()

        let createdCategory = await organizer.createCategory(name: "待读")
        let category = try XCTUnwrap(createdCategory)
        XCTAssertEqual(organizer.selectedCategoryID, category.id)

        var document = try await localFavoriteLibraryStore.load()
        let item = try FavoriteItem(
            target: FavoriteItemTarget(kind: .normalThread, threadID: "904"),
            title: "主题",
            locations: [.category(category.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        await organizer.reload()
        XCTAssertEqual(organizer.derived.categoryEntryCounts[category.id], 1)

        await organizer.renameCategory(id: category.id, name: "已读")
        XCTAssertTrue(organizer.categories.contains { $0.id == category.id && $0.name == "已读" })

        let createdSecondCategory = await organizer.createCategory(name: "同步")
        let second = try XCTUnwrap(createdSecondCategory)
        await organizer.moveCategory(id: second.id, direction: .up)
        let nonDefault = organizer.categories.filter { !$0.isDefault }.sorted { $0.manualOrder < $1.manualOrder }
        XCTAssertEqual(nonDefault.first?.id, second.id)

        await organizer.deleteCategory(id: second.id)
        XCTAssertFalse(organizer.categories.contains { $0.id == second.id })

        try await Task.sleep(nanoseconds: 50_000_000)
        let settings = await settingsStore.load()
        XCTAssertEqual(settings.favorites.selectedCategoryID, organizer.selectedCategoryID)
    }

    func testOpenCollectionStateLoadsAndPersistsThroughSettingsStore() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-open-collection")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "分类")
        let collection = document.createCollection(categoryID: category.id, name: "合集", color: .blue)
        try await localFavoriteLibraryStore.save(document)
        try await settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            selectedCategoryID: FavoriteCategory.defaultID,
            selectedCollectionID: collection.id
        )))

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore
        )
        await organizer.load()

        XCTAssertEqual(organizer.selectedCategoryID, category.id)
        XCTAssertEqual(organizer.selectedCollection?.id, collection.id)

        organizer.closeCollection()
        try await Task.sleep(nanoseconds: 50_000_000)
        var saved = await settingsStore.load()
        XCTAssertEqual(saved.favorites.selectedCategoryID, category.id)
        XCTAssertNil(saved.favorites.selectedCollectionID)

        organizer.openCollection(id: collection.id)
        try await Task.sleep(nanoseconds: 50_000_000)
        saved = await settingsStore.load()
        XCTAssertEqual(saved.favorites.selectedCategoryID, category.id)
        XCTAssertEqual(saved.favorites.selectedCollectionID, collection.id)
    }

    func testLayoutModeLoadsAndPersistsThroughSettingsStore() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-layout")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let settingsStore = SettingsStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "settings"
        )
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            settingsStore: settingsStore
        )
        try await settingsStore.save(AppSettings(favorites: FavoriteLibrarySettings(
            layoutMode: .staggered,
            sortOrder: .displayTitle,
            sortDescending: true,
            showsCategoryCounts: false
        )))

        await organizer.load()
        XCTAssertEqual(organizer.display.layoutMode, .staggered)
        XCTAssertEqual(organizer.filter.sortOrder, .displayTitle)
        XCTAssertTrue(organizer.filter.sortDescending)
        XCTAssertFalse(organizer.display.showsCategoryCounts)

        organizer.updateLayoutMode(.fixedGrid)
        organizer.updateSortOrder(.lastReadAt)
        organizer.updateSortDescending(false)
        organizer.updateShowsCategoryCounts(true)
        try await Task.sleep(nanoseconds: 50_000_000)

        let saved = await settingsStore.load()
        XCTAssertEqual(saved.favorites.layoutMode, .fixedGrid)
        XCTAssertEqual(saved.favorites.sortOrder, .lastReadAt)
        XCTAssertFalse(saved.favorites.sortDescending)
        XCTAssertTrue(saved.favorites.showsCategoryCounts)
    }

    func testAddFavoritePersistsForumMetadataForNormalThread() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-add-cover")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )

        _ = try await FavoriteQuickActions.addFavorite(
            threadID: "902",
            title: "普通主题",
            type: .other,
            authorID: nil,
            forumID: "60",
            forumName: "图文区",
            contentUpdatedAt: Date(timeIntervalSince1970: 600),
            formHash: nil,
            syncToRemote: false,
            boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            remoteRepository: nil
        )

        let target = FavoriteItemTarget(kind: .normalThread, threadID: "902")
        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        XCTAssertEqual(storedItem?.forumID, "60")
        XCTAssertEqual(storedItem?.forumName, "图文区")
        XCTAssertEqual(storedItem?.sourceGroup, .forumBoard(id: "60", label: "图文区"))
        XCTAssertEqual(storedItem?.contentUpdatedAt, Date(timeIntervalSince1970: 600))
    }

    func testAddNovelFavoritePersistsForumMetadataInLocalFirstLibrary() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-add-novel-forum")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        _ = try await FavoriteQuickActions.addFavorite(
            threadID: "903",
            title: "小说主题",
            type: .novel,
            authorID: "42",
            forumID: "49",
            forumName: "百合小说区",
            contentUpdatedAt: Date(timeIntervalSince1970: 700),
            formHash: nil,
            syncToRemote: false,
            boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            remoteRepository: nil
        )

        let target = FavoriteItemTarget(kind: .novelThread, threadID: "903")
        let storedItem = try await localFavoriteLibraryStore.load().items.first { $0.target == target }
        XCTAssertEqual(storedItem?.target.kind, .novelThread)
        XCTAssertEqual(storedItem?.forumID, "49")
        XCTAssertEqual(storedItem?.forumName, "百合小说区")
        XCTAssertEqual(storedItem?.sourceGroup, .forumBoard(id: "49", label: "百合小说区"))
        XCTAssertEqual(storedItem?.contentUpdatedAt, Date(timeIntervalSince1970: 700))
    }

    func testLoadProjectsContentCoverStoreURLWhenFavoriteHasNoCoverURL() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-content-cover")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let contentCoverStore = ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "903")
        let coverURL = try XCTUnwrap(URL(string: "https://img.example.com/store-cover.jpg"))
        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: target,
            title: "普通主题",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        try await contentCoverStore.setAutomaticCover(
            coverURL,
            for: ContentCoverKey(targetType: .thread, targetID: "903")
        )

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            contentCoverStore: contentCoverStore
        )
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.first?.coverURL, coverURL)
    }

    func testLoadProjectsNovelThreadCoverFromSharedThreadKey() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-content-cover-novel-priority")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let contentCoverStore = ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        )
        let target = FavoriteItemTarget(kind: .novelThread, threadID: "905")
        let resolvedCoverURL = try XCTUnwrap(URL(string: "https://img.example.com/resolved-novel-cover.jpg"))
        var document = FavoriteLibraryDocument()
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "小说主题",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)
        // Novel and normal threads share the `.thread` cover key.
        try await contentCoverStore.setAutomaticCover(
            resolvedCoverURL,
            for: ContentCoverKey(targetType: .thread, targetID: "905")
        )

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            contentCoverStore: contentCoverStore
        )
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.first?.coverURL, resolvedCoverURL)
    }

    func testToggleTextCoverSuppressesAndRestoresResolvedCoverURL() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-toggle-text-cover")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let contentCoverStore = ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        )
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "906")
        let coverURL = try XCTUnwrap(URL(string: "https://img.example.com/toggle-cover.jpg"))
        var document = FavoriteLibraryDocument()
        let item = try FavoriteItem(
            target: target,
            title: "长按封面主题",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(item)
        try await localFavoriteLibraryStore.save(document)
        try await contentCoverStore.setAutomaticCover(coverURL, for: ContentCoverKey(targetType: .thread, targetID: "906"))

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            contentCoverStore: contentCoverStore
        )
        await organizer.load()
        XCTAssertEqual(organizer.derived.cards.first?.coverURL, coverURL)
        XCTAssertEqual(organizer.derived.cards.first?.textCoverForced, false)

        let cardBeforeForce = try XCTUnwrap(organizer.derived.cards.first)
        let firstToggleSucceeded = await organizer.toggleTextCover(for: cardBeforeForce)
        XCTAssertTrue(firstToggleSucceeded)
        XCTAssertNil(organizer.derived.cards.first?.coverURL)
        XCTAssertEqual(organizer.derived.cards.first?.textCoverForced, true)

        let cardAfterForce = try XCTUnwrap(organizer.derived.cards.first)
        let secondToggleSucceeded = await organizer.toggleTextCover(for: cardAfterForce)
        XCTAssertTrue(secondToggleSucceeded)
        XCTAssertEqual(organizer.derived.cards.first?.coverURL, coverURL)
        XCTAssertEqual(organizer.derived.cards.first?.textCoverForced, false)
    }

    /// A resolved-directory smart card displays the directory's shared
    /// `.smartManga` cover, so its "使用文字封面" toggle must write the
    /// text-cover-forced flag on that SAME `.smartManga` row — while the
    /// same favorite surfaced as an individual "查看归档收藏" member card
    /// displays (and must keep toggling) its own `.thread` row. Before the
    /// fix, `toggleTextCover` always wrote the representative member's
    /// `.thread` key: the smart card's menu label flipped and the toast
    /// reported success, but the `.smartManga` cover the card displays never
    /// changed.
    func testToggleTextCoverOnSmartCardWritesSmartMangaKeyAndMemberCardWritesThreadKey() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-smart-card-text-cover")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        let contentCoverStore = ContentCoverStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "content-covers"
        )
        let mangaDirectoryStore = try makeMangaDirectoryStore(suiteName: suiteName)
        let directory = MangaDirectory(
            cleanBookName: "文字封面测试漫画",
            strategy: .links,
            sourceKey: "chapter:980",
            chapters: [
                MangaChapter(tid: "980", rawTitle: "第一话", chapterNumber: 1),
                MangaChapter(tid: "981", rawTitle: "第二话", chapterNumber: 2),
            ]
        )
        try await mangaDirectoryStore.saveDirectory(directory)

        var document = try await localFavoriteLibraryStore.load()
        let firstItem = try FavoriteItem(
            target: FavoriteItemTarget(kind: .mangaThread, threadID: "980"),
            title: "第一话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        )
        document.upsertItem(firstItem)
        document.upsertItem(try FavoriteItem(
            target: FavoriteItemTarget(kind: .mangaThread, threadID: "981"),
            title: "第二话",
            forumID: "30",
            forumName: "中文百合漫画区",
            locations: [.category(document.defaultCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let smartMangaKey = ContentCoverKey.smartManga(cleanBookName: directory.cleanBookName)
        let representativeThreadKey = ContentCoverKey.thread(tid: "980")
        let sharedMangaCoverURL = try XCTUnwrap(URL(string: "https://img.example.com/shared-manga-cover.jpg"))
        let chapterThreadCoverURL = try XCTUnwrap(URL(string: "https://img.example.com/chapter-thread-cover.jpg"))
        try await contentCoverStore.setAutomaticCover(sharedMangaCoverURL, for: smartMangaKey)
        try await contentCoverStore.setAutomaticCover(chapterThreadCoverURL, for: representativeThreadKey)

        let organizer = try makeOrganizer(
            libraryStore: localFavoriteLibraryStore,
            contentCoverStore: contentCoverStore,
            mangaDirectoryStore: mangaDirectoryStore
        )
        await organizer.load()

        let mergedCard = try XCTUnwrap(organizer.derived.cards.first)
        XCTAssertTrue(mergedCard.isMergedGroup)
        XCTAssertEqual(mergedCard.coverURL, sharedMangaCoverURL)
        XCTAssertEqual(mergedCard.textCoverForced, false)

        // Forcing the text cover on the smart card must suppress the shared
        // `.smartManga` cover it displays…
        let smartToggleSucceeded = await organizer.toggleTextCover(for: mergedCard)
        XCTAssertTrue(smartToggleSucceeded)
        let forcedCard = try XCTUnwrap(organizer.derived.cards.first)
        XCTAssertNil(forcedCard.coverURL)
        XCTAssertEqual(forcedCard.textCoverForced, true)
        // …by flagging the `.smartManga` row, leaving the representative
        // member's own `.thread` row untouched.
        let smartCoverAfterSmartToggle = await contentCoverStore.cover(for: smartMangaKey)
        XCTAssertEqual(smartCoverAfterSmartToggle?.textCoverForced, true)
        let threadCoverAfterSmartToggle = await contentCoverStore.cover(for: representativeThreadKey)
        XCTAssertEqual(threadCoverAfterSmartToggle?.textCoverForced, false)

        // Toggling back restores the shared cover.
        let smartToggleBackSucceeded = await organizer.toggleTextCover(for: forcedCard)
        XCTAssertTrue(smartToggleBackSucceeded)
        XCTAssertEqual(organizer.derived.cards.first?.coverURL, sharedMangaCoverURL)
        XCTAssertEqual(organizer.derived.cards.first?.textCoverForced, false)

        // The same favorite surfaced as an individual archive member card
        // (deliberately non-smart, `mangaDirectory` nil) displays its own
        // `.thread` cover, so ITS toggle writes the `.thread` row and leaves
        // `.smartManga` alone.
        organizer.openMergedGroup(cleanBookName: mergedCard.resolvedTitle)
        let memberCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.id == firstItem.id })
        XCTAssertNil(memberCard.mangaDirectory)
        XCTAssertEqual(memberCard.coverURL, chapterThreadCoverURL)
        let memberToggleSucceeded = await organizer.toggleTextCover(for: memberCard)
        XCTAssertTrue(memberToggleSucceeded)
        let threadCoverAfterMemberToggle = await contentCoverStore.cover(for: representativeThreadKey)
        XCTAssertEqual(threadCoverAfterMemberToggle?.textCoverForced, true)
        let smartCoverAfterMemberToggle = await contentCoverStore.cover(for: smartMangaKey)
        XCTAssertEqual(smartCoverAfterMemberToggle?.textCoverForced, false)
        let toggledMemberCard = try XCTUnwrap(organizer.derived.cards.first { $0.item.id == firstItem.id })
        XCTAssertNil(toggledMemberCard.coverURL)
        XCTAssertEqual(toggledMemberCard.textCoverForced, true)
    }

    func testSearchModeSubmitsCountsAndExitClearsSelection() async throws {
        let suiteName = YamiboTestDefaults.suiteName(prefix: "local-favorites-search-mode")
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        let localFavoriteLibraryStore = FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
        var document = FavoriteLibraryDocument()
        let secondCategory = document.createCategory(name: "分类B")
        let matchingCollection = document.createCollection(categoryID: document.defaultCategory.id, name: "命中合集")
        _ = document.createCollection(categoryID: document.defaultCategory.id, name: "其他合集")
        let firstTarget = FavoriteItemTarget(kind: .normalThread, threadID: "950")
        let secondTarget = FavoriteItemTarget(kind: .normalThread, threadID: "951")
        let thirdTarget = FavoriteItemTarget(kind: .normalThread, threadID: "952")
        document.upsertItem(try FavoriteItem(
            target: firstTarget,
            title: "命中默认分类",
            locations: [.category(document.defaultCategory.id)]
        ))
        document.upsertItem(try FavoriteItem(
            target: secondTarget,
            title: "其他默认分类",
            locations: [
                .category(document.defaultCategory.id),
                .collection(categoryID: document.defaultCategory.id, collectionID: matchingCollection.id)
            ]
        ))
        document.upsertItem(try FavoriteItem(
            target: thirdTarget,
            title: "命中第二分类",
            locations: [.category(secondCategory.id)]
        ))
        try await localFavoriteLibraryStore.save(document)

        let organizer = try makeOrganizer(libraryStore: localFavoriteLibraryStore)
        await organizer.load()

        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget, secondTarget])

        // Search is a live filter driven directly by the searchable text.
        organizer.filter.searchText = "命中"
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget])
        XCTAssertEqual(organizer.derived.categoryEntryCounts[document.defaultCategory.id], 2)
        XCTAssertEqual(organizer.derived.categoryEntryCounts[secondCategory.id], 1)

        organizer.filter.searchText = ""
        XCTAssertEqual(organizer.derived.cards.map(\.item.target), [firstTarget, secondTarget])
    }
}

private actor FavoriteDeleteTestRecorder {
    private var targetIDs: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func record(_ items: [FavoriteItem]) throws {
        targetIDs.append(contentsOf: items.map(\.id))
        if let error {
            throw error
        }
    }

    func recordedTargetIDs() -> [String] {
        targetIDs
    }
}

private final class LocalFavoriteDeleteTestURLProtocol: URLProtocol {
    nonisolated(unsafe) static var deletedFavoriteIDs: [String] = []

    static func reset() {
        deletedFavoriteIDs = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bbs.yamibo.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let absoluteString = request.url?.absoluteString ?? ""
        let body: String
        let statusCode = 200

        if absoluteString.contains("do=favorite") {
            body = """
            <html><body>
              <ul class="sclist">
                <li>
                  <a href="forum.php?mod=viewthread&tid=955&mobile=2">需要回查远端 ID 的收藏</a>
                  <a class="mdel" href="home.php?mod=spacecp&ac=favorite&op=delete&favid=997">删除</a>
                </li>
              </ul>
            </body></html>
            """
        } else if absoluteString.contains("mod=faq") {
            body = #"<html><body><input name="formhash" value="abc12345" /></body></html>"#
        } else if absoluteString.contains("ac=favorite"),
                  absoluteString.contains("op=delete") {
            let requestBody = Self.requestBodyString(from: request)
            if requestBody.contains("favorite%5B%5D=997") || requestBody.contains("favorite[]=997") {
                Self.deletedFavoriteIDs.append("997")
                body = "<html><body>操作成功</body></html>"
            } else {
                body = "<html><body>操作失败</body></html>"
            }
        } else {
            body = "<html><body>not found</body></html>"
        }

        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://bbs.yamibo.com/")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private func makeLocalFavoriteDeleteTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalFavoriteDeleteTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// Builds a `FavoriteLibraryOrganizer` backed by isolated per-test stores,
/// mirroring the composition root's repository wiring for the given session.
@MainActor
private func makeOrganizer(
    libraryStore: FavoriteLibraryStore? = nil,
    readingProgressStore: ReadingProgressStore? = nil,
    settingsStore: SettingsStore? = nil,
    contentCoverStore: ContentCoverStore? = nil,
    favoriteBackgroundImageStore: FavoriteBackgroundImageStore? = nil,
    mangaDirectoryStore: MangaDirectoryStore? = nil,
    makeForumThreadReaderRepository: (@Sendable () async -> ForumThreadReaderRepository)? = nil,
    session: URLSession? = nil,
    remoteFavoriteDeleteHandler: (([FavoriteItem]) async throws -> Void)? = nil
) throws -> FavoriteLibraryOrganizer {
    let suiteName = YamiboTestDefaults.suiteName(prefix: "favorite-organizer-deps")
    let defaults = try YamiboTestDefaults.make(suiteName: suiteName)
    let sessionStore = SessionStore(defaults: defaults, key: "session")
    let resolvedSession = session ?? YamiboNetworkConfiguration.makeSession()
    return FavoriteLibraryOrganizer(
        libraryStore: libraryStore ?? FavoriteLibraryStore(defaults: defaults, key: "local-favorites"),
        readingProgressStore: readingProgressStore ?? ReadingProgressStore(defaults: defaults, key: "reading-progress"),
        settingsStore: settingsStore ?? SettingsStore(defaults: defaults, key: "settings"),
        contentCoverStore: contentCoverStore ?? ContentCoverStore(defaults: defaults, key: "content-covers"),
        favoriteBackgroundImageStore: favoriteBackgroundImageStore ?? makeFavoriteBackgroundImageStore(suiteName: suiteName),
        mangaDirectoryStore: mangaDirectoryStore,
        makeForumThreadReaderRepository: makeForumThreadReaderRepository,
        makeFavoriteRepository: {
            let sessionState = await sessionStore.load()
            return FavoriteRepository(client: YamiboClient(
                session: resolvedSession,
                cookie: sessionState.cookie,
                userAgent: sessionState.userAgent
            ))
        },
        remoteFavoriteDeleteHandler: remoteFavoriteDeleteHandler
    )
}

/// Real GRDB-backed `MangaDirectoryStore` for a test, mirroring
/// `LocalFavoriteOpenTargetResolverTests`' own helper — the Phase E gap this
/// file's integration test closes is specifically that `makeOrganizer` never
/// injected a real store, so a fake/in-memory double would not prove
/// anything a mock couldn't already; this needs the genuine GRDB-backed type.
private func makeMangaDirectoryStore(suiteName: String) throws -> MangaDirectoryStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("favorite-library-organizer-tests", isDirectory: true)
        .appendingPathComponent(suiteName, isDirectory: true)
    let database = try YamiboDatabase.openPool(rootDirectory: root)
    return MangaDirectoryStore(databasePool: database)
}

/// Temp-directory-scoped `FavoriteBackgroundImageStore` for a test — never
/// the type's own default `baseDirectory`, which resolves to the shared
/// Application Support directory and would collide across parallel test runs.
private func makeFavoriteBackgroundImageStore(suiteName: String) -> FavoriteBackgroundImageStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("favorite-library-organizer-tests", isDirectory: true)
        .appendingPathComponent(suiteName, isDirectory: true)
        .appendingPathComponent("favorite-background", isDirectory: true)
    return FavoriteBackgroundImageStore(baseDirectory: root)
}

/// Polls a `@MainActor` condition until it's true or the timeout elapses —
/// for asserting on state that only updates asynchronously in response to a
/// `NotificationCenter` subscription (e.g. `FavoriteLibraryOrganizer`'s
/// `SettingsStore.didChangeNotification` listener), where a fixed
/// `Task.sleep` would be a flaky guess at how long that takes.
@MainActor
private func waitForOrganizerCondition(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let start = ContinuousClock.now
    while condition() == false {
        if start.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
            throw YamiboError.underlying("Timed out waiting for condition")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
