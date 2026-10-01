import Foundation
import YamiboXCore

/// Owns cover snapshots, stale-read admission, store observation and backfill
/// lifetime. The organizer only supplies grouping inputs and consumes output.
@MainActor
final class FavoriteCoverCoordinator {
    struct Context {
        var items: [FavoriteItem]
        var directories: [MangaDirectory]
    }

    struct Lookup: Equatable {
        var urlsByKey: [ContentCoverKey: URL] = [:]
        var forcedKeys: Set<ContentCoverKey> = []

    }

    private(set) var lookup = Lookup()
    private var context = Context(items: [], directories: [])
    var onChange: (() -> Void)?

    private let store: ContentCoverStore
    private let makeRepository: (@Sendable () async -> any ThreadCoverPageResolving)?
    private var revision: UInt64 = 0
    private var coverRevision: UInt64 = 0
    private var loadedKeys: Set<ContentCoverKey> = []
    private var observationTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var attemptedTargetIDs: Set<String> = []

    init(store: ContentCoverStore, makeRepository: (@Sendable () async -> any ThreadCoverPageResolving)?) {
        self.store = store
        self.makeRepository = makeRepository
        observationTask = StoreChangeObservation.task(
            changes: { store.changes() }, changeID: { store.changeID }
        ) { [weak self] in
            // Coalesce bursts, not the whole backfill network lifetime. Manual
            // edits and completed covers remain visible while later books load.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    deinit {
        observationTask?.cancel()
        backfillTask?.cancel()
    }

    func refresh(_ context: Context) async {
        self.context = context
        await reload(notifyChanges: false)
    }

    private func reload(notifyChanges: Bool = true) async {
        revision &+= 1
        let expectedRevision = revision
        let keys = Set(context.items.compactMap { ContentCoverKey(target: $0.target) }
            + context.directories.map { ContentCoverKey.smartManga(directoryID: $0.id) })
        let changes = store.changedCoverKeys(since: coverRevision, among: keys)
        let isFullRefresh = !notifyChanges || keys != loadedKeys
        let requestedKeys = isFullRefresh ? keys : changes.keys
        guard isFullRefresh || !requestedKeys.isEmpty else {
            coverRevision = changes.revision
            return
        }
        let changed = await load(keys: Array(requestedKeys))
        guard !Task.isCancelled, revision == expectedRevision else { return }
        var snapshot = isFullRefresh ? Lookup() : lookup
        for key in requestedKeys {
            snapshot.urlsByKey[key] = changed.urlsByKey[key]
            if changed.forcedKeys.contains(key) { snapshot.forcedKeys.insert(key) }
            else { snapshot.forcedKeys.remove(key) }
        }
        loadedKeys = keys
        coverRevision = changes.revision
        guard lookup != snapshot else { return }
        lookup = snapshot
        // Explicit refresh callers publish the document and covers together.
        // Store-driven refreshes notify the organizer independently.
        if notifyChanges { onChange?() }
    }

    func refreshSmartManga(_ directories: [MangaDirectory]) async {
        context.directories = directories
        await reload(notifyChanges: false)
    }

    /// Return the requested flag for presentation; re-read the persisted value
    /// before publishing so concurrent mutations remain authoritative.
    func toggleTextCover(for key: ContentCoverKey) async throws -> Bool {
        let forced = !lookup.forcedKeys.contains(key)
        try await store.setTextCoverForced(forced, for: key)
        await reload()
        return forced
    }

    private func load(keys: [ContentCoverKey]) async -> Lookup {
        let covers = await store.covers(for: keys)
        var result = Lookup()
        for key in keys {
            guard let cover = covers[key] else { continue }
            result.urlsByKey[key] = cover.resolvedURL
            if cover.textCoverForced { result.forcedKeys.insert(key) }
        }
        return result
    }

    func scheduleBackfill(for groups: [MangaDirectoryFavoriteGroup]) {
        guard let makeRepository, backfillTask == nil else { return }
        let missing = groups.filter { group in
            let key = ContentCoverKey.smartManga(directoryID: group.directory.id)
            return lookup.urlsByKey[key] == nil
                && !lookup.forcedKeys.contains(key)
                && !attemptedTargetIDs.contains(key.targetID)
        }
        guard !missing.isEmpty else { return }
        attemptedTargetIDs.formUnion(missing.map { ContentCoverKey.smartManga(directoryID: $0.directory.id).targetID })
        backfillTask = Task { [weak self, store] in
            defer {
                self?.backfillTask = nil
                Task { [weak self] in await self?.reload() }
            }
            let service = MangaAutomaticCoverService(store: store)
            for group in missing {
                guard !Task.isCancelled else { return }
                do {
                    try await service.fillMissingCover(for: group.directory, makeRepository: makeRepository)
                } catch is CancellationError {
                    return
                } catch {
                    YamiboLog.persistence.error("Failed to set automatic smartManga cover for \(group.directory.cleanBookName): \(error.localizedDescription)")
                }
                // The store's change stream refreshes the snapshot after commit.
            }
        }
    }
}
