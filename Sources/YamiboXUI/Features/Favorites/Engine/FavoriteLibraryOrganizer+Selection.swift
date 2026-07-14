import Foundation
import YamiboXCore

extension FavoriteLibraryOrganizer {

    // MARK: - Selection operations

    /// True only while browsing the unscoped root list — false while either
    /// a pushed collection detail (`selectedCollectionID`) or a merged smart
    /// card's "查看归档收藏" archive detail (`selectedMergedGroupCleanBookName`)
    /// is open. Collections never appear inside either scoped detail page
    /// (no nested collections in the domain model), so every call site
    /// deciding whether to fold `derived.visibleCollections` into scope or
    /// selection must gate on both — checking only `selectedCollectionID`
    /// (as every one of these call sites once did) let the archive page leak
    /// the current category's sibling collections into its own content and
    /// "select all", since opening it directly from the root list (the
    /// common path) leaves `selectedCollectionID` `nil`.
    var isBrowsingUnscopedRoot: Bool {
        selectedCollectionID == nil && selectedMergedGroupCleanBookName == nil
    }

    func toggleCollectionSelection(id: String) {
        guard isBrowsingUnscopedRoot else { return }
        selection.toggleCollectionSelection(id: id)
    }

    /// Whether `id` names a mode-on `.mangaThread` favorite that renders as a
    /// smart card on the main list — the ground-truth definition
    /// `LocalFavoriteLibraryProjection.cards(in:query:...)` itself uses for
    /// `isModeOnMangaThread` — computed straight from `document.items` +
    /// the current mode/directory snapshot rather than looked up in
    /// `derived.cards`.
    ///
    /// This distinction matters: `filter` (search text / tag / source
    /// filters) can narrow `derived.cards` at any time, and its own `didSet`
    /// deliberately never clears `selection` (`LocalFavoriteBrowseSession`'s
    /// own doc comment: "search is a plain live filter, not a session
    /// mode"). A smart card that's selected and then scrolled out of
    /// `derived.cards` by a filter change would stop being found by a
    /// `derived.cards.first(where:)` lookup while remaining fully selected —
    /// silently reverting it to "looks like an ordinary id" for any
    /// selection-consuming operation. For `deleteSelection` in particular
    /// that would mean deleting just its representative item instead of
    /// skipping it, orphaning every other favorite still archived under it:
    /// exactly the bug this whole feature exists to prevent. Sourcing the
    /// check from `document.items` instead makes it immune to the current
    /// filter entirely.
    ///
    /// Always `false` while the "查看归档收藏" archive page is open
    /// (`selectedMergedGroupCleanBookName != nil`), matching
    /// `cards(in:query:...)`'s own member-scoped computation: every card
    /// there is deliberately an ordinary per-item card, never a smart card.
    private func isSmartCardFavoriteID(_ id: String) -> Bool {
        guard selectedMergedGroupCleanBookName == nil,
              let item = document.items.first(where: { $0.id == id }) else { return false }
        return item.target.kind == .mangaThread && boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID)
    }

    /// Whether the current selection has anything `deleteSelection` would
    /// actually remove: at least one selected collection (dissolving a
    /// collection is unaffected by smart-card concerns entirely), or at
    /// least one selected favorite. When `smartMangaBulkDeleteEnabled` is
    /// off, a smart-card id alone doesn't count — `deleteSelection` skips
    /// every smart-card id in that mode, deleting nothing for them. Backs
    /// `LocalFavoriteSelectionActionBar`'s delete-button visibility — per
    /// that view's own doc comment ("hidden, not merely disabled, when the
    /// current selection can't use it"), a selection made up entirely of
    /// smart cards must not show an active delete button that silently does
    /// nothing when tapped.
    var hasDeletableSelection: Bool {
        selection.selectedCollectionCount > 0
            || (smartMangaBulkDeleteEnabled && !selection.selectedFavoriteIDs.isEmpty)
            || selection.selectedFavoriteIDs.contains { !isSmartCardFavoriteID($0) }
    }

    /// Expands `favoriteIDs` so any smart-card id (`isSmartCardFavoriteID`)
    /// is replaced by the full set of ids for every favorite item currently
    /// archived under it — the same membership its "查看归档收藏" page and
    /// tag-union display use
    /// (`LocalFavoriteLibraryProjection.archivedItems(matching:...)`). A
    /// non-smart-card id passes through unchanged. Used by every
    /// selection-consuming operation, including `deleteSelection` when
    /// `smartMangaBulkDeleteEnabled` is on (see its own doc comment for the
    /// off case, which intentionally keeps requiring the dedicated archive
    /// page for per-item-visible deletion instead).
    func expandedSelectionFavoriteIDs(_ favoriteIDs: Set<String>) -> Set<String> {
        guard selectedMergedGroupCleanBookName == nil else { return favoriteIDs }
        // Built once for every id in this one call, instead of calling
        // `archivedItems(matching:...)` (a full O(N) scan of `document.items`)
        // once per selected id — an O(S x N) shape for S selected ids that
        // this single O(N) precomputation plus O(1) lookups per id replaces.
        // Still always freshly computed from the CURRENT `document.items`
        // here at the top of this call, never cached across separate calls.
        let itemsByEffectiveTitle = LocalFavoriteLibraryProjection.mangaThreadItemsByEffectiveTitle(
            in: document.items,
            mangaDirectoriesByTID: mangaDirectoriesByTID,
            boardReaderSettings: boardReaderSettings
        )
        var expanded = favoriteIDs
        for id in favoriteIDs {
            guard let item = document.items.first(where: { $0.id == id }),
                  item.target.kind == .mangaThread,
                  boardReaderSettings.isSmartComicModeEnabled(forumID: item.forumID) else { continue }
            let directory = mangaDirectoriesByTID[item.target.threadID ?? ""]
            let effectiveTitle = FavoriteCardProjection.resolvedTitle(
                item: item,
                mangaDirectory: directory,
                isModeOnMangaThread: true
            )
            let archived = itemsByEffectiveTitle[effectiveTitle] ?? []
            expanded.formUnion(archived.map(\.id))
        }
        return expanded
    }

    /// Every card currently visible, including smart cards — selecting or
    /// "select all"-ing a smart card is equivalent to selecting every
    /// favorite archived under it, expanded transparently at execution time
    /// by `expandedSelectionFavoriteIDs` (Part C); the id that actually lands
    /// in `selection.selectedFavoriteIDs` is still just the smart card's own
    /// representative id, same as any other card. Backs both
    /// `selectAllVisible()` and `isAllVisibleSelected`.
    private var selectableFavoriteIDs: [String] {
        derived.cards.map(\.id)
    }

    func selectAllVisible() {
        selection.selectAll(
            favoriteIDs: selectableFavoriteIDs,
            collectionIDs: isBrowsingUnscopedRoot ? derived.visibleCollections.map(\.id) : []
        )
    }

    /// Whether every currently-visible favorite/collection is already
    /// selected — this is a plain count comparison, not a per-item
    /// membership diff (mirrors `ReaderCacheSelectionState
    /// .isAllSelected` in the cache sheets' own select-all button).
    var isAllVisibleSelected: Bool {
        let favoriteIDs = selectableFavoriteIDs
        let collectionIDs = isBrowsingUnscopedRoot ? derived.visibleCollections.map(\.id) : []
        let totalCount = favoriteIDs.count + collectionIDs.count
        guard totalCount > 0 else { return false }
        let selectedCount = favoriteIDs.filter(selection.selectedFavoriteIDs.contains).count
            + collectionIDs.filter(selection.selectedCollectionIDs.contains).count
        return selectedCount == totalCount
    }

    var hasVisibleSelectableEntries: Bool {
        !selectableFavoriteIDs.isEmpty || (isBrowsingUnscopedRoot && !derived.visibleCollections.isEmpty)
    }

    /// Select-all ↔ clear-all toggle (cache-sheet select-all button parity):
    /// not a strict per-item inversion — just select everything visible, or
    /// clear it all when everything is already selected.
    func toggleSelectAllVisible() {
        if isAllVisibleSelected {
            selection.clearSelection()
        } else {
            selectAllVisible()
        }
    }

    @discardableResult
    func createCollectionFromSelection(name: String, color: FavoriteCollectionColor = .gray) async -> LocalFavoriteCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let categoryID = selectedCategoryID
        let source = selectionSourceLocation
        guard !trimmed.isEmpty, !favoriteIDs.isEmpty else { return nil }
        let collection = await commit { document in
            let collection = document.createCollection(categoryID: categoryID, name: trimmed, color: color)
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: source
            )
            return collection
        }
        guard let collection else { return nil }
        selectedCollectionID = collection.id
        selection.exitSelectionMode()
        return collection
    }

    func moveSelectionToCategory(id categoryID: String) async {
        guard selection.selectedEntryCount > 0 else { return }
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let collectionIDs = selection.selectedCollectionIDs
        let source = selectionSourceLocation
        let committed: Void? = await commit { document in
            for collectionID in collectionIDs {
                document.moveCollection(id: collectionID, toCategoryID: categoryID)
            }
            document.moveItems(ids: favoriteIDs, to: .category(categoryID), removing: source)
        }
        guard committed != nil else { return }
        selectedCategoryID = categoryID
        selection.exitSelectionMode()
    }

    func moveSelectionToCollection(id collectionID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        let source = selectionSourceLocation
        guard !favoriteIDs.isEmpty,
              let collection = document.collections.first(where: { $0.id == collectionID }) else { return }
        let committed: Void? = await commit { document in
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: source
            )
        }
        guard committed != nil else { return }
        selectedCategoryID = collection.categoryID
        selectedCollectionID = collection.id
        selection.exitSelectionMode()
    }

    func addSelectionToCategory(id categoryID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !favoriteIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.moveItems(ids: favoriteIDs, to: .category(categoryID), removing: nil)
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func addSelectionToCollection(id collectionID: String) async {
        let favoriteIDs = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !favoriteIDs.isEmpty,
              let collection = document.collections.first(where: { $0.id == collectionID }) else { return }
        let committed: Void? = await commit { document in
            document.moveItems(
                ids: favoriteIDs,
                to: .collection(categoryID: collection.categoryID, collectionID: collection.id),
                removing: nil
            )
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    /// Whether all, some, or none of the selected items carry `location` —
    /// drives the tri-state boxes in the move sheet. Routed through
    /// `expandedSelectionFavoriteIDs` exactly like every other
    /// selection-consuming operation, so a selected smart card's tri-state
    /// readout reflects every favorite archived under it, not just its
    /// representative member.
    func selectionLocationState(_ location: FavoriteLocation) -> LocalFavoriteLocationTriState {
        let ids = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !ids.isEmpty else { return .none }
        let selectedItems = document.items.filter { ids.contains($0.id) }
        guard !selectedItems.isEmpty else { return .none }
        let count = selectedItems.filter { $0.locations.contains(location) }.count
        if count == 0 { return .none }
        return count == selectedItems.count ? .all : .some
    }

    /// Adds or removes one location on every selected item. Removal skips
    /// items whose last location it would be (an item always lives somewhere).
    /// Routed through `expandedSelectionFavoriteIDs` exactly like every other
    /// selection-consuming operation — this backs the move sheet
    /// (`LocalFavoriteSelectionMoveSheet`), the actual UI path a user hits
    /// when moving a selected smart card, so it must expand to every
    /// favorite archived under it rather than moving just the representative
    /// member.
    func setSelectionLocation(_ location: FavoriteLocation, included: Bool) async {
        let ids = expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
        guard !ids.isEmpty else { return }
        _ = await commit { document in
            if included {
                document.moveItems(ids: ids, to: location, removing: nil)
            } else {
                document.removeItems(ids: ids, from: location)
            }
        }
    }

    func removeSelectionFromCurrentLocation() async {
        let favoriteIDs = selection.selectedFavoriteIDs
        let source = selectionSourceLocation
        guard !favoriteIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            document.removeItems(ids: favoriteIDs, from: source)
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    func dissolveSelectedCollections() async {
        let collectionIDs = selection.selectedCollectionIDs
        guard !collectionIDs.isEmpty else { return }
        let committed: Void? = await commit { document in
            for collectionID in collectionIDs {
                document.dissolveCollection(id: collectionID)
            }
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }

    /// Entry point for the selection bar's delete: resolves whether the
    /// Yamibo counterparts should be deleted too through the SAME remembered
    /// choice every other remove entry point uses
    /// (`FavoriteRemoveRemoteDecision`), prompting when the user has not
    /// remembered one. `.currentLocation` never touches the website, so it
    /// skips the decision entirely.
    func requestDeleteSelection(scope: LocalFavoriteDeleteScope) async {
        switch scope {
        case .currentLocation:
            await deleteSelection(scope: .currentLocation, removeRemote: false)
        case .everywhere:
            // Must expand smart-card ids the SAME way `deleteSelection` is
            // about to when the setting is on, or the remote-delete
            // candidate set would silently exclude every archived member
            // but the representative — resolving "prompt vs. silent" (and,
            // if silent, whether to delete remote) from an undercounted
            // set, then deleting the full expanded set anyway.
            let deletableIDs = smartMangaBulkDeleteEnabled
                ? expandedSelectionFavoriteIDs(selection.selectedFavoriteIDs)
                : selection.selectedFavoriteIDs.filter { !isSmartCardFavoriteID($0) }
            let candidates = document.items.filter { deletableIDs.contains($0.id) }
            switch await resolveRemoveRemoteDecision(candidates: candidates) {
            case .prompt:
                removeRemotePrompt = LocalFavoriteRemoveRemotePrompt(subject: .selection)
            case let .silent(removeRemote):
                await deleteSelection(scope: .everywhere, removeRemote: removeRemote)
            }
        }
    }

    /// Same decision routing for a single card's delete dialog.
    func requestDeleteItem(_ item: FavoriteItem, scope: LocalFavoriteDeleteScope) async {
        switch scope {
        case .currentLocation:
            await deleteItem(item, scope: .currentLocation, removeRemote: false)
        case .everywhere:
            let latestItem = document.items.first { $0.id == item.id } ?? item
            switch await resolveRemoveRemoteDecision(candidates: [latestItem]) {
            case .prompt:
                removeRemotePrompt = LocalFavoriteRemoveRemotePrompt(subject: .item(item))
            case let .silent(removeRemote):
                await deleteItem(item, scope: .everywhere, removeRemote: removeRemote)
            }
        }
    }

    /// Completes a pending `removeRemotePrompt`: optionally persists the
    /// remembered choice (through the shared quick-actions write path), then
    /// runs the delete that raised the prompt.
    func confirmRemoveRemotePrompt(removeRemote: Bool, remember: Bool) async {
        guard let prompt = removeRemotePrompt else { return }
        removeRemotePrompt = nil
        if remember {
            await FavoriteQuickActions.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore)
        }
        switch prompt.subject {
        case let .item(item):
            await deleteItem(item, scope: .everywhere, removeRemote: removeRemote)
        case .selection:
            await deleteSelection(scope: .everywhere, removeRemote: removeRemote)
        }
    }

    /// Silent when no candidate plausibly exists on the website (nothing to
    /// ask about) or when the user remembered a choice; `.prompt` otherwise.
    private func resolveRemoveRemoteDecision(candidates: [FavoriteItem]) async -> FavoriteRemoveRemoteDecision {
        let canRemoveRemote = candidates.contains(where: \.hasYamiboRemoteCandidate)
        let settings = await settingsStore.load().favorites
        return FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote)
    }

    /// Routed through `expandedSelectionFavoriteIDs` when
    /// `smartMangaBulkDeleteEnabled` is on — unlike the off case, a smart
    /// card selected there is deleted along with every favorite currently
    /// archived under it, the same expansion every other selection-consuming
    /// operation already uses. When the setting is off, delete instead keeps
    /// requiring the dedicated "查看归档收藏" archive page for a smart card:
    /// a smart card can enter `selection.selectedFavoriteIDs` (Part D), so
    /// any such id is partitioned out and skipped entirely — deleting only
    /// the representative item while leaving every other archived member
    /// favorited would orphan them from their now-partially-deleted group,
    /// with no corresponding cleanup — the exact bug that originally
    /// justified excluding smart cards from selection altogether.
    func deleteSelection(scope: LocalFavoriteDeleteScope, removeRemote: Bool) async {
        guard selection.selectedEntryCount > 0 else { return }
        let allSelectedFavoriteIDs = selection.selectedFavoriteIDs
        let favoriteIDs: Set<String>
        if smartMangaBulkDeleteEnabled {
            favoriteIDs = expandedSelectionFavoriteIDs(allSelectedFavoriteIDs)
        } else {
            // `isSmartCardFavoriteID` deliberately does NOT look the id up
            // in `derived.cards` — see its own doc comment — precisely so a
            // smart card scrolled out of the current search/tag/source
            // filter while still selected still gets skipped here instead
            // of silently falling through to a lone, sibling-orphaning
            // delete below.
            let skippedSmartCardFavoriteIDs = allSelectedFavoriteIDs.filter(isSmartCardFavoriteID)
            favoriteIDs = allSelectedFavoriteIDs.subtracting(skippedSmartCardFavoriteIDs)
            if !skippedSmartCardFavoriteIDs.isEmpty {
                transientMessage = L10n.string("favorites.bulk_delete_skipped_smart_manga_message")
            }
        }
        let collectionIDs = selection.selectedCollectionIDs
        guard !favoriteIDs.isEmpty || !collectionIDs.isEmpty else {
            // Nothing left to delete once smart cards are skipped — still
            // exit selection mode so their now-stale ids don't linger
            // selected (`exitSelectionMode()` clears the whole selection
            // unconditionally).
            selection.exitSelectionMode()
            return
        }
        let source = selectionSourceLocation
        let deleter = remoteDeleter
        let committed: Void? = await commit { document in
            switch scope {
            case .currentLocation:
                document.removeItems(ids: favoriteIDs, from: source)
            case .everywhere:
                let selectedItems = document.items.filter { favoriteIDs.contains($0.id) }
                if removeRemote {
                    try await deleter.deleteRemoteFavorites(for: selectedItems)
                }
                for item in selectedItems {
                    document.removeItem(target: item.target)
                }
                for collectionID in collectionIDs {
                    document.dissolveCollection(id: collectionID)
                }
            }
        }
        guard committed != nil else { return }
        selection.exitSelectionMode()
    }
}
