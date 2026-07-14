import Foundation

public struct AppSource: Codable, Equatable, Sendable {
    public var name: String
    public var identifier: String
    public var apps: [AppSourceApp]

    public init(name: String, identifier: String, apps: [AppSourceApp]) {
        self.name = name
        self.identifier = identifier
        self.apps = apps
    }
}

public struct AppSourceApp: Codable, Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var developerName: String?
    public var localizedDescription: String?
    public var iconURL: URL?
    public var versions: [AppSourceVersion]

    public init(
        name: String,
        bundleIdentifier: String,
        developerName: String? = nil,
        localizedDescription: String? = nil,
        iconURL: URL? = nil,
        versions: [AppSourceVersion]
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.developerName = developerName
        self.localizedDescription = localizedDescription
        self.iconURL = iconURL
        self.versions = versions
    }
}

public struct AppSourceVersion: Codable, Equatable, Sendable {
    public var version: String
    public var date: String?
    public var localizedDescription: String?
    public var downloadURL: URL
    public var size: Int64?

    public init(
        version: String,
        date: String? = nil,
        localizedDescription: String? = nil,
        downloadURL: URL,
        size: Int64? = nil
    ) {
        self.version = version
        self.date = date
        self.localizedDescription = localizedDescription
        self.downloadURL = downloadURL
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case date
        case localizedDescription
        case downloadURL
        case size
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        size = try container.decodeFlexibleInt64IfPresent(forKey: .size)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(localizedDescription, forKey: .localizedDescription)
        try container.encode(downloadURL, forKey: .downloadURL)
        try container.encodeIfPresent(size, forKey: .size)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
        if let intValue = try? decodeIfPresent(Int64.self, forKey: key) {
            return intValue
        }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(stringValue)
        }
        return nil
    }
}
