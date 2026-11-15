import Observation
import YamiboXCore

@MainActor
@Observable
final class NovelReaderSessionState {
    let model: NovelReaderViewModel
    let annotations: NovelReaderAnnotationCoordinator
    let searchHighlightController = NovelReaderSearchHighlightController()
    var chromeState: NovelReaderChromeState
    var presentedSheet: NovelReaderPresentedSheet?
    var forumThreadOverlayItem: ForumThreadOverlayItem?
    var imageBrowserItem: ImageBrowserItem?
    var chapterCommentsTarget: ReaderChapterCommentTarget?
    var chapterCommentsHasLaterChapter = false
    var searchPresentation: NovelReaderSearchPresentation?
    var readerLibraryTab: ReaderLibraryPanelTab = .bookmarks
    var isDismissing = false
    var isOfflineBannerDismissed = false
    var isFontBannerDismissed = false

    @ObservationIgnored private var annotationObservation: Task<Void, Never>?

    init(model: NovelReaderViewModel, dependencies: NovelReaderDependencies) {
        self.model = model
        chromeState = NovelReaderChromeState(showsChrome: model.settings.readingMode != .vertical)
        annotations = NovelReaderAnnotationCoordinator(
            model: model, dependencies: dependencies.like, imagePipeline: dependencies.imagePipeline
        )
    }

    deinit { annotationObservation?.cancel() }

    func observeAnnotationsIfNeeded() {
        guard annotationObservation == nil else { return }
        annotations.configure()
        annotationObservation = Task { [annotations] in
            await annotations.observeChanges()
        }
    }

    func end() {
        annotationObservation?.cancel()
        annotationObservation = nil
    }
}
