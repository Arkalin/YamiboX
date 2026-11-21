import Foundation

enum FavoriteContentIdentityRemapping {
    static func normalize(
        _ target: FavoriteContentTarget,
        identities: MangaDirectoryIdentitySnapshot,
        legacy: Bool
    ) -> FavoriteContentTarget {
        guard case let .mangaTitle(id, name) = target else { return target }
        guard legacy || MangaDirectoryIdentityDatabase.isStableIdentity(id) else { return target }
        return .mangaTitle(mangaID: identities.resolve(id, name: name, legacy: legacy), cleanBookName: name)
    }
}
