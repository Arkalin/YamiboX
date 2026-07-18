import Foundation
import os

/// WebDAV sync participant for the synchronized subset of app settings.
/// Last-writer-wins: the payload is a snapshot, never merged, and it is only
/// uploaded automatically after the synchronized subset actually changed.
struct AppSettingsWebDAVParticipant: WebDAVSyncParticipant {
    let datasetID = "appSettings"
    let remoteFileName = "yamibox-app-settings-v1.json"
    let uploadsOnlyWhenMarkedDirty = true

    private let store: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(store: SettingsStore) {
        self.store = store
    }

    func inspectRemote(_ data: Data) throws -> WebDAVRemotePayloadInfo {
        let payload = try decoder.decode(AppSettingsWebDAVPayload.self, from: data)
        return WebDAVRemotePayloadInfo(
            updatedAt: payload.updatedAt,
            accountUID: payload.accountUID,
            revision: payload.syncRevision
        )
    }

    func mergeAndExport(remoteData _: Data?, updatedAt: Date, accountUID: String) async throws -> Data {
        let payload = AppSettingsWebDAVPayload(
            updatedAt: updatedAt,
            accountUID: accountUID,
            appSettings: WebDAVSyncedAppSettings(settings: await store.load())
        )
        return try encoder.encode(payload)
    }

    func applyRemote(_ data: Data) async throws {
        let payload = try decoder.decode(AppSettingsWebDAVPayload.self, from: data)
        let currentSettings = await store.load()
        try await store.save(payload.appSettings.applying(to: currentSettings))
    }

    func localFingerprint() async -> String? {
        let snapshot = WebDAVSyncedAppSettings(settings: await store.load())
        let fingerprintEncoder = JSONEncoder()
        fingerprintEncoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try fingerprintEncoder.encode(snapshot)
        } catch {
            YamiboLog.sync.warning("Failed to encode app settings fingerprint for WebDAV sync: \(error)")
            return nil
        }
        return data.base64EncodedString()
    }
}

/// The subset of `AppSettings` that participates in WebDAV synchronization.
struct WebDAVSyncedAppSettings: Codable, Equatable, Sendable {
    var homePage: AppHomePage
    var webBrowser: WebBrowserSettings

    init(
        homePage: AppHomePage,
        webBrowser: WebBrowserSettings
    ) {
        self.homePage = homePage
        self.webBrowser = webBrowser
    }

    init(settings: AppSettings) {
        self.init(
            homePage: settings.system.homePage,
            webBrowser: settings.webBrowser
        )
    }

    func applying(to settings: AppSettings) -> AppSettings {
        var updated = settings
        updated.system.homePage = homePage
        updated.webBrowser = webBrowser
        return updated
    }
}

struct AppSettingsWebDAVPayload: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var updatedAt: Date
    var accountUID: String?
    /// Monotonic per-dataset sync revision, stamped into the envelope by the
    /// sync service after export; nil for payloads written before revisions
    /// existed. Optional, so the synthesized Codable decodes old payloads
    /// (`decodeIfPresent`) and omits the key when nil.
    var syncRevision: UInt64?
    var appSettings: WebDAVSyncedAppSettings

    init(
        version: Int = Self.currentVersion,
        updatedAt: Date,
        accountUID: String? = nil,
        syncRevision: UInt64? = nil,
        appSettings: WebDAVSyncedAppSettings
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.accountUID = accountUID
        self.syncRevision = syncRevision
        self.appSettings = appSettings
    }
}
