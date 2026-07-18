import Foundation

// Tag mutations of the favorites library document. Split from the former
// monolithic FavoriteLibrary.swift; method bodies moved verbatim.
extension FavoriteLibraryDocument {
    public mutating func createTag(name: String, color: FavoriteTagColor, date: Date = .now) -> FavoriteTag {
        let tag = FavoriteTag(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            manualOrder: ((tags.map(\.manualOrder).max() ?? -1) + 1),
            createdAt: date,
            updatedAt: date
        )
        tags.append(tag)
        return tag
    }

    public mutating func renameTag(id tagID: String, name: String, date: Date = .now) {
        guard let index = tags.firstIndex(where: { $0.id == tagID }) else { return }
        tags[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tags[index].updatedAt = date
    }

    public mutating func recolorTag(id tagID: String, color: FavoriteTagColor, date: Date = .now) {
        guard let index = tags.firstIndex(where: { $0.id == tagID }) else { return }
        tags[index].color = color
        tags[index].updatedAt = date
    }

    public mutating func deleteTag(id tagID: String) {
        tags.removeAll { $0.id == tagID }
        items = items.map { item in
            var item = item
            item.tagIDs.removeAll { $0 == tagID }
            return item
        }
    }

    public mutating func reorderTags(orderedIDs: [String]) {
        let orderByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        tags = tags.map { tag in
            var tag = tag
            guard let order = orderByID[tag.id] else { return tag }
            tag.manualOrder = order
            return tag
        }
    }

    public mutating func assignTag(id tagID: String, to target: FavoriteItemTarget) {
        guard tags.contains(where: { $0.id == tagID }),
              let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        items[index].tagIDs = FavoriteItem.normalizedIDs(items[index].tagIDs + [tagID])
    }

    public mutating func unassignTag(id tagID: String, from target: FavoriteItemTarget) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        items[index].tagIDs.removeAll { $0 == tagID }
    }
}
