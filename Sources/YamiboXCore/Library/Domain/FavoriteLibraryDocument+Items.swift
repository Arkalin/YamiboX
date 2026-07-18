import Foundation

// Item-level mutations of the favorites library document: upsert/import,
// retargeting and healing, remote-mapping refresh, and location
// membership. Split from the former monolithic FavoriteLibrary.swift;
// method bodies moved verbatim.
extension FavoriteLibraryDocument {
    /// Inserts `item`, replacing any existing item with the same target —
    /// an upsert, not a plain append. (Terminology: `upsert*` writes the
    /// local document directly; `import*` materializes a remote favorite
    /// locally during sync; pushing local→Yamibo lives in the UI action
    /// layer as `push*`.)
    public mutating func upsertItem(_ item: FavoriteItem) {
        removeItem(target: item.target)
        items.append(Self.normalizedItem(item, categories: categories, collections: collections, tags: tags))
        // This id is being actively kept alive, not deleted — clear any
        // tombstone `removeItem` above just wrote for it (target ids are
        // content-derived, so re-favoriting a previously removed thread
        // reuses the same id) so a merge doesn't treat the live item as
        // still-deleted.
        deletedItemIDs.removeValue(forKey: item.target.id)
        sortItems()
    }

    @discardableResult
    public mutating func importThreadFavorite(
        threadID: String,
        displayName: String? = nil,
        location: FavoriteLocation? = nil,
        remoteMapping: FavoriteRemoteMapping? = nil,
        date: Date = .now,
        probe: (String) async throws -> FavoriteThreadProbeResult
    ) async throws -> FavoriteItem {
        do {
            let normalizedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await probe(normalizedThreadID)
            return try importThreadFavorite(
                probeResult: result,
                displayName: displayName,
                location: location,
                remoteMapping: remoteMapping,
                date: date
            )
        } catch let failure as FavoriteThreadImportFailure {
            throw failure
        } catch {
            throw FavoriteThreadImportFailure.probeFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public mutating func importThreadFavorite(
        probeResult: FavoriteThreadProbeResult,
        displayName: String? = nil,
        location: FavoriteLocation? = nil,
        remoteMapping: FavoriteRemoteMapping? = nil,
        date: Date = .now
    ) throws -> FavoriteItem {
        // All three `FavoriteItemTargetKind` cases are plain per-thread
        // favorites now (there is no merged-directory kind on this type at
        // all), so a manga chapter thread imports through this same generic
        // path as a normal/novel thread — see step 3 of the smart-comic-mode
        // Phase A report for why the old dedicated
        // `importMangaChapterFavorite` mechanism was removed instead of kept.
        let resolvedLocation = location ?? .category(defaultCategory.id)
        if let existingThreadID = probeResult.target.threadID,
           let existingTarget = items.first(where: { $0.target.threadID == existingThreadID })?.target,
           existingTarget.id != probeResult.target.id {
            retargetItem(from: existingTarget, to: probeResult.target, date: date)
        }

        if let index = items.firstIndex(where: { $0.target.id == probeResult.target.id }) {
            items[index].title = probeResult.title
            if probeResult.sourceGroup != .unknown || probeResult.forumID != nil {
                items[index].sourceGroup = probeResult.sourceGroup
                items[index].forumID = probeResult.forumID
                items[index].forumName = probeResult.forumName
            }
            items[index].contentUpdatedAt = probeResult.contentUpdatedAt ?? items[index].contentUpdatedAt
            if let remoteMapping {
                items[index].remoteMapping = remoteMapping
                items[index].remoteMappingUpdatedAt = date
            }
            if let displayName = displayName?.nilIfBlank {
                items[index].displayName = displayName
                items[index].displayNameUpdatedAt = date
            }
            let locationsBeforeImport = items[index].locations
            items[index].locations = FavoriteItem.normalizedLocations(items[index].locations + [resolvedLocation])
            if items[index].locations != locationsBeforeImport {
                items[index].locationsUpdatedAt = date
            }
            items[index].updatedAt = date
            items[index] = Self.normalizedItem(items[index], categories: categories, collections: collections, tags: tags)
            return items[index]
        }

        let item = try FavoriteItem(
            target: probeResult.target,
            title: probeResult.title,
            displayName: displayName,
            sourceGroup: probeResult.sourceGroup,
            forumID: probeResult.forumID,
            forumName: probeResult.forumName,
            contentUpdatedAt: probeResult.contentUpdatedAt,
            remoteMapping: remoteMapping,
            locations: [resolvedLocation],
            createdAt: date,
            updatedAt: date
        )
        upsertItem(item)
        return item
    }

    public func openRoute(for item: FavoriteItem) -> FavoriteItemOpenRoute {
        switch item.target {
        case let .normalThread(threadID):
            .nativeThread(threadID: threadID)
        case let .novelThread(threadID):
            .novelDetail(threadID: threadID)
        case let .mangaThread(threadID):
            .mangaThread(threadID: threadID)
        }
    }

    // `addMangaTitleFavorite`/`importMangaChapterFavorite`/
    // `mangaRetargetCandidateIndex` (the dormant merged-directory favorite
    // mechanism) and `renameMangaTitle` (its rename counterpart) were removed
    // in the smart-comic-mode Phase A type refactor — see decision #3/#9.
    // `FavoriteItemTarget` cannot represent that identity at all anymore, so
    // there is nothing left for these to operate on; manga chapter favorites
    // now import through the same `importThreadFavorite` path as any other
    // thread (see the comment above it), and a manga directory rename no
    // longer needs to touch favorites at all since `.mangaThread` favorites
    // are keyed by thread id, not by the directory's cleanBookName — see
    // `MangaReaderViewModel.migrateMangaTitleReferences` for the remaining
    // (reading-progress-only) half of that migration.

    public mutating func removeItem(target: FavoriteItemTarget, date: Date = .now) {
        guard items.contains(where: { $0.target.id == target.id }) else { return }
        items.removeAll { $0.target.id == target.id }
        deletedItemIDs[target.id] = date
    }

    /// Refreshes the Yamibo remote mapping after a sync run saw the item on
    /// the website. Passing nil keeps the previously known value.
    public mutating func updateRemoteMapping(
        for target: FavoriteItemTarget,
        yamiboFavoriteID: String?,
        yamiboRemoteOrder: Int?,
        date: Date = .now
    ) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        var mapping = items[index].remoteMapping ?? FavoriteRemoteMapping()
        mapping.yamiboFavoriteID = yamiboFavoriteID ?? mapping.yamiboFavoriteID
        mapping.yamiboRemoteOrder = yamiboRemoteOrder ?? mapping.yamiboRemoteOrder
        mapping.lastSeenAt = date
        items[index].remoteMapping = mapping
        items[index].remoteMappingUpdatedAt = date
        items[index].updatedAt = date
    }

    /// Heals a `.unknown` source group once the actual forum resolves (e.g.
    /// the favorite-update checker fetched the thread and learned its fid).
    /// Items whose forum never resolved at add-time would otherwise never
    /// regain one, which permanently excludes them from fid-scoped features
    /// (like the update-check filter) once the user disables any other
    /// forum's filter. No-ops if the item already has a resolved source
    /// group, so this never clobbers a value obtained elsewhere.
    public mutating func healUnknownSourceGroup(for target: FavoriteItemTarget, forumID: String, forumName: String?, date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }),
              items[index].sourceGroup == .unknown else {
            return
        }
        let metadata = FavoriteSourceGroup.normalizedForumMetadata(
            sourceGroup: .forumBoard(id: forumID, label: forumName ?? forumID),
            forumID: forumID,
            forumName: forumName
        )
        guard case .forumBoard = metadata.sourceGroup else { return }
        items[index].sourceGroup = metadata.sourceGroup
        items[index].forumID = metadata.forumID
        items[index].forumName = metadata.forumName
        items[index].updatedAt = date
    }

    public mutating func retargetItem(from oldTarget: FavoriteItemTarget, to newTarget: FavoriteItemTarget, date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.target.id == oldTarget.id }) else { return }
        var replacement = items[index]
        replacement.target = newTarget
        if oldTarget.id == newTarget.id {
            items[index] = replacement
            sortItems()
            return
        }
        if let duplicateIndex = items.firstIndex(where: { $0.target.id == newTarget.id }) {
            replacement.locations = FavoriteItem.normalizedLocations(items[duplicateIndex].locations + replacement.locations)
            replacement.tagIDs = FavoriteItem.normalizedIDs(items[duplicateIndex].tagIDs + replacement.tagIDs)
            replacement.locationsUpdatedAt = date
            replacement.tagIDsUpdatedAt = date
            items.remove(at: duplicateIndex)
        }
        replacement.updatedAt = date
        if let updatedIndex = items.firstIndex(where: { $0.target.id == oldTarget.id }) {
            items[updatedIndex] = replacement
        } else {
            items.append(replacement)
        }
        sortItems()
        // `oldTarget.id` no longer exists in `items` after this — tombstone
        // it so a stale peer's copy under the old id isn't revived as a
        // duplicate favorite on the next merge (see `deletedItemIDs`'s doc
        // comment). `newTarget.id` is now very much alive, so clear any
        // stale tombstone it might carry from a prior deletion, mirroring
        // `upsertItem`'s own resurrection handling.
        deletedItemIDs[oldTarget.id] = date
        deletedItemIDs.removeValue(forKey: newTarget.id)
    }

    public mutating func addLocation(_ location: FavoriteLocation, to target: FavoriteItemTarget, date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        let isNewLocation = !items[index].locations.contains(location)
        items[index].locations = FavoriteItem.normalizedLocations(items[index].locations + [location])
        items[index] = Self.normalizedItem(items[index], categories: categories, collections: collections, tags: tags)
        // Only a genuinely new location should advance the merge clock — a
        // no-op add (already a member) must not let this call's timestamp
        // spuriously outrun a real, unsynced edit from another device.
        guard isNewLocation else { return }
        items[index].locationsUpdatedAt = date
        items[index].updatedAt = date
    }

    @discardableResult
    public mutating func removeLocation(_ location: FavoriteLocation, from target: FavoriteItemTarget, date: Date = .now) -> Bool {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }),
              items[index].locations.contains(location) else { return false }
        let remaining = items[index].locations.filter { $0 != location }
        guard !remaining.isEmpty else { return false }
        items[index].locations = remaining
        items[index].locationsUpdatedAt = date
        items[index].updatedAt = date
        return true
    }

    private mutating func sortItems() {
        items.sort { lhs, rhs in lhs.id < rhs.id }
    }
}
