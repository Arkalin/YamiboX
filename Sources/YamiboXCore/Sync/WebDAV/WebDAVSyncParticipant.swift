import Foundation

struct WebDAVExportSnapshot: Sendable {
    let data: Data
    let fingerprint: String?
}

struct WebDAVApplySnapshot: Sendable {
    let fingerprint: String?
    let requiresUpload: Bool
}

typealias WebDAVSyncFingerprint = SyncContentFingerprint

struct WebDAVRemotePayloadInfo: Sendable {
    var updatedAt: Date
    var accountUID: String?
    var revision: UInt64?

    init(updatedAt: Date, accountUID: String? = nil, revision: UInt64? = nil) {
        self.updatedAt = updatedAt
        self.accountUID = accountUID
        self.revision = revision
    }
}

enum WebDAVPayloadEnvelope {
    static let syncRevisionKey = "syncRevision"

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

protocol WebDAVSyncParticipant: Sendable {
    var datasetID: String { get }

    var remoteFileName: String { get }

    var remoteDirectories: [String] { get }

    var legacyRemoteFileName: String? { get }

    var uploadsOnlyWhenMarkedDirty: Bool { get }

    var uploadsUntrackedContentAutomatically: Bool { get }

    var localFingerprintDependencies: Set<String> { get }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo

    func mergeAndExportSnapshot(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> WebDAVExportSnapshot

    func applyRemoteSnapshot(_ data: Data) async throws -> WebDAVApplySnapshot

    /// Stable fingerprint of the locally stored dataset, or nil when the dataset
    /// does not use fingerprint-based change detection.
    func readLocalFingerprint() async throws -> String?

    func readLocalDeletionState() async throws -> SyncDeletionState?
}

extension WebDAVSyncParticipant {
    var remoteDirectories: [String] { [] }
    var legacyRemoteFileName: String? { nil }
    var uploadsOnlyWhenMarkedDirty: Bool { false }
    var uploadsUntrackedContentAutomatically: Bool { false }
    var localFingerprintDependencies: Set<String> { [] }

    func readLocalFingerprint() async throws -> String? { nil }
    func readLocalDeletionState() async throws -> SyncDeletionState? { nil }

    func localFingerprint() async -> String? { try? await readLocalFingerprint() }

    func mergeAndExport(remoteData: Data?, updatedAt: Date, accountUID: String) async throws -> Data {
        try await mergeAndExportSnapshot(remoteData: remoteData, updatedAt: updatedAt, accountUID: accountUID).data
    }

    func applyRemote(_ data: Data) async throws {
        _ = try await applyRemoteSnapshot(data)
    }
}
