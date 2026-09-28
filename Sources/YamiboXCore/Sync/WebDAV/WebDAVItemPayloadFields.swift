import Foundation

/// Common wire fields, not a shared dataset/version. Each payload supplies its
/// own current version and keeps ownership of item semantics and merge rules.
struct WebDAVItemPayloadFields<Item: Codable>: Encodable {
    var version: Int
    var updatedAt: Date
    var syncRevision: UInt64?
    var items: [Item]
    var tombstones: [String: Date]

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, syncRevision, items, tombstones
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(syncRevision, forKey: .syncRevision)
        try container.encode(items, forKey: .items)
        try container.encode(tombstones, forKey: .tombstones)
    }
}

extension WebDAVItemPayloadFields {
    init(from decoder: any Decoder, currentVersion: Int) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(Int.self, forKey: .version) else {
            throw WebDAVSyncError.unsupportedPayloadVersion(0)
        }
        guard version == 1 || version == currentVersion else {
            throw WebDAVSyncError.unsupportedPayloadVersion(version)
        }
        self.version = version
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        syncRevision = try container.decodeIfPresent(UInt64.self, forKey: .syncRevision)
        items = try container.decode([Item].self, forKey: .items)
        tombstones = version == 1
            ? try container.decodeIfPresent([String: Date].self, forKey: .tombstones) ?? [:]
            : try container.decode([String: Date].self, forKey: .tombstones)
    }
}
