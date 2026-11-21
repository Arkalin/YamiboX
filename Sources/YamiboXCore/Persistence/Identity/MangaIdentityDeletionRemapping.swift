import Foundation

enum MangaIdentityDeletionRemapping {
    static func normalize(
        _ state: SyncDeletionState,
        identities: MangaDirectoryIdentitySnapshot,
        legacy: Bool = false,
        directoryKeys: Bool = false
    ) -> SyncDeletionState {
        let directoryDataset = directoryKeys
        let tombstones = state.tombstones.mapValues(\.timeIntervalSinceReferenceDate)
        var normalized: [String: Double] = [:]
        func insert(_ key: String, _ date: Double) {
            if let previous = normalized[key] {
                normalized[key] = max(previous, date)
            } else { normalized[key] = date }
        }
        func retainOriginalKey(_ original: String, resolved: String, date: Double) {
            guard resolved != original, !resolved.hasPrefix(pendingPrefix),
                  !resolved.hasPrefix(protectedPrefix) else { return }
            insert(confirmedPrefix + original, date)
        }
        var recovered: Set<String> = []
        for (marker, date) in tombstones where marker.hasPrefix(protectedPrefix) {
            let original = String(marker.dropFirst(protectedPrefix.count))
            guard let parts = mangaKey(original, directoryDataset: directoryDataset) else { continue }
            let timestamp = date
            let guessedID = MangaDirectoryID.legacy(name: parts.value).rawValue
            let guessed = parts.prefix + guessedID
            guard let guessedDate = tombstones[guessed], guessedDate == timestamp else { continue }
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
            let newKey = normalizeKey(key, identities: identities, legacy: legacy, directoryDataset: directoryDataset, deletedAt: date)
            insert(newKey, date)
            let original = key.hasPrefix(pendingPrefix) ? String(key.dropFirst(pendingPrefix.count)) : key
            if (legacy || key.hasPrefix(pendingPrefix)), newKey != key,
               !original.hasPrefix(protectedPrefix), !original.hasPrefix(confirmedPrefix) {
                retainOriginalKey(original, resolved: newKey, date: date)
            }
        }

        var result = state
        result.tombstones = normalized.mapValues { Date(timeIntervalSinceReferenceDate: $0) }
        return result
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
        if !legacyValue, isStableID(value) { return parts.prefix + identities.canonicalID(value) }
        guard let id = identities.legacyIdentities[value] ?? identities.names[value] ?? identities.redirects[value] else {
            return pendingPrefix + key
        }
        let resolved = identities.canonicalID(id)
        let isName = identities.names[value] != nil || parts.prefix == "SmartManga:" || parts.prefix.isEmpty
        if isName, let currentName = identities.titles[resolved], currentName != value {
            guard let deletedAt, deletedAt.isFinite,
                  let renamedAt = identities.titleModifiedAt[resolved], renamedAt.isFinite, renamedAt > 0 else {
                return pendingPrefix + key
            }
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
        return resolveLegacyKey(key, identities: identities, directoryDataset: directoryDataset, legacyValue: legacy, deletedAt: deletedAt)
    }
}
