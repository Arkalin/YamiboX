import Foundation

public struct FavoriteDeletionRequest: Sendable {
    public enum Scope: Sendable {
        case currentLocation(FavoriteLocation)
        case everywhere(removeRemote: Bool)
    }

    public let favoriteIDs: Set<String>
    public let collectionIDs: Set<String>
    public let scope: Scope
    let confirmedItems: Set<FavoriteItem>?
    let confirmedCollections: Set<LocalFavoriteCollection>?

    public init(
        favoriteIDs: Set<String>,
        collectionIDs: Set<String> = [],
        scope: Scope,
        confirmedItems: Set<FavoriteItem>? = nil,
        confirmedCollections: Set<LocalFavoriteCollection>? = nil
    ) {
        self.favoriteIDs = favoriteIDs
        self.collectionIDs = collectionIDs
        self.scope = scope
        self.confirmedItems = confirmedItems
        self.confirmedCollections = confirmedCollections
    }
}

public struct FavoriteDeletionInterruption: LocalizedError, Sendable {
    public let confirmedRemoteRemovalCount: Int
    public let hasUnconfirmedRemoteResult: Bool
    public let underlying: any Error

    public var errorDescription: String? {
        if hasUnconfirmedRemoteResult {
            return confirmedRemoteRemovalCount == 0
                ? L10n.string("favorites.bulk_delete_remote_unconfirmed")
                : L10n.string("favorites.bulk_delete_remote_partial_unconfirmed", confirmedRemoteRemovalCount)
        }
        return L10n.string("favorites.bulk_delete_remote_partial", confirmedRemoteRemovalCount)
    }
}

extension FavoriteCommands {
    public static func deleteFavorites(
        _ request: FavoriteDeletionRequest,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws -> FavoriteLibraryDocument {
        let snapshot = try await localFavoriteLibraryStore.load()
        let items = snapshot.items.filter { request.favoriteIDs.contains($0.id) }
        try validateSelection(request, in: snapshot)
        return try await executeDeletion(
            request, items: items, requiringItemID: nil,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            makeRemoteRepository: makeRemoteRepository
        )
    }

    public static func deleteFavorite(
        id: String,
        scope: FavoriteDeletionRequest.Scope,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws -> FavoriteLibraryDocument? {
        let snapshot = try await localFavoriteLibraryStore.load()
        guard let item = snapshot.items.first(where: { $0.id == id }) else { return nil }
        do {
            return try await executeDeletion(
                FavoriteDeletionRequest(favoriteIDs: [id], scope: scope),
                items: [item], requiringItemID: id,
                localFavoriteLibraryStore: localFavoriteLibraryStore,
                makeRemoteRepository: makeRemoteRepository
            )
        } catch is DeletedItemAbsent {
            return nil
        }
    }

    private struct DeletedItemAbsent: Error {}

    private static func validateSelection(
        _ request: FavoriteDeletionRequest,
        in document: FavoriteLibraryDocument
    ) throws {
        if let expected = request.confirmedItems,
           Set(document.items.filter({ request.favoriteIDs.contains($0.id) })) != expected {
            throw YamiboPersistenceError(context: L10n.string("favorites.bulk_delete_selection_changed"))
        }
        if let expected = request.confirmedCollections,
           Set(document.collections.filter({ request.collectionIDs.contains($0.id) })) != expected {
            throw YamiboPersistenceError(context: L10n.string("favorites.bulk_delete_selection_changed"))
        }
    }

    private static func executeDeletion(
        _ request: FavoriteDeletionRequest,
        items: [FavoriteItem],
        requiringItemID: String?,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws -> FavoriteLibraryDocument {
        var progress = RemoteDeletionProgress()
        do {
            try Task.checkCancellation()
            if case .everywhere(removeRemote: true) = request.scope {
                try await deleteRemoteCounterparts(
                    of: items, makeRemoteRepository: makeRemoteRepository, progress: &progress
                ) {
                    guard request.confirmedItems != nil || request.confirmedCollections != nil else { return }
                    try validateSelection(request, in: await localFavoriteLibraryStore.load())
                }
            }
            try Task.checkCancellation()
            return try await localFavoriteLibraryStore.update { document in
                try validateSelection(request, in: document)
                if let requiringItemID,
                   !document.items.contains(where: { $0.id == requiringItemID }) {
                    throw DeletedItemAbsent()
                }
                switch request.scope {
                case .currentLocation(let location):
                    document.removeItems(ids: Set(items.map(\.id)), from: location)
                case .everywhere:
                    document.removeItems(targets: items.map(\.target))
                    document.dissolveCollections(ids: Array(request.collectionIDs))
                }
                return document
            }
        } catch {
            guard progress.confirmedCount > 0 || progress.hasUnconfirmedResult else { throw error }
            throw FavoriteDeletionInterruption(
                confirmedRemoteRemovalCount: progress.confirmedCount,
                hasUnconfirmedRemoteResult: progress.hasUnconfirmedResult,
                underlying: error
            )
        }
    }

    private struct RemoteDeletionProgress {
        var confirmedCount = 0
        var hasUnconfirmedResult = false
    }

    private static func deleteRemoteCounterparts(
        of items: [FavoriteItem],
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating,
        progress: inout RemoteDeletionProgress,
        beforeDeleting: @Sendable () async throws -> Void
    ) async throws {
        let candidates = items.filter(\.hasYamiboRemoteCandidate)
        guard !candidates.isEmpty else { return }
        let repository = await makeRemoteRepository()
        var resolvedIDs: [String] = []
        var seenIDs: Set<String> = []
        for item in candidates {
            try Task.checkCancellation()
            if let id = try await deletionRemoteID(for: item, repository: repository),
               seenIDs.insert(id).inserted {
                resolvedIDs.append(id)
            }
        }
        for id in resolvedIDs {
            try await beforeDeleting()
            try Task.checkCancellation()
            progress.hasUnconfirmedResult = true
            do {
                try await repository.deleteFavorite(remoteFavoriteID: id)
                progress.hasUnconfirmedResult = false
                progress.confirmedCount += 1
            } catch let error as FavoriteActionError
                where error == .missingFavoriteDeleteID || error == .missingFavoriteDeleteToken {
                progress.hasUnconfirmedResult = false
                throw error
            }
        }
    }

    private static func deletionRemoteID(
        for item: FavoriteItem,
        repository: any ForumThreadFavoriteRemoteOperating
    ) async throws -> String? {
        if let id = FavoriteRemoteIdentity.normalizedID(item.remoteMapping?.yamiboFavoriteID) {
            return id
        }
        guard let favorite = try await repository.remoteFavorite(forThreadID: item.target.threadID, maxPages: 30) else {
            return nil
        }
        guard let id = FavoriteRemoteIdentity.normalizedID(favorite.remoteFavoriteID) else {
            throw FavoriteActionError.missingFavoriteDeleteID
        }
        return id
    }
}
