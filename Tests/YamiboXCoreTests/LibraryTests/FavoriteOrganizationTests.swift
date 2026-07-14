import Foundation
import Testing
@testable import YamiboXCore

@Test func favoriteCategoriesCanBeCreatedRenamedReorderedAndDeletedToDefault() throws {
    var document = FavoriteLibraryDocument()
    let first = document.createCategory(name: "第一类")
    let second = document.createCategory(name: "第二类")
    document.renameCategory(id: first.id, name: "重命名")
    document.reorderCategories(orderedIDs: [second.id, first.id])
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "620")
    let item = try FavoriteItem(target: target, title: "主题", locations: [.category(second.id)])
    document.upsertItem(item)

    document.deleteCategory(id: second.id)

    #expect(document.categories.first(where: { $0.id == first.id })?.name == "重命名")
    #expect(document.categories.first(where: { $0.id == first.id })?.manualOrder == 2)
    let moved = try #require(document.items.first)
    #expect(moved.locations == [.category(FavoriteCategory.defaultID)])
    #expect(document.categories.contains(where: { $0.id == FavoriteCategory.defaultID && $0.isDefault }))
}

@Test func favoriteCollectionsCanBeCreatedRenamedRecoloredReorderedAndDissolved() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let first = document.createCollection(categoryID: categoryID, name: "旧合集", color: .gray)
    let second = document.createCollection(categoryID: categoryID, name: "第二合集", color: .blue)
    document.renameCollection(id: first.id, name: "新合集")
    document.recolorCollection(id: first.id, color: .red)
    document.reorderCollections(categoryID: categoryID, orderedIDs: [second.id, first.id])
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "621")
    let item = try FavoriteItem(
        target: target,
        title: "主题",
        locations: [.collection(categoryID: categoryID, collectionID: first.id)]
    )
    document.upsertItem(item)

    document.dissolveCollection(id: first.id)

    #expect(document.collections.first(where: { $0.id == first.id }) == nil)
    #expect(document.collections.first(where: { $0.id == second.id })?.manualOrder == 0)
    let moved = try #require(document.items.first)
    #expect(moved.locations == [.category(categoryID)])
}

@Test func favoriteItemSupportsMultipleLocationsIncludingSameCategory() throws {
    var document = FavoriteLibraryDocument()
    let categoryID = document.defaultCategory.id
    let firstCollection = document.createCollection(categoryID: categoryID, name: "合集一")
    let secondCollection = document.createCollection(categoryID: categoryID, name: "合集二")
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "622")
    let item = try FavoriteItem(target: target, title: "主题", locations: [.category(categoryID)])
    document.upsertItem(item)

    document.addLocation(.collection(categoryID: categoryID, collectionID: firstCollection.id), to: target)
    document.addLocation(.collection(categoryID: categoryID, collectionID: secondCollection.id), to: target)
    let didRemoveOne = document.removeLocation(.collection(categoryID: categoryID, collectionID: firstCollection.id), from: target)
    let didRemoveSecond = document.removeLocation(.collection(categoryID: categoryID, collectionID: secondCollection.id), from: target)
    let didRemoveFinal = document.removeLocation(.category(categoryID), from: target)

    let stored = try #require(document.items.first)
    #expect(didRemoveOne)
    #expect(didRemoveSecond)
    #expect(!didRemoveFinal)
    #expect(stored.locations == [.category(categoryID)])
}

@Test func favoriteTagsCanBeManagedWithoutChangingLocations() throws {
    var document = FavoriteLibraryDocument()
    let target = FavoriteItemTarget(kind: .normalThread, threadID: "623")
    let item = try FavoriteItem(target: target, title: "主题", locations: [.category(document.defaultCategory.id)])
    document.upsertItem(item)
    let tag = document.createTag(name: "标签", color: .green, date: Date(timeIntervalSince1970: 1))

    document.assignTag(id: tag.id, to: target)
    document.renameTag(id: tag.id, name: "新标签", date: Date(timeIntervalSince1970: 2))
    document.unassignTag(id: tag.id, from: target)
    document.assignTag(id: tag.id, to: target)
    document.deleteTag(id: tag.id)

    let stored = try #require(document.items.first)
    #expect(stored.locations == [.category(FavoriteCategory.defaultID)])
    #expect(stored.tagIDs.isEmpty)
    #expect(document.tags.isEmpty)
}
