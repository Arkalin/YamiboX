import Foundation

public actor WebDAVSyncSettingsStore {
    nonisolated let syncCoordinator = WebDAVSyncCoordinator()
    public static let defaultKey = "yamibox.webdav.sync.settings"

    private nonisolated let changeBroadcaster = StoreChangeBroadcaster()
    public nonisolated var changeID: String { changeBroadcaster.changeID }
    public nonisolated func changes() -> AsyncStream<String> { changeBroadcaster.changes() }

    private static let legacyCredentialReference = "legacy-password"
    private let storage: UserDefaultsJSONStorage<WebDAVSyncSettings>
    private let credentialPersistence: any WebDAVSyncCredentialPersisting
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

    public func save(_ settings: WebDAVSyncSettings) async throws {
        _ = try await withConnectionBoundary {
            let current = loadHydratedSettings()
            return try persist(settings: settings, replacing: current)
        }
    }

    public func reset() async throws {
        try await withConnectionBoundary {
            try resetWithinAccountTransition()
        }
    }

    func resetWithinAccountTransition() throws {
        let current = loadHydratedSettings()
        _ = try persist(settings: WebDAVSyncSettings(), replacing: current, removingCredential: true)
    }

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
            throw YamiboPersistenceError(context: "WebDAV credential migration is unavailable")
        }
        transform(&settings)
        try storage.save(settings)
        postChangeNotification()
        return settings
    }

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
            YamiboLog.sync.error("Unable to migrate WebDAV credential to Keychain: \(error)")
        }
        return settings
    }

    private nonisolated func hasUnmigratedPlaintextCredential(_ settings: WebDAVSyncSettings) -> Bool {
        settings.credentialReference == nil && !settings.password.isEmpty
    }

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
            try credentialPersistence.remove(reference: oldReference)
            removedOldReference = true
        }

        if let oldReference, oldReference != targetReference, !removedOldReference {
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
            YamiboLog.sync.warning("Unable to save WebDAV credential cleanup state: \(error)")
            return settings
        }
    }

    private nonisolated func postChangeNotification() {
        changeBroadcaster.post()
    }
}
