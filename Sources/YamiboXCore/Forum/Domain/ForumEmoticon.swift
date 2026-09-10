import Foundation

public struct ForumEmoticon: Identifiable, Hashable, Sendable {
    public let code: String
    public let imageURL: URL
    public var id: String { code }

    public init(code: String, imageURL: URL) {
        self.code = code
        self.imageURL = imageURL
    }
}

public struct ForumEmoticonCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let items: [ForumEmoticon]

    public init(id: String, name: String, items: [ForumEmoticon]) {
        self.id = id
        self.name = name
        self.items = items
    }
}

public enum ForumEmoticonCatalog {
    // Public editor menu snapshot, verified 2026-09-10. Only the directory is
    // bundled; images use the same authenticated cache as thread images.
    public static let categories: [ForumEmoticonCategory] = {
        struct Category: Decodable {
            let id: String
            let name: String
            let items: [[String]]
        }
        guard let url = Bundle.module.url(forResource: "ForumEmoticons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let categories = try? JSONDecoder().decode([Category].self, from: data) else { return [] }
        let baseURL = YamiboDomain.baseURL.appendingPathComponent("static/image/smiley")
        return categories.map { category in
            ForumEmoticonCategory(id: category.id, name: category.name, items: category.items.compactMap { pair in
                guard pair.count == 2 else { return nil }
                return ForumEmoticon(code: pair[0], imageURL: baseURL.appendingPathComponent(category.id).appendingPathComponent(pair[1]))
            })
        }
    }()
}
