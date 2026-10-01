import Foundation

/// Feature-owned identity capability, consumed only by the composition root.
protocol MangaIdentitySyncParticipant: WebDAVSyncParticipant {
    var mangaIdentityStrategy: MangaIdentityPayloadStrategy? { get }
}

extension MangaIdentitySyncParticipant {
    func applyingMangaIdentity(using store: MangaDirectoryStore) -> any WebDAVSyncParticipant {
        guard let strategy = mangaIdentityStrategy else { return self }
        return MangaIdentityWebDAVParticipant(base: self, directoryStore: store, strategy: strategy)
    }
}

/// Adds identity transport without teaching each dataset's merger about the
/// directory registry. Every payload is self-contained, including when the
/// user elects to sync annotations but not directories.
struct MangaIdentityWebDAVParticipant: WebDAVSyncParticipant {
    static let namespace = "manga-identity-v1"
    private static let identityKey = "mangaIdentities"
    let base: any WebDAVSyncParticipant
    let directoryStore: MangaDirectoryStore
    let strategy: MangaIdentityPayloadStrategy

    var datasetID: String { base.datasetID }
    var legacyRemoteFileName: String? { base.remoteFileName }
    var remoteFileName: String { "\(Self.namespace)/\(base.remoteFileName)" }
    var remoteDirectories: [String] { [Self.namespace] }
    var uploadsOnlyWhenMarkedDirty: Bool { base.uploadsOnlyWhenMarkedDirty }
    var uploadsUntrackedContentAutomatically: Bool { true }
    var localFingerprintDependencies: Set<String> {
        base.localFingerprintDependencies.union([WebDAVSyncContent.mangaDirectories.rawValue])
    }

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
        let contentWasNormalized = try strategy.contentWasNormalized(original: data, normalized: normalized)
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
            data = try await strategy.filteringLegacyDeletions(data, local: base.readLocalDeletionState())
        }
        // Legacy payloads lack a registry. Derive identities only at this
        // import boundary, never from a production write's display name.
        var legacyTargets = exported == nil ? try await strategy.resolveLegacyTargets(in: data, legacy: true, directoryStore: directoryStore, datasetID: datasetID) : [:]
        var identities = try exported ?? strategy.legacyIdentitySnapshot(in: object(data))
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
            legacyTargets = try await strategy.resolveLegacyTargets(in: data, legacy: false, directoryStore: directoryStore, datasetID: datasetID)
        }
        let canonical = try await directoryStore.identitySnapshot()
        return try strategy.normalize(data, identities: canonical, legacy: exported == nil,
            datasetID: datasetID, resolvedTargets: legacyTargets)
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

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebDAVSyncError.emptyPayload
        }
        return object
    }
}
