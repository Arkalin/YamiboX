import Foundation
import Observation
import YamiboXCore

protocol ForumBoardPageLoading: Sendable {
    func cachedForumBoard(
        fid: String,
        page: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?,
        allowExpired: Bool
    ) async -> ForumBoardPage?

    func fetchForumBoard(
        fid: String,
        title: String?,
        page: Int,
        filterID: String?,
        orderFilter: String?,
        orderBy: String?,
        preferCache: Bool
    ) async throws -> ForumBoardPage

    func addBoardFavorite(fid: String, formHash: String?) async throws -> String
}

extension ForumRepository: ForumBoardPageLoading {}

@MainActor
@Observable
final class ForumBoardViewModel {
    var page: ForumBoardPage?
    var errorMessage: String?
    var favoriteMessage: String?
    var transientMessage: String?
    var isLoading = false
    var isRefreshing = false
    var isFavoriting = false
    var selectedFilterID: String?
    var selectedOrderOptionID: String?
    var currentPage: Int
    var boardReaderEntry: BoardReaderSettings.Entry?
    var boardReaderErrorMessage: String?

    let fid: String
    let initialTitle: String?

    @ObservationIgnored private let settingsStore: SettingsStore?
    @ObservationIgnored private let repositoryProvider: @Sendable () async -> any ForumBoardPageLoading
    @ObservationIgnored private var generation = 0
    /// Serializes this view model's two unstructured settings writers (mode
    /// saves and board-name-snapshot refreshes): each new write awaits the
    /// previous one, so a slow earlier write can never land after — and
    /// silently undo — a later one.
    @ObservationIgnored private var boardReaderWriteTask: Task<Void, Never>?

    init(fid: String, title: String?, initialPage: Int = 1, dependencies: ForumDependencies) {
        self.fid = fid
        initialTitle = title
        currentPage = max(1, initialPage)
        settingsStore = dependencies.settingsStore
        repositoryProvider = {
            await dependencies.makeForumRepository()
        }
    }

    init(
        fid: String,
        title: String?,
        initialPage: Int = 1,
        repository: any ForumBoardPageLoading,
        settingsStore: SettingsStore? = nil
    ) {
        self.fid = fid
        initialTitle = title
        currentPage = max(1, initialPage)
        self.settingsStore = settingsStore
        repositoryProvider = {
            repository
        }
    }

    var title: String {
        page?.board.name ?? initialTitle ?? L10n.string("forum.board")
    }

    var subBoards: [ForumBoardSummary] {
        page?.subBoards ?? []
    }

    var pinnedItems: [ForumPinnedItem] {
        page?.pinnedItems ?? []
    }

    var threads: [ForumThreadSummary] {
        page?.threads ?? []
    }

    var pageNavigation: ForumPageNavigation? {
        page?.pageNavigation
    }

    var filters: [ForumFilterOption] {
        page?.filters ?? []
    }

    var orders: [ForumOrderOption] {
        page?.orders ?? []
    }

    var selectedFilterTitle: String {
        filters.first(where: { $0.id == selectedFilterID })?.title ?? L10n.string("forum.board.all")
    }

    var selectedOrderTitle: String {
        selectedOrderOption?.title ?? L10n.string("forum.board.all")
    }

    private var selectedOrderOption: ForumOrderOption? {
        orders.first(where: { $0.id == selectedOrderOptionID })
    }

    func load() async {
        guard !isLoading else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        // Only the latest-generation request may clear the spinners — a
        // superseded request finishing must not hide the indicator of the
        // newer request still in flight. Both flags are cleared because a
        // load/goToPage can supersede a refresh and vice versa; the stale
        // request's own defer no longer runs its reset.
        defer {
            if requestGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }

        let repository = await repositoryProvider()
        if let cached = await repository.cachedForumBoard(
            fid: fid,
            page: currentPage,
            filterID: selectedFilterID,
            orderFilter: selectedOrderOption?.filter,
            orderBy: selectedOrderOption?.orderBy,
            allowExpired: false
        ) {
            apply(cached)
            return
        }

        await fetchPage(currentPage, preferCache: false, failurePresentation: .pageError, requestGeneration: requestGeneration)
    }

    func refresh() async {
        // The reentry guard must precede the generation bump: a second
        // refresh that early-returns after bumping would turn the in-flight
        // refresh stale without starting a replacement, discarding its
        // response and leaving `isRefreshing` stuck true forever.
        guard !isRefreshing else { return }
        generation += 1
        await refresh(requestGeneration: generation)
    }

    func goToPage(_ page: Int) async {
        let nextPage = max(1, page)
        guard nextPage != currentPage else { return }
        generation += 1
        let requestGeneration = generation
        let requestOrderOption = selectedOrderOption
        currentPage = nextPage
        self.page = nil
        errorMessage = nil
        transientMessage = nil
        isLoading = true
        defer {
            if requestGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }
        await fetchPage(
            nextPage,
            preferCache: true,
            orderFilter: requestOrderOption?.filter,
            orderBy: requestOrderOption?.orderBy,
            failurePresentation: .pageError,
            requestGeneration: requestGeneration
        )
    }

    func selectFilter(id: String?) async {
        guard selectedFilterID != id else { return }
        selectedFilterID = id
        currentPage = 1
        await reloadForOptionChange()
    }

    func selectOrder(id: String?) async {
        guard selectedOrderOptionID != id else { return }
        selectedOrderOptionID = id
        currentPage = 1
        await reloadForOptionChange()
    }

    func addFavorite() async {
        guard !isFavoriting else { return }
        isFavoriting = true
        defer { isFavoriting = false }

        do {
            let repository = await repositoryProvider()
            // Success is a lightweight confirmation: surface it through the
            // non-modal transient channel; only failures interrupt via alert.
            transientMessage = try await repository.addBoardFavorite(fid: fid, formHash: page?.formHash)
        } catch {
            favoriteMessage = error.localizedDescription
        }
    }

    func clearTransientMessage() {
        transientMessage = nil
    }

    /// Single source of truth for the reader-settings sheet: the persisted
    /// entry for this board, loaded when the sheet opens and optimistically
    /// updated by `setBoardReaderMode(_:)`.
    func refreshBoardReaderEntry() async {
        guard let settingsStore else { return }
        let entryBeforeLoad = boardReaderEntry
        let loaded = await settingsStore.load().boardReader.entry(forumID: fid)
        // An optimistic update from `setBoardReaderMode(_:)` during the load
        // must not be clobbered by the stale stored value.
        guard boardReaderEntry == entryBeforeLoad else { return }
        boardReaderEntry = loaded
    }

    /// Every mode — including `.normal` (an explicit 普通 choice writes an
    /// entry rather than removing one, R12) — persists as an entry. Every
    /// save stamps the current board-name snapshot: the loaded page's real
    /// name, falling back to the entry's existing snapshot while the page is
    /// unavailable, else `nil` — never a placeholder string.
    func setBoardReaderMode(_ mode: BoardReaderSettings.ReaderMode) {
        guard let settingsStore else { return }
        let previous = boardReaderEntry
        let boardName = boardNameSnapshot ?? previous?.boardName
        let updated = BoardReaderSettings.Entry(mode: mode, boardName: boardName)
        boardReaderEntry = updated

        let fid = fid
        let previousWrite = boardReaderWriteTask
        boardReaderWriteTask = Task {
            await previousWrite?.value
            do {
                // Atomic entry-level mutation: `SettingsStore.update` applies
                // it to freshly loaded settings inside the actor, so it can
                // never clobber a concurrent writer's save with a stale blob.
                try await settingsStore.update { settings in
                    settings.boardReader.setEntry(updated, forumID: fid)
                }
            } catch {
                if boardReaderEntry == updated {
                    boardReaderEntry = previous
                }
                boardReaderErrorMessage = error.localizedDescription
            }
        }
    }

    private var boardNameSnapshot: String? {
        guard let name = page?.board.name, !name.isEmpty else { return nil }
        return name
    }

    private func reloadForOptionChange() async {
        generation += 1
        let requestGeneration = generation
        let requestOrderOption = selectedOrderOption
        page = nil
        errorMessage = nil
        transientMessage = nil
        isLoading = true
        defer {
            if requestGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }
        await fetchPage(
            1,
            preferCache: true,
            orderFilter: requestOrderOption?.filter,
            orderBy: requestOrderOption?.orderBy,
            failurePresentation: .pageError,
            requestGeneration: requestGeneration
        )
    }

    private func refresh(requestGeneration: Int) async {
        isRefreshing = true
        defer {
            if requestGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }
        await fetchPage(currentPage, preferCache: false, failurePresentation: .refreshToast, requestGeneration: requestGeneration)
    }

    private func fetchPage(
        _ pageNumber: Int,
        preferCache: Bool,
        orderFilter: String? = nil,
        orderBy: String? = nil,
        failurePresentation: FailurePresentation,
        requestGeneration: Int
    ) async {
        do {
            let repository = await repositoryProvider()
            let nextPage = try await repository.fetchForumBoard(
                fid: fid,
                title: initialTitle,
                page: pageNumber,
                filterID: selectedFilterID,
                orderFilter: orderFilter ?? selectedOrderOption?.filter,
                orderBy: orderBy ?? selectedOrderOption?.orderBy,
                preferCache: preferCache
            )
            guard requestGeneration == generation else { return }
            apply(nextPage)
            errorMessage = nil
            transientMessage = nil
        } catch {
            guard requestGeneration == generation else { return }
            if failurePresentation == .refreshToast, page != nil {
                errorMessage = nil
                transientMessage = L10n.string("forum.board.refresh_failed", error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ page: ForumBoardPage) {
        self.page = page
        currentPage = page.pageNavigation?.currentPage ?? currentPage
        refreshBoardNameSnapshotIfNeeded(with: page.board.name)
    }

    /// Visiting the board page silently refreshes an existing entry's
    /// board-name snapshot (PRD decision #2). Only refreshes — never creates
    /// an entry — and skips the write entirely when the stored name already
    /// matches, so routine visits do not touch the settings store.
    private func refreshBoardNameSnapshotIfNeeded(with boardName: String) {
        guard let settingsStore, !boardName.isEmpty else { return }
        let fid = fid
        let previousWrite = boardReaderWriteTask
        boardReaderWriteTask = Task {
            await previousWrite?.value
            do {
                // Guarded inside the atomic mutation so it re-checks *fresh*
                // state: if a serialized-just-before mode save removed the
                // entry, this refresh sees that and skips — it can never
                // resurrect a removed entry from a stale copy. An unchanged
                // name leaves the settings untouched, so `update` skips the
                // save entirely and routine visits don't touch the store.
                try await settingsStore.update { settings in
                    guard var entry = settings.boardReader.entry(forumID: fid),
                          entry.boardName != boardName else { return }
                    entry.boardName = boardName
                    settings.boardReader.setEntry(entry, forumID: fid)
                }
            } catch {
                YamiboLog.persistence.warning("Failed to refresh board name snapshot for fid \(fid): \(error)")
            }
        }
    }

    private enum FailurePresentation {
        case pageError
        case refreshToast
    }
}
