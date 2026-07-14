import Foundation

/// Coordination metadata the sync flow needs from a remote payload without
/// understanding the payload's domain content.
struct WebDAVRemotePayloadInfo: Sendable {
    var updatedAt: Date
    var accountUID: String?

    init(updatedAt: Date, accountUID: String? = nil) {
        self.updatedAt = updatedAt
        self.accountUID = accountUID
    }
}

/// One synchronizable dataset. Feature modules implement this protocol and own
/// their payload formats and merge semantics; the Sync module only orchestrates
/// upload/download/conflict decisions over opaque payload data.
protocol WebDAVSyncParticipant: Sendable {
    /// Stable identifier used for dirty tracking and fingerprint bookkeeping.
    var datasetID: String { get }

    /// File name of this dataset inside the remote WebDAV sync directory.
    var remoteFileName: String { get }

    /// When true, automatic sync uploads this dataset only after it has been
    /// marked dirty through fingerprint-based change detection. Manual uploads
    /// always include the dataset.
    var uploadsOnlyWhenMarkedDirty: Bool { get }

    /// Decodes remote payload data just far enough to expose coordination metadata.
    /// Throw a non-`underlying` `WebDAVSyncError` (e.g. `unsupportedPayloadVersion`)
    /// to abort the sync; any other error makes the sync treat the remote payload
    /// as absent.
    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo

    /// Merges local state with the optional remote payload, persists the merge
    /// result locally, and returns the encoded payload to upload.
    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> Data

    /// Replaces local state with the downloaded remote payload.
    func applyRemote(_ data: Data) async throws

    /// Stable fingerprint of the locally stored dataset, or nil when the dataset
    /// does not use fingerprint-based change detection.
    func localFingerprint() async -> String?
}

extension WebDAVSyncParticipant {
    var uploadsOnlyWhenMarkedDirty: Bool { false }

    func localFingerprint() async -> String? { nil }
}
