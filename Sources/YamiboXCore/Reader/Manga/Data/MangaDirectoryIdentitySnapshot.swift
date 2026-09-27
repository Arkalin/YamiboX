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

/// Transforms structured records rather than replacing arbitrary strings. Titles,
/// URLs, excerpts and chapter TIDs are never interpreted as directory keys.
enum MangaDirectoryIdentityJSON {
    static func normalize(_ data: Data, identities: MangaDirectoryIdentitySnapshot, legacy: Bool, datasetID: String? = nil) throws -> Data {
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: normalize(value, identities: identities, legacy: legacy, datasetID: datasetID), options: [.sortedKeys, .fragmentsAllowed])
    }

    private static func normalize(_ value: Any, identities: MangaDirectoryIdentitySnapshot, legacy: Bool, datasetID: String?) -> Any {
        if let array = value as? [Any] { return array.map { normalize($0, identities: identities, legacy: legacy, datasetID: datasetID) } }
        guard let source = value as? [String: Any] else { return value }
        var object = source.mapValues { normalize($0, identities: identities, legacy: legacy, datasetID: datasetID) }
        if source["strategy"] != nil, source["chapters"] != nil, let name = source["cleanBookName"] as? String {
            let id = identities.resolve(source["id"] as? String ?? name, name: name, legacy: legacy)
            object["id"] = id
            // The title has its own conflict clock. Apply its winning value
            // before merging content so the exported receipt matches storage.
            if let title = identities.titles[id], title != id { object["cleanBookName"] = title }
        }
        if ["mangaTitle", "smartManga"].contains(source["kind"] as? String ?? ""), let name = source["cleanBookName"] as? String {
            let id = source["mangaID"] as? String
            // An unresolved legacy history/progress target may survive local
            // migration. New-format transport must not resolve it by name
            // without the containing record's chapter evidence.
            if legacy || source["kind"] as? String != "mangaTitle" || id.map(isStableID) == true {
                object["mangaID"] = identities.resolve(id ?? name, name: name, legacy: legacy)
            }
        }
        if var group = source["smartManga"] as? [String: Any], let name = group["cleanBookName"] as? String {
            group["mangaID"] = identities.resolve(group["mangaID"] as? String ?? name, name: name, legacy: legacy)
            object["smartManga"] = group
        }
        if source["kind"] as? String == "manga", let id = source["id"] as? String {
            object["id"] = identities.resolve(id, legacy: legacy)
        }
        if source["targetType"] as? String == "SmartManga", let id = source["targetID"] as? String {
            object["targetID"] = identities.resolve(id, legacy: legacy)
        }
        if let target = source["mangaDirectory"] as? [String: Any] {
            if let id = target["directoryID"] as? String ?? target["cleanBookName"] as? String {
                object["mangaDirectory"] = ["directoryID": identities.resolve(id, legacy: legacy)]
            }
        }
        // Launch contexts and resolved favorite source metadata have explicit
        // directory fields; guessed names alone do not acquire an identity.
        for field in ["directoryID", "mangaDirectoryID"] {
            if let id = source[field] as? String { object[field] = identities.resolve(id, legacy: legacy) }
        }
        if let id = source["directoryIdentity"] as? String { object["directoryIdentity"] = identities.resolve(id, name: source["cleanBookName"] as? String, legacy: legacy) }
        if let tombstones = source["tombstones"] as? [String: Any] {
            var normalized: [String: Any] = [:]
            let directoryDataset = datasetID == "mangaDirectories"
            func insert(_ key: String, _ date: Any) {
                if let previous = normalized[key] as? Double, let date = date as? Double {
                    normalized[key] = max(previous, date)
                } else { normalized[key] = date }
            }
            func retainOriginalKey(_ original: String, resolved: String, date: Any) {
                guard resolved != original, !resolved.hasPrefix(pendingPrefix),
                      !resolved.hasPrefix(protectedPrefix) else { return }
                insert(confirmedPrefix + original, date)
            }
            // The first identity format used the same marker for guessed and
            // confirmed hashes. An identity already present in the registry
            // is evidence of a real deletion: never downgrade it just because
            // the directory has since been renamed. Only unregistered guesses
            // may return to pending/old-name protection.
            var recovered: Set<String> = []
            for (marker, date) in tombstones where marker.hasPrefix(protectedPrefix) {
                let original = String(marker.dropFirst(protectedPrefix.count))
                guard let parts = mangaKey(original, directoryDataset: directoryDataset),
                      let timestamp = date as? Double else { continue }
                let guessedID = MangaDirectoryID.legacy(name: parts.value).rawValue
                let guessed = parts.prefix + guessedID
                guard let guessedDate = tombstones[guessed] as? Double, guessedDate == timestamp else { continue }
                recovered.formUnion([marker, guessed])
                let canonicalID = identities.canonicalID(guessedID)
                if identities.titles[canonicalID] != nil || tombstones[confirmedPrefix + original] != nil {
                    insert(parts.prefix + canonicalID, date)
                    insert(confirmedPrefix + original, date)
                    continue
                }
                let key = resolveLegacyKey(original, identities: identities, directoryDataset: directoryDataset, legacyValue: true, deletedAt: timestamp)
                insert(key, date)
                retainOriginalKey(original, resolved: key, date: date)
            }
            for (key, date) in tombstones {
                guard !recovered.contains(key) else { continue }
                let newKey = normalizeKey(key, identities: identities, legacy: legacy, directoryDataset: datasetID == "mangaDirectories", deletedAt: date as? Double)
                insert(newKey, date)
                // Original-key markers only filter old-format records. Keep
                // confirmed deletions distinct from rename protection so a
                // later rename cannot undo a successfully resolved deletion.
                let original = key.hasPrefix(pendingPrefix) ? String(key.dropFirst(pendingPrefix.count)) : key
                if (legacy || key.hasPrefix(pendingPrefix)), newKey != key,
                   !original.hasPrefix(protectedPrefix), !original.hasPrefix(confirmedPrefix) {
                    retainOriginalKey(original, resolved: newKey, date: date)
                }
            }
            object["tombstones"] = normalized
        }
        return object
    }

    private static let protectedPrefix = "legacy-name:"
    private static let pendingPrefix = "legacy-pending:"
    private static let confirmedPrefix = "legacy-resolved:"

    private static func isStableID(_ value: String) -> Bool {
        value.hasPrefix("manga-id:") || value.hasPrefix("manga-legacy:") || value.hasPrefix("manga-thread:")
    }

    private static func mangaKey(_ key: String, directoryDataset: Bool) -> (prefix: String, value: String)? {
        for prefix in ["manga-title:", "manga-directory:", "SmartManga:"] where key.hasPrefix(prefix) {
            return (prefix, String(key.dropFirst(prefix.count)))
        }
        return directoryDataset ? ("", key) : nil
    }

    private static func resolveLegacyKey(_ key: String, identities: MangaDirectoryIdentitySnapshot, directoryDataset: Bool, legacyValue: Bool, deletedAt: Double?) -> String {
        guard let parts = mangaKey(key, directoryDataset: directoryDataset) else { return key }
        let value = parts.value
        // A legacy title may itself start with "manga-id:". Explicit legacy
        // aliases win for old keys, but never reinterpret a new-format ID as
        // a display name merely because an alias happens to share its text.
        if !legacyValue, isStableID(value) { return parts.prefix + identities.canonicalID(value) }
        guard let id = identities.legacyIdentities[value] ?? identities.names[value] ?? identities.redirects[value] else {
            return pendingPrefix + key
        }
        let resolved = identities.canonicalID(id)
        // A name tombstone can describe the removal of an old name during a
        // rename, not deletion of the surviving identity. Opaque favorite keys
        // have no such name semantics and can safely follow their mapping.
        let isName = identities.names[value] != nil || parts.prefix == "SmartManga:" || parts.prefix.isEmpty
        if isName, let currentName = identities.titles[resolved], currentName != value {
            // A later real deletion can arrive before the alias of an earlier
            // rename. A different current title alone does not prove that the
            // tombstone merely removed the old name. Compare clocks before
            // turning it into permanent old-format-only protection.
            guard let deletedAt, deletedAt.isFinite,
                  let renamedAt = identities.titleModifiedAt[resolved], renamedAt.isFinite, renamedAt > 0 else {
                return pendingPrefix + key
            }
            // Codable Date uses the 2001 reference epoch; identity title
            // clocks are persisted as Unix seconds.
            if Date(timeIntervalSinceReferenceDate: deletedAt).timeIntervalSince1970 <= renamedAt {
                return protectedPrefix + key
            }
        }
        return parts.prefix + resolved
    }

    static func normalizeKey(_ key: String, identities: MangaDirectoryIdentitySnapshot, legacy: Bool, directoryDataset: Bool = false, deletedAt: Double? = nil) -> String {
        if key.hasPrefix(protectedPrefix) || key.hasPrefix(confirmedPrefix) { return key }
        if key.hasPrefix(pendingPrefix) {
            return resolveLegacyKey(String(key.dropFirst(pendingPrefix.count)), identities: identities, directoryDataset: directoryDataset, legacyValue: true, deletedAt: deletedAt)
        }
        // Raw unknown keys from older new-format payloads also remain
        // retryable. Never manufacture a directory identity from a tombstone.
        return resolveLegacyKey(key, identities: identities, directoryDataset: directoryDataset, legacyValue: legacy, deletedAt: deletedAt)
    }
}
