import Foundation

/// Reconnect to the legacy system session only to cancel it. Never admit new
/// work or commit its results; the persisted queue keeps verified completed files.
public actor DownloadBackgroundSessionMigration {
    public static let shared = DownloadBackgroundSessionMigration()
    private var retirement: Task<Void, Never>?

    public nonisolated static var legacyIdentifier: String {
        YamiboForumEnvironment.current.backgroundDownloadIdentifier
            .replacingOccurrences(of: ".download.", with: ".offlineCache.")
    }

    public func retire() async {
        if let retirement { await retirement.value; return }
        let task = Task {
            let transport = DownloadBackgroundTransport(
                configuration: DownloadBackgroundTransport.makeBackgroundConfiguration(identifier: Self.legacyIdentifier)
            )
            await transport.invalidateRestoredDownloads()
        }
        retirement = task
        await task.value
    }
}
