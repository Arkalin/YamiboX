import Foundation

public struct NovelReaderPresentation: Hashable, Sendable {
    public var generation: UInt64
    public var revision: UInt64
    public var surfaces: [NovelReaderSurface]
    public var selectedSurfaceIdentity: NovelReaderSurfaceIdentity?
    public var selectedSurfaceIndex: Int?
    public var spreads: [NovelReaderPresentationSpread]
    public var chapters: [NovelReaderChapter]
    public var committedSettings: NovelReaderAppearanceSettings
    public var readingState: NovelReaderReadingState
    public var pageLoadSource: NovelReaderProjectionLoadSource
    public var retainedChapterCount: Int
    public var filteredChapterCandidateCount: Int
    public var progressProjection: NovelReaderProgressProjection

    public init(
        generation: UInt64,
        revision: UInt64,
        surfaces: [NovelReaderSurface],
        selectedSurfaceIdentity: NovelReaderSurfaceIdentity?,
        spreads: [NovelReaderPresentationSpread],
        chapters: [NovelReaderChapter] = [],
        committedSettings: NovelReaderAppearanceSettings,
        readingState: NovelReaderReadingState,
        pageLoadSource: NovelReaderProjectionLoadSource = .online,
        retainedChapterCount: Int,
        filteredChapterCandidateCount: Int,
        selectedSurfaceIndex: Int? = nil,
        progressProjection: NovelReaderProgressProjection? = nil,
        usesTwoPageSpread: Bool = false
    ) {
        let resolvedSelectedSurfaceIndex = selectedSurfaceIndex ?? Self.surfaceIndex(
            for: selectedSurfaceIdentity,
            in: surfaces,
            generation: generation
        )
        self.generation = generation
        self.revision = revision
        self.surfaces = surfaces
        self.selectedSurfaceIdentity = selectedSurfaceIdentity
        self.selectedSurfaceIndex = resolvedSelectedSurfaceIndex
        self.spreads = spreads
        self.chapters = chapters
        self.committedSettings = committedSettings
        self.readingState = readingState
        self.pageLoadSource = pageLoadSource
        self.retainedChapterCount = max(0, retainedChapterCount)
        self.filteredChapterCandidateCount = max(0, filteredChapterCandidateCount)
        self.progressProjection = progressProjection ?? NovelReaderProgressProjection(
            readingMode: committedSettings.readingMode,
            usesTwoPageSpread: usesTwoPageSpread,
            pageTurnDirection: committedSettings.pageTurnDirection,
            surfaces: surfaces,
            selectedSurfaceIndex: resolvedSelectedSurfaceIndex ?? 0,
            spreads: spreads,
            readingState: readingState
        )
    }

    public func surfaceIndex(for identity: NovelReaderSurfaceIdentity) -> Int? {
        Self.surfaceIndex(for: identity, in: surfaces, generation: generation)
    }

    private static func surfaceIndex(
        for identity: NovelReaderSurfaceIdentity?,
        in surfaces: [NovelReaderSurface],
        generation: UInt64
    ) -> Int? {
        guard let identity,
              identity.generation == generation,
              surfaces.indices.contains(identity.ordinal),
              surfaces[identity.ordinal].identity == identity else {
            return nil
        }
        return surfaces[identity.ordinal].presentationIndex
    }
}
