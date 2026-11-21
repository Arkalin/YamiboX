import Foundation

public actor WebDAVSyncService {
    private static let minimumAutomaticSyncInterval: TimeInterval = 5 * 60
    private static let minimumLifecycleSyncInterval: TimeInterval = 15

    private let settingsStore: WebDAVSyncSettingsStore
    private let sessionStore: SessionStore
    private let participants: [any WebDAVSyncParticipant]
    private let client: WebDAVClient
    private let policyModule: WebDAVSyncPolicyModule
    private let migrations: [any WebDAVSyncMigrating]

    private enum LocalChanges: Sendable {
        case all
        case datasets(Set<String>)
    }

    init(
        settingsStore: WebDAVSyncSettingsStore,
        sessionStore: SessionStore,
        participants: [any WebDAVSyncParticipant],
        migrations: [any WebDAVSyncMigrating] = [],
        client: WebDAVClient = WebDAVClient(),
        policyModule: WebDAVSyncPolicyModule = WebDAVSyncPolicyModule()
    ) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.participants = participants
        self.migrations = migrations
        self.client = client
        self.policyModule = policyModule
    }

    @discardableResult
    public func upload() async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await performUpload(using: await settingsStore.load(), run: run)
        }
    }

    @discardableResult
    public func upload(using settings: WebDAVSyncSettings, allowingAccountMismatch: Bool = false) async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await performUpload(using: settings, allowingAccountMismatch: allowingAccountMismatch, run: run)
        }
    }

    private func performUpload(
        using settings: WebDAVSyncSettings,
        allowingAccountMismatch: Bool = false,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> Date {
        try await checkCurrent(run)
        guard settings.hasEnabledContent else { throw WebDAVSyncError.noContentSelected }
        let accountUID = try await currentAccountUID()
        try await checkCurrent(run)
        let scopedSettings = try await settingsStore.prepareReceiptScope(for: settings, accountUID: accountUID)
        try await checkCurrent(run)
        let settings = try await prepareDatasets(settings: scopedSettings, accountUID: accountUID, run: run,
            allowingAccountMismatch: allowingAccountMismatch)
        try await checkCurrent(run)
        let remotePayloads = try await fetchRemotePayloads(settings: settings, run: run)
        try await checkCurrent(run)
        if !allowingAccountMismatch {
            try validateAccount(of: remotePayloads, localUID: accountUID)
        }
        let updatedAt = uploadStamp(absorbing: remotePayloads.values.map(\.info.updatedAt).max())
        let uploaded = try await uploadParticipants(
            enabledParticipants(settings),
            remotePayloads: remotePayloads,
            settings: settings,
            accountUID: accountUID,
            updatedAt: updatedAt,
            run: run,
            allowingAccountMismatch: allowingAccountMismatch
        )
        try await updateSettingsAfterSync(settings, updatedAt: updatedAt, outcomes: uploaded, run: run)
        return updatedAt
    }

    @discardableResult
    public func download() async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await performDownload(using: await settingsStore.load(), run: run)
        }
    }

    @discardableResult
    public func download(using settings: WebDAVSyncSettings, allowingAccountMismatch _: Bool = false) async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await performDownload(using: settings, run: run)
        }
    }

    private func performDownload(using settings: WebDAVSyncSettings, run: WebDAVSyncCoordinator.RunToken) async throws -> Date {
        try await checkCurrent(run)
        guard settings.hasEnabledContent else { throw WebDAVSyncError.noContentSelected }
        let accountUID = try await currentAccountUID()
        try await checkCurrent(run)
        let scopedSettings = try await settingsStore.prepareReceiptScope(for: settings, accountUID: accountUID)
        try await checkCurrent(run)
        let settings = try await prepareDatasets(settings: scopedSettings, accountUID: accountUID, run: run)
        try await checkCurrent(run)
        let remotePayloads = try await fetchRemotePayloads(settings: settings, run: run)
        try await checkCurrent(run)
        try validateAccount(of: remotePayloads, localUID: accountUID)
        let applied = try await applyRemotePayloads(remotePayloads, run: run)
        guard let updatedAt = applied.values.map(\.appliedRemoteUpdatedAt).max() else {
            throw WebDAVSyncError.notFound
        }
        try await updateSettingsAfterSync(settings, updatedAt: updatedAt, outcomes: applied, run: run)
        return updatedAt
    }

    @discardableResult
    public func synchronizeAutomatically(bypassingMinimumInterval: Bool = false) async throws -> WebDAVAutomaticSyncResult {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await performAutomaticSync(bypassingMinimumInterval: bypassingMinimumInterval, run: run)
        }
    }

    /// Marks a coalesced local change and makes the automatic-sync decision in
    /// one coordinator run. Nil means the caller cannot identify the dataset.
    /// Fingerprints are local to this run; none survive account/receipt changes.
    func synchronizeAutomatically(
        afterLocalChangesIn datasetIDs: Set<String>?,
        bypassingMinimumInterval: Bool = false
    ) async throws -> WebDAVAutomaticSyncResult {
        let registeredIDs = Set(participants.map(\.datasetID))
        let changes: LocalChanges
        if let datasetIDs, datasetIDs.isSubset(of: registeredIDs) {
            changes = .datasets(datasetIDs)
        } else {
            changes = .all
        }
        return try await settingsStore.syncCoordinator.run { [self] run in
            try await performAutomaticSync(
                bypassingMinimumInterval: bypassingMinimumInterval, localChanges: changes, run: run
            )
        }
    }

    private func performAutomaticSync(
        bypassingMinimumInterval: Bool,
        localChanges: LocalChanges? = nil,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> WebDAVAutomaticSyncResult {
        try await checkCurrent(run)
        var settings = await settingsStore.load()
        try await checkCurrent(run)
        let snapshot = try await sessionStore.snapshot()
        try await checkCurrent(run)
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { return .skipped }
        let sessionState = snapshot.session
        guard policyModule.canSynchronizeAutomatically(settings: settings, session: sessionState) else {
            try await markChangesBeforeSkipping(localChanges, settings: settings, run: run)
            return .skipped
        }
        let accountUID = try? currentAccountUID(from: sessionState)
        guard let accountUID else {
            try await markChangesBeforeSkipping(localChanges, settings: settings, run: run)
            return .skipped
        }
        settings = try await settingsStore.prepareReceiptScope(for: settings, accountUID: accountUID)
        try await checkCurrent(run)
        let disabledContentIDs = settings.disabledContentIDs
        let selectionRevision = settings.contentSelectionRevision
        let participants = enabledParticipants(settings)
        guard !participants.isEmpty else { return .skipped }
        let (locallyChangedIDs, marksAllLocalChanges) = localChangeScope(localChanges, settings: settings)
        let lastReconciledAt = await settingsStore.syncCoordinator.lastAutomaticReconciliation(settings: settings)
        let lastCheck = [lastReconciledAt, settings.lastSyncedAt].compactMap { $0 }.max()
        let skipsNetwork = !bypassingMinimumInterval && lastCheck.map {
            Date.now.timeIntervalSince($0) < Self.minimumAutomaticSyncInterval
        } == true
        try await refreshDirtyState(
            at: .now,
            includeUntracked: marksAllLocalChanges,
            datasetIDs: localChanges != nil && skipsNetwork ? locallyChangedIDs : nil,
            includeUntrackedDatasetIDs: locallyChangedIDs,
            using: settings,
            run: run
        )
        settings = try await reloadSettings(for: settings, run: run)
        settings.disabledContentIDs = disabledContentIDs
        settings.contentSelectionRevision = selectionRevision
        if skipsNetwork {
            return .skipped
        }
        if bypassingMinimumInterval,
           settings.dirtyDatasetIDs.subtracting(settings.disabledContentIDs).isEmpty,
           let lastReconciledAt,
           Date.now.timeIntervalSince(lastReconciledAt) < Self.minimumLifecycleSyncInterval {
            return .skipped
        }
        let result = try await reconcileAutomatically(settings: settings, accountUID: accountUID, run: run)
        try await checkCurrent(run)
        await settingsStore.syncCoordinator.recordAutomaticReconciliation(settings: settings)
        return result
    }

    private func reconcileAutomatically(
        settings initialSettings: WebDAVSyncSettings,
        accountUID: String,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> WebDAVAutomaticSyncResult {
        var settings = initialSettings
        let disabledContentIDs = settings.disabledContentIDs
        let selectionRevision = settings.contentSelectionRevision
        let participants = enabledParticipants(settings)
        settings = try await prepareDatasets(settings: settings, accountUID: accountUID, run: run)

        try await checkCurrent(run)
        let remotePayloads = try await fetchRemotePayloads(settings: settings, run: run)
        try await checkCurrent(run)
        try validateAccount(of: remotePayloads, localUID: accountUID)
        try await refreshDirtyState(at: .now, includeUntracked: false, using: settings, run: run)
        settings = try await reloadSettings(for: settings, run: run)
        settings.disabledContentIDs = disabledContentIDs
        settings.contentSelectionRevision = selectionRevision
        let newestRemoteUpdatedAt = remotePayloads.values.map(\.info.updatedAt).max()
        let remoteIsAhead = remotePayloads.contains { datasetID, payload in
            remotePayloadIsAheadOfLocalState(payload.info, datasetID: datasetID, settings: settings)
        }

        if let newestRemoteUpdatedAt, remoteIsAhead {
            let dirtyParticipants = participants.filter {
                $0.uploadsOnlyWhenMarkedDirty && settings.dirtyDatasetIDs.contains($0.datasetID)
            }
            let applied = try await applyRemotePayloads(
                remotePayloads,
                excludingDatasetIDs: Set(dirtyParticipants.map(\.datasetID)),
                skippingPayloadsAlreadyAbsorbedPer: settings,
                run: run
            )
            guard !dirtyParticipants.isEmpty else {
                try await updateSettingsAfterSync(settings, updatedAt: newestRemoteUpdatedAt, outcomes: applied, run: run)
                return .downloaded
            }
            let updatedAt = uploadStamp(absorbing: newestRemoteUpdatedAt)
            let uploaded = try await uploadParticipants(
                dirtyParticipants,
                remotePayloads: remotePayloads,
                settings: settings,
                accountUID: accountUID,
                updatedAt: updatedAt,
                run: run
            )
            try await updateSettingsAfterSync(
                settings,
                updatedAt: updatedAt,
                outcomes: uploaded.merging(applied) { uploadedOutcome, _ in uploadedOutcome },
                run: run
            )
            return .uploaded
        }

        let included = participants.filter {
            !$0.uploadsOnlyWhenMarkedDirty || settings.dirtyDatasetIDs.contains($0.datasetID)
        }
        let applied = try await applyRemotePayloads(
            remotePayloads,
            excludingDatasetIDs: Set(included.map(\.datasetID)),
            skippingPayloadsAlreadyAbsorbedPer: settings,
            run: run
        )

        if included.isEmpty {
            guard let newestRemoteUpdatedAt, !applied.isEmpty else {
                return .skipped
            }
            try await updateSettingsAfterSync(settings, updatedAt: newestRemoteUpdatedAt, outcomes: applied, run: run)
            return .downloaded
        }

        let updatedAt = uploadStamp(absorbing: newestRemoteUpdatedAt)
        let uploaded = try await uploadParticipants(
            included,
            remotePayloads: remotePayloads,
            settings: settings,
            accountUID: accountUID,
            updatedAt: updatedAt,
            run: run
        )
        try await updateSettingsAfterSync(
            settings,
            updatedAt: updatedAt,
            outcomes: uploaded.merging(applied) { uploadedOutcome, _ in uploadedOutcome },
            run: run
        )
        return .uploaded
    }

    public func markLocalDataChanged(at date: Date = .now) async throws {
        try await settingsStore.syncCoordinator.run { [self] run in
            try await refreshDirtyState(at: date, includeUntracked: true, run: run)
        }
    }

    private func enabledParticipants(_ settings: WebDAVSyncSettings) -> [any WebDAVSyncParticipant] {
        participants.filter { !settings.disabledContentIDs.contains($0.datasetID) }
    }

    private func localChangeScope(
        _ changes: LocalChanges?, settings: WebDAVSyncSettings
    ) -> (Set<String>, Bool) {
        let enabled = enabledParticipants(settings)
        switch changes {
        case .all:
            return (Set(enabled.map(\.datasetID)), true)
        case let .datasets(changed):
            return (Set(enabled.filter {
                changed.contains($0.datasetID) || !$0.localFingerprintDependencies.isDisjoint(with: changed)
            }.map(\.datasetID)), false)
        case nil:
            return ([], false)
        }
    }

    private func markChangesBeforeSkipping(
        _ changes: LocalChanges?, settings: WebDAVSyncSettings, run: WebDAVSyncCoordinator.RunToken
    ) async throws {
        guard changes != nil else { return }
        let (ids, includesAll) = localChangeScope(changes, settings: settings)
        try await refreshDirtyState(
            at: .now, includeUntracked: includesAll, datasetIDs: ids,
            includeUntrackedDatasetIDs: ids, using: settings, run: run
        )
    }

    private func refreshDirtyState(
        at date: Date,
        includeUntracked: Bool,
        datasetIDs: Set<String>? = nil,
        includeUntrackedDatasetIDs: Set<String> = [],
        using snapshot: WebDAVSyncSettings? = nil,
        run: WebDAVSyncCoordinator.RunToken? = nil
    ) async throws {
        if let run { try await checkCurrent(run) }
        let settings: WebDAVSyncSettings
        if let snapshot { settings = snapshot } else { settings = await settingsStore.load() }
        guard settings.isAutoSyncEnabled, !enabledParticipants(settings).isEmpty else { return }
        var changed = Set<String>()
        for participant in enabledParticipants(settings) where participant.uploadsOnlyWhenMarkedDirty {
            guard datasetIDs?.contains(participant.datasetID) ?? true else { continue }
            if let run { try await checkCurrent(run) }
            guard includeUntracked || includeUntrackedDatasetIDs.contains(participant.datasetID)
                || settings.lastSyncedFingerprintByDatasetID[participant.datasetID] != nil
                || participant.uploadsUntrackedContentAutomatically else { continue }
            guard let fingerprint = try await participant.readLocalFingerprint() else { continue }
            if let run { try await checkCurrent(run) }
            if settings.lastSyncedFingerprintByDatasetID[participant.datasetID] != fingerprint {
                changed.insert(participant.datasetID)
            }
        }
        let changedIDs = changed
        try Task.checkCancellation()
        if let run { try await checkCurrent(run) }
        try await settingsStore.update { current in
            guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings),
                  current.receiptScope == settings.receiptScope else { return }
            current.dirtyDatasetIDs.formUnion(changedIDs)
            if !current.dirtyDatasetIDs.subtracting(current.disabledContentIDs).isEmpty { current.localUpdatedAt = date }
        }
        if let run { try await checkCurrent(run) }
    }

    private nonisolated func uploadStamp(absorbing newestRemoteUpdatedAt: Date?) -> Date {
        guard let newestRemoteUpdatedAt else { return .now }
        return max(.now, newestRemoteUpdatedAt.addingTimeInterval(0.001))
    }

    private func currentAccountUID() async throws -> String {
        let snapshot = try await sessionStore.snapshot()
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { throw CancellationError() }
        return try currentAccountUID(from: snapshot.session)
    }

    private nonisolated func currentAccountUID(from sessionState: SessionState) throws -> String {
        guard sessionState.isLoggedIn, sessionState.hasValidAuthenticationCookie else {
            throw YamiboError.notAuthenticated
        }
        let accountUID = sessionState.accountUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accountUID.isEmpty else {
            throw YamiboError.accountUIDUnavailable
        }
        return accountUID
    }

    private func prepareDatasets(
        settings: WebDAVSyncSettings,
        accountUID: String,
        run: WebDAVSyncCoordinator.RunToken,
        allowingAccountMismatch: Bool = false
    ) async throws -> WebDAVSyncSettings {
        let coordinator = settingsStore.syncCoordinator
        let operations = WebDAVSyncMigrationOperations(
            participants: participants,
            fetchRemotePayloads: { settings in
                try await coordinator.checkCurrent(run)
                let payloads = try await self.fetchRemotePayloads(settings: settings, run: run)
                try await coordinator.checkCurrent(run)
                return payloads
            },
            fetchRemoteFile: { [client, coordinator] settings, fileName in
                try await coordinator.checkCurrent(run)
                let file = try await client.fetchPayload(settings: settings, fileName: fileName)
                try await coordinator.checkCurrent(run)
                return file
            },
            validateAccounts: { payloads in
                if !allowingAccountMismatch {
                    try self.validateAccount(of: payloads, localUID: accountUID)
                }
            },
            uploadStamp: { self.uploadStamp(absorbing: $0) },
            upload: { participant, remote, settings, stamp in
                _ = try await self.uploadParticipants(
                    [participant],
                    remotePayloads: remote.map { [participant.datasetID: $0] } ?? [:],
                    settings: settings,
                    accountUID: accountUID,
                    updatedAt: stamp,
                    run: run,
                    allowingAccountMismatch: allowingAccountMismatch
                )
            },
            checkCurrent: {
                try await coordinator.checkCurrent(run)
            }
        )
        var prepared = settings
        for migration in migrations {
            try await checkCurrent(run)
            prepared = try await migration.prepare(
                settings: prepared, accountUID: accountUID, operations: operations
            )
            try await checkCurrent(run)
        }
        return prepared
    }

    private func reloadSettings(
        for snapshot: WebDAVSyncSettings,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> WebDAVSyncSettings {
        try await checkCurrent(run)
        let current = await settingsStore.load()
        try await checkCurrent(run)
        guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(snapshot),
              current.receiptScope == snapshot.receiptScope else {
            throw CancellationError()
        }
        return current
    }

    private func fetchRemotePayloads(
        settings: WebDAVSyncSettings,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> [String: WebDAVRemotePayload] {
        let coordinator = settingsStore.syncCoordinator
        return try await withThrowingTaskGroup(of: (String, WebDAVRemotePayload?).self) { group in
            for participant in enabledParticipants(settings) {
                group.addTask {
                    try await coordinator.checkCurrent(run)
                    let payload = try await self.fetchRemotePayloadIfPresent(for: participant, settings: settings)
                    try await coordinator.checkCurrent(run)
                    return (participant.datasetID, payload)
                }
            }
            var payloads: [String: WebDAVRemotePayload] = [:]
            for try await (datasetID, payload) in group {
                if let payload {
                    payloads[datasetID] = payload
                }
            }
            try await coordinator.checkCurrent(run)
            return payloads
        }
    }

    private nonisolated func fetchRemotePayloadIfPresent(
        for participant: any WebDAVSyncParticipant,
        settings: WebDAVSyncSettings
    ) async throws -> WebDAVRemotePayload? {
        let file: WebDAVRemoteFile
        let coordinator = settingsStore.syncCoordinator
        let name = participant.remoteFileName
        let cached = await coordinator.cachedRemoteFile(name, settings: settings)
        do {
            file = try await client.fetchPayload(settings: settings, fileName: name, cached: cached)
            let info = try participant.inspectRemote(file.data)
            try Task.checkCancellation()
            await coordinator.cacheRemoteFile(file, name: name, settings: settings)
            return WebDAVRemotePayload(data: file.data, info: info, etag: file.etag)
        } catch where error is URLError || LoadDiagnosticError.isCancellation(error) {
            throw error
        } catch {
            await coordinator.cacheRemoteFile(nil, name: name, settings: settings)
            if error as? WebDAVSyncError == .notFound { return nil }
            throw error
        }
    }

    private struct DatasetSyncOutcome: Sendable {
        /// Local fingerprint captured while the local store still matched the
        /// synced content, or nil when the participant has no fingerprint.
        var fingerprint: String?
        var appliedRemoteUpdatedAt: Date
        var uploadedRevision: UInt64?
        var appliedRemoteRevision: UInt64?
        var requiresUpload: Bool = false
    }

    private func uploadParticipants(
        _ included: [any WebDAVSyncParticipant],
        remotePayloads: [String: WebDAVRemotePayload],
        settings: WebDAVSyncSettings,
        accountUID: String,
        updatedAt: Date,
        run: WebDAVSyncCoordinator.RunToken,
        allowingAccountMismatch: Bool = false
    ) async throws -> [String: DatasetSyncOutcome] {
        guard !included.isEmpty else { return [:] }
        var outcomes: [String: DatasetSyncOutcome] = [:]
        let includedIDs = Set(included.map(\.datasetID))
        try await checkCurrent(run)
        try await settingsStore.update { current in
            if current.trimmedBaseURLString.isEmpty, current.contentSelectionRevision == settings.contentSelectionRevision { current = settings }
            guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings),
                  current.receiptScope == settings.receiptScope else { return }
            current.dirtyDatasetIDs.formUnion(includedIDs)
        }
        try await checkCurrent(run)
        try await client.ensureDirectoryExists(settings: settings, namespaces: included.flatMap(\.remoteDirectories))
        try await checkCurrent(run)
        let connection = WebDAVConnectionIdentity(settings)
        if !(await settingsStore.syncCoordinator.hasVerified(connection)) {
            try await checkCurrent(run)
            try await client.verifyConditionalWrites(settings: settings)
            try await checkCurrent(run)
            await settingsStore.syncCoordinator.markVerified(connection)
        }
        for participant in included {
            var remote = remotePayloads[participant.datasetID]
            for attempt in 0...3 {
                try await checkCurrent(run)
                try Task.checkCancellation()
                if !allowingAccountMismatch {
                    try validateAccount(remoteAccountUID: remote?.info.accountUID, localUID: accountUID)
                }
                let condition: WebDAVWriteCondition
                if let remote {
                    guard let etag = remote.etag, WebDAVClient.isStrongETag(etag) else {
                        throw WebDAVSyncError.unsafeConditionalWrite
                    }
                    condition = .matches(etag)
                } else {
                    condition = .absent
                }
                let stamp = max(updatedAt, uploadStamp(absorbing: remote?.info.updatedAt))
                let revision = try nextUploadRevision(datasetID: participant.datasetID,
                    settings: settings, absorbingRemoteRevision: remote?.info.revision)
                let snapshot = try await participant.mergeAndExportSnapshot(
                    remoteData: remote?.data, updatedAt: stamp, accountUID: accountUID)
                try await checkCurrent(run)
                let data = try WebDAVPayloadEnvelope.injectingSyncRevision(revision, into: snapshot.data)
                do {
                    try await checkCurrent(run)
                    try Task.checkCancellation()
                    await settingsStore.syncCoordinator.cacheRemoteFile(nil, name: participant.remoteFileName, settings: settings)
                    let uploaded = try await client.uploadPayloadData(data, settings: settings,
                        fileName: participant.remoteFileName, condition: condition)
                    try await checkCurrent(run)
                    await settingsStore.syncCoordinator.cacheRemoteFile(uploaded, name: participant.remoteFileName, settings: settings)
                } catch WebDAVSyncError.writeConflict {
                    guard attempt < 3 else { throw WebDAVSyncError.writeConflict }
                    try await checkCurrent(run)
                    remote = try await fetchRemotePayloadIfPresent(for: participant, settings: settings)
                    try await checkCurrent(run)
                    continue
                }
                let outcome = DatasetSyncOutcome(fingerprint: snapshot.fingerprint,
                    appliedRemoteUpdatedAt: stamp, uploadedRevision: revision, appliedRemoteRevision: revision)
                outcomes[participant.datasetID] = outcome
                try await updateSettingsAfterSync(settings, updatedAt: stamp,
                    outcomes: [participant.datasetID: outcome], run: run)
                break
            }
        }
        return outcomes
    }

    private func applyRemotePayloads(
        _ remotePayloads: [String: WebDAVRemotePayload],
        excludingDatasetIDs: Set<String> = [],
        skippingPayloadsAlreadyAbsorbedPer settings: WebDAVSyncSettings? = nil,
        run: WebDAVSyncCoordinator.RunToken
    ) async throws -> [String: DatasetSyncOutcome] {
        var outcomes: [String: DatasetSyncOutcome] = [:]
        for participant in participants {
            guard !excludingDatasetIDs.contains(participant.datasetID) else { continue }
            guard let payload = remotePayloads[participant.datasetID] else { continue }
            if let settings,
               remotePayloadIsAlreadyAbsorbed(payload.info, datasetID: participant.datasetID, settings: settings) {
                continue
            }
            try await checkCurrent(run)
            try Task.checkCancellation()
            let applied = try await participant.applyRemoteSnapshot(payload.data)
            try await checkCurrent(run)
            outcomes[participant.datasetID] = DatasetSyncOutcome(
                fingerprint: applied.fingerprint,
                appliedRemoteUpdatedAt: payload.info.updatedAt,
                appliedRemoteRevision: payload.info.revision,
                requiresUpload: applied.requiresUpload
            )
        }
        return outcomes
    }

    private nonisolated func remotePayloadIsAlreadyAbsorbed(
        _ info: WebDAVRemotePayloadInfo,
        datasetID: String,
        settings: WebDAVSyncSettings
    ) -> Bool {
        if let remoteRevision = info.revision,
           let lastAppliedRevision = settings.lastAppliedRemoteRevisionByDatasetID[datasetID] {
            return remoteRevision <= lastAppliedRevision
        }
        return info.updatedAt <= settings.lastAppliedRemoteUpdatedAtByDatasetID[datasetID] ?? .distantPast
    }

    private nonisolated func remotePayloadIsAheadOfLocalState(
        _ info: WebDAVRemotePayloadInfo,
        datasetID: String,
        settings: WebDAVSyncSettings
    ) -> Bool {
        if let remoteRevision = info.revision,
           let localRevision = highestKnownLocalRevision(datasetID: datasetID, settings: settings) {
            return remoteRevision > localRevision
        }
        return info.updatedAt > settings.localUpdatedAt ?? .distantPast
    }

    private nonisolated func highestKnownLocalRevision(
        datasetID: String,
        settings: WebDAVSyncSettings
    ) -> UInt64? {
        [
            settings.localRevisionByDatasetID[datasetID],
            settings.lastAppliedRemoteRevisionByDatasetID[datasetID],
        ]
        .compactMap(\.self)
        .max()
    }

    private nonisolated func nextUploadRevision(
        datasetID: String,
        settings: WebDAVSyncSettings,
        absorbingRemoteRevision: UInt64?
    ) throws -> UInt64 {
        let highestKnown = [
            highestKnownLocalRevision(datasetID: datasetID, settings: settings),
            absorbingRemoteRevision,
        ]
        .compactMap(\.self)
        .max() ?? 0
        guard highestKnown < .max else { throw WebDAVSyncError.uploadRevisionExhausted }
        return highestKnown + 1
    }

    private nonisolated func validateAccount(of remotePayloads: [String: WebDAVRemotePayload], localUID: String) throws {
        for payload in remotePayloads.values {
            try validateAccount(remoteAccountUID: payload.info.accountUID, localUID: localUID)
        }
    }

    private nonisolated func validateAccount(remoteAccountUID: String?, localUID: String) throws {
        guard let remoteAccountUID,
              !remoteAccountUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              remoteAccountUID != localUID else {
            return
        }
        throw WebDAVSyncError.accountMismatch(localUID: localUID, remoteUID: remoteAccountUID)
    }

    private func updateSettingsAfterSync(
        _ settings: WebDAVSyncSettings,
        updatedAt: Date,
        outcomes: [String: DatasetSyncOutcome],
        run: WebDAVSyncCoordinator.RunToken
    ) async throws {
        try await checkCurrent(run)
        var currentFingerprints: [String: String] = [:]
        for participant in participants where outcomes[participant.datasetID] != nil {
            currentFingerprints[participant.datasetID] = try await participant.readLocalFingerprint()
            try await checkCurrent(run)
        }
        let fingerprints = currentFingerprints
        try Task.checkCancellation()
        try await checkCurrent(run)
        try await settingsStore.update { updated in
            if updated.trimmedBaseURLString.isEmpty, updated.contentSelectionRevision == settings.contentSelectionRevision { updated = settings }
            guard WebDAVConnectionIdentity(updated) == WebDAVConnectionIdentity(settings),
                  updated.receiptScope == settings.receiptScope else { return }
            updated.lastSyncedAt = .now
            updated.lastRemoteUpdatedAt = max(updated.lastRemoteUpdatedAt ?? updatedAt, updatedAt)
            for (datasetID, outcome) in outcomes {
                guard updated.contentSelectionRevision == settings.contentSelectionRevision else { continue }
                if outcome.requiresUpload || fingerprints[datasetID] != outcome.fingerprint {
                    updated.dirtyDatasetIDs.insert(datasetID)
                } else {
                    updated.dirtyDatasetIDs.remove(datasetID)
                }
                if let fingerprint = outcome.fingerprint {
                    updated.lastSyncedFingerprintByDatasetID[datasetID] = fingerprint
                }
                updated.lastAppliedRemoteUpdatedAtByDatasetID[datasetID] = outcome.appliedRemoteUpdatedAt
                if let uploadedRevision = outcome.uploadedRevision {
                    updated.localRevisionByDatasetID[datasetID] = max(updated.localRevisionByDatasetID[datasetID] ?? 0, uploadedRevision)
                }
                if let appliedRemoteRevision = outcome.appliedRemoteRevision {
                    updated.lastAppliedRemoteRevisionByDatasetID[datasetID] = max(
                        updated.lastAppliedRemoteRevisionByDatasetID[datasetID] ?? 0, appliedRemoteRevision)
                }
            }
            updated.localUpdatedAt = updated.dirtyDatasetIDs.subtracting(updated.disabledContentIDs).isEmpty
                ? updatedAt : max(updated.localUpdatedAt ?? updatedAt, updatedAt)
        }
        try await checkCurrent(run)
    }

    private func checkCurrent(_ run: WebDAVSyncCoordinator.RunToken) async throws {
        try await settingsStore.syncCoordinator.checkCurrent(run)
    }
}
