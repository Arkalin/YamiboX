import Foundation
import Observation
import YamiboXCore


@MainActor
@Observable
final class SystemSettingsActivity {
    private struct SettingsEditKey: Hashable {
        let ownerID: ObjectIdentifier
        let keyPath: AnyKeyPath
    }

    private struct SettingsEdit {
        let id: UUID
        let rollback: @MainActor () -> Bool
        var hasFailed = false
    }

    @ObservationIgnored private var settingsEdits: [SettingsEditKey: [SettingsEdit]] = [:]
    var activeAction: SystemSettingsAction?
    private(set) var errorIdentity = UUID()
    var errorMessage: String? {
        didSet { errorIdentity = UUID(); errorDetails = nil }
    }
    var errorDetails: LoadFailureDetails?

    var isBusy: Bool {
        activeAction != nil
    }

    func beginSettingsEdit(
        owner: AnyObject,
        keyPath: AnyKeyPath,
        rollback: @escaping @MainActor () -> Bool
    ) -> UUID {
        let editID = UUID()
        let key = SettingsEditKey(ownerID: ObjectIdentifier(owner), keyPath: keyPath)
        settingsEdits[key, default: []].append(SettingsEdit(id: editID, rollback: rollback))
        return editID
    }

    func finishSettingsEdit(owner: AnyObject, keyPath: AnyKeyPath, editID: UUID, succeeded: Bool) {
        let key = SettingsEditKey(ownerID: ObjectIdentifier(owner), keyPath: keyPath)
        guard var edits = settingsEdits[key],
              let index = edits.firstIndex(where: { $0.id == editID }) else { return }
        if succeeded {
            edits.removeFirst(index + 1)
        } else {
            edits[index].hasFailed = true
            while let latest = edits.last, latest.hasFailed {
                edits.removeLast()
                guard latest.rollback() else {
                    edits.removeAll()
                    break
                }
            }
        }
        settingsEdits[key] = edits.isEmpty ? nil : edits
    }
}

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


@MainActor
@Observable
final class SettingsStorageUsage {
    private(set) var webReaderCacheBytes = 0
    private(set) var contentCoverBytes: Int?
    private(set) var mangaDirectoryCacheBytes = 0
    private(set) var downloadBytes = 0
    private(set) var imageCacheBytes: Int?
    private(set) var otherCacheBytes: Int?
    private(set) var readingProgressBytes: Int?
    private(set) var browsingHistoryBytes: Int?
    private(set) var networkLogBytes: Int?

    private let dependencies: SettingsDependencies
    private var refreshGeneration = 0
    private var networkLogRefreshGeneration = 0
    private var hasLoadedAdditionalUsage = false

    init(dependencies: SettingsDependencies) {
        self.dependencies = dependencies
    }

    var webReaderCacheLabel: String {
        Self.cacheLabel(for: webReaderCacheBytes)
    }

    var contentCoverLabel: String {
        additionalUsageLabel(for: contentCoverBytes)
    }

    var mangaDirectoryCacheLabel: String {
        Self.cacheLabel(for: mangaDirectoryCacheBytes)
    }

    var downloadLabel: String {
        Self.cacheLabel(for: downloadBytes)
    }

    var imageCacheLabel: String { additionalUsageLabel(for: imageCacheBytes) }
    var otherCacheLabel: String { additionalUsageLabel(for: otherCacheBytes) }
    var readingProgressLabel: String { additionalUsageLabel(for: readingProgressBytes) }
    var browsingHistoryLabel: String { additionalUsageLabel(for: browsingHistoryBytes) }
    var networkLogLabel: String { additionalUsageLabel(for: networkLogBytes) }

    var summary: SettingsStorageSummary {
        var categories: [SettingsStorageCategoryUsage] = [
            .init(category: .webReader, bytes: webReaderCacheBytes),
            .init(category: .images, bytes: imageCacheBytes),
            .init(category: .other, bytes: otherCacheBytes),
            .init(category: .covers, bytes: contentCoverBytes),
            .init(category: .progress, bytes: readingProgressBytes)
        ]
        categories.append(.init(category: .history, bytes: browsingHistoryBytes))
        categories.append(.init(category: .directories, bytes: mangaDirectoryCacheBytes))
        categories.append(.init(category: .downloads, bytes: downloadBytes))
        categories.append(.init(category: .networkLogs, bytes: networkLogBytes))
        return SettingsStorageSummary(categories: categories, hasLoaded: hasLoadedAdditionalUsage)
    }

    func refresh(includeAdditionalUsage: Bool = true) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let novelBytes = await dependencies.novelReaderCacheStore.totalDiskUsageBytes()
        let mangaProjectionBytes = await dependencies.mangaReaderProjectionStore.totalDiskUsageBytes()
        let forumBytes = await dependencies.forumCacheStore.totalDiskUsageBytes()
        let directoryBytes = await dependencies.mangaDirectoryStore.totalDiskUsageBytes()
        let offlineBytes = await dependencies.downloadStore.totalDiskUsageBytes()
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
            historyBytes = try? await dependencies.library.browsingHistoryStore.estimatedDataUsageBytes()
        }
        let coverBytes = try? await dependencies.contentCoverStore.totalDiskUsageBytes()
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        webReaderCacheBytes = novelBytes + mangaProjectionBytes + forumBytes
        contentCoverBytes = coverBytes
        mangaDirectoryCacheBytes = directoryBytes
        downloadBytes = offlineBytes
        if includeAdditionalUsage {
            imageCacheBytes = imageBytes
            otherCacheBytes = otherBytes
            readingProgressBytes = progressBytes
            browsingHistoryBytes = historyBytes
            hasLoadedAdditionalUsage = true
        }
        await refreshNetworkLogUsage()
    }

    func observeNetworkLogUsage() async {
        let changes = await dependencies.networkLogStore.changes()
        let clock = ContinuousClock()
        var lastRefresh: ContinuousClock.Instant?
        for await _ in changes {
            guard !Task.isCancelled else { return }
            if let lastRefresh {
                do {
                    try await clock.sleep(until: lastRefresh.advanced(by: .milliseconds(250)))
                } catch { return }
            }
            guard !Task.isCancelled else { return }
            lastRefresh = clock.now
            await refreshNetworkLogUsage()
        }
    }

    private func refreshNetworkLogUsage() async {
        networkLogRefreshGeneration += 1
        let generation = networkLogRefreshGeneration
        let bytes = try? await dependencies.networkLogStore.usageBytes()
        guard generation == networkLogRefreshGeneration, !Task.isCancelled else { return }
        networkLogBytes = bytes.map { Int(clamping: $0) }
    }

    func resetToZero() {
        refreshGeneration += 1
        networkLogRefreshGeneration += 1
        webReaderCacheBytes = 0
        contentCoverBytes = 0
        mangaDirectoryCacheBytes = 0
        downloadBytes = 0
        imageCacheBytes = 0
        otherCacheBytes = 0
        readingProgressBytes = 0
        browsingHistoryBytes = 0
        networkLogBytes = 0
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
