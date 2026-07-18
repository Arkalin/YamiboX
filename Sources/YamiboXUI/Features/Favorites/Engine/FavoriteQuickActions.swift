import Foundation
import YamiboXCore

protocol ForumThreadFavoriteRemoteOperating: Sendable {
    func addThreadFavorite(threadID: String, formHash: String?, resolveRemoteFavorite: Bool) async throws -> Favorite?
    func deleteFavorite(remoteFavoriteID: String) async throws
    func remoteFavorite(forThreadID threadID: String, maxPages: Int) async throws -> Favorite?
}

extension FavoriteRepository: ForumThreadFavoriteRemoteOperating {}

/// Local-first quick actions for single favorites (reader star button, detail
/// pages, favorite item menus), plus the shared decision/remember layer every
/// favorite entry point routes through.
///
/// Adding writes the local library first and reports the optional Yamibo push
/// separately — a remote failure never rolls the local favorite back. Deleting
/// with `removeRemote` inverts that: the remote delete runs first, so its
/// failure throws and leaves the local item intact (no half-deleted state).
///
/// ## Terminology (add/import/push/sync boundaries)
/// - **add** — a user-initiated favorite creation: local write first, then
///   an optional immediate Yamibo push per `FavoriteAddSyncDecision`.
/// - **upsert** — the document-level write primitive
///   (`FavoriteLibraryDocument.upsertItem`); replaces by target, never
///   touches the network.
/// - **import** — the sync engine materializing a remote favorite locally
///   (`FavoriteLibraryDocument.importThreadFavorite`).
/// - **push** — transmitting one existing local favorite to Yamibo
///   (`pushFavoriteItemToYamibo`); no local content change beyond the
///   remote mapping.
/// - **sync** — reserved for the bidirectional union engine
///   (`FavoriteYamiboSyncEngine`), which never deletes on either side.
/// - **remove/delete** — local record removal; whether the Yamibo
///   counterpart is deleted too is a separate decision resolved through
///   `FavoriteRemoveRemoteDecision` (never implied by the operation itself).
enum FavoriteQuickActions {
    /// Outcome of a Yamibo push attached to an add or single-item sync.
    enum RemotePushResult: Equatable, Sendable {
        case notAttempted
        case synced
        /// Pushed to Yamibo, but the favorite id could not be resolved yet;
        /// the next sync run backfills the mapping.
        case syncedWithoutMapping
        case failed(String)
    }

    struct AddResult: Sendable {
        var favorite: Favorite
        var remote: RemotePushResult
    }

    static func addFavorite(
        threadID: String,
        title: String,
        type: FavoriteType,
        authorID: String?,
        forumID: String? = nil,
        forumName: String? = nil,
        contentUpdatedAt: Date? = nil,
        localTargetKindOverride: FavoriteItemTargetKind? = nil,
        /// Locations to file the new favorite under, e.g. from the star
        /// button's long-press location picker. Nil or empty falls back to
        /// the default category — every existing call site keeps working
        /// unchanged.
        locations: [FavoriteLocation]? = nil,
        formHash: String?,
        syncToRemote: Bool,
        boardReaderSettings: BoardReaderSettings,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        remoteRepository: (any ForumThreadFavoriteRemoteOperating)?
    ) async throws -> AddResult {
        let favorite = Favorite(title: title, threadID: threadID, authorID: authorID, type: type)
        let item = try await upsertLocalFirstFavorite(
            favorite,
            forumID: forumID,
            forumName: forumName,
            contentUpdatedAt: contentUpdatedAt,
            localTargetKindOverride: localTargetKindOverride,
            locations: locations,
            boardReaderSettings: boardReaderSettings,
            localFavoriteLibraryStore: localFavoriteLibraryStore
        )
        guard syncToRemote, let remoteRepository else {
            return AddResult(favorite: item.favorite(type: type), remote: .notAttempted)
        }
        do {
            let remoteFavorite = try await remoteRepository.addThreadFavorite(
                threadID: threadID,
                formHash: formHash,
                resolveRemoteFavorite: true
            )
            guard let remoteFavoriteID = normalizedRemoteFavoriteID(remoteFavorite?.remoteFavoriteID) else {
                return AddResult(favorite: item.favorite(type: type), remote: .syncedWithoutMapping)
            }
            try await localFavoriteLibraryStore.update { document in
                document.updateRemoteMapping(for: item.target, yamiboFavoriteID: remoteFavoriteID, yamiboRemoteOrder: nil)
            }
            var synced = item
            synced.remoteMapping = FavoriteRemoteMapping(yamiboFavoriteID: remoteFavoriteID, lastSeenAt: .now)
            return AddResult(favorite: synced.favorite(type: type), remote: .synced)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AddResult(favorite: item.favorite(type: type), remote: .failed(message))
        }
    }

    /// With `removeRemote`, an unmapped favorite gets one remote lookup;
    /// finding nothing just means there is nothing to delete on the website.
    static func removeFavorite(
        _ favorite: Favorite,
        removeRemote: Bool,
        boardReaderSettings: BoardReaderSettings,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        remoteRepository: (any ForumThreadFavoriteRemoteOperating)?
    ) async throws {
        if removeRemote, let remoteRepository {
            if let remoteFavoriteID = normalizedRemoteFavoriteID(favorite.remoteFavoriteID) {
                try await remoteRepository.deleteFavorite(remoteFavoriteID: remoteFavoriteID)
            } else if let remoteFavorite = try await remoteRepository.remoteFavorite(forThreadID: favorite.threadID, maxPages: 30),
                      let remoteFavoriteID = normalizedRemoteFavoriteID(remoteFavorite.remoteFavoriteID) {
                try await remoteRepository.deleteFavorite(remoteFavoriteID: remoteFavoriteID)
            }
        }
        try await localFavoriteLibraryStore.update { document in
            // Classification is now forumID-dependent (decision #4), but
            // `Favorite` carries no forumID and every toggle-favorite call
            // site passes `.other` regardless of board — re-deriving the
            // target from `favorite` alone here (as `localTarget(for:)` did
            // pre-Phase-F) would risk computing a different `.id` than the
            // one actually persisted for a manga-board thread (e.g.
            // `manga-thread:704` vs `thread:normal:704`), silently turning
            // this into a no-op for exactly the boards this phase adds
            // support for. Look up the *actually stored* item by threadID
            // and remove its real target instead; only fall back to
            // re-deriving a target when no matching item exists (nothing to
            // look up — e.g. a concurrent removal already won).
            let target = document.items.first { $0.target.threadID == favorite.threadID }?.target
                ?? (try? localTarget(for: favorite, forumID: nil, boardReaderSettings: boardReaderSettings))
            guard let target else { return }
            document.removeItem(target: target)
        }
    }

    /// Re-pins an already-favorited item to exactly `locations` — the star
    /// button's long-press location picker, applied to an item that's
    /// already favorited. A diff/replace (built from the existing
    /// single-location `addLocation`/`removeLocation` primitives, additions
    /// applied before removals so the item is never transiently locationless),
    /// not an additive append — matching Android's "重新指定位置" semantics.
    /// Local-only: unlike add/remove, relocating never asks about Yamibo,
    /// since location membership has no server counterpart. No-ops (returns
    /// without writing) for an empty `locations` — callers must route an
    /// empty selection through the normal remove flow instead, since a
    /// favorite can never end up with zero locations.
    static func relocateFavorite(
        threadID: String,
        locations: [FavoriteLocation],
        localFavoriteLibraryStore: FavoriteLibraryStore
    ) async throws {
        let desiredLocations = Set(locations)
        guard !desiredLocations.isEmpty else { return }
        try await localFavoriteLibraryStore.update { document in
            guard let target = document.items.first(where: { $0.target.threadID == threadID })?.target else { return }
            let currentLocations = Set(document.items.first { $0.target.id == target.id }?.locations ?? [])
            for location in desiredLocations.subtracting(currentLocations) {
                document.addLocation(location, to: target)
            }
            for location in currentLocations.subtracting(desiredLocations) {
                document.removeLocation(location, from: target)
            }
        }
    }

    /// Pushes one existing favorite item to Yamibo (favorites item menu's
    /// "sync to Yamibo" action).
    static func pushFavoriteItemToYamibo(
        _ item: FavoriteItem,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        remoteRepository: any ForumThreadFavoriteRemoteOperating
    ) async throws -> RemotePushResult {
        guard let threadID = item.target.threadID else {
            throw FavoriteActionError.missingFavoriteThreadID
        }
        if normalizedRemoteFavoriteID(item.remoteMapping?.yamiboFavoriteID) != nil {
            return .synced
        }
        let remoteFavorite = try await remoteRepository.addThreadFavorite(
            threadID: threadID,
            formHash: nil,
            resolveRemoteFavorite: true
        )
        guard let remoteFavoriteID = normalizedRemoteFavoriteID(remoteFavorite?.remoteFavoriteID) else {
            return .syncedWithoutMapping
        }
        try await localFavoriteLibraryStore.update { document in
            document.updateRemoteMapping(for: item.target, yamiboFavoriteID: remoteFavoriteID, yamiboRemoteOrder: nil)
        }
        return .synced
    }

    // MARK: - Remembered sync choices

    /// Persists a remembered "sync new favorites to Yamibo?" choice: turns
    /// the add prompt off and records the picked default. The one shared
    /// write path for every entry point offering a remember variant (detail
    /// pages, thread reader, browsing history) and for the system settings
    /// UI's re-editable switches.
    static func rememberAddSyncChoice(_ syncToRemote: Bool, settingsStore: SettingsStore) async {
        do {
            _ = try await settingsStore.update { settings in
                settings.favorites.addSyncPromptEnabled = false
                settings.favorites.addSyncDefault = syncToRemote
            }
        } catch {
            YamiboLog.library.error("Failed to save remembered add-sync choice: \(error)")
        }
    }

    /// Same shared write path for the delete flow's "also remove from
    /// Yamibo?" remembered choice, including the favorites page's
    /// delete-everywhere prompt.
    static func rememberRemoveRemoteChoice(_ removeRemote: Bool, settingsStore: SettingsStore) async {
        do {
            _ = try await settingsStore.update { settings in
                settings.favorites.removeRemotePromptEnabled = false
                settings.favorites.removeRemoteDefault = removeRemote
            }
        } catch {
            YamiboLog.library.error("Failed to save remembered remove-remote choice: \(error)")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private static func upsertLocalFirstFavorite(
        _ favorite: Favorite,
        forumID: String?,
        forumName: String?,
        contentUpdatedAt: Date?,
        localTargetKindOverride: FavoriteItemTargetKind? = nil,
        locations: [FavoriteLocation]? = nil,
        boardReaderSettings: BoardReaderSettings,
        localFavoriteLibraryStore: FavoriteLibraryStore
    ) async throws -> FavoriteItem {
        let target: FavoriteItemTarget
        if let localTargetKindOverride {
            // Callers that already know the content's form (the browsing
            // history page: its rows carry the identity kind recorded at
            // read time) skip the fid-based classification below — a manga
            // history row has no fid to classify with, and re-deriving would
            // misfile it as `.normalThread`.
            target = FavoriteItemTarget(kind: localTargetKindOverride, threadID: favorite.threadID)
        } else {
            target = try localTarget(for: favorite, forumID: forumID, boardReaderSettings: boardReaderSettings)
        }
        return try await localFavoriteLibraryStore.update { document in
            let item = try FavoriteItem(
                target: target,
                title: favorite.title,
                displayName: favorite.displayName,
                forumID: forumID,
                forumName: forumName,
                contentUpdatedAt: contentUpdatedAt,
                locations: locations?.isEmpty == false ? locations! : [.category(document.defaultCategory.id)],
                tagIDs: favorite.tagIDs,
                createdAt: .now,
                updatedAt: .now
            )
            document.upsertItem(item)
            return item
        }
    }

    /// Classifies a favorite's target kind: `.novelThread` keeps its
    /// existing priority over board classification (a novel-type favorite
    /// never becomes a manga thread just because it happens to share a board
    /// id), then falls back to `.mangaThread` purely by the thread's board
    /// fid via `BoardReaderSettings.threadKind(forumID:)` — independent of
    /// that board's Smart Comic Mode bit (the bit only affects display
    /// grouping/routing, not classification). Kind is stamped at add time
    /// and never rewritten by later configuration changes. `forumID` is
    /// optional because not every call site can supply one (see
    /// `removeFavorite`, which looks up the stored target instead of relying
    /// on this classification when possible) — a missing/blank fid simply
    /// can't classify as manga.
    private static func localTarget(
        for favorite: Favorite,
        forumID: String?,
        boardReaderSettings: BoardReaderSettings
    ) throws -> FavoriteItemTarget {
        let kind: FavoriteItemTargetKind
        if favorite.type == .novel {
            kind = .novelThread
        } else if boardReaderSettings.threadKind(forumID: forumID) == .manga {
            kind = .mangaThread
        } else {
            kind = .normalThread
        }
        return FavoriteItemTarget(kind: kind, threadID: favorite.threadID)
    }

    private static func normalizedRemoteFavoriteID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Pending "also delete from Yamibo?" question raised by a remove action.
struct FavoriteRemovePrompt: Identifiable, Equatable, Sendable {
    let favorite: Favorite
    var id: String { favorite.threadID }
}

extension FavoriteQuickActions.RemotePushResult {
    /// Snackbar copy for the three-state add feedback.
    var addFeedbackMessage: String {
        switch self {
        case .notAttempted:
            L10n.string("favorites.quick.added_local")
        case .synced:
            L10n.string("favorites.quick.added_synced")
        case .syncedWithoutMapping:
            L10n.string("favorites.quick.added_synced_pending")
        case let .failed(reason):
            L10n.string("favorites.quick.added_sync_failed", reason)
        }
    }
}

/// Whether adding this favorite should ask about (or silently perform) the
/// Yamibo push, resolved from the user's remembered choice.
enum FavoriteAddSyncDecision: Equatable, Sendable {
    case prompt
    case silent(syncToRemote: Bool)

    static func resolve(settings: FavoriteLibrarySettings, canSyncRemote: Bool) -> FavoriteAddSyncDecision {
        guard canSyncRemote else { return .silent(syncToRemote: false) }
        return settings.addSyncPromptEnabled ? .prompt : .silent(syncToRemote: settings.addSyncDefault)
    }
}

/// Same resolution for the delete flow's "also remove from Yamibo" question.
enum FavoriteRemoveRemoteDecision: Equatable, Sendable {
    case prompt
    case silent(removeRemote: Bool)

    static func resolve(settings: FavoriteLibrarySettings, canRemoveRemote: Bool) -> FavoriteRemoveRemoteDecision {
        guard canRemoveRemote else { return .silent(removeRemote: false) }
        return settings.removeRemotePromptEnabled ? .prompt : .silent(removeRemote: settings.removeRemoteDefault)
    }
}

/// Thread-favorite conversion shared by every favorite entry point (detail
/// pages, thread reader, reader cache sheets).
extension FavoriteItem {
    func favorite(type: FavoriteType) -> Favorite {
        guard let threadID = target.threadID else {
            preconditionFailure("Thread favorite conversion requires thread target")
        }
        return Favorite(
            id: id,
            title: title,
            displayName: displayName,
            threadID: threadID,
            remoteFavoriteID: remoteMapping?.yamiboFavoriteID,
            type: type,
            tagIDs: tagIDs
        )
    }
}
