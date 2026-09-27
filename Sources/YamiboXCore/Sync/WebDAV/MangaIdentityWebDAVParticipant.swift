import Foundation

/// Adds identity transport without teaching each dataset's merger about the
/// directory registry. Every payload is self-contained, including when the
/// user elects to sync annotations but not directories.
struct MangaIdentityWebDAVParticipant: WebDAVSyncParticipant {
    static let namespace = "manga-identity-v1"
    private static let identityKey = "mangaIdentities"
    let base: any WebDAVSyncParticipant
    let directoryStore: MangaDirectoryStore

    var datasetID: String { base.datasetID }
    var legacyRemoteFileName: String? { base.remoteFileName }
    var remoteFileName: String { "\(Self.namespace)/\(base.remoteFileName)" }
    var uploadsOnlyWhenMarkedDirty: Bool { base.uploadsOnlyWhenMarkedDirty }
    var uploadsUntrackedContentAutomatically: Bool { true }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        var info = try base.inspectRemote(data)
        if let account = try object(data)["accountUID"] as? String { info.accountUID = account }
        return info
    }

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot {
        let normalized = try await normalize(remoteData)
        let result = try await base.mergeAndExportSnapshot(remoteData: normalized, updatedAt: updatedAt, accountUID: accountUID)
        let identities = try await directoryStore.identitySnapshot()
        var payload = try object(result.data)
        payload[Self.identityKey] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identities))
        payload["accountUID"] = accountUID
        return WebDAVExportSnapshot(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            fingerprint: try fingerprint(result.fingerprint, identities: identities))
    }

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot {
        guard let normalized = try await normalize(data) else { throw WebDAVSyncError.emptyPayload }
        let contentWasNormalized: Bool
        // The base compares against normalized input. A stale title or a
        // newly resolved legacy key needs repair even if local data matches.
        switch datasetID {
        case WebDAVSyncContent.mangaDirectories.rawValue:
            contentWasNormalized = try MangaDirectoryWebDAVPayload.decode(data).contentFingerprint()
                != MangaDirectoryWebDAVPayload.decode(normalized).contentFingerprint()
        case WebDAVSyncContent.readingProgress.rawValue:
            contentWasNormalized = try JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: data).contentFingerprint()
                != JSONDecoder().decode(ReadingProgressWebDAVPayload.self, from: normalized).contentFingerprint()
        case WebDAVSyncContent.browsingHistory.rawValue:
            contentWasNormalized = try BrowsingHistoryWebDAVPayload.decode(data).contentFingerprint()
                != BrowsingHistoryWebDAVPayload.decode(normalized).contentFingerprint()
        default:
            contentWasNormalized = false
        }
        let result = try await base.applyRemoteSnapshot(normalized)
        let identities = try await directoryStore.identitySnapshot()
        let remoteIdentities = try identitySnapshot(in: data)
        return WebDAVApplySnapshot(fingerprint: try fingerprint(result.fingerprint, identities: identities),
            requiresUpload: result.requiresUpload || contentWasNormalized || remoteIdentities != identities)
    }

    func readLocalFingerprint() async throws -> String? {
        let content = try await base.readLocalFingerprint()
        let identities = try await directoryStore.identitySnapshot()
        return try fingerprint(content, identities: identities)
    }

    private func fingerprint(_ content: String?, identities: MangaDirectoryIdentitySnapshot) throws -> String {
        struct Snapshot: Encodable { var content: String?; var identities: MangaDirectoryIdentitySnapshot }
        return try WebDAVSyncFingerprint.make(Snapshot(content: content, identities: identities))
    }

    private func normalize(_ data: Data?) async throws -> Data? {
        guard var data else { return nil }
        let exported = try identitySnapshot(in: data)
        if exported == nil {
            data = try await filteringLegacyDeletions(data, local: base.readLocalDeletionState())
        }
        // Legacy payloads lack a registry. Derive identities only at this
        // import boundary, never from a production write's display name.
        var legacyTargets = exported == nil ? try await resolveLegacyTargets(in: data, legacy: true) : [:]
        var identities = try exported ?? legacyIdentitySnapshot(in: object(data))
        if !legacyTargets.isEmpty {
            let known = try await directoryStore.identitySnapshot()
            for target in legacyTargets.values where known.titles[target.id] == nil {
                identities.names[target.name] = target.id
                identities.titles[target.id] = target.name
                identities.titleModifiedAt[target.id] = 0
            }
            for target in legacyTargets.values {
                if let old = target.identity, old != target.name { identities.legacyIdentities[old] = target.id }
            }
        }
        try await directoryStore.mergeIdentitySnapshot(identities)
        if exported != nil {
            // Incoming aliases can disambiguate a record preserved by local
            // migration. Retry only after those aliases are in the registry.
            legacyTargets = try await resolveLegacyTargets(in: data, legacy: false)
        }
        let canonical = try await directoryStore.identitySnapshot()
        var content = data
        if datasetID == WebDAVSyncContent.mangaDirectories.rawValue {
            // Decode before rewriting IDs so older payloads acquire their
            // original content lineage, not the already-canonical identity.
            let payload = try MangaDirectoryWebDAVPayload.decode(data)
            content = try JSONEncoder().encode(payload)
        }
        let normalized = try MangaDirectoryIdentityJSON.normalize(content,
            identities: canonical, legacy: exported == nil, datasetID: datasetID)
        guard !legacyTargets.isEmpty else { return normalized }
        var payload = try object(normalized)
        var records = payload["records"] as? [[String: Any]] ?? []
        let field = datasetID == WebDAVSyncContent.browsingHistory.rawValue ? "target" : "contentTarget"
        for (index, target) in legacyTargets {
            guard var value = records[index][field] as? [String: Any] else { continue }
            value["mangaID"] = canonical.canonicalID(target.id)
            records[index][field] = value
        }
        payload["records"] = records
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private struct LegacyTarget {
        var id: String
        var name: String
        var identity: String?
    }

    /// Resolve the complete batch before merging any registry entries. An
    /// ambiguous old backup stays untouched and retryable, rather than making
    /// an irreversible cross-directory redirect from a historical title.
    private func resolveLegacyTargets(in data: Data, legacy: Bool) async throws -> [Int: LegacyTarget] {
        guard datasetID == WebDAVSyncContent.browsingHistory.rawValue || datasetID == WebDAVSyncContent.readingProgress.rawValue else { return [:] }
        let payload = try object(data)
        let records = payload["records"] as? [[String: Any]] ?? []
        let field = datasetID == WebDAVSyncContent.browsingHistory.rawValue ? "target" : "contentTarget"
        var result: [Int: LegacyTarget] = [:]
        var resolvedAliases: [String: String] = [:]
        for (index, record) in records.enumerated() {
            guard let target = record[field] as? [String: Any], target["kind"] as? String == "mangaTitle",
                  let name = target["cleanBookName"] as? String else { continue }
            let chapter = (record["manga"] as? [String: Any])?["chapterThreadID"] as? String ?? record["threadID"] as? String
            let identity = target["mangaID"] as? String
            if !legacy, let identity,
               identity.hasPrefix("manga-id:") || identity.hasPrefix("manga-legacy:") || identity.hasPrefix("manga-thread:") { continue }
            guard let id = try await directoryStore.resolveLegacyImportDirectoryID(name: name,
                identity: identity, chapterTID: chapter, allowNameFallback: legacy) else {
                if !legacy { continue }
                throw YamiboPersistenceError(context: "Ambiguous legacy manga identity in \(datasetID): \(name)")
            }
            if legacy, let identity, identity != name {
                if let previous = resolvedAliases[identity], previous != id.rawValue {
                    throw YamiboPersistenceError(context: "Conflicting legacy manga identity in \(datasetID): \(identity)")
                }
                resolvedAliases[identity] = id.rawValue
            }
            result[index] = LegacyTarget(id: id.rawValue, name: name, identity: identity)
        }
        return result
    }

    private func identitySnapshot(in data: Data) throws -> MangaDirectoryIdentitySnapshot? {
        guard let value = try object(data)[Self.identityKey] else { return nil }
        let snapshot = try JSONDecoder().decode(MangaDirectoryIdentitySnapshot.self,
            from: JSONSerialization.data(withJSONObject: value))
        let ids = Array(snapshot.names.values) + Array(snapshot.legacyIdentities.values)
            + Array(snapshot.redirects.keys) + Array(snapshot.redirects.values) + Array(snapshot.titles.keys)
        guard ids.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              snapshot.titleModifiedAt.values.allSatisfy(\.isFinite) else {
            throw YamiboPersistenceError(context: "Invalid synchronized manga identities")
        }
        return snapshot
    }

    private func legacyIdentitySnapshot(in value: Any) throws -> MangaDirectoryIdentitySnapshot {
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
               datasetID == WebDAVSyncContent.browsingHistory.rawValue || datasetID == WebDAVSyncContent.readingProgress.rawValue { return }
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

    private func filteringLegacyDeletions(_ data: Data, local: SyncDeletionState?) throws -> Data {
        var payload = try object(data)
        let remote = (payload["deletions"] as? [String: Any])?["tombstones"] as? [String: Double] ?? [:]
        var deletions = local?.tombstones.mapValues(\.timeIntervalSinceReferenceDate) ?? [:]
        for (key, date) in remote { deletions[key] = max(deletions[key] ?? date, date) }
        let collection = datasetID == WebDAVSyncContent.contentCovers.rawValue ? "covers" : "records"
        guard let records = payload[collection] as? [[String: Any]] else { return data }
        payload[collection] = records.filter { record in
            let keys: [String]
            let date: Double?
            switch datasetID {
            case WebDAVSyncContent.mangaDirectories.rawValue:
                keys = ((record["directory"] as? [String: Any])?["cleanBookName"] as? String).map { [$0] } ?? []
                date = record["modifiedAt"] as? Double
            case WebDAVSyncContent.contentCovers.rawValue:
                let key = record["key"] as? [String: Any]
                keys = (key?["targetType"] as? String).flatMap { type in
                    (key?["targetID"] as? String).map { [type + ":" + $0] }
                } ?? []
                date = record["updatedAt"] as? Double
            case WebDAVSyncContent.readingProgress.rawValue, WebDAVSyncContent.browsingHistory.rawValue:
                let target = (record["contentTarget"] ?? record["target"]) as? [String: Any]
                guard target?["kind"] as? String == "mangaTitle" else { return true }
                keys = ((target?["mangaID"] ?? target?["cleanBookName"]) as? String).map { ["manga-title:" + $0] } ?? []
                date = (record["updatedAt"] ?? record["lastVisitTime"]) as? Double
            default:
                return true
            }
            guard let date else { return true }
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
