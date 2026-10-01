import Foundation
import Observation
import YamiboXCore

struct FavoriteGroupRemovalPrompt: Identifiable {
    let id = UUID()
    let membership: FavoriteMembership
    let asksRemote: Bool
    let removeRemote: Bool
}

enum FavoriteMemberManagement: String, Identifiable {
    case archive, locations
    var id: String { rawValue }
}

/// The resolved members drive both star presentation and mutations.
@MainActor
@Observable
final class FavoriteActionController {
    struct AddMetadata {
        var title: String
        var authorID: String? = nil
        var forumID: String? = nil
        var forumName: String? = nil
        var contentUpdatedAt: Date? = nil
        var formHash: String? = nil
        var localTargetKindOverride: FavoriteItemTargetKind? = nil
    }

    private(set) var favorite: Favorite?
    private(set) var membership: FavoriteMembership?
    private(set) var document = FavoriteLibraryDocument()
    private(set) var isReady = false
    private(set) var isWorking = false
    private(set) var bulkDeleteEnabled = true
    var errorMessage: String? { didSet { errorDetails = nil } }
    var errorDetails: LoadFailureDetails?
    var transientFeedback: TransientFeedback?
    var transientMessage: String? {
        get { transientFeedback?.message }
        set { transientFeedback = newValue.map { TransientFeedback(message: $0) } }
    }
    var addPromptPresented = false
    var removePrompt: FavoriteRemovePrompt?
    var groupRemovalPrompt: FavoriteGroupRemovalPrompt?
    var management: FavoriteMemberManagement?
    var locationPickerContext: FavoriteLocationPickerContext?

    var isFavorited: Bool { membership?.isFavorited == true }
    var canAct: Bool { isReady && !isWorking }
    var members: [FavoriteItem] { membership?.items ?? [] }
    var accessibilityLabel: String {
        guard isReady else { return L10n.string(errorMessage == nil ? "common.loading" : "common.load_failed") }
        if isFavorited, membership?.isSmartManga == true {
            return L10n.string(bulkDeleteEnabled ? "favorites.work.remove" : "favorites.view_archived_favorites")
        }
        return L10n.string(isFavorited ? "history.favorite.remove" : "history.favorite.add")
    }

    private let threadID: String
    private let type: FavoriteType
    private let defaultTitle: String
    private let allowsAdd: Bool
    private var scope: FavoriteMembershipScope
    @ObservationIgnored private let libraryStore: FavoriteLibraryStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let directoryStore: (any MangaDirectoryBatchReading & MangaDirectoryChangeObserving)?
    @ObservationIgnored private let makeFavoriteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    @ObservationIgnored var makeAddMetadata: (@MainActor () async -> AddMetadata)?
    @ObservationIgnored var didAddFavorite: (@MainActor (FavoriteCommands.AddResult) async -> TransientFeedback)?
    @ObservationIgnored var onFavoriteDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private var pendingLocations: [FavoriteLocation]?
    @ObservationIgnored private var updates: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var storeRevision = 0
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var observedBoardReader: BoardReaderSettings?
    @ObservationIgnored private var observedBulkDelete: Bool?

    init(
        threadID: String, type: FavoriteType, defaultTitle: String,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        settingsStore: SettingsStore,
        makeFavoriteRepository: @escaping @Sendable () async -> any ForumThreadFavoriteRemoteOperating,
        scope: FavoriteMembershipScope? = nil,
        mangaDirectoryStore: (any MangaDirectoryBatchReading & MangaDirectoryChangeObserving)? = nil,
        allowsAdd: Bool = true
    ) {
        self.threadID = threadID
        self.type = type
        self.defaultTitle = defaultTitle
        self.allowsAdd = allowsAdd
        self.scope = scope ?? .thread(threadID)
        libraryStore = localFavoriteLibraryStore
        self.settingsStore = settingsStore
        directoryStore = mangaDirectoryStore
        self.makeFavoriteRepository = makeFavoriteRepository
        let streams = [localFavoriteLibraryStore.changes()]
            + (mangaDirectoryStore.map { [$0.changes()] } ?? [])
        for stream in streams {
            updates.append(Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.storeRevision += 1
                    // Do not supersede a command's preflight read. It retries
                    // if invalidated, and refreshes again when the command ends.
                    if self.isWorking { self.needsRefresh = true; continue }
                    await self.refreshFavorite()
                }
            })
        }
        let settingsChanges = settingsStore.changes()
        updates.append(Task { [weak self, settingsStore] in
            for await _ in settingsChanges {
                guard !Task.isCancelled, let self else { return }
                let settings = await settingsStore.load()
                guard self.observedBoardReader != settings.boardReader
                    || self.observedBulkDelete != settings.favorites.smartMangaBulkDeleteEnabled else { continue }
                self.storeRevision += 1
                if self.isWorking { self.needsRefresh = true; continue }
                await self.refreshFavorite()
            }
        })
    }

    deinit { for task in updates { task.cancel() } }

    func updateScope(_ scope: FavoriteMembershipScope) async {
        self.scope = scope
        await refreshFavorite()
    }

    @discardableResult
    func refreshFavorite() async -> Bool {
        generation += 1
        let current = generation
        let revision = storeRevision
        do {
            let settings = await settingsStore.load()
            let snapshot = try await FavoriteMembershipSnapshot.load(
                libraryStore: libraryStore, directoryStore: directoryStore,
                boardReader: settings.boardReader, additionalThreadIDs: [scope.threadID]
            )
            guard current == generation, !Task.isCancelled else { return false }
            guard revision == storeRevision else { return await refreshFavorite() }
            let resolvedMembership = snapshot.membership(for: scope)
            let didChange = !isReady || membership != resolvedMembership
                || bulkDeleteEnabled != settings.favorites.smartMangaBulkDeleteEnabled
            membership = resolvedMembership
            document = snapshot.document
            favorite = membership?.items.first?.favorite(type: type)
            bulkDeleteEnabled = settings.favorites.smartMangaBulkDeleteEnabled
            observedBoardReader = settings.boardReader
            observedBulkDelete = bulkDeleteEnabled
            isReady = true
            if didChange { onFavoriteDidChange?() }
            return true
        } catch {
            guard current == generation, !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return false }
            isReady = false
            report(error)
            return false
        }
    }

    func toggleFavorite() async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        errorMessage = nil
        pendingLocations = nil
        guard await refreshFavorite(), let membership else { return }
        if membership.isFavorited {
            if membership.isSmartManga {
                await requestGroupRemoval(membership)
            } else if let favorite {
                await requestThreadRemoval(favorite)
            }
        } else {
            await requestAdd()
        }
    }

    private func requestAdd() async {
        guard allowsAdd else { return }
        switch FavoriteAddSyncDecision.resolve(settings: await settingsStore.load().favorites, canSyncRemote: true) {
        case .prompt: addPromptPresented = true
        case let .silent(syncToRemote): await performAdd(syncToRemote: syncToRemote)
        }
    }

    private func requestThreadRemoval(_ favorite: Favorite) async {
        switch FavoriteRemoveRemoteDecision.resolve(
            settings: await settingsStore.load().favorites,
            canRemoveRemote: members.contains(where: \.hasYamiboRemoteCandidate)
        ) {
        case .prompt: removePrompt = FavoriteRemovePrompt(favorite: favorite)
        case let .silent(removeRemote): await performRemoval(favorite, removeRemote: removeRemote)
        }
    }

    private func requestGroupRemoval(_ membership: FavoriteMembership) async {
        let settings = await settingsStore.load().favorites
        guard settings.smartMangaBulkDeleteEnabled else {
            management = .archive
            return
        }
        let decision = FavoriteRemoveRemoteDecision.resolve(
            settings: settings, canRemoveRemote: membership.items.contains(where: \.hasYamiboRemoteCandidate)
        )
        switch decision {
        case .prompt:
            groupRemovalPrompt = FavoriteGroupRemovalPrompt(membership: membership, asksRemote: true, removeRemote: false)
        case let .silent(removeRemote):
            groupRemovalPrompt = FavoriteGroupRemovalPrompt(membership: membership, asksRemote: false, removeRemote: removeRemote)
        }
    }

    func confirmGroupRemoval(_ prompt: FavoriteGroupRemovalPrompt, removeRemote: Bool, remember: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        guard await refreshFavorite(), let membership, membership.isFavorited else { return }
        guard membership.isSmartManga else {
            transientMessage = L10n.string("favorites.work.changed")
            return
        }
        guard bulkDeleteEnabled else { management = .archive; return }
        guard membership.favoriteIDs == prompt.membership.favoriteIDs,
              membership.smartMangaTitle == prompt.membership.smartMangaTitle else {
            await requestGroupRemoval(membership)
            return
        }
        if remember { await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore) }
        do {
            _ = try await FavoriteCommands.deleteFavorites(
                FavoriteDeletionRequest(favoriteIDs: prompt.membership.favoriteIDs, scope: .everywhere(removeRemote: removeRemote)),
                localFavoriteLibraryStore: libraryStore, makeRemoteRepository: makeFavoriteRepository
            )
            await refreshFavorite()
            transientMessage = L10n.string(removeRemote ? "favorites.quick.removed_with_remote" : "favorites.quick.removed")
        } catch { report(error); await refreshFavorite() }
    }

    func confirmAdd(syncToRemote: Bool, remember: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        addPromptPresented = false
        if remember { await FavoriteCommands.rememberAddSyncChoice(syncToRemote, settingsStore: settingsStore) }
        await performAdd(syncToRemote: syncToRemote)
    }

    func confirmRemoval(_ favorite: Favorite, removeRemote: Bool, remember: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        removePrompt = nil
        if remember { await FavoriteCommands.rememberRemoveRemoteChoice(removeRemote, settingsStore: settingsStore) }
        await performRemoval(favorite, removeRemote: removeRemote)
    }

    func presentLocationPicker() async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        guard await refreshFavorite(), let membership else { return }
        guard allowsAdd || membership.isFavorited else { return }
        if membership.isSmartManga, membership.isFavorited {
            management = .locations
            return
        }
        locationPickerContext = FavoriteLocationPickerContext(
            document: document, initialSelection: Set(members.first?.locations ?? []),
            isFavorited: isFavorited, localFavoriteLibraryStore: libraryStore
        )
    }

    func confirmLocationSelection(_ locations: Set<FavoriteLocation>) async {
        guard !isWorking else { return }
        isWorking = true
        defer { finishOperation() }
        locationPickerContext = nil
        guard await refreshFavorite(), let membership else { return }
        // A sibling may have been added while the new-item picker was open.
        // Never reinterpret its empty selection as a group deletion.
        if membership.isSmartManga, membership.isFavorited {
            management = .locations
            return
        }
        if let favorite {
            guard !locations.isEmpty else { await requestThreadRemoval(favorite); return }
            do {
                try await FavoriteCommands.relocateFavorite(threadID: threadID, locations: Array(locations), localFavoriteLibraryStore: libraryStore)
                await refreshFavorite()
                transientMessage = L10n.string("favorites.quick.relocated")
            } catch { report(error) }
        } else if !locations.isEmpty {
            pendingLocations = Array(locations)
            await requestAdd()
        }
    }

    func locationState(_ location: FavoriteLocation) -> LocalFavoriteLocationTriState {
        let count = members.filter { $0.locations.contains(location) }.count
        if count == 0 { return .none }
        return count == members.count ? .all : .some
    }

    func setMemberLocation(_ location: FavoriteLocation, included: Bool) async {
        guard !isWorking, let displayed = membership else { return }
        isWorking = true
        defer { finishOperation() }
        guard await refreshFavorite(), let membership else { return }
        guard membership.favoriteIDs == displayed.favoriteIDs, membership.smartMangaTitle == displayed.smartMangaTitle else {
            transientMessage = L10n.string("favorites.work.changed")
            return
        }
        let ids = membership.favoriteIDs
        do {
            try await libraryStore.update { document in
                if included { document.moveItems(ids: ids, to: location, removing: nil) }
                else { document.removeItems(ids: ids, from: location) }
            }
            await refreshFavorite()
        } catch { report(error) }
    }

    func actions(for item: FavoriteItem) -> FavoriteActionController {
        FavoriteActionController(
            threadID: item.target.threadID ?? "", type: type, defaultTitle: item.resolvedDisplayTitle,
            localFavoriteLibraryStore: libraryStore, settingsStore: settingsStore,
            makeFavoriteRepository: makeFavoriteRepository, allowsAdd: false
        )
    }

    func clearError() { errorMessage = nil }
    func clearTransientMessage() { transientMessage = nil }

    private func finishOperation() {
        isWorking = false
        guard needsRefresh else { return }
        needsRefresh = false
        Task { [weak self] in await self?.refreshFavorite() }
    }

    private func performAdd(syncToRemote: Bool) async {
        guard allowsAdd else { return }
        let locations = pendingLocations
        pendingLocations = nil
        guard await refreshFavorite() else { return }
        guard !isFavorited else { transientMessage = L10n.string("favorites.work.changed"); return }
        do {
            let metadata = await makeAddMetadata?() ?? AddMetadata(title: defaultTitle)
            let result = try await FavoriteCommands.addFavorite(
                threadID: threadID, title: metadata.title, type: type,
                authorID: metadata.authorID, forumID: metadata.forumID, forumName: metadata.forumName,
                contentUpdatedAt: metadata.contentUpdatedAt, localTargetKindOverride: metadata.localTargetKindOverride,
                locations: locations, formHash: metadata.formHash, syncToRemote: syncToRemote,
                boardReaderSettings: await settingsStore.load().boardReader,
                localFavoriteLibraryStore: libraryStore, remoteRepository: await makeFavoriteRepository()
            )
            await refreshFavorite()
            transientFeedback = await didAddFavorite?(result) ?? result.feedback
        } catch { report(error); await refreshFavorite() }
    }

    private func performRemoval(_ favorite: Favorite, removeRemote: Bool) async {
        guard await refreshFavorite() else { return }
        guard let currentFavorite = self.favorite, currentFavorite.id == favorite.id,
              membership?.isSmartManga == false else {
            transientMessage = L10n.string("favorites.work.changed")
            return
        }
        do {
            try await FavoriteCommands.removeFavorite(
                currentFavorite, removeRemote: removeRemote, boardReaderSettings: await settingsStore.load().boardReader,
                localFavoriteLibraryStore: libraryStore,
                remoteRepository: removeRemote ? await makeFavoriteRepository() : nil
            )
            await refreshFavorite()
            transientMessage = L10n.string(removeRemote ? "favorites.quick.removed_with_remote" : "favorites.quick.removed")
        } catch { report(error); await refreshFavorite() }
    }

    private func report(_ error: any Error) {
        guard !Task.isCancelled, !LoadDiagnosticError.isCancellation(error) else { return }
        errorMessage = error.localizedDescription
        errorDetails = LoadFailureDetails(error: error)
        YamiboLog.library.warning("Favorite action failed: \(error)")
    }
}
