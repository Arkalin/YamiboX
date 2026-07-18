import Foundation
import Observation
import YamiboXCore

/// State and commands for the Data & Storage page: cache usage labels, the
/// cache-clearing actions, and full application reset.
@MainActor
@Observable
final class SettingsStorageViewModel: SystemSettingsActivityReporting {
    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    private let storageUsage: SettingsStorageUsage

    /// Installed by the composition root. Application reset wipes *every*
    /// page's persisted state, but only this page can trigger it — the hook
    /// lets the root fan the in-memory reset out to the sibling page models
    /// without this page holding references to (or even knowing about) them.
    @ObservationIgnored var onApplicationDataReset: (@MainActor () -> Void)?

    init(
        dependencies: SettingsDependencies,
        activity: SystemSettingsActivity,
        storageUsage: SettingsStorageUsage
    ) {
        self.dependencies = dependencies
        self.activity = activity
        self.storageUsage = storageUsage
    }

    // The usage counters live in the shared `SettingsStorageUsage` (the
    // management sub-pages refresh them after deletions); these passthroughs
    // keep this page's view and tests reading them from their primary owner.

    var webReaderCacheBytes: Int { storageUsage.webReaderCacheBytes }
    var contentCoverCacheBytes: Int { storageUsage.contentCoverCacheBytes }
    var mangaDirectoryCacheBytes: Int { storageUsage.mangaDirectoryCacheBytes }
    var offlineCacheBytes: Int { storageUsage.offlineCacheBytes }

    var webReaderCacheLabel: String { storageUsage.webReaderCacheLabel }
    var contentCoverCacheLabel: String { storageUsage.contentCoverCacheLabel }
    var mangaDirectoryCacheLabel: String { storageUsage.mangaDirectoryCacheLabel }
    var offlineCacheLabel: String { storageUsage.offlineCacheLabel }

    // MARK: - Cache clearing

    /// Clears every `DiskCacheStore`-backed render/HTML cache: novel and manga
    /// reader page projections plus the forum home/board/thread-page cache.
    /// These three share the same underlying engine and are all equally
    /// re-fetchable, so a single button covers all of them.
    func clearWebReaderCache() async -> Bool {
        activeAction = .clearingWebReaderCache
        defer { activeAction = nil }

        do {
            try await dependencies.novelReaderCacheStore.clearAll()
            try await dependencies.mangaReaderProjectionStore.clearAll()
            try await dependencies.forumCacheStore.clearAll()
            await storageUsage.refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearContentCoverCache() async -> Bool {
        activeAction = .clearingContentCoverCache
        defer { activeAction = nil }

        do {
            try await dependencies.contentCoverStore.clearAll()
            await storageUsage.refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearImageCache() async -> Bool {
        activeAction = .clearingImageCache
        defer { activeAction = nil }

        await dependencies.clearOrdinaryImageCache()
        await storageUsage.refresh()
        return true
    }

    /// Clears the system HTTP cache plus two small stores with no other
    /// bulk-clear entry point: the per-account check-in date cache and the
    /// favorites-update tracking state (tracked targets, detected events, run
    /// history, fid/category filters).
    func clearOtherCaches() async -> Bool {
        activeAction = .clearingOtherCaches
        defer { activeAction = nil }

        URLCache.shared.removeAllCachedResponses()
        await dependencies.checkInStore.clearAll()
        do {
            try await dependencies.favoriteUpdateStore.clearAll()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Application reset

    func resetApplication() async -> Bool {
        activeAction = .resettingApplication
        defer { activeAction = nil }

        do {
            try await dependencies.resetApplicationData()
            // Persisted state is gone; now snap the in-memory page state of
            // every settings page (via the root's hook) and the shared usage
            // counters back to defaults so the UI matches the wiped stores.
            onApplicationDataReset?()
            storageUsage.resetToZero()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
