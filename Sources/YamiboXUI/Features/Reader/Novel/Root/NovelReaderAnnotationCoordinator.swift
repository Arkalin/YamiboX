import Observation
import UIKit
import YamiboXCore

/// Session-scoped annotation state and operations. The view forwards viewport
/// events and handles presentation; persistence remains in the Core service.
@MainActor
@Observable
final class NovelReaderAnnotationCoordinator {
    let selectionController = NovelTextSelectionController()
    let highlightController = NovelLikeHighlightController()
    let operations = AnnotationOperationState()
    private(set) var likedImageAnchors: Set<NovelImageLikeAnchor> = []
    private(set) var capsule = ReaderAnnotationCapsulePresentation(bookmarkCount: 0, likeCount: 0)
    private(set) var isCurrentPositionBookmarked = false
    var noteToEdit: LikeItem?
    private var rememberedSegment: ReaderAnnotationSegment?

    private let model: NovelReaderViewModel
    private let dependencies: LikeDependencies
    private let imagePipeline: any YamiboImageDataLoading
    private let workKey: ReadingWorkKey
    @ObservationIgnored private lazy var feedback = UINotificationFeedbackGenerator()
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var refreshRevision: UInt64 = 0
    @ObservationIgnored private var positionRevision: UInt64 = 0

    init(model: NovelReaderViewModel, dependencies: LikeDependencies, imagePipeline: any YamiboImageDataLoading) {
        self.model = model
        self.dependencies = dependencies
        self.imagePipeline = imagePipeline
        workKey = .novel(threadID: model.context.threadID)
    }

    var selectedSegment: ReaderAnnotationSegment {
        get { rememberedSegment ?? capsule.initialSegment(remembering: nil) }
        set { rememberedSegment = newValue }
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        selectionController.configureNoteEditor { [weak self] item in
            self?.noteToEdit = item
        }
        selectionController.configureLikeCapture(
            workKey: workKey,
            service: NovelTextLikeCaptureService(likeStore: dependencies.likeStore),
            onLikeActionVisible: { [weak self] in self?.feedback.prepare() },
            onFailure: operations.report,
            onCaptured: { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case let .added(item), let .merged(item), let .alreadyLiked(item):
                    highlightController.applyCapturedItem(item)
                }
                feedback.notificationOccurred(.success)
                Task { await self.refresh() }
            }
        )
        highlightController.configure(
            workKey: workKey,
            likeStore: dependencies.likeStore,
            annotations: dependencies.annotations,
            onFailure: operations.report
        )
    }

    /// Structured subscriptions end with the reader's appearance-scoped task.
    /// Subscribe before reading so a concurrent edit cannot fall into a gap.
    func observeChanges() async {
        let likeChanges = dependencies.likeStore.changes()
        let bookmarkChanges = dependencies.bookmarkStore.changes()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                for await _ in likeChanges {
                    guard !Task.isCancelled else { return }
                    await refresh()
                    await resolveChapterTitles()
                }
            }
            group.addTask { [self] in
                for await _ in bookmarkChanges {
                    guard !Task.isCancelled else { return }
                    await refresh()
                }
            }
            await refresh()
            await group.waitForAll()
        }
    }

    func refresh() async {
        refreshRevision &+= 1
        let revision = refreshRevision
        guard let (bookmarkCount, likes) = await operations.perform({
            let bookmarkCount = try await dependencies.bookmarkStore.count(for: workKey)
            let likes = try await dependencies.likeStore.likes(for: workKey)
            return (bookmarkCount, likes)
        }), !Task.isCancelled, revision == refreshRevision else { return }
        capsule = ReaderAnnotationCapsulePresentation(bookmarkCount: bookmarkCount, likeCount: likes.count)
        likedImageAnchors = Set(likes.compactMap { item in
            guard item.kind == .image, case let .novelImage(anchor) = item.anchor else { return nil }
            return anchor
        })
        await refreshPosition()
    }

    func refreshPosition() async {
        positionRevision &+= 1
        let revision = positionRevision
        guard let anchor = currentBookmarkAnchor else {
            isCurrentPositionBookmarked = false
            return
        }
        guard let isBookmarked = await operations.perform({
            try await dependencies.bookmarkStore.bookmark(marking: .novel(anchor), in: workKey) != nil
        }), !Task.isCancelled, revision == positionRevision,
              currentBookmarkAnchor == anchor else { return }
        isCurrentPositionBookmarked = isBookmarked
    }

    /// The view synchronizes its vertical viewport immediately before this call.
    func toggleBookmark() {
        guard let anchor = currentBookmarkAnchor else { return }
        let excerpt = model.previewText(
            translationMode: model.settings.translationMode, characterCount: 40, fallback: ""
        )
        feedback.prepare()
        Task {
            guard let outcome = await operations.perform({
                try await dependencies.annotations.toggleBookmark(
                    work: workKey, anchor: .novel(anchor), excerptText: excerpt.isEmpty ? nil : excerpt
                )
            }) else { return }
            if currentBookmarkAnchor == anchor {
                isCurrentPositionBookmarked = outcome.isBookmarked
            }
            feedback.notificationOccurred(.success)
            await refresh()
        }
    }

    func toggleImage(_ anchor: NovelImageLikeAnchor, imageURL: URL, chapterTitle: String?) {
        feedback.prepare()
        let source = YamiboImageSource(
            url: imageURL, refererPageURL: model.forumURL, offlineScope: model.inlineImageOfflineScope
        )
        Task {
            guard await operations.perform({
                try await dependencies.annotations.toggleImage(
                    work: workKey, anchor: .novel(anchor), sourceImageURL: imageURL,
                    chapterTitle: chapterTitle,
                    imageData: { [imagePipeline] in try await imagePipeline.data(for: source) }
                )
            }) != nil else { return }
            feedback.notificationOccurred(.success)
        }
    }

    func saveNote(for item: LikeItem, note: String?) async {
        await operations.perform {
            try await dependencies.annotations.updateNote(id: item.id, note: note)
        }
    }

    func resolveSortKeys() async {
        await resolveChapterTitles()
        let ordinals = model.currentChapterOrdinalsByIdentity
        guard !ordinals.isEmpty else { return }
        await dependencies.likeStore.resolveChapterOrdinals(ordinals, for: workKey)
    }

    private func resolveChapterTitles() async {
        await dependencies.backfillNovelChapterTitles(in: model.loadedProjectionSnapshots)
    }

    private var currentBookmarkAnchor: NovelBookmarkAnchor? {
        guard let point = model.currentNovelResumePoint else { return nil }
        return NovelBookmarkAnchor(
            chapterIdentity: point.chapterIdentity, textSegmentIdentity: point.textSegmentIdentity,
            displayedTextOffset: point.displayedTextOffset, view: point.view,
            chapterOrdinal: point.chapterOrdinal, chapterTitle: point.chapterTitle,
            resolvedAuthorID: point.authorID
        )
    }

    func resumePoint(for item: BookmarkItem) -> NovelResumePoint? {
        guard case let .novel(anchor) = item.anchor else { return nil }
        return NovelResumePoint(
            view: anchor.view, chapterIdentity: anchor.chapterIdentity,
            textSegmentIdentity: anchor.textSegmentIdentity, displayedTextOffset: anchor.displayedTextOffset,
            chapterOrdinal: anchor.chapterOrdinal, chapterTitle: anchor.chapterTitle,
            segmentProgress: 0, authorID: anchor.resolvedAuthorID, readingModeHint: model.settings.readingMode
        )
    }

    func resumePoint(for payload: LikeAnchorPayload) -> NovelResumePoint? {
        // Like anchors carry semantic positions but not cosmetic resume fields.
        switch payload {
        case let .novelText(anchor):
            NovelResumePoint(
                view: anchor.view, chapterIdentity: anchor.chapterIdentity,
                textSegmentIdentity: anchor.startSegmentIdentity, displayedTextOffset: anchor.start.offset,
                chapterOrdinal: 0, segmentProgress: 0, authorID: anchor.resolvedAuthorID,
                readingModeHint: model.settings.readingMode
            )
        case let .novelImage(anchor):
            NovelResumePoint(
                view: anchor.view, chapterIdentity: anchor.chapterIdentity,
                textSegmentIdentity: NovelTextSegmentIdentity(rawValue: anchor.imageSegmentIdentity),
                displayedTextOffset: 0, chapterOrdinal: 0, segmentProgress: 0,
                authorID: anchor.resolvedAuthorID, readingModeHint: model.settings.readingMode
            )
        case .mangaImage:
            nil
        }
    }
}
