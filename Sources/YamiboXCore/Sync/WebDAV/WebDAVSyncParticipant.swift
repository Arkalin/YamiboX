import Foundation

/// Coordination metadata the sync flow needs from a remote payload without
/// understanding the payload's domain content.
struct WebDAVRemotePayloadInfo: Sendable {
    var updatedAt: Date
    var accountUID: String?
    /// Monotonic per-dataset revision carried in the payload envelope, nil for
    /// payloads written before revisions existed. When both sides of a
    /// comparison carry a revision, it wins over `updatedAt` (wall clocks skew
    /// across devices; revisions cannot).
    var revision: UInt64?

    init(updatedAt: Date, accountUID: String? = nil, revision: UInt64? = nil) {
        self.updatedAt = updatedAt
        self.accountUID = accountUID
        self.revision = revision
    }
}

/// Envelope-level handling of the per-dataset sync revision. The revision is
/// coordination metadata owned by the sync service, not domain content, so the
/// service stamps it into the exported JSON envelope after `mergeAndExport`
/// returns instead of threading a revision parameter through every
/// participant's merge path. Payload types only need to *decode* the field
/// (via `decodeIfPresent`, exposed through `inspectRemote`).
enum WebDAVPayloadEnvelope {
    /// Top-level JSON key, matching the payload structs' `syncRevision`
    /// coding key so `inspectRemote` sees the stamped value on the next fetch.
    static let syncRevisionKey = "syncRevision"

    /// Returns `payloadData` with the top-level `syncRevision` field set.
    /// Falls back to the unstamped data when the payload is not a JSON object
    /// (no participant produces one, but a defect here must not abort the
    /// round): peers then treat the upload as a pre-revision payload and use
    /// the wall-clock fallback, which is exactly the legacy behavior.
    static func injectingSyncRevision(_ revision: UInt64, into payloadData: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            YamiboLog.sync.warning("WebDAV payload is not a JSON object; uploading without syncRevision")
            return payloadData
        }
        object[syncRevisionKey] = revision
        guard let stamped = try? JSONSerialization.data(withJSONObject: object) else {
            YamiboLog.sync.warning("Failed to re-encode WebDAV payload with syncRevision; uploading without it")
            return payloadData
        }
        return stamped
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
