import Foundation

struct MangaIdentityLegacyTarget: Sendable {
    var id: String
    var name: String
    var identity: String?
}

struct MangaIdentityLegacyDeletion {
    var keys: [String]
    var date: Double?
}

/// A feature supplies chapter evidence without exposing its payload layout.
struct MangaIdentityTargetReference: Sendable {
    var index: Int
    var name: String
    var identity: String?
    var chapterTID: String?
}

/// Dataset-owned payload rules. The transport decorator never switches on
/// dataset IDs or decodes a current feature payload. Every dataset supplies a
/// typed normalizer; JSON shape compatibility is confined to legacy imports.
struct MangaIdentityPayloadStrategy: Sendable {
    let legacyTargetField: String?
    let legacyRecordCollection: String
    let legacyRecordDeletion: @Sendable ([String: Any]) -> MangaIdentityLegacyDeletion?
    let prepareForNormalization: @Sendable (Data) throws -> Data
    let contentFingerprint: (@Sendable (Data) throws -> String)?
    let currentTargetReferences: @Sendable (Data) throws -> [MangaIdentityTargetReference]
    let normalizePayload: @Sendable (Data, MangaDirectoryIdentitySnapshot, [Int: MangaIdentityLegacyTarget]) throws -> Data

    init(
        legacyTargetField: String? = nil,
        legacyRecordCollection: String = "records",
        legacyRecordDeletion: @escaping @Sendable ([String: Any]) -> MangaIdentityLegacyDeletion? = { _ in nil },
        prepareForNormalization: @escaping @Sendable (Data) throws -> Data = { $0 },
        contentFingerprint: (@Sendable (Data) throws -> String)? = nil,
        currentTargetReferences: @escaping @Sendable (Data) throws -> [MangaIdentityTargetReference] = { _ in [] },
        normalizePayload: @escaping @Sendable (Data, MangaDirectoryIdentitySnapshot, [Int: MangaIdentityLegacyTarget]) throws -> Data
    ) {
        self.legacyTargetField = legacyTargetField
        self.legacyRecordCollection = legacyRecordCollection
        self.legacyRecordDeletion = legacyRecordDeletion
        self.prepareForNormalization = prepareForNormalization
        self.contentFingerprint = contentFingerprint
        self.currentTargetReferences = currentTargetReferences
        self.normalizePayload = normalizePayload
    }

    func contentWasNormalized(original: Data, normalized: Data) throws -> Bool {
        guard let contentFingerprint else { return false }
        return try contentFingerprint(original) != contentFingerprint(normalized)
    }

    func normalize(
        _ data: Data,
        identities: MangaDirectoryIdentitySnapshot,
        legacy: Bool,
        datasetID: String,
        resolvedTargets: [Int: MangaIdentityLegacyTarget]
    ) throws -> Data {
        let prepared = try prepareForNormalization(data)
        guard legacy else { return try normalizePayload(prepared, identities, resolvedTargets) }
        let normalized = try MangaIdentityLegacyJSONV1.normalize(prepared, identities: identities, legacy: true, datasetID: datasetID)
        guard !resolvedTargets.isEmpty, let field = legacyTargetField else { return normalized }
        var payload = try object(normalized)
        var records = payload["records"] as? [[String: Any]] ?? []
        for (index, target) in resolvedTargets {
            guard var value = records[index][field] as? [String: Any] else { continue }
            value["mangaID"] = identities.canonicalID(target.id)
            records[index][field] = value
        }
        payload["records"] = records
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Resolve the complete batch before merging any registry entries. An
    /// ambiguous old backup stays untouched and retryable, rather than making
    /// an irreversible cross-directory redirect from a historical title.
    func resolveLegacyTargets(in data: Data, legacy: Bool, directoryStore: MangaDirectoryStore, datasetID: String) async throws -> [Int: MangaIdentityLegacyTarget] {
        let references: [MangaIdentityTargetReference]
        if legacy {
            guard let field = legacyTargetField else { return [:] }
            let payload = try object(data)
            let records = payload["records"] as? [[String: Any]] ?? []
            references = records.enumerated().compactMap { index, record in
                guard let target = record[field] as? [String: Any], target["kind"] as? String == "mangaTitle",
                      let name = target["cleanBookName"] as? String else { return nil }
                return MangaIdentityTargetReference(index: index, name: name, identity: target["mangaID"] as? String,
                    chapterTID: (record["manga"] as? [String: Any])?["chapterThreadID"] as? String ?? record["threadID"] as? String)
            }
        } else {
            references = try currentTargetReferences(data)
        }
        var result: [Int: MangaIdentityLegacyTarget] = [:]
        var resolvedAliases: [String: String] = [:]
        for reference in references {
            let name = reference.name
            let identity = reference.identity
            if !legacy, let identity,
               identity.hasPrefix("manga-id:") || identity.hasPrefix("manga-legacy:") || identity.hasPrefix("manga-thread:") { continue }
            guard let id = try await directoryStore.resolveLegacyImportDirectoryID(name: name,
                identity: identity, chapterTID: reference.chapterTID, allowNameFallback: legacy) else {
                if !legacy { continue }
                throw YamiboPersistenceError(context: "Ambiguous legacy manga identity in \(datasetID): \(name)")
            }
            if legacy, let identity, identity != name {
                if let previous = resolvedAliases[identity], previous != id.rawValue {
                    throw YamiboPersistenceError(context: "Conflicting legacy manga identity in \(datasetID): \(identity)")
                }
                resolvedAliases[identity] = id.rawValue
            }
            result[reference.index] = MangaIdentityLegacyTarget(id: id.rawValue, name: name, identity: identity)
        }
        return result
    }

    func legacyIdentitySnapshot(in value: Any) throws -> MangaDirectoryIdentitySnapshot {
        var result = MangaDirectoryIdentitySnapshot()
        func addName(_ name: String) {
            guard !name.isEmpty else { return }
            result.names[name] = MangaDirectoryID.legacy(name: name).rawValue
        }
        func visit(_ value: Any) {
            if let values = value as? [Any] { values.forEach(visit); return }
            guard let object = value as? [String: Any] else { return }
            // History/progress targets are resolved with their containing
            // record's chapter evidence, never by recursively hashing a name.
            if object["kind"] as? String == "mangaTitle",
               legacyTargetField != nil { return }
            if let name = (object["cleanBookName"] ?? object["mangaCleanBookName"]) as? String, !name.isEmpty {
                let id = MangaDirectoryID.legacy(name: name).rawValue
                result.names[name] = id
                if let old = object["mangaID"] as? String { result.legacyIdentities[old] = id }
                if let old = object["favoriteIdentity"] as? String { result.legacyIdentities[old] = id }
                if object["strategy"] != nil, object["chapters"] != nil,
                   let encoded = try? JSONSerialization.data(withJSONObject: object),
                   let directory = try? JSONDecoder().decode(MangaDirectory.self, from: encoded) {
                    result.legacyIdentities[directory.legacyFavoriteIdentity] = id
                }
            }
            if object["kind"] as? String == "manga", let name = object["id"] as? String { addName(name) }
            if object["targetType"] as? String == "SmartManga", let name = object["targetID"] as? String { addName(name) }
            if let target = object["mangaDirectory"] as? [String: Any], let name = target["cleanBookName"] as? String { addName(name) }
            object.values.forEach(visit)
        }
        visit(value)
        return result
    }

    func filteringLegacyDeletions(_ data: Data, local: SyncDeletionState?) throws -> Data {
        var payload = try object(data)
        let remote = (payload["deletions"] as? [String: Any])?["tombstones"] as? [String: Double] ?? [:]
        var deletions = local?.tombstones.mapValues(\.timeIntervalSinceReferenceDate) ?? [:]
        for (key, date) in remote { deletions[key] = max(deletions[key] ?? date, date) }
        let collection = legacyRecordCollection
        guard let records = payload[collection] as? [[String: Any]] else { return data }
        payload[collection] = records.filter { record in
            guard let deletion = legacyRecordDeletion(record),
                  let date = deletion.date else { return true }
            let keys = deletion.keys
            return !keys.contains { key in
                let removedAt = [deletions[key], deletions["legacy-name:" + key], deletions["legacy-pending:" + key], deletions["legacy-resolved:" + key]].compactMap { $0 }.max()
                return removedAt.map { $0 >= date } ?? false
            }
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebDAVSyncError.emptyPayload
        }
        return object
    }
}
