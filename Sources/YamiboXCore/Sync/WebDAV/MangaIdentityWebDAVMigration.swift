import Foundation

/// Compatibility policy for manga-identity-v1. Historical bookkeeping keys and
/// import scopes intentionally retain their persisted names and encoding.
struct MangaIdentityWebDAVMigration: WebDAVSyncMigrating {
    let settingsStore: WebDAVSyncSettingsStore

    /// Imports legacy resources before any new-format merge. Completion is
    /// recorded only after a conditional upload succeeds; a failed import or
    /// upload remains retryable and never advances the migration marker.
    func prepare(
        settings: WebDAVSyncSettings,
        accountUID: String,
        operations: WebDAVSyncMigrationOperations
    ) async throws -> WebDAVSyncSettings {
        struct ImportScope: Encodable {
            var location: String
            var username: String
            var accountUID: String
            var datasetID: String
            var format = MangaIdentityWebDAVParticipant.namespace
        }
        let selected = operations.participants.filter { !settings.disabledContentIDs.contains($0.datasetID) }
        var importScopes: [String: String] = [:]
        for participant in selected where participant.legacyRemoteFileName != nil
            && participant.remoteDirectories.contains(MangaIdentityWebDAVParticipant.namespace) {
            importScopes[participant.datasetID] = try WebDAVSyncFingerprint.make(ImportScope(location: settings.trimmedBaseURLString,
                username: settings.trimmedUsername, accountUID: accountUID, datasetID: participant.datasetID))
        }
        let pendingImports = selected.filter { participant in
            guard let key = importScopes[participant.datasetID] else { return false }
            return !settings.completedMangaIdentityImports.contains(key)
        }
        var remotePayloads: [String: WebDAVRemotePayload] = [:]
        var legacyPayloads: [String: WebDAVRemotePayload] = [:]
        let needsPreflight = !pendingImports.isEmpty || importScopes.contains {
            settings.mangaIdentityBaselineScopeByDatasetID[$0.key] != $0.value
        }
        if needsPreflight {
            // Preflight the entire selected backup before touching local
            // identities, migration bookkeeping, or any remote resource.
            // Completed imports must not reread their legacy snapshots.
            remotePayloads = try await operations.fetchRemotePayloads(settings)
            for participant in pendingImports {
                guard let legacyName = participant.legacyRemoteFileName else { continue }
                let file: WebDAVRemoteFile
                do { file = try await operations.fetchRemoteFile(settings, legacyName) }
                catch WebDAVSyncError.notFound { continue }
                legacyPayloads[participant.datasetID] = WebDAVRemotePayload(
                    data: file.data, info: try participant.inspectRemote(file.data), etag: file.etag
                )
            }
            try operations.validateAccounts(remotePayloads)
            try operations.validateAccounts(legacyPayloads)
            try Task.checkCancellation()
        }

        var effective = settings
        for participant in selected {
            guard let key = importScopes[participant.datasetID] else { continue }
            let id = participant.datasetID
            // Neither old-format history nor another remote/account's
            // baseline may suppress this namespace's first export.
            if effective.mangaIdentityBaselineScopeByDatasetID[id] != key {
                effective.lastSyncedFingerprintByDatasetID[id] = nil
                effective.lastAppliedRemoteUpdatedAtByDatasetID[id] = nil
                effective.lastAppliedRemoteRevisionByDatasetID[id] = nil
                effective.localRevisionByDatasetID[id] = nil
                effective.dirtyDatasetIDs.insert(id)
                effective.mangaIdentityBaselineScopeByDatasetID[id] = key
                try await settingsStore.update { current in
                    if current.trimmedBaseURLString.isEmpty,
                       current.contentSelectionRevision == settings.contentSelectionRevision { current = settings }
                    guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings) else { return }
                    current.lastSyncedFingerprintByDatasetID[id] = nil
                    current.lastAppliedRemoteUpdatedAtByDatasetID[id] = nil
                    current.lastAppliedRemoteRevisionByDatasetID[id] = nil
                    current.localRevisionByDatasetID[id] = nil
                    current.dirtyDatasetIDs.insert(id)
                    current.mangaIdentityBaselineScopeByDatasetID[id] = key
                }
            }
            guard !effective.completedMangaIdentityImports.contains(key) else { continue }
            let remote = remotePayloads[id]
            if let legacy = legacyPayloads[id] {
                _ = try await participant.mergeAndExportSnapshot(remoteData: legacy.data,
                    updatedAt: operations.uploadStamp(legacy.info.updatedAt), accountUID: accountUID)
            }
            try await operations.upload(participant, remote, effective, operations.uploadStamp(remote?.info.updatedAt))
            try Task.checkCancellation()
            let updated = try await settingsStore.update { current in
                guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings) else { return }
                current.completedMangaIdentityImports.insert(key)
            }
            // A settings write can change the destination while an upload is
            // suspended. Never pair this round's fetched payloads with that
            // new connection, even when its migration bookkeeping was skipped.
            guard WebDAVConnectionIdentity(updated) == WebDAVConnectionIdentity(settings) else {
                throw CancellationError()
            }
            effective = updated
            effective.disabledContentIDs = settings.disabledContentIDs
            effective.contentSelectionRevision = settings.contentSelectionRevision
        }
        return effective
    }
}
