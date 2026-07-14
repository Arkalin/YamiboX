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
        lastAppliedRemoteUpdatedAtByDatasetID: [String: Date] = [:]
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
