import Foundation
import Observation
import YamiboXCore

// MARK: - Cross-page activity surface

/// The one in-flight action and pending error message shared by every system
/// settings page.
///
/// These two pieces of state are deliberately *not* split per page: the root
/// settings screen gates navigation on `isBusy` so a still-running action on
/// one page (e.g. Storage) can never become reachable-but-frozen on another
/// page the user navigates to next, and every page installs the same error
/// alert so a fire-and-forget save that fails *after* the user navigated away
/// still surfaces wherever they are now. Keeping a single shared instance
/// preserves exactly the behavior the former monolithic view model had.
@MainActor
@Observable
final class SystemSettingsActivity {
    var activeAction: SystemSettingsAction?
    var errorMessage: String?

    var isBusy: Bool {
        activeAction != nil
    }
}

/// Anything that surfaces busy state and errors through the shared
/// ``SystemSettingsActivity``. The passthrough accessors keep view and test
/// call sites (`viewModel.isBusy`, `viewModel.errorMessage = nil`, …) exactly
/// as they were before the per-page split — the sharing is an implementation
/// detail the views never have to know about.
@MainActor
protocol SystemSettingsActivityReporting: AnyObject {
    var activity: SystemSettingsActivity { get }
}

extension SystemSettingsActivityReporting {
    var isBusy: Bool {
        activity.isBusy
    }

    var activeAction: SystemSettingsAction? {
        get { activity.activeAction }
        set { activity.activeAction = newValue }
    }

    var errorMessage: String? {
        get { activity.errorMessage }
        set { activity.errorMessage = newValue }
    }
}

// MARK: - Cross-page storage usage

/// Disk-usage counters for the four cache categories the Storage page lists.
///
/// A shared model rather than Storage-page-private state because the offline
/// cache and manga directory management pages delete data those counters
/// describe: they refresh this model after a deletion so the Storage page the
/// user pops back to never shows stale byte counts.
@MainActor
@Observable
final class SettingsStorageUsage {
    private(set) var webReaderCacheBytes = 0
    private(set) var contentCoverCacheBytes = 0
    private(set) var mangaDirectoryCacheBytes = 0
    private(set) var offlineCacheBytes = 0

    private let dependencies: SettingsDependencies

    init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    var webReaderCacheLabel: String {
        Self.cacheLabel(for: webReaderCacheBytes)
    }

    var contentCoverCacheLabel: String {
        Self.cacheLabel(for: contentCoverCacheBytes)
    }

    var mangaDirectoryCacheLabel: String {
        Self.cacheLabel(for: mangaDirectoryCacheBytes)
    }

    var offlineCacheLabel: String {
        Self.cacheLabel(for: offlineCacheBytes)
    }

    func refresh() async {
        let novelBytes = await dependencies.novelReaderCacheStore.totalDiskUsageBytes()
        let mangaProjectionBytes = await dependencies.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytes = await dependencies.forumCacheStore.totalDiskUsageBytes()
        webReaderCacheBytes = novelBytes + mangaProjectionBytes + forumBytes
        contentCoverCacheBytes = await dependencies.contentCoverStore.totalDiskUsageBytes()
        mangaDirectoryCacheBytes = await dependencies.mangaDirectoryStore.totalDiskUsageBytes()
        offlineCacheBytes = await dependencies.offlineCacheStore.totalDiskUsageBytes()
    }

    /// Application reset zeroes the counters directly instead of re-reading
    /// the stores: the wipe just succeeded, so a re-read would only race
    /// against it for the same answer.
    func resetToZero() {
        webReaderCacheBytes = 0
        contentCoverCacheBytes = 0
        mangaDirectoryCacheBytes = 0
        offlineCacheBytes = 0
    }

    private static func cacheLabel(for bytes: Int) -> String {
        let megabytes = Double(max(0, bytes)) / 1_048_576
        return String(format: "%.2f MB", megabytes)
    }
}
