import Foundation

public enum LocalFavoriteLibraryProjection {
    public static var supportedSortOrders: [LocalFavoriteLibrarySortOrder] {
        LocalFavoriteLibrarySortOrder.allCases
    }

    public static func cards(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery = LocalFavoriteLibraryQuery(),
        readingProgress: [ReadingProgressRecord] = [],
        // Both default to "nothing resolved locally yet" so every existing
        // caller (in particular the whole pre-Phase-E test suite) keeps
        // building exclusively standalone cards without passing anything
        // new — `groupedCardEntries` short-circuits to "everything
        // standalone" whenever `mangaDirectoriesByTID` is empty, before ever
        // consulting `boardReaderSettings`.
        mangaDirectoriesByTID: [String: MangaDirectory] = [:],
        boardReaderSettings: BoardReaderSettings = BoardReaderSettings(),
        // Precomputed `mangaThreadItemsByEffectiveTitle(in:mangaDirectoriesByTID:
        // boardReaderSettings:)` result, when a caller that needs it for
        // several keys within one derivation (`LocalFavoriteLibraryDerivation`)
        // has already built it once. `nil` (the default, so every existing
        // caller keeps compiling unchanged) means this call builds it fresh
        // from `document.items` itself — still always freshly computed from
        // the CURRENT items, never cached across separate `cards(...)` calls,
        // just no longer rebuilt once per smart card WITHIN this one call.
        mangaThreadItemsByEffectiveTitle: [String: [FavoriteItem]]? = nil
    ) -> [FavoriteCardProjection] {
        let categoryID = query.categoryID ?? document.defaultCategory.id
        let progressByKey = readingProgressLookup(readingProgress)
        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMangaThreadItemsByEffectiveTitle = mangaThreadItemsByEffectiveTitle ?? Self.mangaThreadItemsByEffectiveTitle(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )

        // A smart card's "查看归档收藏" detail page scopes by *effective title*
        // identity instead of the usual category/collection membership:
        // every mode-on `.mangaThread` favorite whose own
        // `FavoriteCardProjection.resolvedTitle(item:mangaDirectory:
        // isModeOnMangaThread:)` currently matches `memberScopeCleanBookName`
        // — not just favorites with an actually-resolved directory, so a
        // favorite still on the local-clean fallback (no directory resolved
        // locally yet) also participates whenever its independently-computed
        // guess happens to match, and a genuinely solitary favorite (no
        // siblings, resolved or not) correctly shows just itself as a
        // "singleton archive" with no special-casing required. Built
        // directly rather than through `groupedCardEntries` so each one
        // becomes a genuinely standalone entry (nil `members`/
        // `mangaDirectory`) — on this page the whole point is telling
        // individual chapters apart, and each one's normal single-item
        // delete path (`.deleteItem`) must keep working with no new deletion
        // code. This mirrors `openCollection`/`selectedCollectionID`'s own
        // "store an id, re-resolve membership fresh on every derive"
        // liveness, just keyed by the effective title.
        //
        // Grouping otherwise runs over the *entire* unfiltered item list
        // (smart-comic-mode decision #5: a smart card's membership/scope is
        // global, independent of which category/collection the query is
        // currently looking at) — only after grouping do category/
        // collection/source/tag filters apply, to the resulting entries'
        // *union* locations/tags rather than any one member's own.
        let entries: [GroupedFavoriteEntry]
        let isMemberScoped = query.memberScopeCleanBookName != nil
        if let memberScopeCleanBookName = query.memberScopeCleanBookName {
            entries = (resolvedMangaThreadItemsByEffectiveTitle[memberScopeCleanBookName] ?? [])
                .map { GroupedFavoriteEntry(representativeItem: $0, members: nil, mangaDirectory: nil) }
        } else {
            entries = groupedCardEntries(
                for: document.items,
                mangaDirectoriesByTID: mangaDirectoriesByTID,
                boardReaderSettings: boardReaderSettings
            )
        }

        let scopedEntries = entries.filter { entry in
            // Directory-identity scoping replaces category/collection
            // scoping entirely for this query — it does not combine with
            // it (a member can live in any category/collection, or none
            // matching the current selection, and must still show here).
            guard !isMemberScoped else { return true }
            if let collectionID = query.collectionID {
                return entry.representativeItem.locations.contains(.collection(categoryID: categoryID, collectionID: collectionID))
            }
            return entry.representativeItem.locations.contains(.category(categoryID))
        }

        let cards = mappedCards(
            from: scopedEntries,
            in: document,
            query: query,
            isMemberScoped: isMemberScoped,
            progressByKey: progressByKey,
            trimmedSearch: trimmedSearch,
            boardReaderSettings: boardReaderSettings,
            resolvedMangaThreadItemsByEffectiveTitle: resolvedMangaThreadItemsByEffectiveTitle
        )

        return sorted(cards, by: query.sortOrder, descending: query.sortsDescending)
    }

    /// Every card `query` would produce, ACROSS every category and
    /// collection at once — `query.categoryID`/`collectionID` are ignored
    /// entirely (every other filter: source, tag, search, still applies).
    /// Unsorted, since bucketing the result by many different
    /// category/collection ids afterward doesn't care about order.
    ///
    /// For a caller that needs the same (grouped + tag-unioned + filtered)
    /// card set bucketed by every category (`LocalFavoriteLibraryDerivation
    /// .categoryEntryCounts`) or every collection
    /// (`.collectionAggregates`) at once, calling `cards(in:query:...)` once
    /// per category/collection id independently re-derives this identical
    /// grouping/mapping/search-filtering work C or K times over. Since the
    /// category/collection scope filter is a pure per-entry location-
    /// membership check that doesn't affect grouping, tag unions, or the
    /// search filter (and vice versa), it commutes with the rest of the
    /// pipeline — computing everything else once here and applying the
    /// scope filter as a final bucketing step over this result is exactly
    /// equivalent to calling `cards(in:query:...)` once per id and
    /// concatenating, just O(N) instead of O(ids × N).
    ///
    /// Never valid for a member-scoped query (`memberScopeCleanBookName`) —
    /// that scope already ignores category/collection entirely, so there is
    /// nothing here to bucket by; callers needing per-category/collection
    /// buckets never set it.
    public static func cardsAcrossAllScopes(
        in document: FavoriteLibraryDocument,
        query: LocalFavoriteLibraryQuery = LocalFavoriteLibraryQuery(),
        readingProgress: [ReadingProgressRecord] = [],
        mangaDirectoriesByTID: [String: MangaDirectory] = [:],
        boardReaderSettings: BoardReaderSettings = BoardReaderSettings(),
        mangaThreadItemsByEffectiveTitle: [String: [FavoriteItem]]? = nil
    ) -> [FavoriteCardProjection] {
        let progressByKey = readingProgressLookup(readingProgress)
        let trimmedSearch = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedMangaThreadItemsByEffectiveTitle = mangaThreadItemsByEffectiveTitle ?? Self.mangaThreadItemsByEffectiveTitle(
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
            in: document,
            query: query,
            isMemberScoped: false,
            progressByKey: progressByKey,
            trimmedSearch: trimmedSearch,
            boardReaderSettings: boardReaderSettings,
            resolvedMangaThreadItemsByEffectiveTitle: resolvedMangaThreadItemsByEffectiveTitle
        )
    }

    /// Shared tail of `cards(in:query:...)`/`cardsAcrossAllScopes(...)`:
    /// source/tag filters, smart-card tag-union + card construction, and the
    /// search filter — everything downstream of entry grouping and the
    /// (optional) category/collection scope filter, which each caller
    /// applies to `entries` differently before calling this.
    private static func mappedCards(
        from entries: [GroupedFavoriteEntry],
        in document: FavoriteLibraryDocument,
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
                // Entries built for the member-scoped "查看归档收藏" archive
                // page are deliberately shown as ordinary (non-smart) cards —
                // same treatment as the `mangaDirectory`/`members: nil`
                // forcing above — so each one displays its OWN raw title via
                // `resolvedTitle`'s non-mode-on branch, gets a working direct
                // "delete" action instead of another "查看归档收藏" button,
                // and isn't excluded from bulk selection. Recomputing this
                // from `entry.representativeItem` here (like the main-list
                // path does) would defeat that: every member is itself a
                // mode-on `.mangaThread` favorite (that's WHY it matched the
                // archive scope), so it would come back `true` for all of
                // them and the whole page would look like N copies of the
                // same unmanageable smart card. The smart-card treatment
                // belongs to the original collapsed card on the main list,
                // not to its individually-surfaced members.
                let isModeOnMangaThread = isMemberScoped
                    ? false
                    : (entry.representativeItem.target.kind == .mangaThread
                        && boardReaderSettings.isSmartComicModeEnabled(forumID: entry.representativeItem.forumID))
                var cardEntry = entry
                if isModeOnMangaThread {
                    // A smart card's displayed tags must be the union of tags
                    // across every favorite currently "archived" under it —
                    // the SAME `archivedItems` membership its own "查看归档
                    // 收藏" page lists (and, per `FavoriteLibraryOrganizer
                    // .expandedSelectionFavoriteIDs`, that a bulk move/tag
                    // operation on it actually affects) — not just
                    // `cardEntry(for:)`'s narrower union across a genuinely
                    // RESOLVED `MangaDirectory`'s members (see that
                    // function's own doc comment: it still unions locations,
                    // but no longer tags). Without this, a still-solitary
                    // smart card — a lone resolved-directory favorite, or one
                    // still on the local-clean fallback with no resolved
                    // directory at all — would show only its own
                    // representative item's tags. For a genuinely solitary
                    // card `archivedItems` just returns `[that one item]`, so
                    // the union trivially equals its own tags — no special-
                    // casing needed. Using the identical `archivedItems`
                    // membership everywhere (card display, archive page,
                    // bulk-operation expansion) keeps all three permanently
                    // in sync: this exact feature has already hit the "two
                    // semantics for the same card" class of bug twice today
                    // (see `LocalFavoriteLibraryQuery.memberScopeCleanBookName`
                    // and this function's own doc comments above), and this
                    // is the fix for a third instance of it.
                    let effectiveTitle = FavoriteCardProjection.resolvedTitle(
                        item: entry.representativeItem,
                        mangaDirectory: entry.mangaDirectory,
                        isModeOnMangaThread: true
                    )
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
                return card(for: cardEntry, document: document, progress: resolvedProgress, isModeOnMangaThread: isModeOnMangaThread)
            }
            .filter { card in
                guard !trimmedSearch.isEmpty else { return true }
                return searchFields(for: card).contains { field in
                    field.localizedCaseInsensitiveContains(trimmedSearch)
                }
            }
    }

    /// Every individual favorite currently "archived" under a smart card
    /// showing `cleanBookName` as its `resolvedTitle` — the exact predicate
    /// `cards(in:query:...)`'s `memberScopeCleanBookName` branch uses to
    /// build the "查看归档收藏" detail page, extracted here so other callers
    /// (the tag-union computation above, and
    /// `FavoriteLibraryOrganizer.expandedSelectionFavoriteIDs` for bulk
    /// move/tag operations on a selected smart card) can compute the exact
    /// same membership without duplicating or drifting from it. One
    /// solitary favorite with no directory at all, or no siblings, still
    /// correctly matches only itself. See the member-scope doc comment on
    /// `LocalFavoriteLibraryQuery.memberScopeCleanBookName` for the full
    /// rationale of matching on `resolvedTitle` rather than an actually-
    /// resolved `MangaDirectory` alone.
    public static func archivedItems(
        matching cleanBookName: String,
        in items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [FavoriteItem] {
        mangaThreadItemsByEffectiveTitle(
            in: items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )[cleanBookName] ?? []
    }

    /// Groups every mode-on `.mangaThread` favorite in `items` by its
    /// effective title (`FavoriteCardProjection.resolvedTitle`) — the exact
    /// same predicate `archivedItems(matching:...)` filters `items` by,
    /// computed once here so a caller that needs the membership for several
    /// different keys within one call (every smart card's tag union, plus
    /// the member-scoped archive page, both inside a single `cards(...)`
    /// call; every selected smart card's expansion inside a single
    /// `expandedSelectionFavoriteIDs` call) can do an O(1) dictionary lookup
    /// per key instead of re-scanning all of `items` once per key —
    /// `archivedItems(matching:...)` itself is now just a single-key lookup
    /// into this dictionary. Must always be recomputed from the CURRENT
    /// `items` on every call that needs it (never cached across separate
    /// derivations) — only the redundant re-scanning *within* one such call
    /// is what this removes.
    public static func mangaThreadItemsByEffectiveTitle(
        in items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> [String: [FavoriteItem]] {
        var itemsByEffectiveTitle: [String: [FavoriteItem]] = [:]
        for item in items {
            // The explicit `isSmartComicModeEnabled(forumID:)` check is required, not
            // redundant with the directory lookup below — see
            // `rawGroupedFavorites`' own doc comment on why a
            // resolved-directory proxy signal must never stand in for the
            // mode-on/off gate (the design doc's three prior same-class
            // bugs). Mode-off items never participate in this scope,
            // resolved directory or not.
            guard item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else {
                continue
            }
            let directory = mangaDirectoriesByTID[item.target.threadID ?? ""]
            // Matches on the SAME effective title `resolvedTitle` shows for
            // a built card — not just an actually-resolved directory's
            // `cleanBookName` — so a favorite still on the local-clean
            // fallback (no directory resolved yet) also joins this scope
            // whenever its own independently-computed guess happens to
            // match.
            let effectiveTitle = FavoriteCardProjection.resolvedTitle(
                item: item,
                mangaDirectory: directory,
                isModeOnMangaThread: true
            )
            itemsByEffectiveTitle[effectiveTitle, default: []].append(item)
        }
        return itemsByEffectiveTitle
    }

    /// Every mode-on `.mangaThread` favorite resolved to a `MangaDirectory`,
    /// grouped by that directory (smart-comic-mode decision #13's cover
    /// backfill trigger). Includes groups of exactly one favorite — a lone
    /// resolved-directory favorite still needs its `.smartManga` cover
    /// resolved even before any sibling favorite joins it into a visible
    /// merge — so this is deliberately *not* filtered down to `count >= 2`
    /// the way `FavoriteCardProjection.mergedMembers` is.
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

    /// Merges collections and cards into one ordering. `.organization` is
    /// each side's own manual/remote order — a collection's `manualOrder`
    /// (set via the up/down arrows) and a card's remote/creation order live
    /// on unrelated scales, so that's the one mode where collections stay a
    /// pinned block ahead of the cards rather than interleaving.
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
        // See the matching switch in `sorted(_:by:descending:)`: date modes
        // bake `descending` into the comparator so undated entries stay
        // last regardless of direction; other modes reverse as a whole.
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

    // MARK: - Virtual merged-directory grouping (smart-comic-mode decision #3/#5)

    /// One resolved-and-possibly-merged card's worth of pre-card data: either
    /// a standalone favorite untouched (`members == nil`, `mangaDirectory ==
    /// nil`) or a directory-resolved `.mangaThread` favorite/group with its
    /// representative item's `locations` already rewritten to the *union*
    /// across every member (decision #5: a merged card appears in every
    /// location any member belongs to). `tagIDs` is NOT unioned here — see
    /// `cardEntry(for:)`'s own doc comment — `cards(in:query:...)`'s caller
    /// unions tags separately, across the broader `archivedItems` scope.
    /// Never persisted — this only ever backs a display card for the current
    /// `cards(...)` call.
    private struct GroupedFavoriteEntry {
        var representativeItem: FavoriteItem
        var members: [FavoriteItem]?
        var mangaDirectory: MangaDirectory?
    }

    private struct RawMangaDirectoryGroup {
        var directory: MangaDirectory
        var members: [FavoriteItem]
    }

    /// Partitions `items` into favorites that stay standalone and favorites
    /// resolved to a shared `MangaDirectory`, using the *explicit*
    /// `BoardReaderSettings.isSmartComicModeEnabled(forumID:)` check — not any proxy
    /// signal (`directoryName != nil`, `cleanBookName.isEmpty`, etc. — see
    /// the design doc's three prior same-class bugs) — as the sole
    /// mode-on/off gate. This is the cheap in-memory pre-filter the design
    /// doc's performance constraint #1 calls for: only mode-on `.mangaThread`
    /// items with a resolved directory even reach the grouping dictionaries
    /// below; everything else is appended to `standalone` without touching
    /// `mangaDirectoriesByTID` again.
    private static func rawGroupedFavorites(
        for items: [FavoriteItem],
        mangaDirectoriesByTID: [String: MangaDirectory],
        boardReaderSettings: BoardReaderSettings
    ) -> (standalone: [FavoriteItem], groups: [RawMangaDirectoryGroup]) {
        guard !mangaDirectoriesByTID.isEmpty else {
            return (items, [])
        }

        var standalone: [FavoriteItem] = []
        var membersByDirectoryID: [String: [FavoriteItem]] = [:]
        var directoryByID: [String: MangaDirectory] = [:]

        for item in items {
            guard item.target.kind == .mangaThread,
                  let threadID = item.target.threadID,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID),
                  let directory = mangaDirectoriesByTID[threadID] else {
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

    /// Orders `members` to match `directory.chapters` (earliest chapter
    /// first). Every member's own tid is guaranteed present in
    /// `directory.chapters` by construction — `mangaDirectoriesByTID` only
    /// ever resolves a directory whose chapter list contains that tid — so
    /// `members` and the ordered result should always be the same length;
    /// the equal-length check is a defensive fallback only, so a stale/edited
    /// directory can never silently drop a favorite from its own card.
    private static func orderedByChapter(_ members: [FavoriteItem], in directory: MangaDirectory) -> [FavoriteItem] {
        let membersByThreadID = Dictionary(uniqueKeysWithValues: members.compactMap { item -> (String, FavoriteItem)? in
            guard let threadID = item.target.threadID else { return nil }
            return (threadID, item)
        })
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

    /// Builds one display entry from a raw directory group: the
    /// earliest-chapter member becomes `representativeItem` (a deterministic,
    /// reload-stable choice — also the anchor cover backfill resolves from),
    /// its `locations` rewritten in place to the union across every member.
    /// `members` on the result is nil (not a 1-element array) when the group
    /// has exactly one favorite, matching `mergedMembers`'s "only non-nil for
    /// an actual merge" contract.
    ///
    /// Deliberately does NOT also union `tagIDs` (it used to) — tags are
    /// unioned separately, and more broadly, by `cards(in:query:...)`'s own
    /// caller using `archivedItems(matching:...)`, which covers every smart
    /// card (including a still-solitary one on the local-clean fallback with
    /// no resolved `MangaDirectory` at all, which this function never even
    /// sees) rather than just a group that made it all the way to a
    /// genuinely RESOLVED directory. Keeping a second, narrower tag union
    /// here would just be redundant work this function's result immediately
    /// gets overwritten by.
    private static func cardEntry(for group: RawMangaDirectoryGroup) -> GroupedFavoriteEntry {
        let members = group.members
        // `rawGroupedFavorites` only ever creates a `membersByDirectoryID`
        // entry by appending to it, so every group it produces has at least
        // one member — this can never actually fire.
        precondition(!members.isEmpty, "RawMangaDirectoryGroup must have at least one member")
        var representative = members[0]
        var unionLocations: [FavoriteLocation] = []
        var seenLocationIDs: Set<String> = []
        for member in members {
            for location in member.locations where seenLocationIDs.insert(location.id).inserted {
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

    /// Progress third-level match (design decision #14): a directory-resolved
    /// entry (merged or a lone favorite alike) prefers the directory-level
    /// `.mangaTitle` reading-progress record — the same record decision #7's
    /// mode-on resume path reads via `LocalFavoriteOpenTargetResolver` — over
    /// its representative member's own per-thread `.mangaThread` record,
    /// since the whole point is showing the manga's current position rather
    /// than whichever specific chapter happens to be the earliest one
    /// favorited. Falls back to the direct id match only when the directory
    /// has no progress record of its own yet (e.g. resolved via sync/cover
    /// backfill but never actually opened locally).
    private static func progress(
        for entry: GroupedFavoriteEntry,
        progressByKey: [String: ReadingProgressRecord],
        boardReaderSettings: BoardReaderSettings
    ) -> ReadingProgressRecord? {
        if let directory = entry.mangaDirectory,
           let directoryProgress = progressByKey[directoryProgressKey(for: directory)] {
            return directoryProgress
        }
        // Progress keys are kind-prefixed, and the reader a favorite opens
        // with follows the board's current configuration (R11) — so a
        // stored-normal favorite on a 小说-configured board records its reads
        // under the `.novelThread` key. Prefer the effective kind's record,
        // falling back to the stored identity's own (reads from before the
        // configuration change keep showing).
        let item = entry.representativeItem
        if let effectiveKey = effectiveProgressKey(for: item, boardReaderSettings: boardReaderSettings),
           let effectiveProgress = progressByKey[effectiveKey] {
            return effectiveProgress
        }
        return progressByKey[progressKey(for: item)]
    }

    /// The progress key the item's *effective* open kind records under —
    /// `nil` when the item's board has no configuration entry (stored kind
    /// is the only identity then) or the item has no thread id.
    private static func effectiveProgressKey(
        for item: FavoriteItem,
        boardReaderSettings: BoardReaderSettings
    ) -> String? {
        guard let threadID = item.target.threadID,
              let mode = boardReaderSettings.entry(forumID: item.forumID)?.mode else {
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
        document: FavoriteLibraryDocument,
        progress: ReadingProgressRecord?,
        isModeOnMangaThread: Bool
    ) -> FavoriteCardProjection {
        let item = entry.representativeItem
        return FavoriteCardProjection(
            item: item,
            sourceGroupLabel: label(for: item.sourceGroup),
            collectionNames: collectionNames(for: item, in: document),
            tags: tags(for: item, in: document),
            recentReadingAt: progress?.lastReadAt,
            // A merged card's "content updated" proxy is the freshest of any
            // member's own content update, not just the representative
            // (earliest-chapter) member's — otherwise a manga that just got a
            // brand-new favorited chapter wouldn't visibly bubble up under
            // the "recently updated" sort.
            lastUpdatedAt: entry.members?.compactMap(\.contentUpdatedAt).max() ?? item.contentUpdatedAt,
            progressPercent: progressPercent(from: progress),
            chapterPageProgress: chapterPageProgress(from: progress),
            // Filled from ContentCoverStore by the library derivation; items
            // deliberately carry no cover of their own.
            coverURL: nil,
            textCoverForced: false,
            mangaDirectory: entry.mangaDirectory,
            mergedMembers: entry.members,
            // Pre-computed by the caller — see the doc comment at the call
            // site in `cards(in:query:...)` for why this can't be recomputed
            // from `item`/`boardReaderSettings` here: doing so would
            // ignore the member-scoped archive page's deliberate "show as an
            // ordinary card" intent and force every one of its cards back to
            // `true`.
            isModeOnMangaThread: isModeOnMangaThread,
            // Computed once here rather than left as a per-access computed
            // property — see `resolvedTitle`'s doc comment on the struct.
            resolvedTitle: FavoriteCardProjection.resolvedTitle(
                item: item,
                mangaDirectory: entry.mangaDirectory,
                isModeOnMangaThread: isModeOnMangaThread
            )
        )
    }

    /// Chinese-locale string compare, pinned rather than following the
    /// device's current locale/region: the app ships a single zh-Hans
    /// localization, so an ambient-locale compare would only make title/
    /// source-group sort order depend on an unrelated device Region
    /// setting instead of being stable across devices (and environments —
    /// this is also what keeps `.displayTitle`/`.sourceGroup` sort order
    /// deterministic in CI, where the simulator's locale doesn't match a
    /// developer machine's).
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
        // .contentUpdatedAt/.lastReadAt already bake `descending` into the
        // comparator above so undated items stay last regardless of
        // direction; every other mode sorts ascending here and is reversed
        // as a whole, which is safe because those modes have no "missing
        // value" sentinel that would otherwise jump to the wrong end.
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

    /// A collection has no single title/source group of its own — its name
    /// stands in for both, so it sorts alongside cards' titles/source groups
    /// as its own pseudo-entry rather than always leading or trailing them.
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

    /// Dated items compare by date, most-recent/oldest-first per
    /// `descending`; undated items always sort last, in both directions,
    /// so switching direction can't fast-forward "never read"/"never
    /// updated" entries to the very top ahead of real recent activity.
    /// Direction is intentionally inverted from the other sort modes:
    /// `descending == false` (the default) shows newest-first, since these
    /// are the two "recency" keys (最近更新/最近阅读) and that's the useful
    /// reading without the user having to flip the toggle first.
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
        // A resolved-directory card's `item.title` is deliberately still its
        // representative member's own post title (see `FavoriteCardProjection
        // .mangaDirectory`'s doc comment), so without this the manga's own
        // name would never be searchable — only whichever specific chapter
        // happened to become the representative. Merged members' own titles
        // are included too so searching by a *specific* favorited chapter's
        // title still finds the merged card it belongs to.
        if let mangaDirectory = card.mangaDirectory {
            fields.append(mangaDirectory.cleanBookName)
        }
        if let members = card.mergedMembers {
            fields += members.map(\.title)
            fields += members.compactMap(\.displayName)
        }
        return fields
    }

    private static func collectionNames(for item: FavoriteItem, in document: FavoriteLibraryDocument) -> [String] {
        let collectionIDs = Set(item.locations.compactMap(\.collectionID))
        return document.collections
            .filter { collectionIDs.contains($0.id) }
            .sorted { $0.manualOrder == $1.manualOrder ? $0.id < $1.id : $0.manualOrder < $1.manualOrder }
            .map(\.name)
    }

    private static func tags(for item: FavoriteItem, in document: FavoriteLibraryDocument) -> [FavoriteTag] {
        let tagIDs = Set(item.tagIDs)
        return document.tags
            .filter { tagIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.manualOrder != rhs.manualOrder {
                    return lhs.manualOrder < rhs.manualOrder
                }
                return lhs.id < rhs.id
        }
    }

    /// `.mangaThread` favorites are plain per-thread favorites of one of the
    /// three manga forums now (smart-comic-mode design decision #4), so they
    /// carry real forum metadata just like any other thread; this falls back
    /// to the source group label only if that metadata is somehow missing.
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
        switch record.kind {
        case .novel:
            return record.novel?.novelDocumentSurfaceProgressPercent
        case .manga:
            guard let manga = record.manga,
                  let pageCount = manga.mangaPageCount,
                  pageCount > 0 else {
                return nil
            }
            return min(max(Int(((Double(manga.mangaPageIndex) + 1) / Double(pageCount) * 100).rounded()), 0), 100)
        case .thread:
            // Normal threads gained page-level progress with browsing
            // history (decision #8's all-entrance resume): a favorited
            // normal thread's card now shows it too, for free.
            guard let thread = record.thread,
                  let pageCount = thread.pageCount,
                  pageCount > 0 else {
                return nil
            }
            return min(max(Int((Double(thread.lastPage) / Double(pageCount) * 100).rounded()), 0), 100)
        }
    }

    private static func chapterPageProgress(from record: ReadingProgressRecord?) -> String? {
        guard let record else { return nil }
        switch record.kind {
        case .novel:
            guard let lastChapter = record.novel?.lastChapter else { return nil }
            return lastChapter
        case .manga:
            guard let manga = record.manga else { return nil }
            if let pageCount = manga.mangaPageCount {
                return L10n.string("favorites.progress.manga_page_total", manga.lastChapter, manga.mangaPageIndex + 1, pageCount)
            }
            return L10n.string("favorites.progress.manga_page", manga.lastChapter, manga.mangaPageIndex + 1)
        case .thread:
            guard let thread = record.thread else { return nil }
            if let pageCount = thread.pageCount {
                return L10n.string("history.progress.page_of_total", String(thread.lastPage), String(pageCount))
            }
            return L10n.string("history.progress.page", String(thread.lastPage))
        }
    }

    private static func readingProgressLookup(_ records: [ReadingProgressRecord]) -> [String: ReadingProgressRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private static func progressKey(for item: FavoriteItem) -> String {
        item.target.id
    }
}
