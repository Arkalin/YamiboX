import Foundation
import YamiboXCore

struct LocalFavoriteFilterState: Equatable, Sendable {
    var selectedSourceFilters: Set<LocalFavoriteSourceFilter> = []
    var selectedTagIDs: Set<String> = []
    var sortOrder: LocalFavoriteLibrarySortOrder = .organization
    var sortDescending = false
    var searchText = ""

    var hasActiveFilters: Bool {
        !selectedSourceFilters.isEmpty || !selectedTagIDs.isEmpty
    }
}

struct FavoriteLibraryDisplayState: Equatable {
    var layoutMode: FavoriteLibraryLayoutMode = .rowCard
    var showsCategoryCounts = true
    var gridCardScale = FavoriteLibrarySettings.defaultGridCardScale
}

struct LocalFavoriteCollectionPreviewTile: Equatable, Sendable {
    let coverSource: YamiboImageSource?
    let title: String
}

struct LocalFavoriteDerivedState: Equatable, Sendable {
    var cards: [FavoriteCardProjection] = []
    var visibleCollections: [LocalFavoriteCollection] = []
    var mixedEntries: [FavoriteMixedEntry] = []
    var categoryEntryCounts: [String: Int] = [:]
    var collectionEntryCounts: [String: Int] = [:]
    var sourceFilterEntryCounts: [LocalFavoriteSourceFilter: Int] = [:]
    var collectionPreviewTiles: [String: [LocalFavoriteCollectionPreviewTile]] = [:]
}

enum LocalFavoriteLibraryDerivation {
    final class Cache {
        fileprivate var structuralInputs: Inputs?
        fileprivate var groups: [String: [FavoriteItem]] = [:]
        fileprivate var metadataIndex: LocalFavoriteLibraryProjection.MetadataIndex?
        fileprivate var previews: [String: [LocalFavoriteCollectionPreviewTile]] = [:]
        fileprivate var globalInputs: Inputs?
        fileprivate var aggregates: [String: CollectionAggregate] = [:]
        fileprivate var categoryCounts: [String: Int] = [:]
    }
    struct Inputs: Sendable {
        var document: FavoriteLibraryDocument
        var selectedCategoryID: String
        var selectedCollectionID: String?
        var filter: LocalFavoriteFilterState
        var readingProgress: [ReadingProgressRecord]
        var coverSourcesByKey: [ContentCoverKey: YamiboImageSource]
        var textCoverForcedKeys: Set<ContentCoverKey>
        var mangaDirectoriesByTID: [String: MangaDirectory] = [:]
        var boardReaderSettings: BoardReaderSettings = BoardReaderSettings()
        var memberScopeGroupKey: String? = nil
        var memberScopeThreadIDs: Set<String>? = nil
    }

    static func derive(_ inputs: Inputs, cache: Cache = Cache()) -> LocalFavoriteDerivedState {
        let previous = cache.structuralInputs
        if previous?.document.collections != inputs.document.collections
            || previous?.document.tags != inputs.document.tags {
            cache.metadataIndex = LocalFavoriteLibraryProjection.MetadataIndex(document: inputs.document)
        }
        let structureChanged = previous?.document != inputs.document
            || previous?.mangaDirectoriesByTID != inputs.mangaDirectoriesByTID
            || previous?.boardReaderSettings != inputs.boardReaderSettings
        if structureChanged {
            cache.groups = LocalFavoriteLibraryProjection.mangaThreadItemsByGroupKey(
            in: inputs.document.items,
            mangaDirectoriesByTID: inputs.mangaDirectoriesByTID,
            boardReaderSettings: inputs.boardReaderSettings
            )
        }
        if structureChanged || previous?.coverSourcesByKey != inputs.coverSourcesByKey {
            cache.previews = collectionPreviewTiles(inputs, mangaThreadItemsByGroupKey: cache.groups)
        }
        cache.structuralInputs = inputs
        var mangaThreadItemsByGroupKey = cache.groups
        if let key = inputs.memberScopeGroupKey, let threadIDs = inputs.memberScopeThreadIDs {
            mangaThreadItemsByGroupKey[key] = inputs.document.items.filter {
                $0.target.kind == .mangaThread && threadIDs.contains($0.target.threadID) &&
                    inputs.boardReaderSettings.isSmartComicModeEnabled(forumID: $0.forumID)
            }
        }
        let cards = resolvedCards(
            in: inputs.document,
            query: LocalFavoriteLibraryQuery(
                categoryID: inputs.selectedCategoryID,
                collectionID: inputs.selectedCollectionID,
                selectedSourceFilters: inputs.filter.selectedSourceFilters,
                selectedTagIDs: inputs.filter.selectedTagIDs,
                sortOrder: inputs.filter.sortOrder,
                sortsDescending: inputs.filter.sortDescending,
                searchText: inputs.filter.searchText,
                memberScopeGroupKey: inputs.memberScopeGroupKey
            ),
            inputs: inputs,
            mangaThreadItemsByGroupKey: mangaThreadItemsByGroupKey,
            metadataIndex: cache.metadataIndex
        )
        let globalChanged = structureChanged
            || cache.globalInputs?.filter.selectedSourceFilters != inputs.filter.selectedSourceFilters
            || cache.globalInputs?.filter.selectedTagIDs != inputs.filter.selectedTagIDs
            || cache.globalInputs?.filter.searchText != inputs.filter.searchText
            || cache.globalInputs?.readingProgress != inputs.readingProgress
        if globalChanged {
            let allCardsAcrossScopes = LocalFavoriteLibraryProjection.cardsAcrossAllScopes(
                in: inputs.document,
                query: LocalFavoriteLibraryQuery(
                    selectedSourceFilters: inputs.filter.selectedSourceFilters,
                    selectedTagIDs: inputs.filter.selectedTagIDs,
                    searchText: inputs.filter.searchText
                ),
                readingProgress: inputs.readingProgress,
                mangaDirectoriesByTID: inputs.mangaDirectoriesByTID,
                boardReaderSettings: inputs.boardReaderSettings,
                mangaThreadItemsByGroupKey: cache.groups,
                metadataIndex: cache.metadataIndex
            )
            cache.aggregates = collectionAggregates(inputs, allCardsAcrossScopes: allCardsAcrossScopes)
            cache.categoryCounts = categoryEntryCounts(
                inputs, collectionEntryCounts: cache.aggregates.mapValues(\.entryCount),
                allCardsAcrossScopes: allCardsAcrossScopes
            )
            cache.globalInputs = inputs
        }
        let aggregates = cache.aggregates
        let collectionCounts = aggregates.mapValues(\.entryCount)
        let collections = visibleCollections(
            in: inputs.document,
            categoryID: inputs.selectedCategoryID,
            filter: inputs.filter,
            collectionEntryCounts: collectionCounts
        )
        return LocalFavoriteDerivedState(
            cards: cards,
            visibleCollections: collections,
            mixedEntries: LocalFavoriteLibraryProjection.mixedEntries(
                cards: cards,
                collections: (inputs.selectedCollectionID == nil && inputs.memberScopeGroupKey == nil)
                    ? collections
                    : [],
                collectionSummaries: aggregates.mapValues(\.sortSummary),
                sortOrder: inputs.filter.sortOrder,
                descending: inputs.filter.sortDescending
            ),
            categoryEntryCounts: cache.categoryCounts,
            collectionEntryCounts: collectionCounts,
            sourceFilterEntryCounts: sourceFilterEntryCounts(inputs, mangaThreadItemsByGroupKey: mangaThreadItemsByGroupKey,
                                                          metadataIndex: cache.metadataIndex),
            collectionPreviewTiles: cache.previews
        )
    }

    private static func resolvedCards(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery,
        inputs: Inputs,
        mangaThreadItemsByGroupKey: [String: [FavoriteItem]],
        metadataIndex: LocalFavoriteLibraryProjection.MetadataIndex?
    ) -> [FavoriteCardProjection] {
        LocalFavoriteLibraryProjection.cards(
            in: document,
            query: query,
            readingProgress: inputs.readingProgress,
            mangaDirectoriesByTID: inputs.mangaDirectoriesByTID,
            boardReaderSettings: inputs.boardReaderSettings,
            mangaThreadItemsByGroupKey: mangaThreadItemsByGroupKey,
            metadataIndex: metadataIndex
        )
        .map { card in
            var card = card
            if let key = card.contentCoverKey {
                card.coverSource = inputs.coverSourcesByKey[key]
                card.textCoverForced = inputs.textCoverForcedKeys.contains(key)
            }
            return card
        }
    }

    private static func categoryEntryCounts(
        _ inputs: Inputs,
        collectionEntryCounts: [String: Int],
        allCardsAcrossScopes: [FavoriteCardProjection]
    ) -> [String: Int] {
        var directCountsByCategoryID: [String: Int] = [:]
        for card in allCardsAcrossScopes {
            for location in card.item.locations {
                guard case let .category(categoryID) = location else { continue }
                directCountsByCategoryID[categoryID, default: 0] += 1
            }
        }
        return Dictionary(uniqueKeysWithValues: inputs.document.categories.map { category in
            let collections = visibleCollections(
                in: inputs.document,
                categoryID: category.id,
                filter: inputs.filter,
                collectionEntryCounts: collectionEntryCounts
            )
            return (category.id, (directCountsByCategoryID[category.id] ?? 0) + collections.count)
        })
    }

    fileprivate struct CollectionAggregate {
        var entryCount: Int
        var sortSummary: FavoriteCollectionSortSummary
    }

    private static func collectionAggregates(
        _ inputs: Inputs,
        allCardsAcrossScopes: [FavoriteCardProjection]
    ) -> [String: CollectionAggregate] {
        var cardsByCollection: [FavoriteLocation: [FavoriteCardProjection]] = [:]
        for card in allCardsAcrossScopes {
            for location in card.item.locations {
                guard case .collection = location else { continue }
                cardsByCollection[location, default: []].append(card)
            }
        }
        return Dictionary(uniqueKeysWithValues: inputs.document.collections.map { collection in
            let location = FavoriteLocation.collection(categoryID: collection.categoryID, collectionID: collection.id)
            let cards = cardsByCollection[location] ?? []
            return (collection.id, CollectionAggregate(entryCount: cards.count, sortSummary: .summarizing(cards)))
        })
    }

    private struct CollectionPreviewCandidate {
        var sortDate: Date
        var coverSource: YamiboImageSource?
        var title: String
    }

    private static func collectionPreviewTiles(
        _ inputs: Inputs,
        mangaThreadItemsByGroupKey: [String: [FavoriteItem]]
    ) -> [String: [LocalFavoriteCollectionPreviewTile]] {
        var membersByLocation: [FavoriteLocation: [FavoriteItem]] = [:]
        for item in inputs.document.items {
            for location in item.locations {
                if case .collection = location { membersByLocation[location, default: []].append(item) }
            }
        }
        return Dictionary(uniqueKeysWithValues: inputs.document.collections.map { collection in
            let location = FavoriteLocation.collection(categoryID: collection.categoryID, collectionID: collection.id)
            let members = membersByLocation[location] ?? []

            var candidates: [CollectionPreviewCandidate] = []
            var seenEffectiveTitles: Set<String> = []
            for item in members {
                let isModeOnMangaThread = item.target.kind == .mangaThread
                    && inputs.boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID)
                guard isModeOnMangaThread else {
                    candidates.append(CollectionPreviewCandidate(
                        sortDate: item.updatedAt,
                        coverSource: inputs.coverSourcesByKey[ContentCoverKey(target: item.target)],
                        title: item.resolvedDisplayTitle
                    ))
                    continue
                }

                let mangaDirectory = inputs.mangaDirectoriesByTID[item.target.threadID]
                let effectiveTitle = FavoriteCardProjection.resolvedTitle(
                    item: item,
                    mangaDirectory: mangaDirectory,
                    isModeOnMangaThread: true
                )
                guard let mangaDirectory else {
                    candidates.append(CollectionPreviewCandidate(
                        sortDate: item.updatedAt,
                        coverSource: inputs.coverSourcesByKey[ContentCoverKey(target: item.target)],
                        title: effectiveTitle
                    ))
                    continue
                }

                guard seenEffectiveTitles.insert(mangaDirectory.id.rawValue).inserted else { continue }

                let groupMembers = mangaThreadItemsByGroupKey[mangaDirectory.id.rawValue] ?? [item]
                let sortDate = groupMembers.map(\.updatedAt).max() ?? item.updatedAt
                let coverSource = inputs.coverSourcesByKey[.smartManga(directoryID: mangaDirectory.id)]
                candidates.append(CollectionPreviewCandidate(sortDate: sortDate, coverSource: coverSource, title: effectiveTitle))
            }

            var newest: [CollectionPreviewCandidate] = []
            for candidate in candidates {
                let index = newest.firstIndex { $0.sortDate < candidate.sortDate } ?? newest.endIndex
                if index < 4 { newest.insert(candidate, at: index) }
                if newest.count > 4 { newest.removeLast() }
            }
            let tiles = newest
                .map { LocalFavoriteCollectionPreviewTile(coverSource: $0.coverSource, title: $0.title) }
            return (collection.id, Array(tiles))
        })
    }

    private static func sourceFilterEntryCounts(
        _ inputs: Inputs,
        mangaThreadItemsByGroupKey: [String: [FavoriteItem]],
        metadataIndex: LocalFavoriteLibraryProjection.MetadataIndex?
    ) -> [LocalFavoriteSourceFilter: Int] {
        let allCards = resolvedCards(
            in: inputs.document,
            query: LocalFavoriteLibraryQuery(
                categoryID: inputs.selectedCategoryID,
                collectionID: inputs.selectedCollectionID,
                selectedSourceFilters: [],
                selectedTagIDs: inputs.filter.selectedTagIDs,
                sortOrder: .organization,
                searchText: inputs.filter.searchText
            ),
            inputs: inputs,
            mangaThreadItemsByGroupKey: mangaThreadItemsByGroupKey,
            metadataIndex: metadataIndex
        )
        return Dictionary(grouping: allCards) { card in
            LocalFavoriteSourceFilter.key(for: card.item)
        }
        .mapValues(\.count)
    }

    private static func visibleCollections(
        in document: FavoriteLibraryDocument,
        categoryID: String,
        filter: LocalFavoriteFilterState,
        collectionEntryCounts: [String: Int]
    ) -> [LocalFavoriteCollection] {
        let trimmedSearch = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSearchFiltersAreActive = !filter.selectedSourceFilters.isEmpty || !filter.selectedTagIDs.isEmpty
        let filtersAreActive = nonSearchFiltersAreActive || !trimmedSearch.isEmpty
        return document.collections
            .filter { collection in
                guard collection.categoryID == categoryID else { return false }
                guard filtersAreActive else { return true }
                let hasMatchingMember = (collectionEntryCounts[collection.id] ?? 0) > 0
                if !trimmedSearch.isEmpty,
                   collection.name.localizedCaseInsensitiveContains(trimmedSearch) {
                    return !nonSearchFiltersAreActive || hasMatchingMember
                }
                return hasMatchingMember
            }
            .sorted { lhs, rhs in
                if lhs.manualOrder != rhs.manualOrder {
                    return lhs.manualOrder < rhs.manualOrder
                }
                return lhs.id < rhs.id
            }
    }
}

actor FavoriteLibraryDerivationWorker {
    private let cache = LocalFavoriteLibraryDerivation.Cache()

    func derive(_ inputs: LocalFavoriteLibraryDerivation.Inputs,
                rootInputs: LocalFavoriteLibraryDerivation.Inputs?) throws -> (LocalFavoriteDerivedState, LocalFavoriteDerivedState) {
        try Task.checkCancellation()
        let scoped = LocalFavoriteLibraryDerivation.derive(inputs, cache: cache)
        try Task.checkCancellation()
        let root = rootInputs.map { LocalFavoriteLibraryDerivation.derive($0, cache: cache) } ?? scoped
        return (scoped, root)
    }
}
