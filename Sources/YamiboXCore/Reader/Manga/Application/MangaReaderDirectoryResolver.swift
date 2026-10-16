import Foundation

public enum MangaReaderDirectoryResolutionError: LocalizedError, Equatable, Sendable {
    case ambiguousOwnership

    public var errorDescription: String? { L10n.string("manga.open.ambiguous_ownership") }
}

/// Resolves the same stable download owner for validation, details and reading.
public enum MangaReaderDirectoryResolver {
    public static func resolve(
        context: MangaLaunchContext,
        store: any MangaDirectoryPersisting,
        downloadStore: (any MangaDownloadStoring)?
    ) async throws -> MangaDirectoryID? {
        if let id = context.directoryID {
            return try await store.directory(id: id)?.id ?? id
        }
        let directoryIDs = try await store.directoryIDs(containingTID: context.chapterTID)
        guard directoryIDs.count <= 1 else {
            throw MangaReaderDirectoryResolutionError.ambiguousOwnership
        }
        if let id = directoryIDs.first { return id }
        let memberships = await downloadStore?.mangaOfflineMembershipCandidates(for: MangaReaderProjectionRequest(
            threadID: context.chapterTID, view: context.chapterView
        )) ?? []
        guard memberships.count <= 1 else {
            throw MangaReaderDirectoryResolutionError.ambiguousOwnership
        }
        return memberships.first.map { MangaDirectoryID(rawValue: $0.ownerName) }
    }
}
