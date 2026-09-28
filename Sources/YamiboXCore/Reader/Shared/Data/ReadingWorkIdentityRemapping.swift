import Foundation

enum ReadingWorkIdentityRemapping {
    static func normalize(
        _ key: ReadingWorkKey,
        identities: MangaDirectoryIdentitySnapshot,
        legacy: Bool
    ) -> ReadingWorkKey {
        var result = key
        if key.kind == .manga { result.id = identities.resolve(key.id, legacy: legacy) }
        return result
    }
}
