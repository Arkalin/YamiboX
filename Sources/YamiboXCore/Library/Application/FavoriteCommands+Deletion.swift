import Foundation

public struct FavoriteDeletionRequest: Sendable {
    public enum Scope: Sendable {
        case currentLocation(FavoriteLocation)
        case everywhere(removeRemote: Bool)
    }

    public let favoriteIDs: Set<String>
    public let collectionIDs: Set<String>
    public let scope: Scope

    public init(favoriteIDs: Set<String>, collectionIDs: Set<String> = [], scope: Scope) {
        self.favoriteIDs = favoriteIDs
        self.collectionIDs = collectionIDs
        self.scope = scope
    }
}

extension FavoriteCommands {
    /// Organizer deletion tolerates missing remote favorites and parsing failures.
    /// Other remote errors abort the local batch, but cannot undo earlier remote
    /// deletions. Only the local mutations form an atomic transaction.
    public static func deleteFavorites(
        _ request: FavoriteDeletionRequest,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws -> FavoriteLibraryDocument {
        let snapshot = try await localFavoriteLibraryStore.load()
        let items = snapshot.items.filter { request.favoriteIDs.contains($0.id) }
        return try await executeDeletion(
            request, items: items, requiringItemID: nil,
            localFavoriteLibraryStore: localFavoriteLibraryStore,
            makeRemoteRepository: makeRemoteRepository
        )
    }

    /// Uses the organizer's deletion policy, not the stricter quick remove policy.
    /// A missing item returns nil without writing or posting a store change.
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

    private static func executeDeletion(
        _ request: FavoriteDeletionRequest,
        items: [FavoriteItem],
        requiringItemID: String?,
        localFavoriteLibraryStore: FavoriteLibraryStore,
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws -> FavoriteLibraryDocument {
        try Task.checkCancellation()
        if case .everywhere(removeRemote: true) = request.scope {
            try await deleteRemoteCounterparts(of: items, makeRemoteRepository: makeRemoteRepository)
        }
        try Task.checkCancellation()
        // Only the selected identities cross the network wait. All edits are
        // applied to the latest document inside the store's transaction.
        return try await localFavoriteLibraryStore.update { document in
            if let requiringItemID,
               !document.items.contains(where: { $0.id == requiringItemID }) {
                throw DeletedItemAbsent()
            }
            switch request.scope {
            case .currentLocation(let location):
                document.removeItems(ids: Set(items.map(\.id)), from: location)
            case .everywhere:
                for item in items {
                    document.removeItem(target: item.target)
                }
                for collectionID in request.collectionIDs {
                    document.dissolveCollection(id: collectionID)
                }
            }
            return document
        }
    }

    private static func deleteRemoteCounterparts(
        of items: [FavoriteItem],
        makeRemoteRepository: @Sendable () async -> any ForumThreadFavoriteRemoteOperating
    ) async throws {
        let candidates = items.filter(\.hasYamiboRemoteCandidate)
        guard !candidates.isEmpty else { return }
        let repository = await makeRemoteRepository()
        for item in candidates {
            try Task.checkCancellation()
            do {
                let id = try await deletionRemoteID(for: item, repository: repository)
                try Task.checkCancellation()
                try await repository.deleteFavorite(remoteFavoriteID: id)
            } catch FavoriteActionError.missingFavoriteDeleteID {
                continue
            } catch YamiboError.parsingFailed {
                YamiboLog.sync.warning("Failed to resolve remote favorite id for thread \(item.target.threadID ?? "?", privacy: .public) during batch delete, skipping remote delete for this item")
                continue
            }
        }
    }

    private static func deletionRemoteID(
        for item: FavoriteItem,
        repository: any ForumThreadFavoriteRemoteOperating
    ) async throws -> String {
        if let id = item.remoteMapping?.yamiboFavoriteID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        guard let threadID = item.target.threadID,
              let favorite = try await repository.remoteFavorite(forThreadID: threadID, maxPages: 30),
              let id = favorite.remoteFavoriteID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw FavoriteActionError.missingFavoriteDeleteID
        }
        return id
    }
}
