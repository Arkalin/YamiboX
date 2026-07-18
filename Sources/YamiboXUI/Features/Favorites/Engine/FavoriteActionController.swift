import Foundation
import Observation
import YamiboXCore

/// The favorite-star orchestration shared by the forum detail pages: routes
/// the button through the remembered add/remove sync decisions, owns the
/// location-picker and prompt state, performs the local-first add / remove /
/// relocate calls via `FavoriteQuickActions`, and keeps `favorite` fresh by
/// observing the favorite library store.
///
/// Media differences stay with the owner: the add metadata (title, author,
/// forum, formHash, content date) is supplied at add time through
/// `makeAddMetadata`, and `onFavoriteDidChange` runs after every mutation or
/// external refresh (the novel detail page rebuilds its chapter directory
/// off favorite state).
@MainActor
@Observable
final class FavoriteActionController {
    /// Media-specific metadata captured at the moment an add executes, so it
    /// reflects the owner's current state (a manga's directory may have
    /// loaded after init; a novel's thread page carries the formHash).
    struct AddMetadata {
        var title: String
        var authorID: String?
        var forumID: String?
        var forumName: String?
        var contentUpdatedAt: Date?
        var formHash: String?

        init(
            title: String,
            authorID: String? = nil,
            forumID: String? = nil,
            forumName: String? = nil,
            contentUpdatedAt: Date? = nil,
            formHash: String? = nil
        ) {
            self.title = title
            self.authorID = authorID
            self.forumID = forumID
            self.forumName = forumName
            self.contentUpdatedAt = contentUpdatedAt
            self.formHash = formHash
        }
    }

    var favorite: Favorite?
    var errorMessage: String?
    var transientMessage: String?
    var addPromptPresented = false
    var removePrompt: FavoriteRemovePrompt?
    var locationPickerContext: FavoriteLocationPickerContext?
    /// Locations picked in `locationPickerContext`, consumed by the next
    /// `performAdd` — set only by `confirmLocationSelection`, so a plain
    /// (non-long-press) add still falls through to `addFavorite`'s
    /// default-category behavior.
    @ObservationIgnored private var pendingLocations: [FavoriteLocation]?

    private let threadID: String
    private let type: FavoriteType
    private let defaultTitle: String
    @ObservationIgnored private let dependencies: ForumDependencies
    /// Wired by the owner right after init (it needs `self` for its current
    /// media state, which Swift's init rules forbid while the controller
    /// property is still being assigned). Unset falls back to `defaultTitle`.
    @ObservationIgnored var makeAddMetadata: (@MainActor () async -> AddMetadata)?
    /// Runs after every favorite mutation or external refresh.
    @ObservationIgnored var onFavoriteDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private var favoriteUpdatesTask: Task<Void, Never>?

    init(
        threadID: String,
        type: FavoriteType,
        defaultTitle: String,
        dependencies: ForumDependencies
    ) {
        self.threadID = threadID
        self.type = type
        self.defaultTitle = defaultTitle
        self.dependencies = dependencies
        favoriteUpdatesTask = StoreChangeObservation.task(
            changes: { [store = dependencies.localFavoriteLibraryStore] in store.changes() },
            changeID: { [store = dependencies.localFavoriteLibraryStore] in store.changeID }
        ) { [weak self] in
            await self?.refreshFavorite()
        }
    }

    deinit {
        favoriteUpdatesTask?.cancel()
    }

    /// Routes the favorite button through the remembered add/remove sync
    /// choices: either performs the action silently or raises the prompt.
    func toggleFavorite() async {
        errorMessage = nil
        let settings = await dependencies.settingsStore.load().favorites

        if let favorite {
            let canRemoveRemote = favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                removePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }

        switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true) {
        case .prompt:
            addPromptPresented = true
        case let .silent(syncToRemote):
            await performAdd(syncToRemote: syncToRemote)
        }
    }

    func confirmAdd(syncToRemote: Bool, remember: Bool) async {
        addPromptPresented = false
        if remember {
            await FavoriteQuickActions.rememberAddSyncChoice(syncToRemote, settingsStore: dependencies.settingsStore)
        }
        await performAdd(syncToRemote: syncToRemote)
    }

    func confirmRemoval(_ favorite: Favorite, removeRemote: Bool, remember: Bool) async {
        removePrompt = nil
        if remember {
            await FavoriteQuickActions.rememberRemoveRemoteChoice(removeRemote, settingsStore: dependencies.settingsStore)
        }
        await performRemoval(favorite, removeRemote: removeRemote)
    }

    /// Star button long-press: opens the location picker pre-filled with
    /// this item's current locations (empty if not yet favorited).
    func presentLocationPicker() async {
        let document = (try? await dependencies.localFavoriteLibraryStore.load()) ?? FavoriteLibraryDocument()
        let currentLocations = await localFavoriteItem()?.locations ?? []
        locationPickerContext = FavoriteLocationPickerContext(
            document: document,
            initialSelection: Set(currentLocations),
            isFavorited: favorite != nil,
            localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore
        )
    }

    /// Routes the picker's confirmed selection: not-yet-favorited creates
    /// with those locations (still subject to the add-sync prompt); already
    /// favorited with a non-empty selection re-pins locally; already
    /// favorited with everything cleared is treated as unfavoriting, through
    /// the normal remove-sync decision — mirroring Android.
    func confirmLocationSelection(_ locations: Set<FavoriteLocation>) async {
        locationPickerContext = nil
        guard let favorite else {
            guard !locations.isEmpty else { return }
            pendingLocations = Array(locations)
            let settings = await dependencies.settingsStore.load().favorites
            switch FavoriteAddSyncDecision.resolve(settings: settings, canSyncRemote: true) {
            case .prompt:
                addPromptPresented = true
            case let .silent(syncToRemote):
                await performAdd(syncToRemote: syncToRemote)
            }
            return
        }
        guard !locations.isEmpty else {
            let settings = await dependencies.settingsStore.load().favorites
            let canRemoveRemote = favorite.remoteFavoriteID?.isEmpty == false
            switch FavoriteRemoveRemoteDecision.resolve(settings: settings, canRemoveRemote: canRemoveRemote) {
            case .prompt:
                removePrompt = FavoriteRemovePrompt(favorite: favorite)
            case let .silent(removeRemote):
                await performRemoval(favorite, removeRemote: removeRemote)
            }
            return
        }
        await performRelocate(Array(locations))
    }

    func clearError() {
        errorMessage = nil
    }

    func clearTransientMessage() {
        transientMessage = nil
    }

    /// Reloads `favorite` from the local library (initial load and
    /// store-change notifications).
    func refreshFavorite() async {
        favorite = await localFavoriteItem()?.favorite(type: type)
        onFavoriteDidChange?()
    }

    private func performAdd(syncToRemote: Bool) async {
        let locations = pendingLocations
        pendingLocations = nil
        do {
            let metadata = await makeAddMetadata?() ?? AddMetadata(title: defaultTitle)
            let result = try await FavoriteQuickActions.addFavorite(
                threadID: threadID,
                title: metadata.title,
                type: type,
                authorID: metadata.authorID,
                forumID: metadata.forumID,
                forumName: metadata.forumName,
                contentUpdatedAt: metadata.contentUpdatedAt,
                locations: locations,
                formHash: metadata.formHash,
                syncToRemote: syncToRemote,
                boardReaderSettings: await dependencies.settingsStore.load().boardReader,
                localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
                remoteRepository: await dependencies.makeFavoriteRepository()
            )
            favorite = result.favorite
            transientMessage = result.remote.addFeedbackMessage
            onFavoriteDidChange?()
        } catch {
            errorMessage = error.localizedDescription
            favorite = await localFavoriteItem()?.favorite(type: type)
            onFavoriteDidChange?()
        }
    }

    private func performRelocate(_ locations: [FavoriteLocation]) async {
        do {
            try await FavoriteQuickActions.relocateFavorite(
                threadID: threadID,
                locations: locations,
                localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore
            )
            transientMessage = L10n.string("favorites.quick.relocated")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func performRemoval(_ favorite: Favorite, removeRemote: Bool) async {
        do {
            try await FavoriteQuickActions.removeFavorite(
                favorite,
                removeRemote: removeRemote,
                boardReaderSettings: await dependencies.settingsStore.load().boardReader,
                localFavoriteLibraryStore: dependencies.localFavoriteLibraryStore,
                remoteRepository: await dependencies.makeFavoriteRepository()
            )
            self.favorite = nil
            transientMessage = removeRemote
                ? L10n.string("favorites.quick.removed_with_remote")
                : L10n.string("favorites.quick.removed")
            onFavoriteDidChange?()
        } catch {
            errorMessage = error.localizedDescription
            self.favorite = await localFavoriteItem()?.favorite(type: type)
            onFavoriteDidChange?()
        }
    }

    private func localFavoriteItem() async -> FavoriteItem? {
        let target = favoriteTarget
        return (try? await dependencies.localFavoriteLibraryStore.load())?.items.first { item in
            item.target.id == target.id || item.target.threadID == target.threadID
        }
    }

    private var favoriteTarget: FavoriteItemTarget {
        switch type {
        case .manga:
            .mangaThread(threadID: threadID)
        case .novel:
            .novelThread(threadID: threadID)
        default:
            .normalThread(threadID: threadID)
        }
    }
}
