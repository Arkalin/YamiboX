import Foundation

/// Portable identity information accompanies every manga-bearing dataset.
public struct MangaDirectoryIdentitySnapshot: Codable, Equatable, Sendable {
    public var names: [String: String]
    public var legacyIdentities: [String: String]
    public var redirects: [String: String]
    public var titles: [String: String]
    public var titleModifiedAt: [String: Double]

    public init(names: [String: String] = [:], legacyIdentities: [String: String] = [:], redirects: [String: String] = [:], titles: [String: String] = [:], titleModifiedAt: [String: Double] = [:]) {
        self.names = names
        self.legacyIdentities = legacyIdentities
        self.redirects = redirects
        self.titles = titles
        self.titleModifiedAt = titleModifiedAt
    }

    private enum CodingKeys: CodingKey { case names, legacyIdentities, redirects, titles, titleModifiedAt }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        names = try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        legacyIdentities = try values.decodeIfPresent([String: String].self, forKey: .legacyIdentities) ?? [:]
        redirects = try values.decodeIfPresent([String: String].self, forKey: .redirects) ?? [:]
        titles = try values.decodeIfPresent([String: String].self, forKey: .titles) ?? [:]
        titleModifiedAt = try values.decodeIfPresent([String: Double].self, forKey: .titleModifiedAt) ?? [:]
    }

    public func canonicalID(_ id: String) -> String {
        var current = id
        var visited: Set<String> = []
        while let next = redirects[current], visited.insert(current).inserted {
            current = next
        }
        return current
    }

    func resolve(_ value: String, name: String? = nil, legacy: Bool) -> String {
        if legacy, let id = legacyIdentities[value] ?? name.flatMap({ names[$0] }) ?? names[value] { return canonicalID(id) }
        if value.hasPrefix("manga-id:") || value.hasPrefix("manga-legacy:") || value.hasPrefix("manga-thread:") { return canonicalID(value) }
        if let id = legacyIdentities[value] ?? names[value] ?? name.flatMap({ names[$0] }) { return canonicalID(id) }
        return legacy ? MangaDirectoryID.legacy(name: name ?? value).rawValue : canonicalID(value)
    }
}
