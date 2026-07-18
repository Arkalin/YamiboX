import Foundation

// The organizational containers favorites are filed into: the location
// coordinate plus the category and collection types it addresses. They are
// small and only ever change together, so they share one file.

public enum FavoriteLocation: Codable, Hashable, Identifiable, Sendable {
    case category(String)
    case collection(categoryID: String, collectionID: String)

    public var id: String {
        switch self {
        case let .category(categoryID):
            "category:\(categoryID)"
        case let .collection(categoryID, collectionID):
            "category:\(categoryID):collection:\(collectionID)"
        }
    }

    public var categoryID: String {
        switch self {
        case let .category(categoryID), let .collection(categoryID, _):
            categoryID
        }
    }

    public var collectionID: String? {
        if case let .collection(_, collectionID) = self {
            return collectionID
        }
        return nil
    }
}

public struct FavoriteCategory: Codable, Hashable, Identifiable, Sendable {
    public static let defaultID = "default"
    public static let defaultStorageName = "default"

    public let id: String
    public var name: String
    public var manualOrder: Int
    public var isDefault: Bool

    public init(id: String = UUID().uuidString, name: String, manualOrder: Int = 0, isDefault: Bool = false) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.manualOrder = manualOrder
        self.isDefault = isDefault
    }

    public static var defaultCategory: FavoriteCategory {
        FavoriteCategory(id: defaultID, name: defaultStorageName, manualOrder: 0, isDefault: true)
    }

    public var displayName: String {
        isDefault ? L10n.string("favorites.default_category") : name
    }
}

public enum FavoriteCollectionColor: String, Codable, CaseIterable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray
}

public struct LocalFavoriteCollection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var categoryID: String
    public var name: String
    public var color: FavoriteCollectionColor
    public var manualOrder: Int

    public init(
        id: String = UUID().uuidString,
        categoryID: String,
        name: String,
        color: FavoriteCollectionColor = .gray,
        manualOrder: Int = 0
    ) {
        self.id = id
        self.categoryID = categoryID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.color = color
        self.manualOrder = manualOrder
    }
}
