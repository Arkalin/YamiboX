import XCTest
@testable import YamiboXCore
import YamiboXTestSupport
@testable import YamiboXUI

/// Covers the long-press "choose favorite location" feature's two new
/// `FavoriteQuickActions` surfaces: `addFavorite(locations:)` and
/// `relocateFavorite`.
@MainActor
final class FavoriteQuickActionsLocationTests: XCTestCase {
    func testAddFavoriteWithExplicitLocationsFilesUnderThoseLocationsNotDefaultCategory() async throws {
        let store = try makeStore(prefix: "quick-actions-add-explicit-locations")
        var document = try await store.load()
        let category = document.createCategory(name: "分类A")
        let collection = document.createCollection(categoryID: category.id, name: "合集A")
        try await store.save(document)

        _ = try await FavoriteQuickActions.addFavorite(
            threadID: "8001",
            title: "指定位置收藏",
            type: .manga,
            authorID: nil,
            locations: [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)],
            formHash: nil,
            syncToRemote: false,
            boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: store,
            remoteRepository: nil
        )

        let storedDocument = try await store.load()
        let item = try XCTUnwrap(storedDocument.items.first { $0.target.threadID == "8001" })
        XCTAssertEqual(
            Set(item.locations),
            [.category(category.id), .collection(categoryID: category.id, collectionID: collection.id)]
        )
    }

    func testAddFavoriteWithNilLocationsFallsBackToDefaultCategory() async throws {
        let store = try makeStore(prefix: "quick-actions-add-nil-locations")

        _ = try await FavoriteQuickActions.addFavorite(
            threadID: "8002",
            title: "默认位置收藏",
            type: .manga,
            authorID: nil,
            formHash: nil,
            syncToRemote: false,
            boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: store,
            remoteRepository: nil
        )

        let document = try await store.load()
        let item = try XCTUnwrap(document.items.first { $0.target.threadID == "8002" })
        XCTAssertEqual(item.locations, [.category(document.defaultCategory.id)])
    }

    func testAddFavoriteWithEmptyLocationsArrayFallsBackToDefaultCategory() async throws {
        let store = try makeStore(prefix: "quick-actions-add-empty-locations")

        _ = try await FavoriteQuickActions.addFavorite(
            threadID: "8003",
            title: "空选择收藏",
            type: .manga,
            authorID: nil,
            locations: [],
            formHash: nil,
            syncToRemote: false,
            boardReaderSettings: BoardReaderSettings(),
            localFavoriteLibraryStore: store,
            remoteRepository: nil
        )

        let document = try await store.load()
        let item = try XCTUnwrap(document.items.first { $0.target.threadID == "8003" })
        XCTAssertEqual(item.locations, [.category(document.defaultCategory.id)])
    }

    func testRelocateFavoriteReplacesLocationsRatherThanAppending() async throws {
        let store = try makeStore(prefix: "quick-actions-relocate-replace")
        var document = try await store.load()
        let categoryA = document.createCategory(name: "分类A")
        let categoryB = document.createCategory(name: "分类B")
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "8004")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "待重新定位收藏",
            locations: [.category(categoryA.id)]
        ))
        try await store.save(document)

        try await FavoriteQuickActions.relocateFavorite(
            threadID: "8004",
            locations: [.category(categoryB.id)],
            localFavoriteLibraryStore: store
        )

        let storedDocument = try await store.load()
        let item = try XCTUnwrap(storedDocument.items.first { $0.target.id == target.id })
        XCTAssertEqual(item.locations, [.category(categoryB.id)])
    }

    func testRelocateFavoriteKeepsOverlapAndAddsNewLocationsAndRemovesDroppedOnes() async throws {
        let store = try makeStore(prefix: "quick-actions-relocate-diff")
        var document = try await store.load()
        let categoryA = document.createCategory(name: "分类A")
        let categoryB = document.createCategory(name: "分类B")
        let categoryC = document.createCategory(name: "分类C")
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "8005")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "多位置收藏",
            locations: [.category(categoryA.id), .category(categoryB.id)]
        ))
        try await store.save(document)

        // Drop B, keep A, add C.
        try await FavoriteQuickActions.relocateFavorite(
            threadID: "8005",
            locations: [.category(categoryA.id), .category(categoryC.id)],
            localFavoriteLibraryStore: store
        )

        let storedDocument = try await store.load()
        let item = try XCTUnwrap(storedDocument.items.first { $0.target.id == target.id })
        XCTAssertEqual(Set(item.locations), [.category(categoryA.id), .category(categoryC.id)])
    }

    func testRelocateFavoriteWithEmptyLocationsIsANoOp() async throws {
        let store = try makeStore(prefix: "quick-actions-relocate-empty")
        var document = try await store.load()
        let category = document.createCategory(name: "分类A")
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "8006")
        document.upsertItem(try FavoriteItem(
            target: target,
            title: "不应被清空的收藏",
            locations: [.category(category.id)]
        ))
        try await store.save(document)

        try await FavoriteQuickActions.relocateFavorite(
            threadID: "8006",
            locations: [],
            localFavoriteLibraryStore: store
        )

        let storedDocument = try await store.load()
        let item = try XCTUnwrap(storedDocument.items.first { $0.target.id == target.id })
        XCTAssertEqual(item.locations, [.category(category.id)])
    }

    func testRelocateFavoriteForUnknownThreadIDIsANoOp() async throws {
        let store = try makeStore(prefix: "quick-actions-relocate-unknown")

        // Must not throw even though nothing matches this thread id.
        try await FavoriteQuickActions.relocateFavorite(
            threadID: "does-not-exist",
            locations: [.category(FavoriteCategory.defaultID)],
            localFavoriteLibraryStore: store
        )

        let document = try await store.load()
        XCTAssertTrue(document.items.isEmpty)
    }

    private func makeStore(prefix: String) throws -> FavoriteLibraryStore {
        let suiteName = YamiboTestDefaults.suiteName(prefix: prefix)
        _ = try YamiboTestDefaults.make(suiteName: suiteName)
        return FavoriteLibraryStore(
            defaults: try YamiboTestDefaults.defaults(suiteName: suiteName),
            key: "local-favorites"
        )
    }
}
