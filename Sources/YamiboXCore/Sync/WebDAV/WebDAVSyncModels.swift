import Foundation

public struct WebDAVSyncSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var username: String
    public var password: String
    public var isAutoSyncEnabled: Bool
    public var lastSyncedAt: Date?
    public var lastRemoteUpdatedAt: Date?
    public var localUpdatedAt: Date?
    /// Datasets flagged as changed since the last sync; only consulted for
    /// participants that upload exclusively when marked dirty.
    public var dirtyDatasetIDs: Set<String>
    /// Fingerprint of each fingerprint-tracked dataset as of the last time it
    /// was marked or synchronized, used for change detection.
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

    public init(
        baseURLString: String = "",
        username: String = "",
        password: String = "",
        isAutoSyncEnabled: Bool = false,
        lastSyncedAt: Date? = nil,
        lastRemoteUpdatedAt: Date? = nil,
        localUpdatedAt: Date? = nil,
        dirtyDatasetIDs: Set<String> = [],
        lastSyncedFingerprintByDatasetID: [String: String] = [:],
        lastAppliedRemoteUpdatedAtByDatasetID: [String: Date] = [:],
        localRevisionByDatasetID: [String: UInt64] = [:],
        lastAppliedRemoteRevisionByDatasetID: [String: UInt64] = [:]
    ) {
        self.baseURLString = baseURLString
        self.username = username
        self.password = password
        self.isAutoSyncEnabled = isAutoSyncEnabled
        self.lastSyncedAt = lastSyncedAt
        self.lastRemoteUpdatedAt = lastRemoteUpdatedAt
        self.localUpdatedAt = localUpdatedAt
        self.dirtyDatasetIDs = dirtyDatasetIDs
        self.lastSyncedFingerprintByDatasetID = lastSyncedFingerprintByDatasetID
        self.lastAppliedRemoteUpdatedAtByDatasetID = lastAppliedRemoteUpdatedAtByDatasetID
        self.localRevisionByDatasetID = localRevisionByDatasetID
        self.lastAppliedRemoteRevisionByDatasetID = lastAppliedRemoteRevisionByDatasetID
    }

    private enum CodingKeys: String, CodingKey {
        case baseURLString
        case username
        case password
        case isAutoSyncEnabled
        case lastSyncedAt
        case lastRemoteUpdatedAt
        case localUpdatedAt
        case dirtyDatasetIDs
        case lastSyncedFingerprintByDatasetID
        case lastAppliedRemoteUpdatedAtByDatasetID
        case localRevisionByDatasetID
        case lastAppliedRemoteRevisionByDatasetID
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
            lastSyncedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt),
            lastRemoteUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .lastRemoteUpdatedAt),
            localUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .localUpdatedAt),
            dirtyDatasetIDs: try container.decodeIfPresent(Set<String>.self, forKey: .dirtyDatasetIDs) ?? [],
            lastSyncedFingerprintByDatasetID: try container.decodeIfPresent([String: String].self, forKey: .lastSyncedFingerprintByDatasetID) ?? [:],
            lastAppliedRemoteUpdatedAtByDatasetID: try container.decodeIfPresent([String: Date].self, forKey: .lastAppliedRemoteUpdatedAtByDatasetID) ?? [:],
            localRevisionByDatasetID: try container.decodeIfPresent([String: UInt64].self, forKey: .localRevisionByDatasetID) ?? [:],
            lastAppliedRemoteRevisionByDatasetID: try container.decodeIfPresent([String: UInt64].self, forKey: .lastAppliedRemoteRevisionByDatasetID) ?? [:]
        )
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
    case invalidConfiguration
    case notFound
    case notAuthenticated
    case unsupportedPayloadVersion(Int)
    case invalidResponse(Int?)
    case emptyPayload
    case accountMismatch(localUID: String, remoteUID: String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            L10n.string("webdav.error.invalid_configuration")
        case .notFound:
            L10n.string("webdav.error.not_found")
        case .notAuthenticated:
            L10n.string("webdav.error.not_authenticated")
        case let .unsupportedPayloadVersion(version):
            L10n.string("webdav.error.unsupported_version", version)
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
