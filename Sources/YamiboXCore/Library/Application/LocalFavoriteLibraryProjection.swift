import Foundation

public enum LocalFavoriteLibraryProjection {
    public struct MetadataIndex: Sendable {
        fileprivate let collections: [LocalFavoriteCollection]
        fileprivate let tags: [FavoriteTag]
        fileprivate let collectionsByID: [String: [(rank: Int, name: String)]]
        fileprivate let tagsByID: [String: [(rank: Int, tag: FavoriteTag)]]

        public init(document: FavoriteLibraryDocument) {
            collections = document.collections
            tags = document.tags
            let orderedCollections = collections.enumerated().sorted { lhs, rhs in
                if lhs.element.manualOrder != rhs.element.manualOrder {
                    return lhs.element.manualOrder < rhs.element.manualOrder
                }
                if lhs.element.id != rhs.element.id { return lhs.element.id < rhs.element.id }
                return lhs.offset < rhs.offset
            }
            let orderedTags = tags.enumerated().sorted { lhs, rhs in
                if lhs.element.manualOrder != rhs.element.manualOrder {
                    return lhs.element.manualOrder < rhs.element.manualOrder
                }
                if lhs.element.id != rhs.element.id { return lhs.element.id < rhs.element.id }
                return lhs.offset < rhs.offset
            }
            var collectionLookup: [String: [(rank: Int, name: String)]] = [:]
            for (rank, entry) in orderedCollections.enumerated() {
                collectionLookup[entry.element.id, default: []].append((rank, entry.element.name))
            }
            var tagLookup: [String: [(rank: Int, tag: FavoriteTag)]] = [:]
            for (rank, entry) in orderedTags.enumerated() {
                tagLookup[entry.element.id, default: []].append((rank, entry.element))
            }
            collectionsByID = collectionLookup
            tagsByID = tagLookup
        }

        fileprivate func matches(_ document: FavoriteLibraryDocument) -> Bool {
            collections == document.collections && tags == document.tags
        }
    }

    public static var supportedSortOrders: [LocalFavoriteLibrarySortOrder] {
        LocalFavoriteLibrarySortOrder.allCases
    }

    public static func cards(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery = LocalFavoriteLibraryQuery(),
        readingProgress: [ReadingProgressRecord] = [],
        mangaDirectoriesByTID: [String: MangaDirectory] = [:],
        boardReaderSettings: BoardReaderSettings = BoardReaderSettings(),
        mangaThreadItemsByGroupKey: [String: [FavoriteItem]]? = nil,
        metadataIndex: MetadataIndex? = nil
    ) -> [FavoriteCardProjection] {
        let categoryID = query.categoryID ?? document.defaultCategory.id
        let progressByKey = readingProgressLookup(readingProgress)
        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMangaThreadItemsByEffectiveTitle = mangaThreadItemsByGroupKey ?? Self.mangaThreadItemsByGroupKey(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )

        let entries: [GroupedFavoriteEntry]
        let isMemberScoped = query.memberScopeGroupKey != nil
        if let memberScopeGroupKey = query.memberScopeGroupKey {
            entries = (resolvedMangaThreadItemsByEffectiveTitle[memberScopeGroupKey] ?? [])
                .map { GroupedFavoriteEntry(representativeItem: $0, members: nil, mangaDirectory: nil) }
        } else {
            entries = groupedCardEntries(
                for: document.items,
                mangaDirectoriesByTID: mangaDirectoriesByTID,
                boardReaderSettings: boardReaderSettings
            )
        }

        let scopedEntries = entries.filter { entry in
            guard !isMemberScoped else { return true }
            if let collectionID = query.collectionID {
                return entry.representativeItem.locations.contains(.collection(categoryID: categoryID, collectionID: collectionID))
            }
            return entry.representativeItem.locations.contains(.category(categoryID))
        }

        let cards = mappedCards(
            from: scopedEntries,
            metadata: metadataIndex.flatMap { $0.matches(document) ? $0 : nil } ?? MetadataIndex(document: document),
            query: query,
            isMemberScoped: isMemberScoped,
            progressByKey: progressByKey,
            trimmedSearch: trimmedSearch,
            boardReaderSettings: boardReaderSettings,
            resolvedMangaThreadItemsByEffectiveTitle: resolvedMangaThreadItemsByEffectiveTitle
        )

        return sorted(cards, by: query.sortOrder, descending: query.sortsDescending)
    }

    public static func cardsAcrossAllScopes(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery = LocalFavoriteLibraryQuery(),
        readingProgress: [ReadingProgressRecord] = [],
        mangaDirectoriesByTID: [String: MangaDirectory] = [:],
        boardReaderSettings: BoardReaderSettings = BoardReaderSettings(),
        mangaThreadItemsByGroupKey: [String: [FavoriteItem]]? = nil,
        metadataIndex: MetadataIndex? = nil
    ) -> [FavoriteCardProjection] {
        let progressByKey = readingProgressLookup(readingProgress)
        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMangaThreadItemsByEffectiveTitle = mangaThreadItemsByGroupKey ?? Self.mangaThreadItemsByGroupKey(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        let entries = groupedCardEntries(
            for: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        return mappedCards(
            from: entries,
            metadata: metadataIndex.flatMap { $0.matches(document) ? $0 : nil } ?? MetadataIndex(document: document),
            query: query,
            isMemberScoped: false,
            progressByKey: progressByKey,
            trimmedSearch: trimmedSearch,
            boardReaderSettings: boardReaderSettings,
            resolvedMangaThreadItemsByEffectiveTitle: resolvedMangaThreadItemsByEffectiveTitle
        )
    }

    private static func mappedCards(
        from entries: [GroupedFavoriteEntry],
        metadata: MetadataIndex,
        query: LocalFavoriteLibraryQuery,
        isMemberScoped: Bool,
        progressByKey: [String: ReadingProgressRecord],
        trimmedSearch: String,
        boardReaderSettings: BoardReaderSettings,
        resolvedMangaThreadItemsByEffectiveTitle: [String: [FavoriteItem]]
    ) -> [FavoriteCardProjection] {
        entries
            .filter { entry in
                query.selectedSourceFilters.isEmpty
                    || query.selectedSourceFilters.contains { $0.matches(entry.representativeItem) }
            }
            .filter { entry in
                query.selectedTagIDs.isEmpty || query.selectedTagIDs.isSubset(of: Set(entry.representativeItem.tagIDs))
            }
            .map { entry -> FavoriteCardProjection in
                let resolvedProgress = progress(for: entry, progressByKey: progressByKey, boardReaderSettings: boardReaderSettings)
                let isModeOnMangaThread = isMemberScoped
                    ? false
                    : (entry.representativeItem.target.kind == .mangaThread
                        && boardReaderSettings.isSmartComicModeEnabled(forumID: entry.representativeItem.forumID))
                var cardEntry = entry
                if isModeOnMangaThread {
                    let effectiveTitle = FavoriteCardProjection.groupKey(item: entry.representativeItem, mangaDirectory: entry.mangaDirectory)
                    let archived = resolvedMangaThreadItemsByEffectiveTitle[effectiveTitle] ?? []
                    var unionTagIDs: [String] = []
                    var seenTagIDs: Set<String> = []
                    for item in archived {
                        for tagID in item.tagIDs where seenTagIDs.insert(tagID).inserted {
                            unionTagIDs.append(tagID)
                        }
                    }
                    cardEntry.representativeItem.tagIDs = FavoriteItem.normalizedIDs(unionTagIDs)
                }
                return card(for: cardEntry, metadata: metadata, progress: resolvedProgress, isModeOnMangaThread: isModeOnMangaThread)
            }
            .filter { card in
                guard !trimmedSearch.isEmpty else { return true }
                return searchFields(for: card).contains { field in
                    field.localizedCaseInsensitiveContains(trimmedSearch)
                }
            }
    }

    public static func archivedItems(
        matching cleanBookName: String,
        in items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [FavoriteItem] {
        mangaThreadItemsByGroupKey(
            in: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )[cleanBookName] ?? []
    }

    public static func mangaThreadItemsByGroupKey(
        in items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [String: [FavoriteItem]] {
        var itemsByEffectiveTitle: [String: [FavoriteItem]] = [:]
        for item in items {
            guard item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else {
                continue
            }
            let directory = mangaDirectoriesByTID[item.target.threadID]
            let effectiveTitle = FavoriteCardProjection.groupKey(item: item, mangaDirectory: directory)
            itemsByEffectiveTitle[effectiveTitle, default: []].append(item)
        }
        return itemsByEffectiveTitle
    }

    public static func mangaDirectoryGroups(
        for items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [MangaDirectoryFavoriteGroup] {
        rawGroupedFavorites(
            for: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        ).groups.map { raw in
            MangaDirectoryFavoriteGroup(directory: raw.directory, members: raw.members)
        }
    }

    public static func mixedEntries(
        cards: [FavoriteCardProjection],
        collections: [LocalFavoriteCollection],
        collectionSummaries: [String: FavoriteCollectionSortSummary],
        sortOrder: LocalFavoriteLibrarySortOrder,
        descending: Bool
    ) -> [FavoriteMixedEntry] {
        let entries = collections.map(FavoriteMixedEntry.collection) + cards.map(FavoriteMixedEntry.card)
        guard sortOrder != .organization else {
            return entries
        }
        let sortedEntries = entries.sorted { lhs, rhs in
            compareMixed(lhs, rhs, by: sortOrder, descending: descending, collectionSummaries: collectionSummaries)
        }
        switch sortOrder {
        case .contentUpdatedAt, .lastReadAt:
            return sortedEntries
        default:
            return descending ? sortedEntries.reversed() : sortedEntries
        }
    }

    public static func displayedEntryCount(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery = LocalFavoriteLibraryQuery(),
        readingProgress: [ReadingProgressRecord] = [],
        mangaDirectoriesByTID: [String: MangaDirectory] = [:],
        boardReaderSettings: BoardReaderSettings = BoardReaderSettings()
    ) -> Int {
        cards(
            in: document,
            query: query,
            readingProgress: readingProgress,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        ).count
    }

    private struct GroupedFavoriteEntry {
        var representativeItem: FavoriteItem
        var members: [FavoriteItem]?
        var mangaDirectory: MangaDirectory?
    }

    private struct RawMangaDirectoryGroup {
        var directory: MangaDirectory
        var members: [FavoriteItem]
    }

    private static func rawGroupedFavorites(
        for items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> (standalone: [FavoriteItem], groups: [RawMangaDirectoryGroup]) {
        guard !mangaDirectoriesByTID.isEmpty else {
            return (items, [])
        }

        var standalone: [FavoriteItem] = []
        var membersByDirectoryID: [MangaDirectoryID: [FavoriteItem]] = [:]
        var directoryByID: [MangaDirectoryID: MangaDirectory] = [:]

        for item in items {
            guard item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID),
                  let directory = mangaDirectoriesByTID[item.target.threadID] else {
                standalone.append(item)
                continue
            }
            directoryByID[directory.id] = directory
            membersByDirectoryID[directory.id, default: []].append(item)
        }

        let groups = membersByDirectoryID.compactMap { directoryID, members -> RawMangaDirectoryGroup? in
            guard let directory = directoryByID[directoryID] else { return nil }
            return RawMangaDirectoryGroup(directory: directory, members: orderedByChapter(members, in: directory))
        }
        return (standalone, groups)
    }

    private static func orderedByChapter(_ members: [FavoriteItem], in directory: MangaDirectory) -> [FavoriteItem] {
        let membersByThreadID = Dictionary(members.map { ($0.target.threadID, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = directory.chapters.compactMap { membersByThreadID[$0.tid] }
        return ordered.count == members.count ? ordered : members
    }

    private static func groupedCardEntries(
        for items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [GroupedFavoriteEntry] {
        let raw = rawGroupedFavorites(
            for: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        let standaloneEntries = raw.standalone.map {
            GroupedFavoriteEntry(representativeItem: $0, members: nil, mangaDirectory: nil)
        }
        let resolvedEntries = raw.groups.map(cardEntry(for:))
        return standaloneEntries + resolvedEntries
    }

    private static func cardEntry(for group: RawMangaDirectoryGroup) -> GroupedFavoriteEntry {
        let members = group.members
        precondition(!members.isEmpty, "RawMangaDirectoryGroup must have at least one member")
        var representative = members[0]
        var unionLocations: [FavoriteLocation] = []
        var seenLocations: Set<FavoriteLocation> = []
        for member in members {
            for location in member.locations where seenLocations.insert(location).inserted {
                unionLocations.append(location)
            }
        }
        representative.locations = FavoriteItem.normalizedLocations(unionLocations)

        return GroupedFavoriteEntry(
            representativeItem: representative,
            members: members.count > 1 ? members : nil,
            mangaDirectory: group.directory
        )
    }

    private static func progress(
        for entry: GroupedFavoriteEntry,
        progressByKey: [String: ReadingProgressRecord],
        boardReaderSettings: BoardReaderSettings
    ) -> ReadingProgressRecord? {
        if let directory = entry.mangaDirectory,
           let directoryProgress = progressByKey[directoryProgressKey(for: directory)] {
            return directoryProgress
        }
        let item = entry.representativeItem
        if let effectiveKey = effectiveProgressKey(for: item, boardReaderSettings: boardReaderSettings),
           let effectiveProgress = progressByKey[effectiveKey] {
            return effectiveProgress
        }
        return progressByKey[progressKey(for: item)]
    }

    private static func effectiveProgressKey(
        for item: FavoriteItem,
        boardReaderSettings: BoardReaderSettings
    ) -> String? {
        let threadID = item.target.threadID
        guard let mode = boardReaderSettings.entry(forumID: item.forumID)?.mode else {
            return nil
        }
        switch mode {
        case .normal:
            return FavoriteContentTarget.normalThread(threadID: threadID).id
        case .novel:
            return FavoriteContentTarget.novelThread(threadID: threadID).id
        case .manga:
            return FavoriteContentTarget.mangaThread(threadID: threadID).id
        }
    }

    private static func directoryProgressKey(for directory: MangaDirectory) -> String {
        FavoriteContentTarget(mangaID: directory.favoriteIdentity, mangaCleanBookName: directory.cleanBookName).id
    }

    private static func card(
        for entry: GroupedFavoriteEntry,
        metadata: MetadataIndex,
        progress: ReadingProgressRecord?,
        isModeOnMangaThread: Bool
    ) -> FavoriteCardProjection {
        let item = entry.representativeItem
        return FavoriteCardProjection(
            item: item,
            sourceGroupLabel: label(for: item.sourceGroup),
            collectionNames: collectionNames(for: item, metadata: metadata),
            tags: tags(for: item, metadata: metadata),
            recentReadingAt: progress?.lastReadAt,
            lastUpdatedAt: ([item.contentUpdatedAt]
                + (entry.members?.map(\.contentUpdatedAt) ?? [])
                + (isModeOnMangaThread ? (entry.mangaDirectory?.chapters.map(\.publishTime) ?? []) : []))
                .compactMap { $0 }.max(),
            progressPercent: progressPercent(from: progress),
            chapterPageProgress: chapterPageProgress(from: progress),
            coverSource: nil,
            textCoverForced: false,
            mangaDirectory: entry.mangaDirectory,
            mergedMembers: entry.members,
            isModeOnMangaThread: isModeOnMangaThread,
            resolvedTitle: FavoriteCardProjection.resolvedTitle(
                item: item,
                mangaDirectory: entry.mangaDirectory,
                isModeOnMangaThread: isModeOnMangaThread
            )
        )
    }

    private static func sortCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive], range: nil, locale: Locale(identifier: "zh_CN"))
    }

    private static func sorted(
        _ cards: [FavoriteCardProjection],
        by sortOrder: LocalFavoriteLibrarySortOrder,
        descending: Bool
    ) -> [FavoriteCardProjection] {
        let sortedCards = cards.sorted { lhs, rhs in
            switch sortOrder {
            case .organization:
                return compareOrganization(lhs, rhs)
            case .contentUpdatedAt:
                return compareDates(lhs.lastUpdatedAt, rhs.lastUpdatedAt, lhsID: lhs.id, rhsID: rhs.id, descending: descending)
            case .yamiboRemoteOrder:
                let lhsOrder = lhs.item.remoteMapping?.yamiboRemoteOrder ?? Int.max
                let rhsOrder = rhs.item.remoteMapping?.yamiboRemoteOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id < rhs.id
            case .displayTitle:
                let result = sortCompare(lhs.resolvedTitle, rhs.resolvedTitle)
                return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
            case .sourceGroup:
                let result = sortCompare(sourceGroupSortKey(for: lhs), sourceGroupSortKey(for: rhs))
                return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
            case .lastReadAt:
                return compareDates(lhs.recentReadingAt, rhs.recentReadingAt, lhsID: lhs.id, rhsID: rhs.id, descending: descending)
            }
        }
        switch sortOrder {
        case .contentUpdatedAt, .lastReadAt:
            return sortedCards
        default:
            return descending ? sortedCards.reversed() : sortedCards
        }
    }

    private static func compareMixed(
        _ lhs: FavoriteMixedEntry,
        _ rhs: FavoriteMixedEntry,
        by sortOrder: LocalFavoriteLibrarySortOrder,
        descending: Bool,
        collectionSummaries: [String: FavoriteCollectionSortSummary]
    ) -> Bool {
        switch sortOrder {
        case .organization:
            return false
        case .contentUpdatedAt:
            return compareDates(
                mixedUpdatedAt(lhs, collectionSummaries), mixedUpdatedAt(rhs, collectionSummaries),
                lhsID: lhs.id, rhsID: rhs.id, descending: descending
            )
        case .yamiboRemoteOrder:
            let lhsOrder = mixedRemoteOrder(lhs, collectionSummaries) ?? Int.max
            let rhsOrder = mixedRemoteOrder(rhs, collectionSummaries) ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.id < rhs.id
        case .displayTitle:
            let result = sortCompare(mixedTitle(lhs), mixedTitle(rhs))
            return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
        case .sourceGroup:
            let result = sortCompare(mixedSourceGroupKey(lhs), mixedSourceGroupKey(rhs))
            return result == .orderedSame ? lhs.id < rhs.id : result == .orderedAscending
        case .lastReadAt:
            return compareDates(
                mixedReadAt(lhs, collectionSummaries), mixedReadAt(rhs, collectionSummaries),
                lhsID: lhs.id, rhsID: rhs.id, descending: descending
            )
        }
    }

    private static func mixedUpdatedAt(_ entry: FavoriteMixedEntry, _ summaries: [String: FavoriteCollectionSortSummary]) -> Date? {
        switch entry {
        case let .card(card):
            card.lastUpdatedAt
        case let .collection(collection):
            summaries[collection.id]?.latestUpdatedAt
        }
    }

    private static func mixedReadAt(_ entry: FavoriteMixedEntry, _ summaries: [String: FavoriteCollectionSortSummary]) -> Date? {
        switch entry {
        case let .card(card):
            card.recentReadingAt
        case let .collection(collection):
            summaries[collection.id]?.latestReadAt
        }
    }

    private static func mixedRemoteOrder(_ entry: FavoriteMixedEntry, _ summaries: [String: FavoriteCollectionSortSummary]) -> Int? {
        switch entry {
        case let .card(card):
            card.item.remoteMapping?.yamiboRemoteOrder
        case let .collection(collection):
            summaries[collection.id]?.minRemoteOrder
        }
    }

    private static func mixedTitle(_ entry: FavoriteMixedEntry) -> String {
        switch entry {
        case let .card(card):
            card.resolvedTitle
        case let .collection(collection):
            collection.name
        }
    }

    private static func mixedSourceGroupKey(_ entry: FavoriteMixedEntry) -> String {
        switch entry {
        case let .card(card):
            sourceGroupSortKey(for: card)
        case let .collection(collection):
            collection.name
        }
    }

    private static func compareOrganization(_ lhs: FavoriteCardProjection, _ rhs: FavoriteCardProjection) -> Bool {
        let lhsOrder = lhs.item.remoteMapping?.yamiboRemoteOrder
        let rhsOrder = rhs.item.remoteMapping?.yamiboRemoteOrder
        switch (lhsOrder, rhsOrder) {
        case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
            return lhsOrder < rhsOrder
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.item.createdAt != rhs.item.createdAt {
                return lhs.item.createdAt < rhs.item.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?, lhsID: String, rhsID: String, descending: Bool) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            return descending ? lhs < rhs : lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhsID < rhsID
        }
    }

    private static func searchFields(for card: FavoriteCardProjection) -> [String] {
        var fields = [
            card.item.displayName,
            card.item.title,
            card.sourceGroupLabel
        ].compactMap(\.self) + card.tags.map(\.name)
        if let mangaDirectory = card.mangaDirectory {
            fields.append(mangaDirectory.cleanBookName)
        }
        if let members = card.mergedMembers {
            fields += members.map(\.title)
            fields += members.compactMap(\.displayName)
        }
        return fields
    }

    private static func collectionNames(for item: FavoriteItem, metadata: MetadataIndex) -> [String] {
        Set(item.locations.compactMap(\.collectionID))
            .flatMap { metadata.collectionsByID[$0] ?? [] }
            .sorted { $0.rank < $1.rank }
            .map(\.name)
    }

    private static func tags(for item: FavoriteItem, metadata: MetadataIndex) -> [FavoriteTag] {
        Set(item.tagIDs)
            .flatMap { metadata.tagsByID[$0] ?? [] }
            .sorted { $0.rank < $1.rank }
            .map(\.tag)
    }

    private static func sourceGroupSortKey(for card: FavoriteCardProjection) -> String {
        if let forumName = card.item.forumName {
            return forumName
        }
        if let forumID = card.item.forumID {
            return forumID
        }
        return card.sourceGroupLabel
    }

    private static func label(for sourceGroup: FavoriteSourceGroup) -> String {
        switch sourceGroup {
        case let .forumBoard(_, label):
            label
        case .smartManga:
            L10n.string("favorites.filter.manga")
        case .unknown:
            L10n.string("favorites.source_group.unknown")
        }
    }

    private static func progressPercent(from record: ReadingProgressRecord?) -> Int? {
        guard let record else { return nil }
        return ReadingProgressPresentation.percent(for: record)
    }

    private static func chapterPageProgress(from record: ReadingProgressRecord?) -> String? {
        guard let record else { return nil }
        return ReadingProgressPresentation.positionText(for: record)
    }

    private static func readingProgressLookup(_ records: [ReadingProgressRecord]) -> [String: ReadingProgressRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private static func progressKey(for item: FavoriteItem) -> String {
        item.target.id
    }
}
