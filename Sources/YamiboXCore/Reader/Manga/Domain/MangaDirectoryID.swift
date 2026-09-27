import CryptoKit
import Foundation

/// A persisted identity, never recomputed when a directory's metadata changes.
public struct MangaDirectoryID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init() {
        rawValue = "manga-id:" + UUID().uuidString.lowercased()
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Only legacy importers may derive an identity from a name. Independent
    /// devices importing the same old primary key must produce the same ID.
    static func legacy(name: String) -> Self {
        let key = "yamibox/manga-directory/v1\u{0}" + name.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(rawValue: "manga-legacy:" + digest)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid manga directory ID")
        }
        rawValue = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
