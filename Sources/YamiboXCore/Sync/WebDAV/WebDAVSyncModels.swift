import Foundation

public enum WebDAVSyncContent: String, Codable, CaseIterable, Sendable, Identifiable {
    case favoriteLibrary, likeLibrary, bookmarkLibrary, readingProgress
    case contentCovers, appSettings, mangaDirectories, browsingHistory

    public var id: String { rawValue }
    public var title: String { L10n.string("webdav.content.\(rawValue)") }
}

/// The receipt fields in `WebDAVSyncSettings` describe one remote/account
/// scope. The password is deliberately not part of this value: changing a
/// credential is a connection change and clears the receipts before the new
/// connection is admitted.
struct WebDAVReceiptScope: Codable, Equatable, Sendable {
    let baseURL: String
    let username: String
    let accountUID: String

    init(settings: WebDAVSyncSettings, accountUID: String) {
        baseURL = settings.trimmedBaseURLString
        username = settings.trimmedUsername
        self.accountUID = accountUID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct WebDAVSyncSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var username: String
    /// In-memory only. `encode(to:)` intentionally omits this field; the
    /// settings store hydrates it from Keychain after decoding.
    public var password: String
    /// Non-secret reference to the Keychain item containing `password`.
    var credentialReference: String?
    var pendingCredentialDeletionReferences: Set<String> = []
    public var isAutoSyncEnabled: Bool
    public var disabledContentIDs: Set<String>
    public var contentSelectionRevision: UInt64

    public func isEnabled(_ content: WebDAVSyncContent) -> Bool {
        !disabledContentIDs.contains(content.rawValue)
    }

    public var hasEnabledContent: Bool {
        WebDAVSyncContent.allCases.contains { isEnabled($0) }
    }

    public func deletionNotice(for content: WebDAVSyncContent) -> String {
        if isEnabled(content) { return L10n.string("webdav.deletion.enabled") }
        return L10n.string(content == .mangaDirectories || content == .browsingHistory
            ? "webdav.deletion.local_only" : "webdav.deletion.pending")
    }
    public var lastSyncedAt: Date?
    public var lastRemoteUpdatedAt: Date?
    public var localUpdatedAt: Date?
    /// Datasets flagged as changed since the last sync; only consulted for
    /// participants that upload exclusively when marked dirty.
    public var dirtyDatasetIDs: Set<String>
    /// Fingerprint of the last committed sync snapshot, never advanced just
    /// because a local edit was detected.
    public var lastSyncedFingerprintByDatasetID: [String: String]
    /// `updatedAt` of the newest remote payload whose content this device has
    /// absorbed (by applying it or by producing it through an upload), per
    /// dataset. Lets the upload path apply newer remote data for datasets that
    /// are not locally dirty instead of discarding it.
    public var lastAppliedRemoteUpdatedAtByDatasetID: [String: Date]
    /// Monotonic (Lamport-style) revision this device stamped onto its most
    /// recent upload of each dataset. Revisions, not wall clocks, decide sync
    /// direction whenever both sides carry one, so cross-device clock skew
    /// cannot flip a comparison; the `updatedAt` fields above stay as the
    /// fallback for pre-revision peers and for interval bookkeeping.
    public var localRevisionByDatasetID: [String: UInt64]
    /// Revision of the newest remote payload whose content this device has
    /// absorbed (by applying it or by producing it through an upload), per
    /// dataset. Revision-bearing counterpart of
    /// `lastAppliedRemoteUpdatedAtByDatasetID`.
    public var lastAppliedRemoteRevisionByDatasetID: [String: UInt64]
    /// Successful one-way imports, scoped to remote location, account and dataset.
    public var completedMangaIdentityImports: Set<String>
    /// Scope of the active new-format baseline, independent of import history.
    public var mangaIdentityBaselineScopeByDatasetID: [String: String]
    /// The remote location and forum account whose receipt dictionaries are
    /// valid. A mismatch forces a fresh reconciliation instead of allowing a
    /// revision floor from another destination or account to suppress data.
    var receiptScope: WebDAVReceiptScope?

    public init(
        baseURLString: String = "",
        username: String = "",
        password: String = "",
        isAutoSyncEnabled: Bool = false,
        disabledContentIDs: Set<String> = [],
        contentSelectionRevision: UInt64 = 0,
        lastSyncedAt: Date? = nil,
        lastRemoteUpdatedAt: Date? = nil,
        localUpdatedAt: Date? = nil,
        dirtyDatasetIDs: Set<String> = [],
        lastSyncedFingerprintByDatasetID: [String: String] = [:],
        lastAppliedRemoteUpdatedAtByDatasetID: [String: Date] = [:],
        localRevisionByDatasetID: [String: UInt64] = [:],
        lastAppliedRemoteRevisionByDatasetID: [String: UInt64] = [:],
        completedMangaIdentityImports: Set<String> = [],
        mangaIdentityBaselineScopeByDatasetID: [String: String] = [:]
    ) {
        self.baseURLString = baseURLString
        self.username = username
        self.password = password
        self.credentialReference = nil
        self.isAutoSyncEnabled = isAutoSyncEnabled
        self.disabledContentIDs = disabledContentIDs
        self.contentSelectionRevision = contentSelectionRevision
        self.lastSyncedAt = lastSyncedAt
        self.lastRemoteUpdatedAt = lastRemoteUpdatedAt
        self.localUpdatedAt = localUpdatedAt
        self.dirtyDatasetIDs = dirtyDatasetIDs
        self.lastSyncedFingerprintByDatasetID = lastSyncedFingerprintByDatasetID
        self.lastAppliedRemoteUpdatedAtByDatasetID = lastAppliedRemoteUpdatedAtByDatasetID
        self.localRevisionByDatasetID = localRevisionByDatasetID
        self.lastAppliedRemoteRevisionByDatasetID = lastAppliedRemoteRevisionByDatasetID
        self.completedMangaIdentityImports = completedMangaIdentityImports
        self.mangaIdentityBaselineScopeByDatasetID = mangaIdentityBaselineScopeByDatasetID
        self.receiptScope = nil
    }

    private enum CodingKeys: String, CodingKey {
        case baseURLString
        case username
        // Decoded for migration from the old UserDefaults blob only. Never
        // emitted by encode(to:).
        case password
        case credentialReference
        case pendingCredentialDeletionReferences
        case isAutoSyncEnabled
        case disabledContentIDs, contentSelectionRevision
        case lastSyncedAt
        case lastRemoteUpdatedAt
        case localUpdatedAt
        case dirtyDatasetIDs
        case lastSyncedFingerprintByDatasetID
        case lastAppliedRemoteUpdatedAtByDatasetID
        case localRevisionByDatasetID
        case lastAppliedRemoteRevisionByDatasetID
        case completedMangaIdentityImports
        case mangaIdentityBaselineScopeByDatasetID
        case receiptScope
    }

    /// Every field decodes with `decodeIfPresent ?? default` (the same
    /// tolerance pattern as `FavoriteLibrarySettings`): a stored blob written
    /// before a field existed must keep decoding, because a decode failure
    /// makes `UserDefaultsJSONStorage` degrade to defaults and would silently
    /// drop the user's credentials along with all sync bookkeeping.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURLString: try container.decodeIfPresent(String.self, forKey: .baseURLString) ?? "",
            username: try container.decodeIfPresent(String.self, forKey: .username) ?? "",
            password: try container.decodeIfPresent(String.self, forKey: .password) ?? "",
            isAutoSyncEnabled: try container.decodeIfPresent(Bool.self, forKey: .isAutoSyncEnabled) ?? false,
            disabledContentIDs: try container.decodeIfPresent(Set<String>.self, forKey: .disabledContentIDs) ?? [],
            contentSelectionRevision: try container.decodeIfPresent(UInt64.self, forKey: .contentSelectionRevision) ?? 0,
            lastSyncedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt),
            lastRemoteUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .lastRemoteUpdatedAt),
            localUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .localUpdatedAt),
            dirtyDatasetIDs: try container.decodeIfPresent(Set<String>.self, forKey: .dirtyDatasetIDs) ?? [],
            lastSyncedFingerprintByDatasetID: try container.decodeIfPresent([String: String].self, forKey: .lastSyncedFingerprintByDatasetID) ?? [:],
            lastAppliedRemoteUpdatedAtByDatasetID: try container.decodeIfPresent([String: Date].self, forKey: .lastAppliedRemoteUpdatedAtByDatasetID) ?? [:],
            localRevisionByDatasetID: try container.decodeIfPresent([String: UInt64].self, forKey: .localRevisionByDatasetID) ?? [:],
            lastAppliedRemoteRevisionByDatasetID: try container.decodeIfPresent([String: UInt64].self, forKey: .lastAppliedRemoteRevisionByDatasetID) ?? [:],
            completedMangaIdentityImports: try container.decodeIfPresent(Set<String>.self, forKey: .completedMangaIdentityImports) ?? [],
            mangaIdentityBaselineScopeByDatasetID: try container.decodeIfPresent([String: String].self, forKey: .mangaIdentityBaselineScopeByDatasetID) ?? [:]
        )
        credentialReference = try container.decodeIfPresent(String.self, forKey: .credentialReference)
        pendingCredentialDeletionReferences = try container.decodeIfPresent(Set<String>.self, forKey: .pendingCredentialDeletionReferences) ?? []
        receiptScope = try container.decodeIfPresent(WebDAVReceiptScope.self, forKey: .receiptScope)
    }

    /// Keep secrets out of the generic JSON storage. The old `password` key
    /// remains decodable solely so the settings store can migrate it without
    /// deleting the plaintext until a secure write succeeds.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURLString, forKey: .baseURLString)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
        try container.encode(pendingCredentialDeletionReferences, forKey: .pendingCredentialDeletionReferences)
        try container.encode(isAutoSyncEnabled, forKey: .isAutoSyncEnabled)
        try container.encode(disabledContentIDs, forKey: .disabledContentIDs)
        try container.encode(contentSelectionRevision, forKey: .contentSelectionRevision)
        try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encodeIfPresent(lastRemoteUpdatedAt, forKey: .lastRemoteUpdatedAt)
        try container.encodeIfPresent(localUpdatedAt, forKey: .localUpdatedAt)
        try container.encode(dirtyDatasetIDs, forKey: .dirtyDatasetIDs)
        try container.encode(lastSyncedFingerprintByDatasetID, forKey: .lastSyncedFingerprintByDatasetID)
        try container.encode(lastAppliedRemoteUpdatedAtByDatasetID, forKey: .lastAppliedRemoteUpdatedAtByDatasetID)
        try container.encode(localRevisionByDatasetID, forKey: .localRevisionByDatasetID)
        try container.encode(lastAppliedRemoteRevisionByDatasetID, forKey: .lastAppliedRemoteRevisionByDatasetID)
        try container.encode(completedMangaIdentityImports, forKey: .completedMangaIdentityImports)
        try container.encode(mangaIdentityBaselineScopeByDatasetID, forKey: .mangaIdentityBaselineScopeByDatasetID)
        try container.encodeIfPresent(receiptScope, forKey: .receiptScope)
    }

    /// Receipt state is disposable remote bookkeeping. Local content remains
    /// in its feature stores and is fingerprinted again on the next automatic
    /// round, so a new destination cannot inherit floors from the old one.
    mutating func clearRemoteReceiptState() {
        lastSyncedAt = nil
        lastRemoteUpdatedAt = nil
        localUpdatedAt = nil
        dirtyDatasetIDs.removeAll()
        lastSyncedFingerprintByDatasetID.removeAll()
        lastAppliedRemoteUpdatedAtByDatasetID.removeAll()
        localRevisionByDatasetID.removeAll()
        lastAppliedRemoteRevisionByDatasetID.removeAll()
        completedMangaIdentityImports.removeAll()
        mangaIdentityBaselineScopeByDatasetID.removeAll()
        receiptScope = nil
    }

    public var trimmedBaseURLString: String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isConfigured: Bool {
        URL(string: trimmedBaseURLString) != nil && !trimmedUsername.isEmpty
    }
}

public enum WebDAVSyncDirection: String, Codable, CaseIterable, Sendable {
    case upload
    case download
}

public enum WebDAVAutomaticSyncResult: Equatable, Sendable {
    case skipped
    case downloaded
    case uploaded
}

public enum WebDAVSyncError: LocalizedError, Equatable, Sendable {
    case noContentSelected
    case invalidConfiguration
    case notFound
    case notAuthenticated
    case unsupportedPayloadVersion(Int)
    case unsafeConditionalWrite
    case writeConflict
    case invalidResponse(Int?)
    case emptyPayload
    case accountMismatch(localUID: String, remoteUID: String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .noContentSelected:
            L10n.string("webdav.error.no_content_selected")
        case .invalidConfiguration:
            L10n.string("webdav.error.invalid_configuration")
        case .notFound:
            L10n.string("webdav.error.not_found")
        case .notAuthenticated:
            L10n.string("webdav.error.not_authenticated")
        case let .unsupportedPayloadVersion(version):
            L10n.string("webdav.error.unsupported_version", version)
        case .unsafeConditionalWrite:
            L10n.string("webdav.error.unsafe_conditional_write")
        case .writeConflict:
            L10n.string("webdav.error.write_conflict")
        case let .invalidResponse(statusCode):
            if let statusCode {
                L10n.string("webdav.error.invalid_response_with_status", statusCode)
            } else {
                L10n.string("webdav.error.invalid_response")
            }
        case .emptyPayload:
            L10n.string("webdav.error.empty_payload")
        case .accountMismatch:
            L10n.string("webdav.error.account_mismatch")
        case let .underlying(message):
            message
        }
    }
}
