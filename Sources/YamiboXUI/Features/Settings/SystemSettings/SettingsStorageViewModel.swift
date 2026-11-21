import Foundation
import Observation
import YamiboXCore

@MainActor
@Observable
final class SettingsStorageViewModel: SystemSettingsActivityReporting {
    let dependencies: SettingsDependencies
    let activity: SystemSettingsActivity

    private let storageUsage: SettingsStorageUsage

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


    var webReaderCacheBytes: Int { storageUsage.webReaderCacheBytes }
    var contentCoverBytes: Int? { storageUsage.contentCoverBytes }
    var mangaDirectoryCacheBytes: Int { storageUsage.mangaDirectoryCacheBytes }
    var downloadBytes: Int { storageUsage.downloadBytes }
    var imageCacheBytes: Int? { storageUsage.imageCacheBytes }
    var otherCacheBytes: Int? { storageUsage.otherCacheBytes }
    var readingProgressBytes: Int? { storageUsage.readingProgressBytes }
    var browsingHistoryBytes: Int? { storageUsage.browsingHistoryBytes }
    var networkLogBytes: Int? { storageUsage.networkLogBytes }

    var webReaderCacheLabel: String { storageUsage.webReaderCacheLabel }
    var contentCoverLabel: String { storageUsage.contentCoverLabel }
    var mangaDirectoryCacheLabel: String { storageUsage.mangaDirectoryCacheLabel }
    var downloadLabel: String { storageUsage.downloadLabel }
    var imageCacheLabel: String { storageUsage.imageCacheLabel }
    var otherCacheLabel: String { storageUsage.otherCacheLabel }
    var readingProgressLabel: String { storageUsage.readingProgressLabel }
    var browsingHistoryLabel: String { storageUsage.browsingHistoryLabel }
    var networkLogLabel: String { storageUsage.networkLogLabel }
    var summary: SettingsStorageSummary { storageUsage.summary }

    func refreshStorageUsage() async {
        await storageUsage.refresh()
    }

    func observeNetworkLogUsage() async {
        await storageUsage.observeNetworkLogUsage()
    }


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
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    func clearContentCovers() async -> Bool {
        activeAction = .clearingContentCovers
        defer { activeAction = nil }

        do {
            try await dependencies.contentCoverStore.clearAllForSync()
            await storageUsage.refresh()
            return true
        } catch {
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
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

    func clearOtherCaches() async -> Bool {
        activeAction = .clearingOtherCaches
        defer { activeAction = nil }

        dependencies.httpCache.removeAllCachedResponses()
        await dependencies.checkInStore.clearAll()
        do {
            try await dependencies.favoriteUpdateStore.clearAll()
            await storageUsage.refresh()
            return true
        } catch {
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    func clearReadingProgress() async -> Bool {
        activeAction = .clearingReadingProgress
        defer { activeAction = nil }

        do {
            try await dependencies.library.readingProgressStore.clearAllForSync()
            await storageUsage.refresh()
            return true
        } catch {
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }

    func clearBrowsingHistory() async -> Bool {
        let store = dependencies.library.browsingHistoryStore
        activeAction = .clearingBrowsingHistory
        defer { activeAction = nil }

        do {
            try await store.clearAllForSync()
            await storageUsage.refresh()
            return true
        } catch {
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }


    func resetApplication() async -> Bool {
        activeAction = .resettingApplication
        defer { activeAction = nil }

        do {
            try await dependencies.resetApplicationData()
            onApplicationDataReset?()
            storageUsage.resetToZero()
            return true
        } catch {
            await storageUsage.refresh()
            if !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) {
                errorMessage = error.localizedDescription
                errorDetails = LoadFailureDetails(error: error)
            }
            return false
        }
    }
}
