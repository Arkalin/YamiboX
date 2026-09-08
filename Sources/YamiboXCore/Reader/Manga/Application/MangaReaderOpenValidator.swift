import Foundation

public enum MangaReaderOpenError: LocalizedError, Equatable, Sendable {
    case noReadableImages

    public var errorDescription: String? { L10n.string("manga.open.no_readable_images") }
}

/// Uses the reader's real author-scoped projection pipeline, including offline caches.
public struct MangaReaderOpenValidator: Sendable {
    private let loadProjection: @Sendable (MangaReaderProjectionRequest) async throws -> MangaReaderProjection

    public init(loadProjection: @escaping @Sendable (MangaReaderProjectionRequest) async throws -> MangaReaderProjection) {
        self.loadProjection = loadProjection
    }

    public func validate(_ context: MangaLaunchContext) async throws -> MangaReaderProjection {
        do {
            let projection = try await loadProjection(MangaReaderProjectionRequest(
                threadID: context.chapterTID,
                view: context.chapterView,
                offlineOwnerName: context.directoryName
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
