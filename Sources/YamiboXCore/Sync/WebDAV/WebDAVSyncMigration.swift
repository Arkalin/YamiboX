import Foundation

struct WebDAVRemotePayload: Sendable {
    var data: Data
    var info: WebDAVRemotePayloadInfo
    var etag: String?
}

/// A format upgrade runs inside the same sync coordinator as the enclosing round.
/// Policies own their bookkeeping; transport and conditional writes stay in the engine.
protocol WebDAVSyncMigrating: Sendable {
    func prepare(
        settings: WebDAVSyncSettings,
        accountUID: String,
        operations: WebDAVSyncMigrationOperations
    ) async throws -> WebDAVSyncSettings
}

struct WebDAVSyncMigrationOperations: Sendable {
    let participants: [any WebDAVSyncParticipant]
    let fetchRemotePayloads: @Sendable (WebDAVSyncSettings) async throws -> [String: WebDAVRemotePayload]
    let fetchRemoteFile: @Sendable (WebDAVSyncSettings, String) async throws -> WebDAVRemoteFile
    let validateAccounts: @Sendable ([String: WebDAVRemotePayload]) throws -> Void
    let uploadStamp: @Sendable (Date?) -> Date
    let upload: @Sendable (any WebDAVSyncParticipant, WebDAVRemotePayload?, WebDAVSyncSettings, Date) async throws -> Void
}
