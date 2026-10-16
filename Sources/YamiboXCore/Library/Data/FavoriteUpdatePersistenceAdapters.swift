import Foundation

extension FavoriteUpdateStore: FavoriteUpdateStatePersisting {}

extension FavoriteLibraryStore: FavoriteUpdateLibraryAccessing {
    public func recordContentUpdate(for target: FavoriteItemTarget, contentUpdatedAt: Date) async throws {
        let document = try await load()
        guard document.items.contains(where: {
            $0.target == target && ($0.contentUpdatedAt.map { $0 < contentUpdatedAt } ?? true)
        }) else { return }
        try await update { document in
            document.recordContentUpdate(for: target, contentUpdatedAt: contentUpdatedAt)
        }
    }

    public func healUnknownSourceGroup(for target: FavoriteItemTarget, forumID: String, forumName: String?) async throws {
        try await update { document in
            document.healUnknownSourceGroup(for: target, forumID: forumID, forumName: forumName)
        }
    }
}
