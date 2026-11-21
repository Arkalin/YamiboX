import Foundation

public enum FavoriteCommands {
    public enum RemotePushResult: Equatable, Sendable {
        case notAttempted
        case synced
        case syncedWithoutMapping
        case failed(String)
    }

    public struct AddResult: Sendable {
        public var favorite: Favorite
        public var remote: RemotePushResult
        public var failureDetails: LoadFailureDetails? = nil
    }

    public static func addFavorite(
        threadID: String,
        title: String,
        type: FavoriteType,
        authorID: String?,
        forumID: String? = nil,
        forumName: String? = nil,
        contentUpdatedAt: Date? = nil,
        localTargetKindOverride: FavoriteItemTargetKind? = nil,
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
            let remoteFavoriteID = normalizedRemoteFavoriteID(remoteFavorite?.remoteFavoriteID)
            try await localFavoriteLibraryStore.update { document in
                document.updateRemoteMapping(for: item.target, yamiboFavoriteID: remoteFavoriteID, yamiboRemoteOrder: nil)
            }
            var synced = item
            synced.remoteMapping = FavoriteRemoteMapping(yamiboFavoriteID: remoteFavoriteID, lastSeenAt: .now)
            return AddResult(favorite: synced.favorite(type: type), remote: remoteFavoriteID == nil ? .syncedWithoutMapping : .synced)
        } catch {
            if Task.isCancelled || LoadDiagnosticError.isCancellation(error) { throw CancellationError() }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AddResult(
                favorite: item.favorite(type: type), remote: .failed(message),
                failureDetails: LoadFailureDetails(error: error, requestContext: threadID)
            )
        }
    }

    public static func removeFavorite(
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
            let target = document.items.first { $0.target.threadID == favorite.threadID }?.target
                ?? (try? localTarget(for: favorite, forumID: nil, boardReaderSettings: boardReaderSettings))
            guard let target else { return }
            document.removeItem(target: target)
        }
    }

    public static func relocateFavorite(
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

    public static func pushFavoriteItemToYamibo(
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
        let remoteFavoriteID = normalizedRemoteFavoriteID(remoteFavorite?.remoteFavoriteID)
        try await localFavoriteLibraryStore.update { document in
            document.updateRemoteMapping(for: item.target, yamiboFavoriteID: remoteFavoriteID, yamiboRemoteOrder: nil)
        }
        return remoteFavoriteID == nil ? .syncedWithoutMapping : .synced
    }

    public static func rememberAddSyncChoice(_ syncToRemote: Bool, settingsStore: SettingsStore) async {
        do {
            _ = try await settingsStore.update { settings in
                settings.favorites.addSyncPromptEnabled = false
                settings.favorites.addSyncDefault = syncToRemote
            }
        } catch {
            YamiboLog.library.error("Failed to save remembered add-sync choice: \(error)")
        }
    }

    public static func rememberRemoveRemoteChoice(_ removeRemote: Bool, settingsStore: SettingsStore) async {
        do {
            _ = try await settingsStore.update { settings in
                settings.favorites.removeRemotePromptEnabled = false
                settings.favorites.removeRemoteDefault = removeRemote
            }
        } catch {
            YamiboLog.library.error("Failed to save remembered remove-remote choice: \(error)")
        }
    }

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
        FavoriteRemoteIdentity.normalizedID(value)
    }
}
