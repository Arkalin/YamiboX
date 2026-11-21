import Foundation

extension FavoriteLibraryDocument {
    public mutating func upsertItem(_ item: FavoriteItem) {
        removeItem(target: item.target)
        items.append(Self.normalizedItem(item, categories: categories, collections: collections, tags: tags))
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
        let resolvedLocation = location ?? .category(defaultCategory.id)
        let threadID = probeResult.target.threadID
        if let existingTarget = items.first(where: { $0.target.threadID == threadID })?.target,
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
            items[index].contentUpdatedAt = [probeResult.contentUpdatedAt, items[index].contentUpdatedAt].compactMap { $0 }.max()
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

    public mutating func recordContentUpdate(for target: FavoriteItemTarget, contentUpdatedAt: Date) {
        for index in items.indices where items[index].target == target {
            guard items[index].contentUpdatedAt.map({ $0 >= contentUpdatedAt }) != true else { continue }
            items[index].contentUpdatedAt = contentUpdatedAt
        }
    }

    public mutating func removeItem(target: FavoriteItemTarget, date: Date = .now) {
        guard items.contains(where: { $0.target.id == target.id }) else { return }
        items.removeAll { $0.target.id == target.id }
        deletedItemIDs[target.id] = date
    }

    public mutating func removeItems(
        targets: [FavoriteItemTarget],
        now: () -> Date = { .now }
    ) {
        guard !targets.isEmpty else { return }
        let liveIDs = Set(items.map { $0.target.id })
        var dates: [String: Date] = [:]
        for target in targets {
            let date = now()
            let id = target.id
            guard liveIDs.contains(id), dates[id] == nil else { continue }
            dates[id] = date
        }
        guard !dates.isEmpty else { return }
        items.removeAll { dates[$0.target.id] != nil }
        deletedItemIDs.merge(dates, uniquingKeysWith: { _, new in new })
    }

    public mutating func updateRemoteMapping(
        for target: FavoriteItemTarget,
        yamiboFavoriteID: String?,
        yamiboRemoteOrder: Int?,
        date: Date = .now
    ) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        updateRemoteMapping(at: index, yamiboFavoriteID: yamiboFavoriteID, yamiboRemoteOrder: yamiboRemoteOrder, date: date)
    }

    mutating func updateRemoteMapping(
        at index: Int,
        yamiboFavoriteID: String?,
        yamiboRemoteOrder: Int?,
        date: Date = .now
    ) {
        var mapping = items[index].remoteMapping ?? FavoriteRemoteMapping()
        mapping.yamiboFavoriteID = FavoriteRemoteIdentity.normalizedID(yamiboFavoriteID)
            ?? FavoriteRemoteIdentity.normalizedID(mapping.yamiboFavoriteID)
        mapping.yamiboRemoteOrder = yamiboRemoteOrder ?? mapping.yamiboRemoteOrder
        mapping.lastSeenAt = date
        items[index].remoteMapping = mapping
        items[index].remoteMappingUpdatedAt = date
        items[index].updatedAt = date
    }

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
        if oldTarget != newTarget { replacement.contentUpdatedAt = nil }
        if oldTarget.id == newTarget.id {
            items[index] = replacement
            sortItems()
            return
        }
        if let duplicateIndex = items.firstIndex(where: { $0.target.id == newTarget.id }) {
            replacement.contentUpdatedAt = items[duplicateIndex].contentUpdatedAt
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
        deletedItemIDs[oldTarget.id] = date
        deletedItemIDs.removeValue(forKey: newTarget.id)
    }

    public mutating func addLocation(_ location: FavoriteLocation, to target: FavoriteItemTarget, date: Date = .now) {
        guard let index = items.firstIndex(where: { $0.target.id == target.id }) else { return }
        addLocation(location, at: index, date: date)
    }

    mutating func addLocation(_ location: FavoriteLocation, at index: Int, date: Date = .now) {
        let isNewLocation = !items[index].locations.contains(location)
        items[index].locations = FavoriteItem.normalizedLocations(items[index].locations + [location])
        items[index] = Self.normalizedItem(items[index], categories: categories, collections: collections, tags: tags)
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
