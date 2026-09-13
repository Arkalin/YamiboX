import Foundation

public actor WebDAVSyncService {
    /// Floor between unattended automatic sync rounds triggered by ongoing
    /// local edits (e.g. reading progress ticking every page turn). Chosen to
    /// cut chatter during an active reading session by roughly two orders of
    /// magnitude versus the previous ~2.4s cadence, while foreground/background
    /// transitions (see `bypassingMinimumInterval`) still sync promptly.
    private static let minimumAutomaticSyncInterval: TimeInterval = 5 * 60

    private let settingsStore: WebDAVSyncSettingsStore
    private let sessionStore: SessionStore
    private let participants: [any WebDAVSyncParticipant]
    private let client: WebDAVClient
    private let policyModule: WebDAVSyncPolicyModule

    init(
        settingsStore: WebDAVSyncSettingsStore,
        sessionStore: SessionStore,
        participants: [any WebDAVSyncParticipant],
        client: WebDAVClient = WebDAVClient(),
        policyModule: WebDAVSyncPolicyModule = WebDAVSyncPolicyModule()
    ) {
        self.settingsStore = settingsStore
        self.sessionStore = sessionStore
        self.participants = participants
        self.client = client
        self.policyModule = policyModule
    }

    @discardableResult
    public func upload() async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] in
            try await performUpload(using: settingsStore.load())
        }
    }

    @discardableResult
    public func upload(using settings: WebDAVSyncSettings, allowingAccountMismatch: Bool = false) async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] in
            try await performUpload(using: settings, allowingAccountMismatch: allowingAccountMismatch)
        }
    }

    private func performUpload(using settings: WebDAVSyncSettings, allowingAccountMismatch: Bool = false) async throws -> Date {
        guard settings.hasEnabledContent else { throw WebDAVSyncError.noContentSelected }
        let accountUID = try await currentAccountUID()
        let remotePayloads = try await fetchRemotePayloads(settings: settings)
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
            allowingAccountMismatch: allowingAccountMismatch
        )
        try await updateSettingsAfterSync(settings, updatedAt: updatedAt, outcomes: uploaded)
        return updatedAt
    }

    @discardableResult
    public func download() async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] in
            try await performDownload(using: settingsStore.load())
        }
    }

    @discardableResult
    public func download(using settings: WebDAVSyncSettings, allowingAccountMismatch _: Bool = false) async throws -> Date {
        try await settingsStore.syncCoordinator.run { [self] in
            try await performDownload(using: settings)
        }
    }

    private func performDownload(using settings: WebDAVSyncSettings) async throws -> Date {
        guard settings.hasEnabledContent else { throw WebDAVSyncError.noContentSelected }
        let accountUID = try await currentAccountUID()
        let remotePayloads = try await fetchRemotePayloads(settings: settings)
        try validateAccount(of: remotePayloads, localUID: accountUID)
        let applied = try await applyRemotePayloads(remotePayloads)
        guard let updatedAt = applied.values.map(\.appliedRemoteUpdatedAt).max() else {
            throw WebDAVSyncError.notFound
        }
        try await updateSettingsAfterSync(settings, updatedAt: updatedAt, outcomes: applied)
        return updatedAt
    }

    /// - Parameter bypassingMinimumInterval: Foreground activation and the
    ///   background flush are natural, infrequent checkpoints and always pass
    ///   `true` here. The debounced local-change path (many rounds during an
    ///   active reading session) leaves this `false` so most of those rounds
    ///   are skipped, only touching `localUpdatedAt`/dirty state, not the network.
    @discardableResult
    public func synchronizeAutomatically(bypassingMinimumInterval: Bool = false) async throws -> WebDAVAutomaticSyncResult {
        try await settingsStore.syncCoordinator.run { [self] in
            try await performAutomaticSync(bypassingMinimumInterval: bypassingMinimumInterval)
        }
    }

    private func performAutomaticSync(bypassingMinimumInterval: Bool) async throws -> WebDAVAutomaticSyncResult {
        var settings = await settingsStore.load()
        let disabledContentIDs = settings.disabledContentIDs
        let selectionRevision = settings.contentSelectionRevision
        let participants = enabledParticipants(settings)
        guard !participants.isEmpty else { return .skipped }
        let snapshot = try await sessionStore.snapshot()
        guard await sessionStore.isCurrentGeneration(snapshot.generation) else { return .skipped }
        let sessionState = snapshot.session
        guard policyModule.canSynchronizeAutomatically(settings: settings, session: sessionState) else { return .skipped }
        try await refreshDirtyState(at: .now, includeUntracked: false, using: settings)
        settings = await settingsStore.load()
        settings.disabledContentIDs = disabledContentIDs
        settings.contentSelectionRevision = selectionRevision
        if !bypassingMinimumInterval,
           let lastSyncedAt = settings.lastSyncedAt,
           Date.now.timeIntervalSince(lastSyncedAt) < Self.minimumAutomaticSyncInterval {
            return .skipped
        }
        guard let accountUID = try? currentAccountUID(from: sessionState) else { return .skipped }

        let remotePayloads = try await fetchRemotePayloads(settings: settings)
        try validateAccount(of: remotePayloads, localUID: accountUID)
        try await refreshDirtyState(at: .now, includeUntracked: false, using: settings)
        settings = await settingsStore.load()
        settings.disabledContentIDs = disabledContentIDs
        settings.contentSelectionRevision = selectionRevision
        let newestRemoteUpdatedAt = remotePayloads.values.map(\.info.updatedAt).max()
        // Per-dataset direction decision: a dataset whose remote payload and
        // local bookkeeping both carry revisions compares by revision (immune
        // to wall-clock skew between devices); any dataset missing a revision
        // on either side falls back to the wall-clock comparison, which for a
        // round with only pre-revision payloads reduces to the previous
        // `newestRemoteUpdatedAt > localUpdatedAt` rule exactly.
        let remoteIsAhead = remotePayloads.contains { datasetID, payload in
            remotePayloadIsAheadOfLocalState(payload.info, datasetID: datasetID, settings: settings)
        }

        if let newestRemoteUpdatedAt, remoteIsAhead {
            // Dirty datasets merge and upload immediately. Clean datasets
            // merge without uploading; any retained local-only changes are
            // marked pending by the transaction receipt for the next round.
            let dirtyParticipants = participants.filter {
                $0.uploadsOnlyWhenMarkedDirty && settings.dirtyDatasetIDs.contains($0.datasetID)
            }
            let applied = try await applyRemotePayloads(
                remotePayloads,
                excludingDatasetIDs: Set(dirtyParticipants.map(\.datasetID)),
                skippingPayloadsAlreadyAbsorbedPer: settings
            )
            guard !dirtyParticipants.isEmpty else {
                try await updateSettingsAfterSync(settings, updatedAt: newestRemoteUpdatedAt, outcomes: applied)
                return .downloaded
            }
            let updatedAt = uploadStamp(absorbing: newestRemoteUpdatedAt)
            let uploaded = try await uploadParticipants(
                dirtyParticipants,
                remotePayloads: remotePayloads,
                settings: settings,
                accountUID: accountUID,
                updatedAt: updatedAt
            )
            try await updateSettingsAfterSync(
                settings,
                updatedAt: updatedAt,
                outcomes: uploaded.merging(applied) { uploadedOutcome, _ in uploadedOutcome }
            )
            return .uploaded
        }

        let included = participants.filter {
            !$0.uploadsOnlyWhenMarkedDirty || settings.dirtyDatasetIDs.contains($0.datasetID)
        }
        // Non-dirty datasets still converge in the upload direction: another
        // device may have uploaded them while this device's `localUpdatedAt`
        // was ahead, so any fetched payload newer than what this device last
        // absorbed is applied rather than discarded.
        let applied = try await applyRemotePayloads(
            remotePayloads,
            excludingDatasetIDs: Set(included.map(\.datasetID)),
            skippingPayloadsAlreadyAbsorbedPer: settings
        )

        if included.isEmpty {
            guard let newestRemoteUpdatedAt, !applied.isEmpty else {
                // Nothing uploaded and nothing applied: leave every sync
                // timestamp untouched so a no-op round cannot shadow a remote
                // update that lands later.
                return .skipped
            }
            // Every remote payload is now at or below this device's absorbed
            // state, so the newest remote stamp is the truthful local stamp.
            try await updateSettingsAfterSync(settings, updatedAt: newestRemoteUpdatedAt, outcomes: applied)
            return .downloaded
        }

        let updatedAt = uploadStamp(absorbing: newestRemoteUpdatedAt)
        let uploaded = try await uploadParticipants(
            included,
            remotePayloads: remotePayloads,
            settings: settings,
            accountUID: accountUID,
            updatedAt: updatedAt
        )
        try await updateSettingsAfterSync(
            settings,
            updatedAt: updatedAt,
            outcomes: uploaded.merging(applied) { uploadedOutcome, _ in uploadedOutcome }
        )
        return .uploaded
    }

    /// Records that locally synchronized data changed and re-fingerprints
    /// every fingerprint-tracked participant, marking it dirty if its
    /// synchronized subset actually changed. Runs unconditionally regardless
    /// of which dataset's notification triggered the call: callers don't say
    /// which participant changed, and fingerprinting is cheap, so checking
    /// all of them is simpler and cannot under-mark a dataset dirty (unlike an
    /// earlier version gated on a per-caller flag, which left non-flagged
    /// participants' dirty state uncomputed forever).
    public func markLocalDataChanged(at date: Date = .now) async throws {
        try await settingsStore.syncCoordinator.run { [self] in
            try await refreshDirtyState(at: date, includeUntracked: true)
        }
    }

    private func enabledParticipants(_ settings: WebDAVSyncSettings) -> [any WebDAVSyncParticipant] {
        participants.filter { !settings.disabledContentIDs.contains($0.datasetID) }
    }

    private func refreshDirtyState(at date: Date, includeUntracked: Bool, using snapshot: WebDAVSyncSettings? = nil) async throws {
        let settings: WebDAVSyncSettings
        if let snapshot { settings = snapshot } else { settings = await settingsStore.load() }
        guard settings.isAutoSyncEnabled, !enabledParticipants(settings).isEmpty else { return }
        var changed = Set<String>()
        for participant in enabledParticipants(settings) where participant.uploadsOnlyWhenMarkedDirty {
            guard includeUntracked || settings.lastSyncedFingerprintByDatasetID[participant.datasetID] != nil
                || participant.uploadsUntrackedContentAutomatically else { continue }
            guard let fingerprint = try await participant.readLocalFingerprint() else { continue }
            if settings.lastSyncedFingerprintByDatasetID[participant.datasetID] != fingerprint {
                changed.insert(participant.datasetID)
            }
        }
        let changedIDs = changed
        try Task.checkCancellation()
        try await settingsStore.update { current in
            guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings) else { return }
            current.dirtyDatasetIDs.formUnion(changedIDs)
            if !current.dirtyDatasetIDs.subtracting(current.disabledContentIDs).isEmpty { current.localUpdatedAt = date }
        }
    }

    /// Stamp for an upload produced by a round that also absorbed remote
    /// payloads up to `newestRemoteUpdatedAt`. Wall clocks differ across
    /// devices, so `.now` alone could sort the merged upload *before* the
    /// remote payload it just absorbed; peers that already recorded that
    /// remote stamp as applied would then skip the merged result and
    /// convergence would stall until an unrelated later change. Nudging just
    /// past the absorbed stamp keeps the ordering truthful. Revisions are the
    /// primary ordering now; this stays as defense in depth for the wall-clock
    /// fallback paths (pre-revision peers and payloads).
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
        guard sessionState.isLoggedIn, !sessionState.cookie.isEmpty else {
            throw YamiboError.notAuthenticated
        }
        let accountUID = sessionState.accountUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accountUID.isEmpty else {
            throw YamiboError.accountUIDUnavailable
        }
        return accountUID
    }

    private struct RemotePayload: Sendable {
        var data: Data
        var info: WebDAVRemotePayloadInfo
        var etag: String?
    }

    /// Per-dataset GETs run concurrently: every sync round starts with this
    /// fetch, and the startup round sits on the app-launch critical path (the
    /// bootstrap placeholder stays up until it finishes), so the round's fetch
    /// latency must be the slowest single request, not the sum over all
    /// datasets — on a high-latency WebDAV server the difference is tens of
    /// seconds. Any fetch failing fails the round exactly as the previous
    /// serial loop did; the group cancels the requests still in flight.
    private func fetchRemotePayloads(settings: WebDAVSyncSettings) async throws -> [String: RemotePayload] {
        try await withThrowingTaskGroup(of: (String, RemotePayload?).self) { group in
            for participant in enabledParticipants(settings) {
                group.addTask {
                    (participant.datasetID, try await self.fetchRemotePayloadIfPresent(for: participant, settings: settings))
                }
            }
            var payloads: [String: RemotePayload] = [:]
            for try await (datasetID, payload) in group {
                if let payload {
                    payloads[datasetID] = payload
                }
            }
            return payloads
        }
    }

    private nonisolated func fetchRemotePayloadIfPresent(
        for participant: any WebDAVSyncParticipant,
        settings: WebDAVSyncSettings
    ) async throws -> RemotePayload? {
        let file: WebDAVRemoteFile
        do {
            file = try await client.fetchPayload(settings: settings, fileName: participant.remoteFileName)
        } catch WebDAVSyncError.notFound {
            return nil
        }
        return RemotePayload(data: file.data, info: try participant.inspectRemote(file.data), etag: file.etag)
    }

    /// Per-dataset result of one sync round, consumed by
    /// `updateSettingsAfterSync` to update dirty/fingerprint/applied
    /// bookkeeping only for datasets that actually synced.
    private struct DatasetSyncOutcome: Sendable {
        /// Local fingerprint captured while the local store still matched the
        /// synced content, or nil when the participant has no fingerprint.
        var fingerprint: String?
        /// The remote `updatedAt` this device is now caught up to for the
        /// dataset: the payload's stamp when applied, the round's stamp when
        /// uploaded (after an upload, local content == remote content).
        var appliedRemoteUpdatedAt: Date
        /// The revision this round minted for its own upload of the dataset,
        /// nil when the dataset was applied rather than uploaded.
        var uploadedRevision: UInt64?
        /// The remote revision this device is now caught up to for the
        /// dataset: the payload's revision when applied (nil for pre-revision
        /// payloads), the freshly minted revision when uploaded — mirroring
        /// `appliedRemoteUpdatedAt`, and for the same reason: without it the
        /// next round would treat the device's own upload as unseen remote
        /// news and re-apply it.
        var appliedRemoteRevision: UInt64?
        var requiresUpload: Bool = false
    }

    private func uploadParticipants(
        _ included: [any WebDAVSyncParticipant],
        remotePayloads: [String: RemotePayload],
        settings: WebDAVSyncSettings,
        accountUID: String,
        updatedAt: Date,
        allowingAccountMismatch: Bool = false
    ) async throws -> [String: DatasetSyncOutcome] {
        guard !included.isEmpty else { return [:] }
        var outcomes: [String: DatasetSyncOutcome] = [:]
        let includedIDs = Set(included.map(\.datasetID))
        try await settingsStore.update { current in
            if current.trimmedBaseURLString.isEmpty, current.contentSelectionRevision == settings.contentSelectionRevision { current = settings }
            guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings) else { return }
            current.dirtyDatasetIDs.formUnion(includedIDs)
        }
        try await client.ensureDirectoryExists(settings: settings)
        let connection = WebDAVConnectionIdentity(settings)
        if !(await settingsStore.syncCoordinator.hasVerified(connection)) {
            try await client.verifyConditionalWrites(settings: settings)
            await settingsStore.syncCoordinator.markVerified(connection)
        }
        for participant in included {
            var remote = remotePayloads[participant.datasetID]
            for attempt in 0...3 {
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
                let snapshot = try await participant.mergeAndExportSnapshot(
                    remoteData: remote?.data, updatedAt: stamp, accountUID: accountUID)
                let revision = nextUploadRevision(datasetID: participant.datasetID,
                    settings: settings, absorbingRemoteRevision: remote?.info.revision)
                let data = WebDAVPayloadEnvelope.injectingSyncRevision(revision, into: snapshot.data)
                do {
                    try Task.checkCancellation()
                    try await client.uploadPayloadData(data, settings: settings,
                        fileName: participant.remoteFileName, condition: condition)
                } catch WebDAVSyncError.writeConflict {
                    guard attempt < 3 else { throw WebDAVSyncError.writeConflict }
                    remote = try await fetchRemotePayloadIfPresent(for: participant, settings: settings)
                    continue
                }
                let outcome = DatasetSyncOutcome(fingerprint: snapshot.fingerprint,
                    appliedRemoteUpdatedAt: stamp, uploadedRevision: revision, appliedRemoteRevision: revision)
                outcomes[participant.datasetID] = outcome
                try await updateSettingsAfterSync(settings, updatedAt: stamp, outcomes: [participant.datasetID: outcome])
                break
            }
        }
        return outcomes
    }

    /// - Parameter settings: When non-nil, payloads this device has already
    ///   absorbed per the settings' bookkeeping are skipped (revision
    ///   comparison when both sides carry one, wall-clock fallback otherwise).
    ///   The manual download path passes nil and applies unconditionally.
    private func applyRemotePayloads(
        _ remotePayloads: [String: RemotePayload],
        excludingDatasetIDs: Set<String> = [],
        skippingPayloadsAlreadyAbsorbedPer settings: WebDAVSyncSettings? = nil
    ) async throws -> [String: DatasetSyncOutcome] {
        var outcomes: [String: DatasetSyncOutcome] = [:]
        for participant in participants {
            guard !excludingDatasetIDs.contains(participant.datasetID) else { continue }
            guard let payload = remotePayloads[participant.datasetID] else { continue }
            if let settings,
               remotePayloadIsAlreadyAbsorbed(payload.info, datasetID: participant.datasetID, settings: settings) {
                continue
            }
            try Task.checkCancellation()
            let applied = try await participant.applyRemoteSnapshot(payload.data)
            outcomes[participant.datasetID] = DatasetSyncOutcome(
                fingerprint: applied.fingerprint,
                appliedRemoteUpdatedAt: payload.info.updatedAt,
                appliedRemoteRevision: payload.info.revision,
                requiresUpload: applied.requiresUpload
            )
        }
        return outcomes
    }

    /// Whether the content of a fetched payload is already reflected in this
    /// device's local state, per the settings' per-dataset bookkeeping. The
    /// revision pair decides when both sides carry one; either side missing a
    /// revision falls back to the previous wall-clock rule
    /// (`updatedAt <= lastApplied`).
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

    /// Whether a fetched payload carries content this device has not caught up
    /// to, i.e. the download direction is warranted for the dataset. Revision
    /// comparison when both sides carry one; either side missing a revision
    /// falls back to the previous wall-clock rule
    /// (`updatedAt > localUpdatedAt`).
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

    /// Highest revision this device has authored (`localRevisionByDatasetID`)
    /// or absorbed (`lastAppliedRemoteRevisionByDatasetID`) for the dataset,
    /// nil when the dataset has no revision bookkeeping yet (pre-revision
    /// install or never-synced dataset).
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

    /// Revision to stamp onto this round's upload of a dataset: strictly above
    /// every revision this device has authored, previously absorbed, or is
    /// absorbing from the remote payload merged into this very export.
    /// Clamped rather than trapping on a (corrupt) `UInt64.max` input.
    private nonisolated func nextUploadRevision(
        datasetID: String,
        settings: WebDAVSyncSettings,
        absorbingRemoteRevision: UInt64?
    ) -> UInt64 {
        let highestKnown = [
            highestKnownLocalRevision(datasetID: datasetID, settings: settings),
            absorbingRemoteRevision,
        ]
        .compactMap(\.self)
        .max() ?? 0
        return min(highestKnown, .max - 1) + 1
    }

    private func validateAccount(of remotePayloads: [String: RemotePayload], localUID: String) throws {
        for payload in remotePayloads.values {
            try validateAccount(remoteAccountUID: payload.info.accountUID, localUID: localUID)
        }
    }

    private func validateAccount(remoteAccountUID: String?, localUID: String) throws {
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
        outcomes: [String: DatasetSyncOutcome]
    ) async throws {
        var currentFingerprints: [String: String] = [:]
        for participant in participants where outcomes[participant.datasetID] != nil {
            currentFingerprints[participant.datasetID] = try await participant.readLocalFingerprint()
        }
        let fingerprints = currentFingerprints
        try Task.checkCancellation()
        try await settingsStore.update { updated in
            if updated.trimmedBaseURLString.isEmpty, updated.contentSelectionRevision == settings.contentSelectionRevision { updated = settings }
            guard WebDAVConnectionIdentity(updated) == WebDAVConnectionIdentity(settings) else { return }
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
                // Revision-less payloads must not erase the monotonic floor.
                if let appliedRemoteRevision = outcome.appliedRemoteRevision {
                    updated.lastAppliedRemoteRevisionByDatasetID[datasetID] = max(
                        updated.lastAppliedRemoteRevisionByDatasetID[datasetID] ?? 0, appliedRemoteRevision)
                }
            }
            updated.localUpdatedAt = updated.dirtyDatasetIDs.subtracting(updated.disabledContentIDs).isEmpty
                ? updatedAt : max(updated.localUpdatedAt ?? updatedAt, updatedAt)
        }
    }
}
