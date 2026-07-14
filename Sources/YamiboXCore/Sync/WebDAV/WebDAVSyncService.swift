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
        let settings = await settingsStore.load()
        return try await upload(using: settings)
    }

    @discardableResult
    public func upload(using settings: WebDAVSyncSettings, allowingAccountMismatch: Bool = false) async throws -> Date {
        let accountUID = try await currentAccountUID()
        let remotePayloads = try await fetchRemotePayloads(settings: settings)
        if !allowingAccountMismatch {
            try validateAccount(of: remotePayloads, localUID: accountUID)
        }
        let updatedAt = Date.now
        let uploaded = try await uploadParticipants(
            participants,
            remotePayloads: remotePayloads,
            settings: settings,
            accountUID: accountUID,
            updatedAt: updatedAt
        )
        try await updateSettingsAfterSync(settings, updatedAt: updatedAt, outcomes: uploaded)
        return updatedAt
    }

    @discardableResult
    public func download() async throws -> Date {
        let settings = await settingsStore.load()
        return try await download(using: settings)
    }

    @discardableResult
    public func download(using settings: WebDAVSyncSettings, allowingAccountMismatch _: Bool = false) async throws -> Date {
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
        let settings = await settingsStore.load()
        let sessionState = await sessionStore.load()
        guard policyModule.canSynchronizeAutomatically(settings: settings, session: sessionState) else { return .skipped }
        if !bypassingMinimumInterval,
           let lastSyncedAt = settings.lastSyncedAt,
           Date.now.timeIntervalSince(lastSyncedAt) < Self.minimumAutomaticSyncInterval {
            return .skipped
        }
        guard let accountUID = try? currentAccountUID(from: sessionState) else { return .skipped }

        let remotePayloads = try await fetchRemotePayloads(settings: settings)
        try validateAccount(of: remotePayloads, localUID: accountUID)
        let newestRemoteUpdatedAt = remotePayloads.values.map(\.info.updatedAt).max()
        let localUpdatedAt = settings.localUpdatedAt ?? .distantPast

        if let newestRemoteUpdatedAt, newestRemoteUpdatedAt > localUpdatedAt {
            let applied = try await applyRemotePayloads(remotePayloads)
            try await updateSettingsAfterSync(settings, updatedAt: newestRemoteUpdatedAt, outcomes: applied)
            return .downloaded
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
            newerThan: settings.lastAppliedRemoteUpdatedAtByDatasetID
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

        let updatedAt = Date.now
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
        var settings = await settingsStore.load()
        guard settings.isAutoSyncEnabled else { return }
        for participant in participants where participant.uploadsOnlyWhenMarkedDirty {
            guard let fingerprint = await participant.localFingerprint() else { continue }
            if settings.lastSyncedFingerprintByDatasetID[participant.datasetID] != fingerprint {
                settings.dirtyDatasetIDs.insert(participant.datasetID)
                settings.lastSyncedFingerprintByDatasetID[participant.datasetID] = fingerprint
            }
        }
        // `localUpdatedAt` only advances while some dataset is actually dirty:
        // an unconditional bump (e.g. from the background flush) would keep
        // shadowing newer remote uploads from other devices even though this
        // device has nothing to say, starving the download direction forever.
        if !settings.dirtyDatasetIDs.isEmpty {
            settings.localUpdatedAt = date
        }
        try await settingsStore.save(settings)
    }

    private func currentAccountUID() async throws -> String {
        try currentAccountUID(from: await sessionStore.load())
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
    }

    private func fetchRemotePayloads(settings: WebDAVSyncSettings) async throws -> [String: RemotePayload] {
        var payloads: [String: RemotePayload] = [:]
        for participant in participants {
            if let payload = try await fetchRemotePayloadIfPresent(for: participant, settings: settings) {
                payloads[participant.datasetID] = payload
            }
        }
        return payloads
    }

    private func fetchRemotePayloadIfPresent(
        for participant: any WebDAVSyncParticipant,
        settings: WebDAVSyncSettings
    ) async throws -> RemotePayload? {
        let data: Data
        do {
            data = try await client.fetchPayloadData(settings: settings, fileName: participant.remoteFileName)
        } catch WebDAVSyncError.notFound {
            return nil
        }
        do {
            return RemotePayload(data: data, info: try participant.inspectRemote(data))
        } catch let error as WebDAVSyncError {
            if case .underlying = error {
                YamiboLog.sync.warning("WebDAV inspectRemote failed for dataset \(participant.datasetID): \(error)")
                return nil
            }
            throw error
        } catch {
            YamiboLog.sync.warning("WebDAV inspectRemote failed for dataset \(participant.datasetID): \(error)")
            return nil
        }
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
    }

    private func uploadParticipants(
        _ included: [any WebDAVSyncParticipant],
        remotePayloads: [String: RemotePayload],
        settings: WebDAVSyncSettings,
        accountUID: String,
        updatedAt: Date
    ) async throws -> [String: DatasetSyncOutcome] {
        guard !included.isEmpty else { return [:] }
        var outcomes: [String: DatasetSyncOutcome] = [:]
        try await client.ensureDirectoryExists(settings: settings)
        for participant in included {
            let payloadData = try await participant.mergeAndExport(
                remoteData: remotePayloads[participant.datasetID]?.data,
                updatedAt: updatedAt,
                accountUID: accountUID
            )
            // Fingerprint captured at export time, while the local store still
            // equals the exported content: recomputing after the PUT would
            // absorb local changes made while the upload was in flight, so
            // they would never be flagged dirty and never uploaded.
            let fingerprint = await participant.localFingerprint()
            try await client.uploadPayloadData(payloadData, settings: settings, fileName: participant.remoteFileName)
            outcomes[participant.datasetID] = DatasetSyncOutcome(
                fingerprint: fingerprint,
                appliedRemoteUpdatedAt: updatedAt
            )
        }
        return outcomes
    }

    private func applyRemotePayloads(
        _ remotePayloads: [String: RemotePayload],
        excludingDatasetIDs: Set<String> = [],
        newerThan lastAppliedByDatasetID: [String: Date]? = nil
    ) async throws -> [String: DatasetSyncOutcome] {
        var outcomes: [String: DatasetSyncOutcome] = [:]
        for participant in participants {
            guard !excludingDatasetIDs.contains(participant.datasetID) else { continue }
            guard let payload = remotePayloads[participant.datasetID] else { continue }
            if let lastAppliedByDatasetID,
               payload.info.updatedAt <= lastAppliedByDatasetID[participant.datasetID] ?? .distantPast {
                continue
            }
            try await participant.applyRemote(payload.data)
            outcomes[participant.datasetID] = DatasetSyncOutcome(
                fingerprint: await participant.localFingerprint(),
                appliedRemoteUpdatedAt: payload.info.updatedAt
            )
        }
        return outcomes
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
        var updated = settings
        updated.lastSyncedAt = .now
        updated.lastRemoteUpdatedAt = updatedAt
        updated.localUpdatedAt = updatedAt
        for (datasetID, outcome) in outcomes {
            updated.dirtyDatasetIDs.remove(datasetID)
            if let fingerprint = outcome.fingerprint {
                updated.lastSyncedFingerprintByDatasetID[datasetID] = fingerprint
            }
            updated.lastAppliedRemoteUpdatedAtByDatasetID[datasetID] = outcome.appliedRemoteUpdatedAt
        }
        try await settingsStore.save(updated)
    }
}
