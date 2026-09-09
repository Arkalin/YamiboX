import Foundation
import XCTest
@testable import YamiboXCore

final class FavoriteCommandDomainTests: XCTestCase {
    func testMoveItemsAndReplaceTagsDoNotBumpFieldClocksOnNoOpEdits() throws {
        var document = FavoriteLibraryDocument()
        let category = document.createCategory(name: "Category")
        let tag = document.createTag(name: "Tag", color: .blue)
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "9201")
        let baseDate = Date(timeIntervalSince1970: 1100)
        let item = try FavoriteItem(target: target, title: "Favorite", locations: [.category(category.id)], tagIDs: [tag.id], updatedAt: baseDate)
        document.upsertItem(item)
        let before = try XCTUnwrap(document.items.first)

        document.moveItems(ids: [target.id], to: .category(category.id), removing: nil)
        XCTAssertEqual(try XCTUnwrap(document.items.first).locationsUpdatedAt, before.locationsUpdatedAt)
        document.replaceTags(for: [target.id], with: [tag.id])
        XCTAssertEqual(try XCTUnwrap(document.items.first).tagIDsUpdatedAt, before.tagIDsUpdatedAt)
        XCTAssertEqual(try XCTUnwrap(document.items.first).updatedAt, before.updatedAt)

        let otherCategory = document.createCategory(name: "Other")
        document.moveItems(ids: [target.id], to: .category(otherCategory.id), removing: .category(category.id))
        XCTAssertNotEqual(try XCTUnwrap(document.items.first).locationsUpdatedAt, before.locationsUpdatedAt)
    }

    func testRemoveItemsPreservesLastLocationAndTagReplacementRejectsUnknownTags() throws {
        var document = FavoriteLibraryDocument()
        let tag = document.createTag(name: "Tag", color: .blue)
        let target = FavoriteItemTarget(kind: .normalThread, threadID: "1")
        let location = FavoriteLocation.category(document.defaultCategory.id)
        document.upsertItem(try FavoriteItem(target: target, title: "Favorite", locations: [location]))
        document.removeItems(ids: [target.id], from: location)
        XCTAssertEqual(document.items.first?.locations, [location])
        document.replaceTags(for: [target.id], with: ["unknown", tag.id])
        XCTAssertEqual(document.items.first?.tagIDs, [tag.id])
    }

    func testCategoryAndCollectionReorderBoundaries() {
        var document = FavoriteLibraryDocument()
        let first = document.createCategory(name: "First")
        let second = document.createCategory(name: "Second")
        XCTAssertNil(document.reorderedCategoryIDs(moving: document.defaultCategory.id, .down))
        XCTAssertNil(document.reorderedCategoryIDs(moving: first.id, .up))
        XCTAssertNil(document.reorderedCategoryIDs(moving: second.id, .down))
        XCTAssertEqual(document.reorderedCategoryIDs(moving: first.id, .down), [second.id, first.id])
        let a = document.createCollection(categoryID: first.id, name: "A")
        let b = document.createCollection(categoryID: first.id, name: "B")
        _ = document.createCollection(categoryID: second.id, name: "Elsewhere")
        XCTAssertNil(document.reorderedCollectionIDs(moving: a.id, .up))
        XCTAssertNil(document.reorderedCollectionIDs(moving: b.id, .down))
        XCTAssertNil(document.reorderedCollectionIDs(moving: "missing", .up))
        let reordered = document.reorderedCollectionIDs(moving: a.id, .down)
        XCTAssertEqual(reordered?.categoryID, first.id)
        XCTAssertEqual(reordered?.orderedIDs, [b.id, a.id])
    }

    func testRememberedDecisionsRespectCapabilityAndPromptPreference() {
        var settings = FavoriteLibrarySettings()
        settings.addSyncPromptEnabled = true
        settings.removeRemotePromptEnabled = true
        XCTAssertEqual(FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true), .prompt)
        XCTAssertEqual(FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: true), .prompt)
        XCTAssertEqual(FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: false), .silent(syncToRemote: false))
        XCTAssertEqual(FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: false), .silent(removeRemote: false))
        settings.addSyncPromptEnabled = false
        settings.removeRemotePromptEnabled = false
        for value in [false, true] {
            settings.addSyncDefault = value
            settings.removeRemoteDefault = value
            XCTAssertEqual(FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true), .silent(syncToRemote: value))
            XCTAssertEqual(FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: true), .silent(removeRemote: value))
        }
    }
}
