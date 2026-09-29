import Foundation

public enum MangaReaderOpenError: LocalizedError, Equatable, Sendable {
    case noReadableImages

    public var errorDescription: String? { L10n.string("manga.open.no_readable_images") }
}

/// Uses the reader's real author-scoped projection pipeline, including downloads.
public struct MangaReaderOpenValidator: Sendable {
    private let loadProjection: @Sendable (MangaReaderProjectionRequest) async throws -> MangaReaderProjection
    private let resolveDirectoryID: @Sendable (MangaLaunchContext) async throws -> MangaDirectoryID?

    public init(
        resolveDirectoryID: @escaping @Sendable (MangaLaunchContext) async throws -> MangaDirectoryID? = { $0.directoryID },
        loadProjection: @escaping @Sendable (MangaReaderProjectionRequest) async throws -> MangaReaderProjection
    ) {
        self.resolveDirectoryID = resolveDirectoryID
        self.loadProjection = loadProjection
    }

    public func validate(_ context: MangaLaunchContext) async throws -> MangaReaderProjection {
        do {
            let directoryID = try await resolveDirectoryID(context)
            let projection = try await loadProjection(MangaReaderProjectionRequest(
                threadID: context.chapterTID,
                view: context.chapterView,
                offlineOwnerName: directoryID?.rawValue
            ))
            try Task.checkCancellation()
            guard !projection.imageURLs.isEmpty else { throw MangaReaderOpenError.noReadableImages }
            return projection
        } catch {
            if LoadDiagnosticError.classificationError(error) as? YamiboError == MangaReaderDataSupport.currentMangaChapterParsingFailure() {
                throw MangaReaderOpenError.noReadableImages
            }
            throw error
        }
    }
}
