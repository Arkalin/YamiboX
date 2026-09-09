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
    var errorMessage: String? {
        didSet { errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?

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
    var errorDetails: LoadFailureDetails? {
        get { activity.errorDetails }
        set { activity.errorDetails = newValue }
    }

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

/// File sizes and logical data-size estimates for the Storage page.
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
    private(set) var imageCacheBytes: Int?
    private(set) var otherCacheBytes: Int?
    private(set) var readingProgressBytes: Int?
    private(set) var browsingHistoryBytes: Int?

    private let dependencies: SettingsDependencies
    private var refreshGeneration = 0
    private var hasLoadedAdditionalUsage = false

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

    var imageCacheLabel: String { additionalUsageLabel(for: imageCacheBytes) }
    var otherCacheLabel: String { additionalUsageLabel(for: otherCacheBytes) }
    var readingProgressLabel: String { additionalUsageLabel(for: readingProgressBytes) }
    var browsingHistoryLabel: String { additionalUsageLabel(for: browsingHistoryBytes) }

    var summary: SettingsStorageSummary {
        var categories: [SettingsStorageCategoryUsage] = [
            .init(category: .webReader, bytes: webReaderCacheBytes),
            .init(category: .images, bytes: imageCacheBytes),
            .init(category: .other, bytes: otherCacheBytes),
            .init(category: .covers, bytes: contentCoverCacheBytes),
            .init(category: .progress, bytes: readingProgressBytes)
        ]
        if dependencies.library.browsingHistoryStore != nil {
            categories.append(.init(category: .history, bytes: browsingHistoryBytes))
        }
        categories.append(.init(category: .directories, bytes: mangaDirectoryCacheBytes))
        categories.append(.init(category: .offline, bytes: offlineCacheBytes))
        return SettingsStorageSummary(categories: categories, hasLoaded: hasLoadedAdditionalUsage)
    }

    func refresh(includeAdditionalUsage: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let novelBytes = await dependencies.novelReaderCacheStore.totalDiskUsageBytes()
        let mangaProjectionBytes = await dependencies.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytes = await dependencies.forumCacheStore.totalDiskUsageBytes()
        let coverBytes = await dependencies.contentCoverStore.totalDiskUsageBytes()
        let directoryBytes = await dependencies.mangaDirectoryStore.totalDiskUsageBytes()
        let offlineBytes = await dependencies.offlineCacheStore.totalDiskUsageBytes()
        var imageBytes: Int?
        var otherBytes: Int?
        var progressBytes: Int?
        var historyBytes: Int?
        if includeAdditionalUsage {
            imageBytes = await dependencies.ordinaryImageCacheUsageBytes()
            let checkInBytes = await dependencies.checkInStore.estimatedDataUsageBytes()
            if let updateBytes = try? await dependencies.favoriteUpdateStore.estimatedDataUsageBytes() {
                otherBytes = dependencies.httpCache.currentDiskUsage + checkInBytes + updateBytes
            }
            progressBytes = try? await dependencies.library.readingProgressStore.estimatedDataUsageBytes()
            historyBytes = try? await dependencies.library.browsingHistoryStore?.estimatedDataUsageBytes()
        }
        // A clear/reset or newer refresh must win over an older suspended read.
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        webReaderCacheBytes = novelBytes + mangaProjectionBytes + forumBytes
        contentCoverCacheBytes = coverBytes
        mangaDirectoryCacheBytes = directoryBytes
        offlineCacheBytes = offlineBytes
        if includeAdditionalUsage {
            imageCacheBytes = imageBytes
            otherCacheBytes = otherBytes
            readingProgressBytes = progressBytes
            browsingHistoryBytes = historyBytes
            hasLoadedAdditionalUsage = true
        }
    }

    /// Application reset zeroes the counters directly instead of re-reading
    /// the stores: the wipe just succeeded, so a re-read would only race
    /// against it for the same answer.
    func resetToZero() {
        refreshGeneration += 1
        webReaderCacheBytes = 0
        contentCoverCacheBytes = 0
        mangaDirectoryCacheBytes = 0
        offlineCacheBytes = 0
        imageCacheBytes = 0
        otherCacheBytes = 0
        readingProgressBytes = 0
        browsingHistoryBytes = dependencies.library.browsingHistoryStore == nil ? nil : 0
        hasLoadedAdditionalUsage = true
    }

    private func additionalUsageLabel(for bytes: Int?) -> String {
        guard let bytes else {
            return L10n.string(hasLoadedAdditionalUsage
                ? "settings.storage_usage_unavailable"
                : "settings.storage_usage_calculating")
        }
        return Self.cacheLabel(for: bytes)
    }

    nonisolated static func cacheLabel(for bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(max(0, bytes)))
    }
}
