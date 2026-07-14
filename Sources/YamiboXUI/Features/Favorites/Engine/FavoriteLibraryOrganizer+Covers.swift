import Foundation
import YamiboXCore

extension FavoriteLibraryOrganizer {

    // MARK: - Manga directory grouping (smart-comic-mode decision #3/#5)

    /// Resolves the tid → `MangaDirectory` map virtual favorites grouping
    /// needs, in exactly one batched query — the design doc's performance
    /// constraint #1. `items` is first narrowed in memory (no I/O) to
    /// mode-on `.mangaThread` favorites only, using the *explicit*
    /// `BoardReaderSettings.isSmartComicModeEnabled(forumID:)` check (never a proxy
    /// signal — this exact class of bug bit three earlier phases), before
    /// the single `MangaDirectoryStore.directories(containingTIDs:)` round
    /// trip. Called only from `load()`/`reload()`, never from
    /// `refreshDerivedState()` or any SwiftUI-observed computed property —
    /// performance constraint #2.
    func resolveMangaDirectories(
        for items: [FavoriteItem],
        boardReaderSettings: BoardReaderSettings
    ) async -> [String: MangaDirectory] {
        guard let mangaDirectoryStore else { return [:] }
        let candidateTIDs = items.compactMap { item -> String? in
            guard item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else {
                return nil
            }
            return item.target.threadID
        }
        guard !candidateTIDs.isEmpty else { return [:] }
        do {
            return try await mangaDirectoryStore.directories(containingTIDs: candidateTIDs)
        } catch {
            YamiboLog.persistence.warning("Failed to resolve manga directories for favorites grouping; showing manga favorites standalone this load: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Covers

    /// Cover state for card display, keyed by the same `ContentCoverKey`
    /// each card's `contentCoverKey` resolves. `.thread` and `.smartManga`
    /// keys share the one keyspace; the two loaders below each fill their
    /// own disjoint slice of it.
    struct ContentCoverLookup {
        var urlsByKey: [ContentCoverKey: URL] = [:]
        var forcedKeys: Set<ContentCoverKey> = []

        /// The two slices' key spaces are disjoint (`.thread` vs
        /// `.smartManga` target types), so merging is purely additive.
        func merging(_ other: ContentCoverLookup) -> ContentCoverLookup {
            ContentCoverLookup(
                urlsByKey: urlsByKey.merging(other.urlsByKey) { _, new in new },
                forcedKeys: forcedKeys.union(other.forcedKeys)
            )
        }

        /// Replaces only the `.smartManga` entries, leaving `.thread`
        /// entries untouched — for callers that re-resolved directories or
        /// settings without re-reading every favorite's own thread cover.
        mutating func replaceSmartMangaSlice(with smart: ContentCoverLookup) {
            urlsByKey = urlsByKey.filter { $0.key.targetType != .smartManga }
                .merging(smart.urlsByKey) { _, new in new }
            forcedKeys = forcedKeys.filter { $0.targetType != .smartManga }
                .union(smart.forcedKeys)
        }
    }

    /// The per-favorite `.thread(tid:)` cover slice. `.smartManga` covers
    /// for resolved directories come from `smartMangaCoverLookup(for:)` and
    /// merge into the same keyspace.
    func loadContentCovers(for items: [FavoriteItem]) async -> ContentCoverLookup {
        // Batched into one `ContentCoverStore.covers(for:)` read transaction
        // instead of one actor round-trip + GRDB read per item — an N+1 that
        // scaled linearly with the whole favorites library on every
        // load()/reload().
        let keys = items.compactMap { ContentCoverKey(target: $0.target) }
        let covers = await contentCoverStore.covers(for: keys)
        var lookup = ContentCoverLookup()
        for key in keys {
            guard let cover = covers[key] else { continue }
            if let resolvedURL = cover.resolvedURL {
                lookup.urlsByKey[key] = resolvedURL
            }
            if cover.textCoverForced {
                lookup.forcedKeys.insert(key)
            }
        }
        return lookup
    }

    /// Toggles whether the card shows the text placeholder cover instead of
    /// its resolved automatic/manual cover (card context-menu action).
    /// Takes the whole card, not just `card.item`, because the key to write
    /// is the key the card's cover actually reads (`card.contentCoverKey`):
    /// a resolved-directory smart card displays the directory's shared
    /// `.smartManga` cover, while the same `FavoriteItem` surfaced as a
    /// "查看归档收藏" member card displays its own `.thread` cover.
    @discardableResult
    func toggleTextCover(for card: FavoriteCardProjection) async -> Bool {
        guard let key = card.contentCoverKey else { return false }
        let forced = !coverLookup.forcedKeys.contains(key)
        do {
            try await contentCoverStore.setTextCoverForced(forced, for: key)
        } catch {
            YamiboLog.library.error("Failed to toggle text cover for \(card.item.id): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            return false
        }
        let cover = await contentCoverStore.cover(for: key)
        if cover?.textCoverForced == true {
            coverLookup.forcedKeys.insert(key)
        } else {
            coverLookup.forcedKeys.remove(key)
        }
        coverLookup.urlsByKey[key] = cover?.resolvedURL
        // Bumped so any in-flight reload racing this write (see
        // `coverLookupRevision`'s doc comment) detects it's now stale and
        // skips instead of clobbering this optimistic update.
        coverLookupRevision += 1
        refreshDerivedState()
        // Un-forcing a smart card whose `.smartManga` cover never resolved
        // leaves it imageless again — give the backfill a chance right away
        // instead of waiting for the next unrelated reload. (A no-op in
        // every other case: forced keys and covered groups are filtered out
        // of the backfill's own missing check.)
        scheduleMangaCoverBackfill(for: document.items)
        transientMessage = forced
            ? L10n.string("cover.use_text_cover_success_message")
            : L10n.string("cover.use_image_cover_success_message")
        return true
    }

    /// The `.smartManga(cleanBookName:)` cover slice for every currently-
    /// resolved directory (decision #13/#16) — the cover source for any card
    /// with a resolved `mangaDirectory`, merged or not.
    func smartMangaCoverLookup(for directories: [MangaDirectory]) async -> ContentCoverLookup {
        // Same batching as `loadContentCovers(for:)` above — one read
        // transaction for every directory's `.smartManga` key instead of one
        // actor round-trip per directory.
        let keys = directories.map { ContentCoverKey.smartManga(cleanBookName: $0.cleanBookName) }
        let covers = await contentCoverStore.covers(for: keys)
        var lookup = ContentCoverLookup()
        for key in keys {
            guard let cover = covers[key] else { continue }
            if let resolvedURL = cover.resolvedURL {
                lookup.urlsByKey[key] = resolvedURL
            }
            if cover.textCoverForced {
                lookup.forcedKeys.insert(key)
            }
        }
        return lookup
    }

    /// Resolves missing `.smartManga` covers for computed manga-directory
    /// groups (smart-comic-mode decision #13/#16). The old trigger —
    /// stored `.mangaTitle`-targeted favorites — is permanently gone since
    /// the Phase A type refactor (`FavoriteItemTarget` only has
    /// `.normalThread`/`.novelThread`/`.mangaThread`); this now triggers off
    /// `LocalFavoriteLibraryProjection.mangaDirectoryGroups` instead — the
    /// same mode-on `.mangaThread` favorites resolved to a directory that
    /// back the virtual merged-card grouping — using each group's earliest
    /// chapter tid, via the same `ThreadCoverResolver`/
    /// `ContentCoverStore.setAutomaticCover` mechanism the pre-Phase-A
    /// `.mangaTitle` implementation used. Standalone mode-off cards get
    /// their cover from `MangaReaderViewModel`'s Phase D auto-thread-cover
    /// resolution instead (when the user actually reads them), so they are
    /// deliberately not this function's concern.
    func scheduleMangaCoverBackfill(for items: [FavoriteItem]) {
        guard let makeForumThreadReaderRepository, mangaCoverBackfillTask == nil else { return }
        let groups = LocalFavoriteLibraryProjection.mangaDirectoryGroups(
            for: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        let missing = groups.filter { group in
            let key = ContentCoverKey.smartManga(cleanBookName: group.directory.cleanBookName)
            return coverLookup.urlsByKey[key] == nil
                // A text-cover-forced group resolves no URL above, but it is
                // a deliberate "no image", not a missing cover — resolving
                // an automatic URL for it would be wasted network every
                // session (the forced flag suppresses whatever resolves).
                && !coverLookup.forcedKeys.contains(key)
                && !attemptedMangaCoverTargetIDs.contains(key.targetID)
        }
        guard !missing.isEmpty else { return }
        // Marked attempted synchronously, before the resolution task even
        // starts, so a reload firing again (from an unrelated favorite/
        // progress change) while this batch is still in flight doesn't
        // re-attempt the same groups.
        attemptedMangaCoverTargetIDs.formUnion(
            missing.map { ContentCoverKey.smartManga(cleanBookName: $0.directory.cleanBookName).targetID }
        )
        mangaCoverBackfillTask = Task { [weak self, contentCoverStore] in
            defer { self?.mangaCoverBackfillTask = nil }
            let repository = await makeForumThreadReaderRepository()
            let resolver = ThreadCoverResolver()
            for group in missing {
                if Task.isCancelled { return }
                let key = ContentCoverKey.smartManga(cleanBookName: group.directory.cleanBookName)
                // `resolvedURL` alone is not enough here: a text-cover-forced
                // row resolves nil even when a URL is stored, and overwriting
                // its automatic URL for a cover the flag suppresses anyway
                // would be wasted work.
                if let existing = await contentCoverStore.cover(for: key),
                   existing.textCoverForced || existing.resolvedURL != nil {
                    continue
                }
                guard let firstChapter = group.directory.chapters.first else { continue }
                guard let coverURL = await resolver.resolve(
                    thread: ThreadIdentity(tid: firstChapter.tid),
                    title: group.directory.cleanBookName,
                    repository: repository
                ) else {
                    continue
                }
                do {
                    _ = try await contentCoverStore.setAutomaticCover(coverURL, for: key)
                } catch {
                    YamiboLog.persistence.error("Failed to set automatic smartManga cover for \(group.directory.cleanBookName): \(error.localizedDescription)")
                }
                // `setAutomaticCover` posts `ContentCoverStore
                // .didChangeNotification` on success, which this organizer
                // already subscribes to (`coverUpdatesTask` →
                // `reloadContentCovers()`), so no manual state refresh is
                // needed here.
            }
        }
    }
}
