import Foundation

/// Binds the isolated test sandbox to one origin, never supplies launch configuration.
@MainActor
public enum YamiboTestSiteBootstrap {
    private struct Binding: Codable {
        var origin: String?
        var resetPending: Bool
    }

    public static func prepare(websiteDataClearer: any WebsiteDataClearing) async throws -> Bool {
        let environment = try YamiboForumEnvironment.launchConfiguration.get()
        guard environment.requiresTestSitePreparation else { return false }
        let file = YamiboDatabase.defaultRootDirectory().deletingLastPathComponent()
            .appendingPathComponent("YamiboXTestSiteBinding.plist")
        let manager = FileManager.default
        let previous: Binding?
        if manager.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            previous = try? PropertyListDecoder().decode(Binding.self, from: data)
        } else {
            previous = nil
        }
        let origin = environment.baseURL.absoluteString
        guard previous?.origin != origin || previous?.resetPending != false else { return false }
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Binding(origin: previous?.origin, resetPending: true))
            .write(to: file, options: .atomic)

        // No WebView, session observers or runtime are active while resetting.
        let context = YamiboAppContext(
            databasePool: try YamiboDatabase.openPool(),
            websiteDataClearer: websiteDataClearer
        )
        await context.offlineCacheBackgroundDownloadTransport.invalidateRestoredDownloads()
        try await context.resetApplicationData()
        // Nuke stages deletions; flush them before another pipeline can read disk.
        guard await context.imagePipeline.totalDiskUsageBytes() == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        try PropertyListEncoder().encode(Binding(origin: origin, resetPending: false))
            .write(to: file, options: .atomic)
        return true
    }
}
