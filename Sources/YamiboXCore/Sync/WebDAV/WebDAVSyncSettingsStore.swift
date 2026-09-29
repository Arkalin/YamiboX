import Foundation

public actor WebDAVSyncSettingsStore {
    nonisolated let syncCoordinator = WebDAVSyncCoordinator()
    public static let defaultKey = "yamibox.webdav.sync.settings"

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    /// Multicast change feed; each element is the `changeID` of the store
    /// instance that made the change (see `StoreChangeBroadcaster`).
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private static let legacyCredentialReference = "legacy-password"
    private let storage: UserDefaultsJSONStorage<WebDAVSyncSettings>
    private let credentialPersistence: any WebDAVSyncCredentialPersisting
    /// A read failure must not turn an empty password in the settings screen
    /// into an instruction to delete the only copy of the secret.
    private var unreadableCredentialReferences: Set<String> = []

    public init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.init(
            defaults: defaults,
            key: key,
            credentialPersistence: KeychainWebDAVCredentialPersistence()
        )
    }

    init(
        defaults: UserDefaults,
        key: String,
        credentialPersistence: any WebDAVSyncCredentialPersisting
    ) {
        self.storage = UserDefaultsJSONStorage(defaults: defaults, key: key) { error in
            YamiboLog.sync.error("Failed to decode stored WebDAV sync settings, resetting to defaults: \(error)")
        }
        self.credentialPersistence = credentialPersistence
    }

    public func load() async -> WebDAVSyncSettings {
        loadHydratedSettings()
    }

    /// Publishes a complete settings value behind the same barrier used for a
    /// destination edit. This is intentionally not used by ordinary receipt
    /// updates: a sync round must be able to make its small bookkeeping writes
    /// without cancelling itself.
    public func save(_ settings: WebDAVSyncSettings) async throws {
        _ = try await withConnectionBoundary {
            let current = loadHydratedSettings()
            return try persist(settings: settings, replacing: current)
        }
    }

    /// Direct reset acquires the same barrier as a connection edit.
    public func reset() async throws {
        try await withConnectionBoundary {
            try resetWithinAccountTransition()
        }
    }

    /// Only the application reset workflow calls this while it already owns
    /// the account-transition barrier. Never infer ownership from a busy flag.
    func resetWithinAccountTransition() throws {
        let current = loadHydratedSettings()
        _ = try persist(settings: WebDAVSyncSettings(), replacing: current, removingCredential: true)
    }

    /// A URL, username, or password edit is a synchronization boundary. The
    /// coordinator cancels and joins old/queued runs before this method writes
    /// the new non-secret settings, so no later run can retain the old target
    /// merely because it was queued first.
    public func saveConnection(
        baseURLString: String,
        username: String,
        password: String,
        isAutoSyncEnabled: Bool
    ) async throws -> WebDAVSyncSettings {
        try await withConnectionBoundary {
            let current = loadHydratedSettings()
            var next = current
            next.baseURLString = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            next.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            next.password = password
            next.isAutoSyncEnabled = isAutoSyncEnabled
            return try persist(settings: next, replacing: current)
        }
    }

    /// Establishes the scope for receipt dictionaries before a run fetches or
    /// admits any remote payload. Account transitions reuse the same settings
    /// record, so the account UID is part of the scope in addition to the
    /// destination identity.
    func prepareReceiptScope(
        for settings: WebDAVSyncSettings,
        accountUID: String
    ) throws -> WebDAVSyncSettings {
        var current = loadHydratedSettings()
        guard WebDAVConnectionIdentity(current) == WebDAVConnectionIdentity(settings) else {
            throw CancellationError()
        }
        guard !hasUnmigratedPlaintextCredential(current) else {
            throw YamiboPersistenceError(context: "WebDAV credential migration is unavailable")
        }
        if let reference = current.credentialReference,
           unreadableCredentialReferences.contains(reference) {
            throw YamiboPersistenceError(context: "WebDAV credential is temporarily unavailable")
        }

        let scope = WebDAVReceiptScope(settings: current, accountUID: accountUID)
        guard current.receiptScope != scope else { return current }
        current.clearRemoteReceiptState()
        current.receiptScope = scope
        try storage.save(current)
        postChangeNotification()
        return current
    }

    @discardableResult
    public func setContent(_ content: WebDAVSyncContent, enabled: Bool) throws -> WebDAVSyncSettings {
        try update { settings in
            guard settings.isEnabled(content) != enabled else { return }
            let id = content.rawValue
            settings.contentSelectionRevision &+= 1
            if enabled {
                settings.disabledContentIDs.remove(id)
                settings.dirtyDatasetIDs.insert(id)
                settings.lastSyncedFingerprintByDatasetID[id] = nil
                settings.lastAppliedRemoteUpdatedAtByDatasetID[id] = nil
                settings.lastAppliedRemoteRevisionByDatasetID[id] = nil
            } else {
                settings.disabledContentIDs.insert(id)
            }
        }
    }

    @discardableResult
    func update(_ transform: @Sendable (inout WebDAVSyncSettings) -> Void) throws -> WebDAVSyncSettings {
        var settings = loadHydratedSettings()
        guard !hasUnmigratedPlaintextCredential(settings) else {
            // `encode(to:)` omits the legacy password. Refuse a bookkeeping
            // write until the secure migration succeeds rather than silently
            // deleting the only recoverable copy.
            throw YamiboPersistenceError(context: "WebDAV credential migration is unavailable")
        }
        transform(&settings)
        try storage.save(settings)
        postChangeNotification()
        return settings
    }

    /// Executes a synchronous persistence mutation while the coordinator
    /// barrier is held. Keeping the body synchronous is important: the store
    /// actor must not call back into the coordinator while the coordinator is
    /// awaiting the store, which would deadlock an account transition.
    private func withConnectionBoundary<T: Sendable>(
        _ body: () throws -> T
    ) async throws -> T {
        let token = try await syncCoordinator.beginConnectionChange()
        do {
            try Task.checkCancellation()
            let result = try body()
            await syncCoordinator.endConnectionChange(token)
            return result
        } catch {
            await syncCoordinator.endConnectionChange(token)
            throw error
        }
    }

    /// Reads the non-secret document and hydrates its Keychain reference. An
    /// old password field is migrated only after the secure write succeeds;
    /// if either that write or the preference rewrite fails, the old blob is
    /// deliberately left untouched and remains retryable.
    private func loadHydratedSettings() -> WebDAVSyncSettings {
        var settings = retryPendingCredentialDeletions(storage.load(default: WebDAVSyncSettings()))

        if let reference = settings.credentialReference {
            do {
                settings.password = try credentialPersistence.read(reference: reference) ?? ""
                unreadableCredentialReferences.remove(reference)
            } catch {
                unreadableCredentialReferences.insert(reference)
                settings.password = ""
                YamiboLog.sync.error("Unable to read WebDAV credential from Keychain: \(error)")
            }
            return settings
        }

        guard !settings.password.isEmpty else { return settings }
        let legacyPassword = settings.password
        do {
            try credentialPersistence.write(legacyPassword, reference: Self.legacyCredentialReference)
            var migrated = settings
            migrated.password = ""
            migrated.credentialReference = Self.legacyCredentialReference
            try storage.save(migrated)
            postChangeNotification()
            settings = migrated
            settings.password = legacyPassword
        } catch {
            // Do not clear or rewrite the old JSON blob on failure. A later
            // load can retry the secure migration with the plaintext intact.
            YamiboLog.sync.error("Unable to migrate WebDAV credential to Keychain: \(error)")
        }
        return settings
    }

    private nonisolated func hasUnmigratedPlaintextCredential(_ settings: WebDAVSyncSettings) -> Bool {
        settings.credentialReference == nil && !settings.password.isEmpty
    }

    /// Writes the secret first (when one is needed), then writes only the
    /// non-secret settings document. A new reference makes the two stores
    /// recoverable if the preference write fails: the old reference still
    /// serves the old document, and the new item can be removed as an orphan.
    private func persist(
        settings requested: WebDAVSyncSettings,
        replacing current: WebDAVSyncSettings,
        removingCredential: Bool = false
    ) throws -> WebDAVSyncSettings {
        var next = requested
        next.pendingCredentialDeletionReferences = current.pendingCredentialDeletionReferences
        let oldReference = current.credentialReference
        if !removingCredential, requested.password.isEmpty,
           let oldReference, unreadableCredentialReferences.contains(oldReference) {
            // A failed hydration is not an explicit request to erase a secret,
            // even when another connection field was edited in the meantime.
            throw YamiboPersistenceError(context: "WebDAV credential is temporarily unavailable")
        }
        let passwordUnchanged = requested.password == current.password
        let locationUnchanged = requested.trimmedBaseURLString == current.trimmedBaseURLString &&
            requested.trimmedUsername == current.trimmedUsername
        let targetReference: String?
        var createdReference: String?

        if removingCredential {
            targetReference = nil
        } else if requested.password.isEmpty {
            targetReference = passwordUnchanged && locationUnchanged ? oldReference : nil
        } else if passwordUnchanged, let oldReference {
            targetReference = oldReference
        } else {
            let reference = UUID().uuidString
            try credentialPersistence.write(requested.password, reference: reference)
            targetReference = reference
            createdReference = reference
        }
        next.credentialReference = targetReference

        let connectionChanged = WebDAVConnectionIdentity(current) != WebDAVConnectionIdentity(next)
        if connectionChanged {
            next.clearRemoteReceiptState()
            next.credentialReference = targetReference
            next.password = requested.password
        }

        var removedOldReference = false
        if targetReference == nil, let oldReference {
            // Do not remove the only secure copy until the new connection
            // value is ready to be published. If the defaults write fails,
            // the catch block restores this reference from the old settings.
            try credentialPersistence.remove(reference: oldReference)
            removedOldReference = true
        }

        if let oldReference, oldReference != targetReference, !removedOldReference {
            // Persist cleanup intent with the replacement reference so a
            // transient Keychain deletion failure remains retryable on launch.
            next.pendingCredentialDeletionReferences.insert(oldReference)
        }

        do {
            try storage.save(next)
        } catch {
            if let createdReference {
                try? credentialPersistence.remove(reference: createdReference)
            }
            if removedOldReference, !current.password.isEmpty, let oldReference {
                try? credentialPersistence.write(current.password, reference: oldReference)
            }
            throw error
        }

        next = retryPendingCredentialDeletions(next)
        if let targetReference { unreadableCredentialReferences.remove(targetReference) }
        if let oldReference, oldReference != targetReference { unreadableCredentialReferences.remove(oldReference) }
        postChangeNotification()
        return next
    }

    private func retryPendingCredentialDeletions(_ settings: WebDAVSyncSettings) -> WebDAVSyncSettings {
        guard !settings.pendingCredentialDeletionReferences.isEmpty else { return settings }
        var updated = settings
        for reference in settings.pendingCredentialDeletionReferences where reference != settings.credentialReference {
            do {
                try credentialPersistence.remove(reference: reference)
                updated.pendingCredentialDeletionReferences.remove(reference)
            } catch {
                YamiboLog.sync.warning("Unable to remove superseded WebDAV credential: \(error)")
            }
        }
        guard updated.pendingCredentialDeletionReferences != settings.pendingCredentialDeletionReferences else { return settings }
        do {
            try storage.save(updated)
            return updated
        } catch {
            // Deletion is idempotent; retaining the intent is safe to retry.
            YamiboLog.sync.warning("Unable to save WebDAV credential cleanup state: \(error)")
            return settings
        }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
