import Foundation
import Testing
@testable import YamiboXCore

@Test func tagColorsPreserveLegacyDataAndCustomColors() throws {
    for (name, expected) in zip(
        ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"],
        FavoriteTagColor.presetColors
    ) {
        let data = try JSONSerialization.data(withJSONObject: ["id": "legacy", "name": "Tag", "color": name])
        let tag = try JSONDecoder().decode(FavoriteTag.self, from: data)
        #expect(tag.color == expected)
        #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(tag.color)) == name)
    }
    let missingColor = Data(#"{"id":"legacy","name":"Tag"}"#.utf8)
    #expect(try JSONDecoder().decode(FavoriteTag.self, from: missingColor).color == .gray)

    var document = FavoriteLibraryDocument()
    let tag = document.createTag(name: "Custom", color: .custom(red: 18, green: 171, blue: 239))
    document.recolorTag(id: tag.id, color: .custom(red: 255, green: 128, blue: 0))
    let restored = try JSONDecoder().decode(FavoriteLibraryDocument.self, from: JSONEncoder().encode(document))
    #expect(restored.tags.first { $0.id == tag.id }?.color == .custom(red: 255, green: 128, blue: 0))
}

@Test func collectionColorsPreserveLegacyEncoding() throws {
    let colors: [(String, FavoriteCollectionColor)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
        ("blue", .blue), ("purple", .purple), ("pink", .pink), ("gray", .gray)
    ]
    for (name, color) in colors {
        let data = try JSONEncoder().encode(name)
        #expect(try JSONDecoder().decode(FavoriteCollectionColor.self, from: data) == color)
        #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(color)) == name)
    }
}

@Test func customCollectionColorsSurviveDocumentRoundTrip() throws {
    var document = FavoriteLibraryDocument()
    let color = FavoriteCollectionColor.custom(red: 18, green: 171, blue: 239)
    let collection = document.createCollection(categoryID: document.defaultCategory.id, name: "Custom", color: color)
    let data = try JSONEncoder().encode(document)
    let restored = try JSONDecoder().decode(FavoriteLibraryDocument.self, from: data)
    #expect(restored.collections.first { $0.id == collection.id }?.color == color)
    #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(color)) == "#12ABEF")
    for hex in ["#000000", "#ffffff", "#12abef"] {
        let decoded = try JSONDecoder().decode(FavoriteCollectionColor.self, from: JSONEncoder().encode(hex))
        #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(decoded)) == hex.uppercased())
    }
}

@Test func collectionColorsRejectMalformedValues() throws {
    for value in ["", "unknown", "#123", "123456", "#GG0000", "#+12345", "#1234567"] {
        let data = try JSONEncoder().encode(value)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FavoriteCollectionColor.self, from: data)
        }
    }
}

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

@Test func favoriteCategoryMutationClocksOnlyAdvanceForRealChanges() throws {
    let createdAt = Date(timeIntervalSince1970: 100)
    let renamedAt = createdAt.addingTimeInterval(10)
    let reorderedAt = createdAt.addingTimeInterval(20)
    let noOpAt = createdAt.addingTimeInterval(30)
    var document = FavoriteLibraryDocument()
    let first = document.createCategory(name: "第一类", date: createdAt)
    let second = document.createCategory(name: "第二类", date: createdAt)

    #expect(document.defaultCategory.updatedAt == Date(timeIntervalSince1970: 0))
    #expect(first.updatedAt == createdAt)
    #expect(second.updatedAt == createdAt)

    document.renameCategory(id: first.id, name: " 第一类 ", date: noOpAt)
    #expect(document.categories.first { $0.id == first.id }?.updatedAt == createdAt)

    document.renameCategory(id: first.id, name: "重命名", date: renamedAt)
    #expect(document.categories.first { $0.id == first.id }?.updatedAt == renamedAt)

    document.reorderCategories(orderedIDs: [second.id, first.id], date: reorderedAt)
    #expect(document.categories.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.categories.first { $0.id == second.id }?.updatedAt == reorderedAt)

    document.reorderCategories(orderedIDs: [second.id, first.id], date: noOpAt)
    #expect(document.categories.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.categories.first { $0.id == second.id }?.updatedAt == reorderedAt)
}

@Test func favoriteCollectionMutationClocksOnlyAdvanceForRealChanges() throws {
    let createdAt = Date(timeIntervalSince1970: 200)
    let renamedAt = createdAt.addingTimeInterval(10)
    let recoloredAt = createdAt.addingTimeInterval(20)
    let reorderedAt = createdAt.addingTimeInterval(30)
    let movedAt = createdAt.addingTimeInterval(40)
    let noOpAt = createdAt.addingTimeInterval(50)
    var document = FavoriteLibraryDocument()
    let source = document.createCategory(name: "原分类", date: createdAt)
    let destination = document.createCategory(name: "目标分类", date: createdAt)
    let first = document.createCollection(
        categoryID: source.id,
        name: "第一合集",
        color: .gray,
        date: createdAt
    )
    let second = document.createCollection(
        categoryID: source.id,
        name: "第二合集",
        color: .blue,
        date: createdAt
    )

    #expect(first.updatedAt == createdAt)
    #expect(second.updatedAt == createdAt)

    document.renameCollection(id: first.id, name: " 第一合集 ", date: noOpAt)
    document.recolorCollection(id: first.id, color: .gray, date: noOpAt)
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == createdAt)

    document.renameCollection(id: first.id, name: "重命名合集", date: renamedAt)
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == renamedAt)
    document.recolorCollection(id: first.id, color: .red, date: recoloredAt)
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == recoloredAt)

    document.reorderCollections(
        categoryID: source.id,
        orderedIDs: [second.id, first.id],
        date: reorderedAt
    )
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.collections.first { $0.id == second.id }?.updatedAt == reorderedAt)
    document.reorderCollections(
        categoryID: source.id,
        orderedIDs: [second.id, first.id],
        date: noOpAt
    )
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.collections.first { $0.id == second.id }?.updatedAt == reorderedAt)

    let memberTargets = [
        FavoriteItemTarget(kind: .normalThread, threadID: "clock-1"),
        FavoriteItemTarget(kind: .normalThread, threadID: "clock-2"),
    ]
    for target in memberTargets {
        let item = try FavoriteItem(
            target: target,
            title: "合集成员",
            locations: [.collection(categoryID: source.id, collectionID: first.id)],
            updatedAt: createdAt
        )
        document.upsertItem(item)
    }

    document.moveCollection(id: first.id, toCategoryID: destination.id, date: movedAt)
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == movedAt)
    for target in memberTargets {
        let member = try #require(document.items.first { $0.target == target })
        #expect(member.locationsUpdatedAt == movedAt)
        #expect(member.updatedAt == movedAt)
        #expect(member.locations.contains(.collection(categoryID: destination.id, collectionID: first.id)))
    }

    document.moveCollection(id: first.id, toCategoryID: destination.id, date: noOpAt)
    #expect(document.collections.first { $0.id == first.id }?.updatedAt == movedAt)
}

@Test func favoriteTagMutationClocksOnlyAdvanceForRealChanges() throws {
    let createdAt = Date(timeIntervalSince1970: 300)
    let renamedAt = createdAt.addingTimeInterval(10)
    let recoloredAt = createdAt.addingTimeInterval(20)
    let reorderedAt = createdAt.addingTimeInterval(30)
    let noOpAt = createdAt.addingTimeInterval(40)
    var document = FavoriteLibraryDocument()
    let first = document.createTag(name: "第一标签", color: .gray, date: createdAt)
    let second = document.createTag(name: "第二标签", color: .blue, date: createdAt)

    #expect(first.updatedAt == createdAt)
    #expect(second.updatedAt == createdAt)

    document.renameTag(id: first.id, name: " 第一标签 ", date: noOpAt)
    document.recolorTag(id: first.id, color: .gray, date: noOpAt)
    #expect(document.tags.first { $0.id == first.id }?.updatedAt == createdAt)

    document.renameTag(id: first.id, name: "重命名标签", date: renamedAt)
    #expect(document.tags.first { $0.id == first.id }?.updatedAt == renamedAt)
    document.recolorTag(id: first.id, color: .red, date: recoloredAt)
    #expect(document.tags.first { $0.id == first.id }?.updatedAt == recoloredAt)

    document.reorderTags(orderedIDs: [second.id, first.id], date: reorderedAt)
    #expect(document.tags.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.tags.first { $0.id == second.id }?.updatedAt == reorderedAt)
    document.reorderTags(orderedIDs: [second.id, first.id], date: noOpAt)
    #expect(document.tags.first { $0.id == first.id }?.updatedAt == reorderedAt)
    #expect(document.tags.first { $0.id == second.id }?.updatedAt == reorderedAt)
}
