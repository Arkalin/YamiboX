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
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case manualOrder
        case isDefault
        case updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        manualOrder: Int = 0,
        isDefault: Bool = false,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.manualOrder = manualOrder
        self.isDefault = isDefault
        self.updatedAt = updatedAt
    }

    public static var defaultCategory: FavoriteCategory {
        FavoriteCategory(
            id: defaultID,
            name: defaultStorageName,
            manualOrder: 0,
            isDefault: true,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    public var displayName: String {
        isDefault ? L10n.string("favorites.default_category") : name
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        manualOrder = try container.decode(Int.self, forKey: .manualOrder)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }
}

public typealias FavoriteCollectionColor = FavoriteColor

public enum FavoriteColor: Codable, Hashable, Sendable {
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray
    case custom(red: UInt8, green: UInt8, blue: UInt8)

    public static let presetColors: [Self] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .gray]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        case "pink": self = .pink
        case "gray": self = .gray
        default:
            guard value.count == 7, value.first == "#",
                  value.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let rgb = UInt32(value.dropFirst(), radix: 16) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid favorite color")
            }
            self = .custom(red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255), blue: UInt8(rgb & 255))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let value: String
        switch self {
        case .red: value = "red"
        case .orange: value = "orange"
        case .yellow: value = "yellow"
        case .green: value = "green"
        case .blue: value = "blue"
        case .purple: value = "purple"
        case .pink: value = "pink"
        case .gray: value = "gray"
        case let .custom(red, green, blue):
            value = String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LocalFavoriteCollection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var categoryID: String
    public var name: String
    public var color: FavoriteCollectionColor
    public var manualOrder: Int
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case categoryID
        case name
        case color
        case manualOrder
        case updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        categoryID: String,
        name: String,
        color: FavoriteCollectionColor = .gray,
        manualOrder: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.categoryID = categoryID
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.color = color
        self.manualOrder = manualOrder
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(FavoriteCollectionColor.self, forKey: .color)
        manualOrder = try container.decode(Int.self, forKey: .manualOrder)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }
}
