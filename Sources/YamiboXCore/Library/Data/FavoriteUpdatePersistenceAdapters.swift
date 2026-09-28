import Foundation

extension FavoriteUpdateStore: FavoriteUpdateStatePersisting {}

extension FavoriteLibraryStore: FavoriteUpdateLibraryAccessing {
    public func healUnknownSourceGroup(for target: FavoriteItemTarget, forumID: String, forumName: String?) async throws {
        try await update { document in
            document.healUnknownSourceGroup(for: target, forumID: forumID, forumName: forumName)
        }
    }
}
